-- Standard functions cached as locals: hot paths call them often.
local mathFloor = math.floor
local mathAbs = math.abs
local mathMax = math.max
local mathMin = math.min
local strFormat = string.format

Warfront = Warfront or {}

local WF = Warfront
local Contours = WF.AreaContours
local Map = {
  areas = {},
  order = {},
  groups = {},
  -- FIFO from buildHead to buildTail (see PushBuild); empty when head > tail.
  buildQueue = {},
  buildHead = 1,
  buildTail = 0,
  cache = {},
  cacheCount = 0,
  groupSerial = 0,
  revision = 0,
  dirty = true,
  enabled = true,
  visibleCount = 0,
  visiblePatches = 0,
  visibleIcons = 0,
  failures = 0,
  -- What the last world map refresh saw, kept after the map closes for /wfd map.
  probe = {},
}

WF.Map = Map

-- Shared with modules/map_routes.lua and modules/map_hover.lua, which load
-- next: each aliases what it uses and adds the functions map.lua calls back.
-- Keep every map file far below Lua 5.1's limit of 200 active locals
-- (.claude/forever-compatibility.md, Top-level local limit).
local Kit = {}
Map.Kit = Kit

Map.COLORS = {
  HORDE = { 0.90, 0.12, 0.08 },
  ALLIANCE = { 0.10, 0.42, 1.00 },
  RESOURCE = { 1.00, 0.78, 0.05 },
  NEUTRAL = { 0.72, 0.72, 0.72 },
}

Map.POI_TYPES = {
  OUTPOST = true,
  SETTLEMENT = true,
  FOREST = true,
  GOLD_MINE = true,
  FARM = true,
  CAPITAL = true,
  -- A secondary capturable objective feeding the Front Network (decision 0123).
  WAR_CAMP = true,
}

-- A faction capital (decisions 0103, 0107): never captured outside its siege,
-- always held by the faction of its zone. One per city, traced on the zone map
-- that shows the city; any other map refuses the definition.
Map.CAPITAL_FACTIONS = {
stormwindcity = "ALLIANCE",
ironforge = "ALLIANCE",
darnassus = "ALLIANCE",
orgrimmar = "HORDE",
undercity = "HORDE",
thunderbluff = "HORDE",
}

-- Resource POIs are harvested, never controlled: no faction owner (decision 0029).
Map.RESOURCE_TYPES = {
  FOREST = true,
  GOLD_MINE = true,
  FARM = true,
}

-- Every POI picture comes from one 512 x 512 RLE atlas of 72 px cells (this
-- client draws large uncompressed TGA atlases as diagonal bands). Active rows:
-- War Camp, Outpost, Settlement levels 1 to 3, resources, capital. Columns:
-- 0 neutral, 1 half Horde, 2 Horde, 3 half Alliance, 4 Alliance.
local POI_ICON_ATLAS = "Interface\\AddOns\\Warfront\\media\\Textures\\Icons\\MapPOIIconAtlas"
local POI_ICON_ATLAS_SIZE = 512
local POI_ICON_CELL = 72

-- First row of each type; a Settlement adds its level minus one.
Map.POI_ICON_ROWS = {
  WAR_CAMP = 0,
  OUTPOST = 1,
  SETTLEMENT = 2,
  CAPITAL = 6,
  GOLD_MINE = 5,
  FOREST = 5,
  FARM = 5,
}

-- Resource POIs have one permanent picture each, packed onto their shared row.
Map.POI_ICON_RESOURCE_COLUMNS = {
  GOLD_MINE = 0,
  FOREST = 1,
  FARM = 2,
}

Map.POI_ICON_STATES = { [0] = "neutral", [1] = "half_horde", [2] = "horde", [3] = "half_alliance", [4] = "alliance" }

-- Columns are capture states for controlled POIs.
Map.POI_ICON_COLUMNS = {
  HORDE = 2,
  ALLIANCE = 4,
}

-- Half-captured columns, shown while a challenger holds 50 % or more.
Map.POI_ICON_HALF_COLUMNS = {
  HORDE = 1,
  ALLIANCE = 3,
}

-- Texture path, coordinates (left, right, top, bottom) and pixel size of a
-- POI picture; level is a held Settlement's level. nil for an unknown type.
function Map.GetIcon(poiType, colorKey, column, level)
  local row = Map.POI_ICON_ROWS[poiType]
  if not row then return nil end
  if Map.RESOURCE_TYPES[poiType] then
    column = Map.POI_ICON_RESOURCE_COLUMNS[poiType] or 0
  else
    column = column or Map.POI_ICON_COLUMNS[colorKey or ""] or 0
    if not Map.POI_ICON_STATES[column] then column = 0 end
    if poiType == "SETTLEMENT" then row = row + mathMax(1, mathMin(3, level or 1)) - 1 end
  end
  local cell = POI_ICON_CELL / POI_ICON_ATLAS_SIZE
  local left, top = column * cell, row * cell
  return POI_ICON_ATLAS, left, left + cell, top, top + cell, POI_ICON_CELL, POI_ICON_CELL
end

-- Width and height of a picture of w x h pixels drawn in a square of `size`.
function Map.FitIcon(size, w, h)
  if not w or not h or w <= 0 or h <= 0 then return size, size end
  if w >= h then return size, size * h / w end
  return size * w / h, size
end

local PROFILE_TEXTURE =
  "Interface\\AddOns\\Warfront\\media\\Textures\\Map\\Contours\\AreaContourProfileStrong"
local PROFILE_ALPHA = 1.00
-- Hovering stacks a second copy of the area patches at this opacity on top of
-- the normal ones, which raises the fill from about 50 % to about 62 %.
local HOVER_ALPHA = 0.50
local HOVER_INTERVAL = 0.05
local POI_ICON_SIZE = 21.42
-- Types drawn at another size than POI_ICON_SIZE, as a size multiplier.
local POI_ICON_SCALE = {
  SETTLEMENT = 1.15,
  CAPITAL = 1.3,
}
local function IconSize(poiType)
  local preferences = WF.Preferences
  local scale = preferences and preferences:Get("mapIconScale") or 1
  return POI_ICON_SIZE * scale * (POI_ICON_SCALE[poiType] or 1)
end
-- Zoomed in, POI icons and their labels grow less than the map: their size
-- follows the zoom to `power` (0 = fixed on screen, 1 = grows with the map),
-- never below `min` of their unzoomed size. Map.iconZoom holds the factor.
Map.ICON_ZOOM = { power = 0.6, min = 0.55 }
Map.iconZoom = 1
-- Half-width of the icon hover square, as a share of the icon size (the art
-- leaves a transparent margin, so the full 0.5 would catch empty corners).
local ICON_HIT_RATIO = 0.4
local CACHE_LIMIT = 64
local REFRESH_INTERVAL = 0.25

local function GetGlobal(name)
  if WF.Compat and WF.Compat.Global then return WF.Compat.Global(name) end
  if _G then return _G[name] end
  return nil
end

-- Forever has GetMouseFoci (every region under the cursor, topmost first)
-- instead of GetMouseFocus. Returns a function giving the topmost region.
local function MouseFocusGetter()
  local getFoci = GetGlobal("GetMouseFoci")
  if type(getFoci) ~= "function" then return nil end
  return function()
    local foci = getFoci()
    if type(foci) == "table" then return foci[1] end
    return nil
  end
end

local function Clamp(value, minimum, maximum)
  if value < minimum then return minimum end
  if value > maximum then return maximum end
  return value
end

-- Map names are a small fixed set and this runs on every refresh and hover:
-- cache each result (false for a name with no key) instead of a gsub per call.
local canonicalNames = {}

local function CanonicalMapName(value)
  if type(value) ~= "string" then return nil end
  local cached = canonicalNames[value]
  if cached ~= nil then return cached or nil end
  local normalized = string.lower(string.gsub(value, "[^%w]", ""))
  if normalized == "" then normalized = false end
  canonicalNames[value] = normalized
  return normalized or nil
end

Map.CanonicalMapName = CanonicalMapName

-- Forever uiMapIDs for the fixed catalog zone keys. OpenMap's stitched canvas
-- can use any map beneath the visible view, so every POI needs its source ID.
local FOREVER_ZONE_IDS = {}
do
  local keys = WF.Compat and WF.Compat.MAP_KEYS or {}
  for mapID, name in pairs(keys) do
    local key = CanonicalMapName(name)
    if key then FOREVER_ZONE_IDS[key] = mapID end
  end
end

local function CopyLocations(locations)
  if type(locations) ~= "table" then
    return nil, "locations must be a table"
  end

  local output = {}
  local index = 1
  local total = #locations
  while index <= total do
    local location = locations[index]
    local x = location and (location.x or location[1])
    local y = location and (location.y or location[2])
    if type(x) ~= "number" or type(y) ~= "number"
        or x < 0 or x > 100 or y < 0 or y > 100 then
      return nil, "each location needs numeric x/y coordinates from 0 to 100"
    end
    output[#output + 1] = { x = x, y = y }
    index = index + 1
  end

  if #output == 0 then
    return nil, "at least one location is required"
  end
  return output
end

local function ResolveColor(value)
  if type(value) == "string" then
    local preset = Map.COLORS[string.upper(value)]
    if preset then return { preset[1], preset[2], preset[3] } end
    return nil, "unknown color preset"
  end
  if type(value) ~= "table" then
    return nil, "color must be HORDE, ALLIANCE, RESOURCE, NEUTRAL, or an RGB table"
  end
  local red = value.r or value[1]
  local green = value.g or value[2]
  local blue = value.b or value[3]
  if type(red) ~= "number" or type(green) ~= "number" or type(blue) ~= "number" then
    return nil, "custom color needs numeric red, green, and blue values"
  end
  return {
    Clamp(red, 0, 1), Clamp(green, 0, 1), Clamp(blue, 0, 1),
  }
end

local function NormalizeDefinition(definition)
  if type(definition) ~= "table" then
    return nil, "area definition must be a table"
  end
  if type(definition.id) ~= "string" or definition.id == "" then
    return nil, "area id must be a non-empty string"
  end
  local mapName = definition.map or definition.mapFile or definition.zone
  local mapKey = CanonicalMapName(mapName)
  if not mapKey then
    return nil, "map must be a non-empty zone map name"
  end

  local poiType = definition.type
  if type(poiType) ~= "string" or not Map.POI_TYPES[poiType] then
    return nil, "type must be OUTPOST, SETTLEMENT, WAR_CAMP, FOREST, GOLD_MINE, FARM, or CAPITAL"
  end
  local capitalFaction = nil
  if poiType == "CAPITAL" then
    capitalFaction = Map.CAPITAL_FACTIONS[mapKey]
if not capitalFaction then return nil, "a capital must be on a faction capital map" end
  end

  local locations = definition.locations
  if not locations and definition.x and definition.y then
    locations = { { x = definition.x, y = definition.y } }
  end
  local copiedLocations, locationError = CopyLocations(locations)
  if not copiedLocations then return nil, locationError end

  local copiedVertices = nil
  if definition.vertices ~= nil then
    copiedVertices, locationError = CopyLocations(definition.vertices)
    if not copiedVertices then return nil, "vertices: " .. tostring(locationError) end
    if #copiedVertices < 3 then
      return nil, "vertices must contain at least three ordered coordinates"
    end
  end

  local copiedControlVertices = nil
  if definition.controlVertices ~= nil then
    copiedControlVertices, locationError = CopyLocations(definition.controlVertices)
    if not copiedControlVertices then
      return nil, "controlVertices: " .. tostring(locationError)
    end
    local controlTotal = #copiedControlVertices
    if controlTotal < 3 or controlTotal > 32 then
      return nil, "controlVertices must contain 3 to 32 ordered coordinates"
    end
  end

  local shape = nil
  if definition.shape == "circle" then
    local radius = definition.radius
    local centerX = definition.x or copiedLocations[1].x
    local centerY = definition.y or copiedLocations[1].y
    if type(radius) ~= "number" or radius < 0.15 or radius > 10 then
      return nil, "circle radius must be a number from 0.15 to 10"
    end
    if type(centerX) ~= "number" or type(centerY) ~= "number"
        or centerX < 0 or centerX > 100 or centerY < 0 or centerY > 100 then
      return nil, "circle center needs numeric x/y coordinates from 0 to 100"
    end
    shape = { type = "circle", x = centerX, y = centerY, radius = radius }
    copiedVertices = nil
    copiedControlVertices = nil
  elseif definition.shape ~= nil and definition.shape ~= "polygon" then
    return nil, "shape must be polygon or circle"
  end

  local colorValue = definition.color or definition.category
  local color, colorError = ResolveColor(colorValue)
  if not color then return nil, colorError end
  local colorKey = nil
  if type(colorValue) == "string" then
    colorKey = string.upper(colorValue)
  elseif type(definition.colorKey) == "string" then
    colorKey = definition.colorKey
  end
  -- The catalog always ships NEUTRAL: a capital takes its faction's color.
  if capitalFaction then
    local preset = Map.COLORS[capitalFaction]
    color = { preset[1], preset[2], preset[3] }
    colorKey = capitalFaction
  end

  return {
    id = definition.id,
    map = mapName,
    mapKey = mapKey,
    type = poiType,
    category = definition.category,
    label = definition.label,
    color = color,
    colorKey = colorKey,
    locations = copiedLocations,
    vertices = copiedVertices,
    controlVertices = copiedControlVertices,
    shape = shape,
    enabled = definition.enabled ~= false,
  }
end

local function HideObject(object)
  if not object or type(object.Hide) ~= "function" then return false end
  return pcall(object.Hide, object) and true or false
end

local function HideHoverPatches(entry)
  if not entry or not entry.hoverTextures then return end
  for index = 1, #entry.hoverTextures do
    HideObject(entry.hoverTextures[index])
  end
end

local function HideEntry(entry)
  HideHoverPatches(entry)
  if entry and entry.icon then HideObject(entry.icon) end
  if entry and entry.stockLabel then HideObject(entry.stockLabel) end
  if entry and entry.stockBarBack then HideObject(entry.stockBarBack) end
  if entry and entry.stockBarFill then HideObject(entry.stockBarFill) end
  if entry and entry.siegeIcon then HideObject(entry.siegeIcon) end
  if entry and entry.frame then HideObject(entry.frame) end
  if entry then
    entry.active = false
    entry.iconShown = false
  end
end

local function StoreArea(self, normalized)
  local isNew = self.areas[normalized.id] == nil
  self.areas[normalized.id] = normalized
  if isNew then self.order[#self.order + 1] = normalized.id end

  local entry = self.groups[normalized.id]
  if entry then
    entry.layoutKey = nil
    entry.pending = nil
    HideEntry(entry)
  end
  self.revision = self.revision + 1
  self.dirty = true
  return true
end

function Map:RegisterArea(definition)
  local normalized, err = NormalizeDefinition(definition)
  if not normalized then return false, err end
  return StoreArea(self, normalized)
end

function Map:RegisterPOI(definition)
  return self:RegisterArea(definition)
end

Map.AddPOI = Map.RegisterPOI

function Map:RegisterAreas(definitions)
  if type(definitions) ~= "table" then return false, "definitions must be a table" end
  local normalized = {}
  local index = 1
  local total = #definitions
  while index <= total do
    local definition, err = NormalizeDefinition(definitions[index])
    if not definition then return false, "entry " .. tostring(index) .. ": " .. tostring(err) end
    normalized[#normalized + 1] = definition
    index = index + 1
  end
  -- Store the validated copies directly: normalizing them a second time would
  -- reject the circle shape table built by the first pass.
  index = 1
  while index <= total do
    StoreArea(self, normalized[index])
    index = index + 1
  end
  return true, total
end

-- Shows the captured owner (HORDE, ALLIANCE, or nil for the static colour) and a
-- half-captured icon for the challenger at 50 % or more. Returns true on change.
-- unconfirmed: the owner is only a hint of other players (decision 0038), drawn
-- halfway to grey.
function Map:SetCaptureView(id, ownerKey, halfKey, unconfirmed)
  local area = type(id) == "string" and self.areas[id] or nil
  if not area then return false end
  local sim = self.simFront
  if sim and sim.owners and sim.owners[id] ~= nil then
    ownerKey, halfKey, unconfirmed = sim.owners[id] or nil, sim.halves and sim.halves[id] or nil, nil
  end
  if area.baseColorKey == nil then
    area.baseColorKey = area.colorKey or false
    area.baseColor = area.color
  end
  local colorKey = area.baseColorKey or nil
  local color = area.baseColor
  local preset = ownerKey and Map.COLORS[ownerKey]
  if preset then colorKey = ownerKey end
  unconfirmed = preset and unconfirmed and true or nil
  local column = halfKey and Map.POI_ICON_HALF_COLUMNS[halfKey] or nil
  if area.colorKey == colorKey and area.iconColumn == column and area.unconfirmed == unconfirmed then
    return false
  end
  if preset then
    if unconfirmed then color = { (preset[1] + 0.5) / 2, (preset[2] + 0.5) / 2, (preset[3] + 0.5) / 2 }
    else color = { preset[1], preset[2], preset[3] } end
  end
  area.colorKey = colorKey
  area.color = color
  area.iconColumn = column
  area.unconfirmed = unconfirmed
  self.dirty = true
  return true
end

function Map:RemoveArea(id)
  if type(id) ~= "string" or not self.areas[id] then return false end
  self.areas[id] = nil
  if self.shadows then self.shadows[id] = nil end
  local entry = self.groups[id]
  if entry then
    entry.pending = nil
    HideEntry(entry)
  end
  local index = 1
  while index <= #self.order do
    if self.order[index] == id then
      table.remove(self.order, index)
      break
    end
    index = index + 1
  end
  self.revision = self.revision + 1
  self.dirty = true
  return true
end

function Map:SetEnabled(enabled)
  self.enabled = enabled and true or false
  self.dirty = true
  if not self.enabled then self:HideAll() end
end

local function Settings()
  local storage = WF.Storage
  if not storage or type(storage.GetDB) ~= "function" or storage.readOnly then return nil end
  local db = storage:GetDB()
  if type(db) ~= "table" or type(db.settings) ~= "table" then return nil end
  return db.settings
end

function Map:IconScale()
  return WF.Preferences and WF.Preferences:Get("mapIconScale") or 1
end

function Map:AreaOpacity()
  return WF.Preferences and WF.Preferences:Get("mapAreaOpacity") or PROFILE_ALPHA
end

function Map:PathOpacity()
  return WF.Preferences and WF.Preferences:Get("mapPathOpacity") or 0.4
end

function Map:LabelMode()
  return WF.Preferences and WF.Preferences:Get("mapLabelMode") or "always"
end

function Map:ApplyLabelVisibility(entry)
  if not entry or not entry.labelFrame then return end
  local mode = self:LabelMode()
  if mode == "hidden" or (mode == "hover" and self.hoverId ~= entry.id) then
    HideObject(entry.labelFrame)
  elseif type(entry.labelFrame.Show) == "function" then
    entry.labelFrame:Show()
  end
end

-- Player choices from the world map filter's Warfront category.
-- "Points of interest", saved in WarfrontDB.settings.mapHidden: POI areas and
-- icons, and the minimap drawing.
function Map:Hidden()
  local settings = Settings()
  if settings then return settings.mapHidden and true or false end
  return self.hidden and true or false
end

-- "Campaign routes", saved in WarfrontDB.settings.mapRoutesHidden: the
-- continent campaign route and the secured zone emblems.
function Map:RoutesHidden()
  local settings = Settings()
  if settings then return settings.mapRoutesHidden and true or false end
  return self.routesHidden and true or false
end

local function RedrawAfterFilter(self)
  self.dirty = true
  self:HideAll()
  self.lastSignature = nil
  self:Refresh(true)
end

function Map:ApplyPreferences()
  for _, entry in pairs(self.groups) do self:ApplyLabelVisibility(entry) end
  RedrawAfterFilter(self)
end

function Map:SetHidden(hidden)
  self.hidden = hidden and true or false
  local settings = Settings()
  if settings then settings.mapHidden = self.hidden or nil end
  RedrawAfterFilter(self)
end

-- "Scouts and armies", saved in WarfrontDB.settings.mapUnitsHidden: travelling
-- scouts and armies on every map.
function Map:UnitsHidden()
  local settings = Settings()
  if settings then return settings.mapUnitsHidden and true or false end
  return self.unitsHidden and true or false
end

function Map:SetUnitsHidden(hidden)
  self.unitsHidden = hidden and true or false
  local settings = Settings()
  if settings then settings.mapUnitsHidden = self.unitsHidden or nil end
  RedrawAfterFilter(self)
end

function Map:SetRoutesHidden(hidden)
  self.routesHidden = hidden and true or false
  local settings = Settings()
  if settings then settings.mapRoutesHidden = self.routesHidden or nil end
  RedrawAfterFilter(self)
end

local function GetCanvas()
  local canvas = WF.Compat and WF.Compat.GetWorldMapCanvas and WF.Compat.GetWorldMapCanvas()
  if not canvas or type(canvas.GetWidth) ~= "function"
      or type(canvas.GetHeight) ~= "function" then
    return nil
  end
  return canvas
end

-- OpenMap projects every zone into one stitched world while retaining a
-- changeable Blizzard host map beneath it. Return that host only when the
-- public projection API is complete; ordinary maps keep their native path.
local function StitchedHost()
  local api = GetGlobal("OpenMapAPI")
  if type(api) ~= "table" or type(api.IsStitched) ~= "function"
      or type(api.WorldFromMap) ~= "function" or type(api.MapFromWorld) ~= "function" then
    return nil
  end
  local stitchedOk, stitched = pcall(api.IsStitched)
  if not stitchedOk or not stitched then return nil end
  local frame = GetGlobal("WorldMapFrame")
  if not frame or type(frame.GetMapID) ~= "function" then return nil end
  local hostOk, hostID = pcall(frame.GetMapID, frame)
  if not hostOk or type(hostID) ~= "number" then return nil end
  return api, hostID
end

local function TransformMapPoint(api, fromID, toID, x, y)
  if not api then return x, y end
  if type(fromID) ~= "number" or type(toID) ~= "number" then return nil end
  local worldOk, u, v = pcall(api.WorldFromMap, fromID, x, y)
  if not worldOk or type(u) ~= "number" or type(v) ~= "number" then return nil end
  local mapOk, mappedX, mappedY = pcall(api.MapFromWorld, toID, u, v)
  if not mapOk or type(mappedX) ~= "number" or type(mappedY) ~= "number" then return nil end
  return mappedX, mappedY
end

local function EnsureStitchedZoneBits()
  if Map.stitchedZoneBitsRevision == Map.revision then
    return Map.stitchedZoneBits, Map.allStitchedZoneMask
  end
  local bits, nextBit, all = {}, 1, 0
  for index = 1, #Map.order do
    local area = Map.areas[Map.order[index]]
    local key = area and area.mapKey
    if key and FOREVER_ZONE_IDS[key] and not bits[key] then
      bits[key] = nextBit
      all = all + nextBit
      nextBit = nextBit * 2
    end
  end
  Map.stitchedZoneBits = bits
  Map.allStitchedZoneMask = all
  Map.stitchedZoneBitsRevision = Map.revision
  return bits, all
end

-- Only build zones whose projected rectangles overlap OpenMap's current view.
-- The bit mask changes only when a zone enters or leaves the view, so ordinary
-- pans and zooms do not relayout every already-positioned patch.
local function StitchedZoneMask(api, hostID)
  local bits, all = EnsureStitchedZoneBits()
  local frame = GetGlobal("WorldMapFrame")
  if not frame or type(frame.GetViewRect) ~= "function" then return all end
  local rectOk, rect = pcall(frame.GetViewRect, frame)
  if not rectOk or not rect then return all end
  local function Side(method)
    if type(rect[method]) ~= "function" then return nil end
    local ok, value = pcall(rect[method], rect)
    if ok and type(value) == "number" then return value end
    return nil
  end
  local viewLeft, viewRight = Side("GetLeft"), Side("GetRight")
  local viewTop, viewBottom = Side("GetTop"), Side("GetBottom")
  if not viewLeft or not viewRight or not viewTop or not viewBottom then return all end

  local mask = 0
  for mapKey, bit in pairs(bits) do
    local sourceID = FOREVER_ZONE_IDS[mapKey]
    local x1, y1 = TransformMapPoint(api, sourceID, hostID, 0, 0)
    local x2, y2 = TransformMapPoint(api, sourceID, hostID, 1, 1)
    if x1 and x2 then
      local left, right = mathMin(x1, x2), mathMax(x1, x2)
      local top, bottom = mathMin(y1, y2), mathMax(y1, y2)
      if right >= viewLeft and left <= viewRight
          and bottom >= viewTop and top <= viewBottom then
        mask = mask + bit
      end
    end
  end
  return mask
end

local function StitchedZoneVisible(mask, mapKey)
  local bits = EnsureStitchedZoneBits()
  local bit = bits[mapKey]
  return bit and mathFloor((mask or 0) / bit) % 2 == 1 or false
end

local function ProjectAreaPoint(api, hostID, area, x, y)
  if not api then return x, y end
  return TransformMapPoint(api, FOREVER_ZONE_IDS[area.mapKey], hostID, x, y)
end

local function GetCanvasSize(canvas)
  if not canvas then return nil end
  local widthOk, width = pcall(canvas.GetWidth, canvas)
  local heightOk, height = pcall(canvas.GetHeight, canvas)
  if not widthOk or not heightOk or type(width) ~= "number" or type(height) ~= "number"
      or width <= 0 or height <= 0 then
    return nil
  end
  return width, height
end

-- The level Warfront's layers stack on: the canvas, or above OpenMap's art.
-- OpenMap (optional map addon) draws its stitched world on this canvas up to
-- OpenMapAPI.ArtTopLevel(), which would cover frames at the canvas level.
-- Frame level of one of the world map's pin layers, or nil.
local function PinLevel(kind)
  local worldMap = GetGlobal("WorldMapFrame")
  if not worldMap or type(worldMap.GetPinFrameLevelsManager) ~= "function" then return nil end
  local managerOk, manager = pcall(worldMap.GetPinFrameLevelsManager, worldMap)
  if not managerOk or not manager or type(manager.GetValidFrameLevel) ~= "function" then
    return nil
  end
  local levelOk, level = pcall(manager.GetValidFrameLevel, manager, kind)
  if levelOk and type(level) == "number" then return level end
  return nil
end

local function BaseLevel(canvas)
  if not canvas or type(canvas.GetFrameLevel) ~= "function" then return nil end
  local ok, base = pcall(canvas.GetFrameLevel, canvas)
  if not ok or type(base) ~= "number" then return nil end

  -- Blizzard's exploration pin covers the canvas at its own high frame level.
  -- Keep Warfront above it while remaining below the native map's other POIs.
  local level = PinLevel("PIN_FRAME_LEVEL_MAP_EXPLORATION")
  if level and level > base then base = level end

  local api = GetGlobal("OpenMapAPI")
  if type(api) == "table" and type(api.IsStitched) == "function"
      and type(api.ArtTopLevel) == "function" then
    local stitchedOk, stitched = pcall(api.IsStitched)
    local topOk, top = pcall(api.ArtTopLevel)
    if stitchedOk and stitched and topOk and type(top) == "number" and top >= base then
      base = top + 1
    end
  end
  return base
end

-- Anchors a group frame to the canvas and shows it, skipping the calls when
-- nothing changed: refreshes reapply visible groups several times a second.
local function AnchorAndShow(frame, canvas)
  if not frame then return end
  if canvas and frame.wfAnchor ~= canvas and type(frame.SetAllPoints) == "function" then
    if pcall(frame.SetAllPoints, frame, canvas) then frame.wfAnchor = canvas end
  end
  if type(frame.Show) == "function" then
    local shownOk, shown = true, false
    if type(frame.IsShown) == "function" then shownOk, shown = pcall(frame.IsShown, frame) end
    if not shownOk or not shown then pcall(frame.Show, frame) end
  end
end

local function GetCurrentMapFile()
  local getMapInfo = GetGlobal("GetMapInfo")
  if type(getMapInfo) ~= "function" then return nil end
  local ok, name = pcall(getMapInfo)
  if not ok or type(name) ~= "string" or name == "" then return nil end

  local getZone = GetGlobal("GetCurrentMapZone")
  if type(getZone) == "function" then
    local zoneOk, zoneIndex = pcall(getZone)
    if zoneOk and type(zoneIndex) == "number" and zoneIndex == 0 then return nil end
  end
  return name
end

-- Route and bar layers sit above the native zone hover highlight (user,
-- 2026-11-14): the hovered zone must never cover a route line or node.
local function GroupLevel(frame, base)
  local want = base + frame.wfLevelOffset
  if frame.wfAboveHighlight then
    local highlight = PinLevel("PIN_FRAME_LEVEL_MAP_HIGHLIGHT")
    if highlight and highlight + 1 > base then want = highlight + frame.wfLevelOffset end
  end
  return want
end

local function CreateGroup(name, levelOffset, aboveHighlight)
  local canvas = GetCanvas()
  local create = GetGlobal("CreateFrame")
  if not canvas or type(create) ~= "function" then return nil end

  if not name then
    Map.groupSerial = Map.groupSerial + 1
    name = "WarfrontMapAreaGroup" .. tostring(Map.groupSerial)
  end
  local ok, frame = pcall(create, "Frame", name, canvas)
  if not ok or not frame then return nil end
  if type(frame.SetAllPoints) == "function" then pcall(frame.SetAllPoints, frame, canvas) end
  if type(frame.EnableMouse) == "function" then pcall(frame.EnableMouse, frame, false) end
  frame.wfLevelOffset = levelOffset or 1
  frame.wfAboveHighlight = aboveHighlight and true or nil
  local base = BaseLevel(canvas)
  if base and type(frame.SetFrameLevel) == "function" then
    pcall(frame.SetFrameLevel, frame, GroupLevel(frame, base))
  end
  HideObject(frame)
  return frame
end

local function GetEntry(id)
  local entry = Map.groups[id]
  if entry then return entry end
  local frame = CreateGroup()
  if not frame then return nil end
  entry = { id = id, frame = frame, textures = {}, visible = 0, active = false }
  Map.groups[id] = entry
  return entry
end

local function LayoutKey(area)
  local parts = { area.id, area.mapKey, area.type }
  local index = 1
  local total = #area.locations
  while index <= total do
    local location = area.locations[index]
    parts[#parts + 1] = tostring(location.x) .. ":" .. tostring(location.y)
    index = index + 1
  end
  parts[#parts + 1] = "vertices"
  index = 1
  total = #(area.vertices or {})
  while index <= total do
    local vertex = area.vertices[index]
    parts[#parts + 1] = tostring(vertex.x) .. ":" .. tostring(vertex.y)
    index = index + 1
  end
  parts[#parts + 1] = "controlVertices"
  index = 1
  total = #(area.controlVertices or {})
  while index <= total do
    local vertex = area.controlVertices[index]
    parts[#parts + 1] = tostring(vertex.x) .. ":" .. tostring(vertex.y)
    index = index + 1
  end
  if area.shape then
    parts[#parts + 1] = area.shape.type
    parts[#parts + 1] = tostring(area.shape.x) .. ":" .. tostring(area.shape.y)
    parts[#parts + 1] = tostring(area.shape.radius)
  end
  return table.concat(parts, "|")
end

local function StoreCache(key, patches)
  if Map.cache[key] then return Map.cache[key] end
  if Map.cacheCount >= CACHE_LIMIT then
    Map.cache = {}
    Map.cacheCount = 0
  end
  Map.cache[key] = patches
  Map.cacheCount = Map.cacheCount + 1
  return patches
end

local function BuildRecords(patches)
  local records = {}
  local grid = Contours.GRID
  local index = 1
  local total = #(patches or {})
  while index <= total do
    local patch = patches[index]
    local left = mathMax(0, patch[1])
    local top = mathMax(0, patch[2])
    local right = mathMin(grid, patch[3])
    local bottom = mathMin(grid, patch[4])
    if right > left and bottom > top then
      table.insert(records, {
        left / grid, top / grid, right / grid, bottom / grid,
        Contours.ProfileU(patch[5]), Contours.ProfileU(patch[6]), 0.25, 0.75,
      })
    end
    index = index + 1
  end
  return records
end

local function CreatePatch(entry)
  if not entry.frame or type(entry.frame.CreateTexture) ~= "function" then return nil end
  local ok, texture = pcall(entry.frame.CreateTexture, entry.frame, nil, "ARTWORK")
  if not ok then return nil end
  return texture
end

local function GetIconPosition(area)
  if area.shape then return area.shape.x / 100, area.shape.y / 100 end
  local points = area.controlVertices or area.vertices or area.locations
  local total = #(points or {})
  if total == 0 then return nil end
  -- Middle of the bounding box, matching iconAnchor() in the HTML editor.
  local minX, maxX = points[1].x, points[1].x
  local minY, maxY = points[1].y, points[1].y
  local index = 2
  while index <= total do
    local point = points[index]
    if point.x < minX then minX = point.x end
    if point.x > maxX then maxX = point.x end
    if point.y < minY then minY = point.y end
    if point.y > maxY then maxY = point.y end
    index = index + 1
  end
  return (minX + maxX) / 200, (minY + maxY) / 200
end

-- Also the anchor of travel distances (modules/scout.lua, decision 0050).
Map.IconPosition = GetIconPosition

-- "level/capacity" of a resource POI (modules/stock.lua) and its fill share
-- in [0, 1], nil for other types.
local function StockText(area)
  local stock = WF.Stock
  if not stock or type(stock.View) ~= "function" then return nil end
  local ok, view = pcall(stock.View, stock, area.id)
  if not ok or type(view) ~= "table" then return nil end
  local level, capacity = mathFloor(view.level), mathFloor(view.capacity)
  local share = 0
  if capacity > 0 then share = mathMax(0, mathMin(1, level / capacity)) end
  return level .. "/" .. capacity, share
end

-- Small stock bar under the label: a fill from red (empty) to green (full)
-- and a dark part for the rest. Local display only. Both pieces sit on the
-- label's own draw layer (OVERLAY), side by side, so the bar stacks like the
-- text above neighbouring icons and never needs two pieces to overlap.
local STOCK_BAR_TEXTURE = "Interface\\Buttons\\WHITE8X8"
local STOCK_BAR_WIDTH = 30
local STOCK_BAR_HEIGHT = 3

local function HideStockBar(entry)
  if entry.stockBarBack then HideObject(entry.stockBarBack) end
  if entry.stockBarFill then HideObject(entry.stockBarFill) end
end

-- Label and stock bar draw on a child of the POI group a few frame levels
-- higher, so a neighbouring icon never covers them.
local LABEL_LEVEL_RAISE = 3

-- POI groups do not keep one shared level: each takes the map's level when it
-- is created, and the map's level moves (pandaUI reparents and zooms it, a
-- minimized map lowers it). Labels therefore sit above the highest POI group
-- and the map itself, measured again on every refresh.
local function UpdateLabelLevel()
  local top = 0
  local base = BaseLevel(GetCanvas())
  if base then top = base + 1 end
  for _, entry in pairs(Map.groups) do
    if entry.frame then
      local ok, level = pcall(entry.frame.GetFrameLevel, entry.frame)
      if ok and type(level) == "number" and level > top then top = level end
    end
  end
  Map.labelLevel = top + LABEL_LEVEL_RAISE
end

local function RaiseLabelFrame(entry)
  local frame = entry.labelFrame
  if not frame or not entry.frame then return end
  if not Map.labelLevel then UpdateLabelLevel() end
  pcall(function()
    local level = Map.labelLevel
    if frame:GetFrameLevel() ~= level then frame:SetFrameLevel(level) end
  end)
end

local function LabelFrame(entry)
  if entry.labelFrame then return entry.labelFrame end
  local create = GetGlobal("CreateFrame")
  if not entry.frame or type(create) ~= "function" then return nil end
  local ok, frame = pcall(create, "Frame", nil, entry.frame)
  if not ok or not frame then return nil end
  pcall(function()
    frame:SetAllPoints(entry.frame)
    frame:EnableMouse(false)
    frame:SetScale(Map.iconZoom)
  end)
  entry.labelFrame = frame
  RaiseLabelFrame(entry)
  return frame
end

local function PlaceStockBar(entry, share)
  if not entry.stockBarBack then
    local layer = LabelFrame(entry)
    if not layer or type(layer.CreateTexture) ~= "function" then return end
    local ok = pcall(function()
      local half = STOCK_BAR_WIDTH / 2
      local back = layer:CreateTexture(nil, "OVERLAY")
      back:SetTexture(STOCK_BAR_TEXTURE)
      back:SetVertexColor(0, 0, 0, 0.7)
      back:SetHeight(STOCK_BAR_HEIGHT)
      back:SetPoint("TOPRIGHT", entry.stockLabel, "BOTTOM", half, -2)
      local fill = layer:CreateTexture(nil, "OVERLAY")
      fill:SetTexture(STOCK_BAR_TEXTURE)
      fill:SetHeight(STOCK_BAR_HEIGHT)
      fill:SetPoint("TOPLEFT", entry.stockLabel, "BOTTOM", -half, -2)
      entry.stockBarBack = back
      entry.stockBarFill = fill
    end)
    if not ok then return end
  end
  local back, fill = entry.stockBarBack, entry.stockBarFill
  local filled = mathFloor(STOCK_BAR_WIDTH * mathMax(0, mathMin(1, share)) + 0.5)
  if share > 0 and filled < 1 then filled = 1 end
  pcall(function()
    if filled > 0 then
      fill:SetWidth(filled)
      fill:SetVertexColor(1 - share, share, 0, 0.9)
      fill:Show()
    else
      fill:Hide()
    end
    if filled < STOCK_BAR_WIDTH then
      back:SetWidth(STOCK_BAR_WIDTH - filled)
      back:Show()
    else
      back:Hide()
    end
  end)
end

-- "Level n" of a Settlement held by a faction (modules/garrison.lua), nil
-- otherwise. Read from the garrison state of the current owner generation,
-- never created here: no state yet means level 1.
local function SettlementLevel(area)
  local garrison, capture = WF.Garrison, WF.Capture
  if area.type ~= "SETTLEMENT" or not garrison or not capture or type(garrison.Level) ~= "function" then
    return nil
  end
  local ok, owner, generation = pcall(capture.GetOwner, capture, area.id)
  if not ok or (owner ~= "H" and owner ~= "A") then return nil end
  local st = garrison.states and garrison.states[area.id]
  if not st or st.gen ~= generation then return 1 end
  return garrison.Level(st.gold, st.wood)
end

-- Every reader goes through Map.SettlementLevel (window, HUD, minimap, map
-- icons and tooltips), so one replacement (WarfrontDev's demo) reaches them all.
local function LevelText(area)
  local level = Map.SettlementLevel(area)
  return level and ("Level " .. level) or nil
end

Map.SettlementLevel = SettlementLevel
Map.LevelText = LevelText

-- Settlement levels change between layouts: switch the icon row only when the
-- level does (the layout itself sets it in PlaceIcon).
local function RefreshLevelIcon(entry, area)
  if area.type ~= "SETTLEMENT" or not entry.iconShown or not entry.icon then return end
  local level = Map.SettlementLevel(area)
  if entry.icon.WarfrontLevel == level then return end
  local path, left, right, top, bottom = Map.GetIcon(area.type, area.colorKey, area.iconColumn, level)
  if not path then return end
  local ok = pcall(function()
    if entry.icon.WarfrontPath ~= path then
      entry.icon:SetTexture(path)
      entry.icon.WarfrontPath = path
    end
    entry.icon:SetTexCoord(left, right, top, bottom)
  end)
  if ok then entry.icon.WarfrontLevel = level end
end

-- Label under a resource POI icon (its stock); anchored once to the icon, its
-- text is set only when it changes. Settlement levels live in the tooltip.
local function PlaceStockLabel(entry, area)
  local text, share
  if entry.iconShown then
    text, share = StockText(area)
  end
  if not text then
    if entry.stockLabel then HideObject(entry.stockLabel) end
    HideStockBar(entry)
    Map:ApplyLabelVisibility(entry)
    return
  end
  if not entry.stockLabel then
    local layer = LabelFrame(entry)
    if not layer or type(layer.CreateFontString) ~= "function" then return end
    local ok, label = pcall(layer.CreateFontString, layer, nil, "OVERLAY",
      "GameFontHighlightSmall")
    if not ok or not label then return end
    local anchored = pcall(function()
      label:SetPoint("TOP", entry.icon, "BOTTOM", 0, 3)
    end)
    if not anchored then return end
    entry.stockLabel = label
  end
  local label = entry.stockLabel
  RaiseLabelFrame(entry)
  pcall(function()
    if label.WarfrontText ~= text then
      label:SetText(text)
      label.WarfrontText = text
    end
    label:Show()
  end)
  if share then PlaceStockBar(entry, share) else HideStockBar(entry) end
  Map:ApplyLabelVisibility(entry)
end

local function PlaceIcon(entry, area, width, height, stitchedAPI, hostID)
  local level = Map.SettlementLevel(area)
  local path, left, right, top, bottom, pw, ph = Map.GetIcon(area.type, area.colorKey, area.iconColumn, level)
  entry.iconShown = false
  if not path then
    if entry.icon then HideObject(entry.icon) end
    if entry.stockLabel then HideObject(entry.stockLabel) end
    if entry.siegeIcon then HideObject(entry.siegeIcon) end
    HideStockBar(entry)
    return true
  end
  if not entry.frame or type(entry.frame.CreateTexture) ~= "function" then return false end
  if not entry.icon then
    local ok, icon = pcall(entry.frame.CreateTexture, entry.frame, nil, "OVERLAY")
    if not ok or not icon then return false end
    entry.icon = icon
  end
  local x, y = GetIconPosition(area)
  x, y = ProjectAreaPoint(stitchedAPI, hostID, area, x, y)
  if not x or not y then return false end
  if type(entry.icon.SetTexture) ~= "function" or type(entry.icon.ClearAllPoints) ~= "function"
      or type(entry.icon.SetTexCoord) ~= "function"
      or type(entry.icon.SetPoint) ~= "function" or type(entry.icon.SetWidth) ~= "function"
      or type(entry.icon.SetHeight) ~= "function" or type(entry.icon.Show) ~= "function" then
    return false
  end
  local ok = pcall(function()
    if entry.icon.WarfrontPath ~= path then
      entry.icon:SetTexture(path)
      entry.icon.WarfrontPath = path
    end
    entry.icon:SetTexCoord(left, right, top, bottom)
    entry.icon.WarfrontLevel = level
    entry.icon:ClearAllPoints()
    entry.icon:SetPoint("CENTER", entry.frame, "TOPLEFT", x * width, -y * height)
    local iconWidth, iconHeight = Map.FitIcon(IconSize(area.type), pw, ph)
    entry.icon.WarfrontWidth, entry.icon.WarfrontHeight = iconWidth, iconHeight
    entry.icon:SetWidth(iconWidth * Map.iconZoom)
    entry.icon:SetHeight(iconHeight * Map.iconZoom)
    entry.icon:Show()
  end)
  entry.iconShown = ok and true or false
  PlaceStockLabel(entry, area)
  Map.PaintZoneSiege(entry, area)
  return entry.iconShown
end

-- Icon factor for the current zoom: the canvas scale over the scale that fits
-- the whole canvas in the view (Blizzard's least zoom; OpenMap's host map
-- filling the window). 1 at that view, zoomed out, or when unknown.
function Map:IconZoomFactor()
  local frame = GetGlobal("WorldMapFrame")
  local container = frame and frame.ScrollContainer
  local canvas = GetCanvas()
  if not container or not canvas or type(container.GetCanvasScale) ~= "function"
      or type(container.GetWidth) ~= "function" or type(container.GetHeight) ~= "function" then
    return 1
  end
  local ok, scale, viewW, viewH, canvasW, canvasH = pcall(function()
    return container:GetCanvasScale(), container:GetWidth(), container:GetHeight(),
      canvas:GetWidth(), canvas:GetHeight()
  end)
  if not ok or type(scale) ~= "number" or scale <= 0 or type(viewW) ~= "number"
      or type(viewH) ~= "number" or type(canvasW) ~= "number" or type(canvasH) ~= "number"
      or canvasW <= 0 or canvasH <= 0 then
    return 1
  end
  local fit = mathMin(viewW / canvasW, viewH / canvasH)
  if fit <= 0 or scale <= fit then return 1 end
  local config = self.ICON_ZOOM
  return mathMax(config.min, (scale / fit) ^ (config.power - 1))
end

-- Resizes shown icons and scales their label layer (stock text and bar) when
-- the zoom factor moves; called on every canvas zoom step and refresh.
function Map:ApplyIconZoom()
  local factor = self:IconZoomFactor()
  if mathAbs(factor - self.iconZoom) < 0.005 then return end
  self.iconZoom = factor
  for _, entry in pairs(self.groups) do
    local icon = entry.icon
    if icon and icon.WarfrontWidth then
      pcall(function()
        icon:SetWidth(icon.WarfrontWidth * factor)
        icon:SetHeight(icon.WarfrontHeight * factor)
      end)
    end
    local siege = entry.siegeIcon
    if siege then
      pcall(function()
        siege:SetWidth(Map.ZONE_SIEGE_SIZE * factor)
        siege:SetHeight(Map.ZONE_SIEGE_SIZE * factor)
      end)
    end
    if entry.labelFrame then pcall(entry.labelFrame.SetScale, entry.labelFrame, factor) end
  end
end

local function PlacePatch(entry, texture, record, width, height, color, alpha,
    area, stitchedAPI, hostID)
  if not texture then return false end
  if type(texture.SetTexture) ~= "function" or type(texture.SetTexCoord) ~= "function"
      or type(texture.SetVertexColor) ~= "function"
      or type(texture.ClearAllPoints) ~= "function"
      or type(texture.SetPoint) ~= "function" or type(texture.SetWidth) ~= "function"
      or type(texture.SetHeight) ~= "function" or type(texture.Show) ~= "function" then
    return false
  end

  local left, top = ProjectAreaPoint(stitchedAPI, hostID, area, record[1], record[2])
  local right, bottom = ProjectAreaPoint(stitchedAPI, hostID, area, record[3], record[4])
  if not left or not top or not right or not bottom then return false end

  local ok = pcall(function()
    if texture.WarfrontPath ~= PROFILE_TEXTURE then
      texture:SetTexture(PROFILE_TEXTURE)
      texture.WarfrontPath = PROFILE_TEXTURE
    end
    texture:SetTexCoord(record[5], record[6], record[7], record[8])
    texture:SetVertexColor(color[1], color[2], color[3], (alpha or PROFILE_ALPHA) * Map:AreaOpacity())
    texture:ClearAllPoints()
    texture:SetPoint("TOPLEFT", entry.frame, "TOPLEFT",
      left * width, -top * height)
    texture:SetWidth(mathMax(0.1, (right - left) * width))
    texture:SetHeight(mathMax(0.1, (bottom - top) * height))
    texture:Show()
  end)
  return ok and true or false
end

local function ApplyEntry(entry, area, width, height, stitchedAPI, hostID)
  if not entry or not entry.frame or not entry.records then return 0 end
  local failures = 0
  local index = 1
  local total = #entry.records
  while index <= total do
    if not entry.textures[index] then entry.textures[index] = CreatePatch(entry) end
    if not PlacePatch(entry, entry.textures[index], entry.records[index], width, height,
        area.color, nil, area, stitchedAPI, hostID) then
      failures = failures + 1
      HideObject(entry.textures[index])
    end
    index = index + 1
  end
  while index <= #entry.textures do
    HideObject(entry.textures[index])
    index = index + 1
  end
  entry.visible = total
  entry.active = true
  AnchorAndShow(entry.frame, GetCanvas())
  if not PlaceIcon(entry, area, width, height, stitchedAPI, hostID) then failures = failures + 1 end
  return failures
end

-- The build queue keeps head and tail indices: popping the head moves no
-- entry (table.remove(t, 1) shifted the whole list once per frame).
local function PushBuild(entry)
  local tail = Map.buildTail + 1
  Map.buildQueue[tail] = entry
  Map.buildTail = tail
end

local function PopBuild()
  local head = Map.buildHead
  if head > Map.buildTail then return nil end
  local entry = Map.buildQueue[head]
  Map.buildQueue[head] = nil
  if head == Map.buildTail then
    Map.buildHead, Map.buildTail = 1, 0
  else
    Map.buildHead = head + 1
  end
  return entry
end

function Map:BuildCount()
  return self.buildTail - self.buildHead + 1
end

local function QueueBuild(entry, area, key)
  entry.layoutKey = key
  entry.records = nil
  entry.pending = {
    key = key,
    areaId = area.id,
    build = Contours.BeginBuild(
      area.locations, area.vertices, area.shape, area.controlVertices),
  }
  if not entry.queued then
    entry.queued = true
    PushBuild(entry)
  end
  Map:WakeDriver()
end

function Map:StepBuildQueue()
  local entry = PopBuild()
  if not entry then return false end
  entry.queued = nil
  local pending = entry.pending
  if not pending then return false end

  local done, patches = Contours.StepBuild(pending.build, Contours.BUILD_ROWS_PER_TICK)
  if not done then
    entry.queued = true
    PushBuild(entry)
    return false
  end

  patches = StoreCache(pending.key, patches)
  if entry.pending == pending then
    entry.records = BuildRecords(patches)
    entry.pending = nil
    self.dirty = true
  end
  return true
end

-- Open map: build steps under a small per-frame time budget, and a refresh as
-- soon as the queue drains, so a zone's areas show within a few frames. Closed
-- map (or no clock): one step per frame as before, never felt in play.
function Map:StepBuilds(open)
  if self:BuildCount() <= 0 then return end
  local clock = open and GetGlobal("debugprofilestop") or nil
  local start = type(clock) == "function" and clock() or nil
  local steps, completed = 0, false
  repeat
    if self:StepBuildQueue() then completed = true end
    steps = steps + 1
  until not start or steps >= 32 or self:BuildCount() <= 0 or clock() - start >= 4
  if completed and self:BuildCount() <= 0 then self.refreshNow = true end
end

-- Records of an area for the minimap (modules/minimap_areas.lua), whatever
-- zone the world map shows: the world map's own records, the shared cache, or
-- nil while its build is queued. Re-keyed only when the revision changes.
Map.PROFILE_TEXTURE = PROFILE_TEXTURE
Map.shadows = {}

function Map:GetAreaRecords(area)
  local shadow = self.shadows[area.id]
  if not shadow then
    shadow = {}
    self.shadows[area.id] = shadow
  end
  if shadow.revision ~= self.revision then
    shadow.revision = self.revision
    local key = LayoutKey(area)
    if shadow.layoutKey ~= key then
      local entry = self.groups[area.id]
      local cached = self.cache[key]
      if entry and entry.layoutKey == key and entry.records then
        shadow.layoutKey, shadow.pending, shadow.records = key, nil, entry.records
      elseif cached then
        shadow.layoutKey, shadow.pending, shadow.records = key, nil, BuildRecords(cached)
      else
        QueueBuild(shadow, area, key)
      end
    end
  end
  return shadow.records
end

-- Zone capture bars on the continent maps -----------------------------------
-- On a continent map, the two zones of the Active Front show the Capture HUD
-- bar at their middle. Zones secured behind either front show that faction's
-- badge instead. The bar's shares are the number of POIs each faction holds,
-- from the owner color the zone map shows. Local display only: nothing is sent.
-- Fallback zone rectangles from the source client. On Forever the live
-- C_Map.GetMapRectOnMap result below takes precedence.
local CONTINENT_ZONES = {
  elwynn = { "azeroth", 0.410927, 0.656515, 0.098603, 0.098633 },
  westfall = { "azeroth", 0.368846, 0.718749, 0.099432, 0.099432 },
  hilsbrad = { "azeroth", 0.424244, 0.301134, 0.090909, 0.090909 },
  arathi = { "azeroth", 0.479168, 0.323862, 0.102273, 0.102273 },
  durotar = { "kalimdor", 0.517098, 0.448028, 0.143683, 0.143683 },
  barrens = { "kalimdor", 0.392493, 0.456011, 0.275364, 0.275392 },
}
Map.CONTINENT_ZONES = CONTINENT_ZONES
local CONTINENT_KEYS = { azeroth = true, kalimdor = true }
local ZONE_BAR_TEXTURE = "Interface\\Buttons\\WHITE8X8"
-- Secured route zones show their faction emblem, scaled down as one frame.
-- Active Front zones show their capture share as the ring of their campaign
-- node instead (RouteNodeRing*.tga), which replaced the horizontal bar.
local ZONE_BAR_WIDTH = 70
local ZONE_BAR_HEIGHT = 12
local ZONE_BAR_SCALE = 0.75
local ZONE_BADGE_WIDTH, ZONE_BADGE_HEIGHT = 16, 19
-- 43 x ZONE_BAR_SCALE = 32 canvas units (48 until 2026-11-14, reduced by the user).
local ZONE_OWNER_ICON_SIZE = 43
local ZONE_FACTION_TEXTURES = {
  ALLIANCE = "Interface\\AddOns\\Warfront\\media\\Textures\\UI\\Front\\FactionAlliance",
  HORDE = "Interface\\AddOns\\Warfront\\media\\Textures\\UI\\Front\\FactionHorde",
}
local FRONT_OWNER_KEYS = { H = "HORDE", A = "ALLIANCE" }
Map.zoneBars = { slots = {}, count = 0 }
-- War Camp icons on the continent and world maps (Points of interest filter).
Map.warCamps = { icons = {}, records = {}, count = 0 }

-- Per displayed uiMapID: rects[mapKey] is the zone's rectangle, or false when
-- the zone is not beneath that map; children is the set of its descendants'
-- uiMapIDs, read once. Map data is static, so a zone off the displayed
-- continent no longer rescans every descendant on each refresh.
local foreverZoneRects = {}

local function ForeverZoneRect(mapKey)
  if not C_Map or type(C_Map.GetMapChildrenInfo) ~= "function"
      or type(C_Map.GetMapRectOnMap) ~= "function" then return nil end
  local frame = GetGlobal("WorldMapFrame")
  if not frame or type(frame.GetMapID) ~= "function" then return nil end
  local ok, topMapID = pcall(frame.GetMapID, frame)
  if not ok or type(topMapID) ~= "number" then return nil end
  local top = foreverZoneRects[topMapID]
  if not top then
    top = { rects = {} }
    foreverZoneRects[topMapID] = top
  end
  local cached = top.rects[mapKey]
  if cached then return cached[1], cached[2], cached[3], cached[4] end
  if cached == false then return nil end
  local zoneID = FOREVER_ZONE_IDS[mapKey]
  if not zoneID then return nil end
  if not top.children then
    local children = C_Map.GetMapChildrenInfo(topMapID, nil, true)
    -- An empty answer is not trusted as "no zone here": asked again next time.
    if type(children) ~= "table" or #children == 0 then return nil end
    local set = {}
    for index = 1, #children do
      local child = children[index]
      if child and type(child.mapID) == "number" then set[child.mapID] = true end
    end
    top.children = set
  end
  if not top.children[zoneID] then
    top.rects[mapKey] = false
    return nil
  end
  local minX, maxX, minY, maxY = C_Map.GetMapRectOnMap(zoneID, topMapID)
  if type(minX) == "number" and type(maxX) == "number"
      and type(minY) == "number" and type(maxY) == "number" then
    local rect = { minX, maxX, minY, maxY }
    top.rects[mapKey] = rect
    return rect[1], rect[2], rect[3], rect[4]
  end
  return nil
end

local function ForeverZoneCenter(mapKey)
  local minX, maxX, minY, maxY = ForeverZoneRect(mapKey)
  if not minX then return nil end
  return (minX + maxX) / 2, (minY + maxY) / 2
end

-- Assigned by the campaign-route renderer below. Front markers call it only
-- after this file has loaded, so their bars and badges share the exact
-- Settlement anchor used by the route instead of the middle of the zone.
local CampaignPoint

-- The displayed continent's key, or nil on a zone or the world map.
local function CurrentContinentKey()
  local getZone, getMapInfo = GetGlobal("GetCurrentMapZone"), GetGlobal("GetMapInfo")
  if type(getZone) ~= "function" or type(getMapInfo) ~= "function" then return nil end
  local zoneOk, zoneIndex = pcall(getZone)
  if not zoneOk or zoneIndex ~= 0 then return nil end
  local ok, name = pcall(getMapInfo)
  if not ok then return nil end
  local key = CanonicalMapName(name)
  if key and CONTINENT_KEYS[key] then return key end
  return nil
end

-- True on the world map (both continents, no zone).
local function IsWorldMap()
  local getZone, getMapInfo = GetGlobal("GetCurrentMapZone"), GetGlobal("GetMapInfo")
  if type(getZone) ~= "function" or type(getMapInfo) ~= "function" then return false end
  local zoneOk, zoneIndex = pcall(getZone)
  if not zoneOk or zoneIndex ~= 0 then return false end
  local ok, name = pcall(getMapInfo)
  if ok and CanonicalMapName(name) == "world" then return true end
  -- The standard API answers 0 on the world map.
  local getContinent = GetGlobal("GetCurrentMapContinent")
  if type(getContinent) ~= "function" then return false end
  local continentOk, continent = pcall(getContinent)
  return continentOk and continent == 0
end

-- One entry per zone of the continent with controlled POIs, in POI order:
-- mapKey, total, alliance and horde counts and shares, and the bar anchor
-- (middle of the zone's rectangle) in units of the continent map.
function Map:ZoneShares(continentKey)
  local list = {}
  -- The world map shows every continent: any zone counts, and the anchor is
  -- set from the campaign point (FrontZones) for the zones on a route.
  local isWorld = continentKey == "world" or continentKey == "stitched"
  if not isWorld and not CONTINENT_KEYS[continentKey or ""] then return list end
  local zones = {}
  local index = 1
  for index = 1, #self.order do
    local area = self.areas[self.order[index]]
    local zone = area and area.enabled and CONTINENT_ZONES[area.mapKey or ""]
    local foreverX, foreverY
    local onContinent = zone and zone[1] == continentKey
    if isWorld then
      onContinent, foreverX, foreverY = area and area.enabled and area.mapKey and true or false, 0, 0
    end
    -- New catalog zones need no guessed fallback rectangle: C_Map locates them
    -- directly on the continent currently displayed.
    if not onContinent and not zone and area then
      foreverX, foreverY = ForeverZoneCenter(area.mapKey)
      onContinent = foreverX ~= nil
    end
    -- A capital never changes hands outside its siege: it adds nothing to a
    -- share. War Camps feed the Front Network, never these front-zone shares
    -- (decision 0123 § 8).
    if onContinent and Map.POI_TYPES[area.type]
        and not Map.RESOURCE_TYPES[area.type] and area.type ~= "CAPITAL" and area.type ~= "WAR_CAMP" then
      local entry = zones[area.mapKey]
      if not entry then
        if not foreverX then foreverX, foreverY = ForeverZoneCenter(area.mapKey) end
        entry = {
          mapKey = area.mapKey, total = 0, alliance = 0, horde = 0,
          x = foreverX or zone[2] + zone[4] / 2,
          y = foreverY or zone[3] + zone[5] / 2,
        }
        zones[area.mapKey] = entry
        list[#list + 1] = entry
      end
      entry.total = entry.total + 1
      if area.colorKey == "ALLIANCE" then
        entry.alliance = entry.alliance + 1
      elseif area.colorKey == "HORDE" then
        entry.horde = entry.horde + 1
      end
    end
  end
  index = 1
  for index = 1, #list do
    local entry = list[index]
    entry.allianceShare = entry.alliance / entry.total
    entry.hordeShare = entry.horde / entry.total
  end
  return list
end

-- Keeps only route zones on this continent. The player's own target is the
-- Active Front (both targets while the faction is unknown), plus the player's
-- pressed Settlement; completed nodes behind the lines carry their side,
-- except the other faction's target, which keeps its numbered node.
function Map:FrontZones(continentKey)
  local shares = self:ZoneShares(continentKey)
  local front = WF.Front
  if not front or type(front.HasRoutes) ~= "function" or not front:HasRoutes()
      or type(front.Targets) ~= "function" then
    return {}
  end
  local capture = WF.Capture
  local playerSide = not self.simFront and capture and type(capture.MyFaction) == "function"
    and capture:MyFaction()
  local active, owners, anchors, targets = {}, {}, {}, {}
  local routes = front.routes or {}
  for r = 1, #routes do
    local route = routes[r]
    local forward, rear = self:FrontTargets(front, route)
    local advancing = FRONT_OWNER_KEYS[route.advancing]
    local defending = route.advancing == "H" and "ALLIANCE" or "HORDE"
    local mine = playerSide == route.advancing
    local theirs = playerSide and not mine
    -- Your own Settlement gets its bar back once the other side takes one of
    -- its Outposts (decision 0111).
    local threat, threatId = 0, nil
    if playerSide and type(front.Threat) == "function" then threat, threatId = front:Threat(route, playerSide) end
    local threatArea = threat >= 2 and threatId and self.areas[threatId]
    if threatArea and threatArea.mapKey then active[threatArea.mapKey], owners[threatArea.mapKey] = true, nil end
    for n = 1, #route.nodes do
      local area = self.areas[route.nodes[n].id]
      local mapKey = area and area.mapKey
      if mapKey then
        anchors[mapKey] = area
        if (n == forward and not theirs) or (n == rear and not mine) then
          active[mapKey], owners[mapKey] = true, nil
        elseif n == forward or n == rear then
          -- The other faction's target stays contestable: no emblem, its
          -- numbered node keeps the holder's full ring (user, 2026-11-15).
          targets[mapKey], owners[mapKey] = true, nil
        elseif not active[mapKey] and not targets[mapKey] and n < forward then
          owners[mapKey] = advancing
        elseif not active[mapKey] and not targets[mapKey] and n > rear then
          owners[mapKey] = defending
        end
      end
    end
  end
  local list = {}
  for index = 1, #shares do
    local zone = shares[index]
    local anchor = anchors[zone.mapKey]
    if anchor and CampaignPoint then
      local anchorX, anchorY = CampaignPoint(anchor, continentKey)
      if anchorX then zone.x, zone.y = anchorX, anchorY end
    end
    if active[zone.mapKey] then
      zone.activeFront = true
      list[#list + 1] = zone
    elseif owners[zone.mapKey] then
      zone.ownerKey = owners[zone.mapKey]
      list[#list + 1] = zone
    end
  end
  return list
end

local function ZoneBarBadge(frame, piece, point, relative, x)
  local badge = frame:CreateTexture(nil, "OVERLAY")
  badge:SetWidth(ZONE_BADGE_WIDTH)
  badge:SetHeight(ZONE_BADGE_HEIGHT)
  badge:SetPoint(point, frame, relative, x, 0)
  local skin = WF.Skin
  badge.skinned = skin and type(skin.Apply) == "function" and skin:Apply(badge, piece) or false
  return badge
end

local function ZoneFactionIcon(texture, ownerKey)
  local path = ZONE_FACTION_TEXTURES[ownerKey]
  if path then
    texture:SetTexture(path)
    texture:SetTexCoord(0, 1, 0, 1)
    texture:SetVertexColor(1, 1, 1, 1)
    return
  end
  local color = Map.COLORS[ownerKey] or Map.COLORS.NEUTRAL
  texture:SetTexture(ZONE_BAR_TEXTURE)
  texture:SetTexCoord(0, 1, 0, 1)
  texture:SetVertexColor(color[1], color[2], color[3], 1)
end

local function ZoneBarSlot(bars, index)
  local slot = bars.slots[index]
  if slot then return slot end
  if not bars.frame then bars.frame = CreateGroup("WarfrontMapZoneBars", 3, true) end
  local group = bars.frame
  local create = GetGlobal("CreateFrame")
  if not group or type(create) ~= "function" then return nil end
  local ok = pcall(function()
    -- An unscaled 1 px holder takes the map position; the scaled emblem sits
    -- on it with no offset, so the position never depends on its scale.
    local holder = create("Frame", nil, group)
    holder:SetWidth(1)
    holder:SetHeight(1)
    if type(holder.EnableMouse) == "function" then holder:EnableMouse(false) end
    local frame = create("Frame", nil, holder)
    frame:SetWidth(ZONE_BAR_WIDTH)
    frame:SetHeight(ZONE_BAR_HEIGHT)
    frame:SetScale(ZONE_BAR_SCALE)
    frame:SetPoint("CENTER", holder, "CENTER", 0, 0)
    if type(frame.EnableMouse) == "function" then frame:EnableMouse(false) end
    slot = {
      holder = holder, frame = frame,
      owner = ZoneBarBadge(frame, "badge.neutral", "CENTER", "CENTER", 0),
    }
    slot.owner:SetWidth(ZONE_OWNER_ICON_SIZE)
    slot.owner:SetHeight(ZONE_OWNER_ICON_SIZE)
  end)
  if not ok or not slot then return nil end
  bars.slots[index] = slot
  return slot
end

local function HideZoneBarSlot(slot)
  HideObject(slot.holder)
end

function Map:HideZoneBars()
  local bars = self.zoneBars
  for index = 1, #bars.slots do
    HideZoneBarSlot(bars.slots[index])
  end
  if bars.frame then HideObject(bars.frame) end
  bars.count = 0
end

function Map:RefreshZoneBars(continentKey, width, height)
  local bars = self.zoneBars
  local zones = self:FrontZones(continentKey)
  local canvas = GetCanvas()
  local used = 0
  local index = 1
  while index <= #zones do
    local zone = zones[index]
    -- Active Front zones: their campaign node's capture ring shows the share.
    if not zone.activeFront then
      local slot = ZoneBarSlot(bars, used + 1)
      if not slot then break end
      used = used + 1
      slot.mapKey = zone.mapKey
      slot.x, slot.y = zone.x, zone.y
      slot.holder:ClearAllPoints()
      slot.holder:SetPoint("CENTER", bars.frame, "TOPLEFT", zone.x * width, -zone.y * height)
      ZoneFactionIcon(slot.owner, zone.ownerKey)
      slot.owner:Show()
      slot.frame:Show()
      slot.holder:Show()
    end
    index = index + 1
  end
  index = used + 1
  while index <= #bars.slots do
    HideZoneBarSlot(bars.slots[index])
    index = index + 1
  end
  bars.count = used
  if bars.frame then
    if used > 0 then
      if canvas and type(bars.frame.SetAllPoints) == "function" then
        pcall(bars.frame.SetAllPoints, bars.frame, canvas)
      end
      bars.frame:Show()
    else
      HideObject(bars.frame)
    end
  end
end

-- Draws the zone bars of a continent map, hiding them if anything fails.
local function DrawZoneBars(continentKey, width, height)
  local ok, err = pcall(Map.RefreshZoneBars, Map, continentKey, width, height)
  if ok then return end
  pcall(Map.HideZoneBars, Map)
  if WF.RecordError then WF.RecordError("map zone bars", err) end
end

-- Campaign route on continent maps -------------------------------------------
-- The campaign is a static, high-contrast backbone. Travelling units keep the
-- small gold dots and arrows, while the campaign uses one continuous outlined
-- gold line curving through its large numbered nodes, with one chevron near
-- the advancing front. Like Questie's patrol paths, each chord of the sampled
-- curve is one texture stretched over a mitered quad with SetVertexOffset.
(function()
local CAMPAIGN_LINE_TEXTURE = "Interface\\AddOns\\Warfront\\media\\Textures\\UI\\Route\\RouteLine"
-- Painted double chevron (tools/assets/ui/route/RouteChevron.png) as a grey
-- copy, tinted with the colour of the faction moving: Alliance blue, Horde red.
local CAMPAIGN_CHEVRON_TINT_TEXTURE = "Interface\\AddOns\\Warfront\\media\\Textures\\UI\\Route\\RouteChevronTint"
-- Painted node (2026-11-14, sources in tools/assets/ui/route): all pieces share
-- one 64 x 64 layout centred on the node (centre disc r 0-21, gold rim r 21-23,
-- capture band r 23-29, outline r 29-31). The coloured rings are complete
-- circles; only an arc of each is drawn (LayoutCampaignArc).
local CAMPAIGN_RING_TRACK_TEXTURE = "Interface\\AddOns\\Warfront\\media\\Textures\\UI\\Route\\RouteNodeRingTrack"
local CAMPAIGN_RING_ALLIANCE_TEXTURE = "Interface\\AddOns\\Warfront\\media\\Textures\\UI\\Route\\RouteNodeRingAlliance"
local CAMPAIGN_RING_HORDE_TEXTURE = "Interface\\AddOns\\Warfront\\media\\Textures\\UI\\Route\\RouteNodeRingHorde"
local CAMPAIGN_NODE_CENTER_TEXTURE = "Interface\\AddOns\\Warfront\\media\\Textures\\UI\\Route\\RouteNodeCenter"
local CAMPAIGN_NODE_GLOW_TEXTURE = "Interface\\AddOns\\Warfront\\media\\Textures\\UI\\Route\\RouteNodeGlow"
-- Node numbers 0-9, built by tools/build_route_digits.py (4 x 4 grid of cells
-- in the node layout, each digit's ink centred).
local CAMPAIGN_NODE_DIGITS_TEXTURE = "Interface\\AddOns\\Warfront\\media\\Textures\\UI\\Route\\RouteNodeDigits"
-- The hover glow is painted for 1.5 x the node size.
local CAMPAIGN_GLOW_SCALE = 1.5
-- Arc wedges: at most this angle each, so their straight outer edge stays
-- within a quarter texel of the circle.
local CAMPAIGN_ARC_STEP = math.pi / 12
-- Wedge radii in texels of the 64 x 64 layout: inside the gold rim, and just
-- outside the band's antialiased edge once the chord is accounted for.
local CAMPAIGN_ARC_INNER, CAMPAIGN_ARC_OUTER = 21, 31.5
-- Locked nodes: disc and ring partly desaturated, then tinted warm so they
-- read as a faded grey-beige on the parchment (user, 2026-11-14: full grey
-- contrasted too much).
local CAMPAIGN_LOCKED_DESATURATION = 0.6
local CAMPAIGN_LOCKED_TINT = { 1, 0.95, 0.88 }
local CAMPAIGN_NODE_SHADOW_TEXTURE = "Interface\\AddOns\\Warfront\\media\\Textures\\UI\\Route\\RouteNodeShadow"
-- RouteLine.tga (built from the painted source in tools/assets/ui/route)
-- holds the cross-section of the approved reference: short soft shadow,
-- brown outline, shaded gold core. Canvas units: the world map canvas shows
-- about twice as large on screen, so 4.5 units give the reference's 3 px core
-- with under 2 px of shadow on each side.
local CAMPAIGN_LINE_QUAD_WIDTH = 4.5
-- Curves are sampled into chords about this long, 2 to 40 per segment.
local CAMPAIGN_CURVE_STEP = 8
local CAMPAIGN_CURVE_MAX_PIECES = 40
local CAMPAIGN_ROUTE_MAX_PIECES = 600
-- Miters longer than this many half widths (turns past 120 degrees) are cut.
local CAMPAIGN_MITER_LIMIT = 2
local CAMPAIGN_NODE_SIZE = 20
local CAMPAIGN_ACTIVE_SIZE = 25
local CAMPAIGN_NUMBER_SIZE = 18
local CAMPAIGN_CHEVRON_SIZE = 14
-- Capital crown (POI atlas cell, ink 68 of 72 px wide) on a capital node not
-- yet attacked, a little wider than a secured zone's emblem ink; once the
-- capital is the target, the crown fills this share of the disc (2026-11-20).
local CAMPAIGN_CAPITAL_CROWN_SIZE, CAMPAIGN_CAPITAL_CROWN_IN_DISC = 24, 0.72
-- Arrow tint of the faction moving.
local CAMPAIGN_ROUTE_COLORS = {
  H = Map.COLORS.HORDE,
  A = Map.COLORS.ALLIANCE,
}
-- Threat levels 2 (an Outpost lost) and 3 (siege) of decision 0111.
local CAMPAIGN_THREAT_COLORS = { [2] = { 1.00, 0.50, 0.08 }, [3] = { 0.95, 0.16, 0.10 } }
local CAMPAIGN_THREAT_RING_SIZE = 36
-- Both factions' chevrons fully opaque (user, 2026-11-14, amends decision 0111).
local CAMPAIGN_CHEVRON_ALPHA = 1
-- Pixels before node 1 for the chevron of a target at node 1.
local CAMPAIGN_CHEVRON_LEAD = 24
-- Siege alert up and right of a besieged node (user, 2026-11-15: the catapult
-- is kept): a 4 x 4 flipbook of 16 frames, stepped by Map:AnimateSieges.
local CAMPAIGN_SIEGE_CATAPULT_TEXTURE = "Interface\\AddOns\\Warfront\\media\\Textures\\UI\\Front\\SiegeCatapultFlipbook"
local CAMPAIGN_SIEGE_ICON_SIZE = 26
local CAMPAIGN_SIEGE_FPS = 12
local CAMPAIGN_SIEGE_FRAMES = 16

Map.campaignRoutes = {
  lines = {}, arrows = {},
  nodeShadows = {}, glows = {}, tracks = {}, centers = {}, arcs = {},
  labels = {}, digits = {}, capitalBadges = {}, records = {}, chevronHits = {},
  siegeCatapults = {}, lockIcons = {},
  lineCount = 0, arrowCount = 0, nodeCount = 0, segmentCount = 0,
}

CampaignPoint = function(area, continentKey)
  if not area or not area.enabled then return nil end
  local x, y = GetIconPosition(area)
  if not x then return nil end
  -- World map: through the continents' place on it (Map.WORLD_CONTINENTS).
  if continentKey == "world" then
    local viewPoint = Kit.ViewPoint
    if not viewPoint then return nil end
    return viewPoint(area, "world")
  end
  -- OpenMap's stitched world: through its projection onto the host map, as
  -- the icons are placed.
  if continentKey == "stitched" then
    if not Map.stitchedAPI then return nil end
    return ProjectAreaPoint(Map.stitchedAPI, Map.stitchedHostID, area, x, y)
  end
  local minX, maxX, minY, maxY = ForeverZoneRect(area.mapKey)
  if minX then
    return minX + x * (maxX - minX), minY + y * (maxY - minY)
  end
  local zone = CONTINENT_ZONES[area.mapKey or ""]
  if not zone or zone[1] ~= continentKey then return nil end
  return zone[2] + x * zone[4], zone[3] + y * zone[5]
end

-- Only the player's own target is active; both while the faction is unknown.
local function CampaignNodeState(route, index, forward, rear, total, capital, playerSide)
  if capital then return forward > total and "active" or "locked" end
  local mine = playerSide == route.advancing
  local theirs = playerSide and not mine
  if (index == forward and not theirs) or (index == rear and not mine) then return "active" end
  if index < forward then return route.advancing end
  if index > rear then return route.advancing == "H" and "A" or "H" end
  return "locked"
end

local function CampaignFileTexture(list, index, frame, layer, path)
  local texture = Kit.RouteTexture(list, index, frame, layer)
  if texture and texture.WarfrontPath ~= path then
    texture:SetTexture(path)
    texture:SetTexCoord(0, 1, 0, 1)
    texture.WarfrontPath = path
  end
  return texture
end

local function CampaignLabel(list, index, frame)
  local label = list[index]
  if label then return label end
  if type(frame.CreateFontString) ~= "function" then return nil end
  local ok, created = pcall(frame.CreateFontString, frame, nil, "OVERLAY", "GameFontHighlightSmall")
  if not ok or not created then return nil end
  created:SetWidth(CAMPAIGN_NUMBER_SIZE)
  created:SetHeight(CAMPAIGN_NUMBER_SIZE)
  created:SetJustifyH("CENTER")
  created:SetJustifyV("MIDDLE")
  created:SetTextColor(0.10, 0.06, 0.02)
  -- GameFontHighlightSmall inherits SystemFont_Shadow_Small: no shadow on the
  -- dark number over the light medallion.
  if created.SetShadowOffset then created:SetShadowOffset(0, 0) end
  if created.SetShadowColor then created:SetShadowColor(0, 0, 0, 0) end
  list[index] = created
  return created
end

local function PlaceCampaignTexture(texture, frame, x, y, size)
  if not texture then return end
  texture:SetWidth(size)
  texture:SetHeight(size)
  texture:ClearAllPoints()
  texture:SetPoint("CENTER", frame, "TOPLEFT", x, y)
  texture:Show()
end

-- Stretches a texture over the quad sl, sr (start left/right) to el, er
-- (end left/right), in canvas pixels with y down. The texture's rows run along
-- the chord; anchors and vertex offsets have y up. Vertex indexes: 1 upper
-- left, 2 lower left, 3 upper right, 4 lower right.
local function DrawCampaignQuad(texture, frame, slx, sly, srx, sry, elx, ely, erx, ery)
  local minX = math.min(slx, srx, elx, erx)
  local maxX = math.max(slx, srx, elx, erx)
  local minY = math.min(sly, sry, ely, ery)
  local maxY = math.max(sly, sry, ely, ery)
  texture:ClearAllPoints()
  texture:SetPoint("TOPLEFT", frame, "TOPLEFT", minX, -minY)
  texture:SetPoint("BOTTOMRIGHT", frame, "TOPLEFT", maxX, -maxY)
  texture:SetVertexOffset(1, slx - minX, minY - sly)
  texture:SetVertexOffset(3, elx - maxX, minY - ely)
  texture:SetVertexOffset(2, srx - minX, maxY - sry)
  texture:SetVertexOffset(4, erx - maxX, maxY - ery)
  texture:Show()
end

-- A painted node piece on its own sublevel, filtered like the map canvas.
local function CampaignNodeTexture(list, index, frame, layer, sublevel, path)
  local texture = list[index]
  if not texture then
    if type(frame.CreateTexture) ~= "function" then return nil end
    local ok, created = pcall(frame.CreateTexture, frame, nil, layer, nil, sublevel)
    if not ok or not created then return nil end
    if type(created.SetSnapToPixelGrid) == "function" then created:SetSnapToPixelGrid(false) end
    if type(created.SetTexelSnappingBias) == "function" then created:SetTexelSnappingBias(0) end
    texture, list[index] = created, created
  end
  if texture.WarfrontPath ~= path then
    texture:SetTexture(path, "CLAMP", "CLAMP", "TRILINEAR")
    texture.WarfrontPath = path
  end
  return texture
end

-- Zone maps: the same catapult flipbook up and right of a besieged
-- Settlement's (or capital's) POI icon (user, 2026-11-19), kept by area id in
-- Map.zoneSiegeIcons and stepped with the continent ones by Map:AnimateSieges.
Map.ZONE_SIEGE_SIZE = CAMPAIGN_SIEGE_ICON_SIZE
Map.zoneSiegeIcons = {}

function Map.PaintZoneSiege(entry, area)
  local front = WF.Front
  local node = entry.iconShown and entry.icon and front and type(front.HasRoutes) == "function"
    and front:HasRoutes()
    and (front.bySettlement and front.bySettlement[area.id] or front.byCapital and front.byCapital[area.id])
  if not node or not Map:SiegeRunning(node.route, area.id) then
    if entry.siegeIcon then HideObject(entry.siegeIcon) end
    return
  end
  local catapult = CampaignNodeTexture(Map.zoneSiegeIcons, area.id, entry.frame, "OVERLAY", 1,
    CAMPAIGN_SIEGE_CATAPULT_TEXTURE)
  if not catapult then return end
  pcall(function()
    if entry.siegeIcon ~= catapult then
      entry.siegeIcon = catapult
      catapult:ClearAllPoints()
      catapult:SetPoint("BOTTOMLEFT", entry.icon, "TOPRIGHT", -4, -4)
    end
    if not catapult.WarfrontFlip then catapult:SetTexCoord(0, 0.25, 0, 0.25) end
    catapult:SetWidth(Map.ZONE_SIEGE_SIZE * Map.iconZoom)
    catapult:SetHeight(Map.ZONE_SIEGE_SIZE * Map.iconZoom)
    catapult:Show()
  end)
end

-- Draws the arc from angle from to angle to (radians, clockwise from the top)
-- of a complete painted ring, centred on cx, cy (canvas pixels, y down) at
-- size: wedge quads placed with SetVertexOffset, each sampling the ring image
-- exactly where it lies (8-value SetTexCoord). Returns the textures used.
local function LayoutCampaignArc(list, used, frame, path, cx, cy, size, from, to)
  if to - from <= 0.001 then return used end
  local steps = math.ceil((to - from) / CAMPAIGN_ARC_STEP)
  local outer = size * CAMPAIGN_ARC_OUTER / 64 / math.cos((to - from) / steps / 2)
  local inner = size * CAMPAIGN_ARC_INNER / 64
  local function Corner(radius, angle)
    local dx, dy = math.sin(angle) * radius, -math.cos(angle) * radius
    return cx + dx, cy + dy, 0.5 + dx / size, 0.5 + dy / size
  end
  for step = 0, steps - 1 do
    local texture = CampaignNodeTexture(list, used + 1, frame, "ARTWORK", 1, path)
    if not texture or type(texture.SetVertexOffset) ~= "function" then return used end
    used = used + 1
    local a0 = from + (to - from) * step / steps
    local a1 = from + (to - from) * (step + 1) / steps
    local slx, sly, slu, slv = Corner(outer, a0)
    local srx, sry, sru, srv = Corner(inner, a0)
    local elx, ely, elu, elv = Corner(outer, a1)
    local erx, ery, eru, erv = Corner(inner, a1)
    texture:SetTexCoord(slu, slv, sru, srv, elu, elv, eru, erv)
    DrawCampaignQuad(texture, frame, slx, sly, srx, sry, elx, ely, erx, ery)
  end
  return used
end
-- Shared with the Active Front drawer's siege countdown ring (main_window.lua).
Map.LayoutRingArc = LayoutCampaignArc
Map.RING_TEXTURES = {
  track = CAMPAIGN_RING_TRACK_TEXTURE, A = CAMPAIGN_RING_ALLIANCE_TEXTURE, H = CAMPAIGN_RING_HORDE_TEXTURE,
}

-- Shares of the capture ring: live Alliance and Horde shares on an Active
-- Front node, a full ring for a zone its faction secured, none otherwise.
local function CampaignNodeShares(record)
  if record.allianceShare then return record.allianceShare, record.hordeShare end
  if record.state == "A" then return 1, 0 end
  if record.state == "H" then return 0, 1 end
  return 0, 0
end

local function GreyCampaignPiece(texture, grey)
  if not texture then return end
  if type(texture.SetDesaturation) == "function" then
    texture:SetDesaturation(grey and CAMPAIGN_LOCKED_DESATURATION or 0)
  elseif type(texture.SetDesaturated) == "function" then
    texture:SetDesaturated(grey)
  end
  local tint = CAMPAIGN_LOCKED_TINT
  if grey then
    texture:SetVertexColor(tint[1], tint[2], tint[3], 1)
  else
    texture:SetVertexColor(1, 1, 1, 1)
  end
end

-- The catapult flipbook up and right of a besieged node; it stays on its first
-- frame until Map:AnimateSieges steps it.
function Map.PaintSiegeIcons(routes, index, record, frame, x, y)
  if not record.siege then
    HideObject(routes.siegeCatapults[index])
    return
  end
  local catapult = CampaignNodeTexture(routes.siegeCatapults, index, frame, "OVERLAY", 3, CAMPAIGN_SIEGE_CATAPULT_TEXTURE)
  if not catapult then return end
  local size = CAMPAIGN_SIEGE_ICON_SIZE
  if not catapult.WarfrontFlip then catapult:SetTexCoord(0, 0.25, 0, 0.25) end
  PlaceCampaignTexture(catapult, frame, x + CAMPAIGN_ACTIVE_SIZE / 2 + size / 2 - 4,
    -(y - CAMPAIGN_ACTIVE_SIZE / 2 - size / 2 + 4), size)
end

-- The War Balance padlock (atlas piece icon.lock, 81 x 100) down and right of
-- a locked node, overlapping its rim (user, 2026-11-16).
function Map.PaintLockIcon(routes, index, record, frame, x, y, nodeSize)
  local list = routes.lockIcons
  if record.state ~= "locked" then
    HideObject(list[index])
    return
  end
  local icon = list[index]
  if not icon then
    local skin = WF.Skin
    if not skin or type(skin.GreyLock) ~= "function" then return end
    -- Grey like the locked node it marks, lightened (user, 2026-11-16).
    icon = skin:GreyLock(frame, 10, 12)
    if not icon then return end
    list[index] = icon
  end
  icon:ClearAllPoints()
  icon:SetPoint("CENTER", frame, "TOPLEFT", x + nodeSize / 2 - 2, -(y + nodeSize / 2 - 2))
  icon:Show()
end

-- The capital POI's crown, in its holder's colour (user, 2026-11-20): alone
-- before the capital is attacked, inside the disc once it is the target.
function Map.PaintCapitalCrown(routes, index, record, frame, x, y, size)
  local path, left, right, top, bottom =
    Map.GetIcon("CAPITAL", FRONT_OWNER_KEYS[record.owner] or "ALLIANCE")
  local crown = CampaignNodeTexture(routes.capitalBadges, index, frame, "OVERLAY", 2, path)
  if not crown then return end
  crown:SetTexCoord(left, right, top, bottom)
  crown:SetVertexColor(1, 1, 1, 1)
  PlaceCampaignTexture(crown, frame, x, -y, size)
end

local function PaintCampaignNode(routes, index, record)
  if not record then return end
  local frame = routes.frame
  local shadow = CampaignFileTexture(routes.nodeShadows, index, frame, "BORDER", CAMPAIGN_NODE_SHADOW_TEXTURE)
  local glow = CampaignNodeTexture(routes.glows, index, frame, "BORDER", 1, CAMPAIGN_NODE_GLOW_TEXTURE)
  local track = CampaignNodeTexture(routes.tracks, index, frame, "ARTWORK", 0, CAMPAIGN_RING_TRACK_TEXTURE)
  local center = CampaignNodeTexture(routes.centers, index, frame, "ARTWORK", 2, CAMPAIGN_NODE_CENTER_TEXTURE)
  local label = CampaignLabel(routes.labels, index, frame)
  local active = record.state == "active"
  -- A faction emblem stands alone: no disc, ring or number under it. Secured
  -- zones get theirs from the zone markers; a capital not yet attacked shows
  -- its holder's capital crown here.
  local capitalEmblem = record.capital and not active
  if record.emblem or capitalEmblem then
    HideObject(shadow)
    HideObject(glow)
    HideObject(track)
    HideObject(center)
    local arcs = routes.arcs[index] or {}
    for arc = 1, #arcs do HideObject(arcs[arc]) end
    HideObject(routes.digits[index])
    HideObject(label)
    HideObject(routes.siegeCatapults[index])
    HideObject(routes.lockIcons[index])
    if capitalEmblem then
      Map.PaintCapitalCrown(routes, index, record, frame, record.cx, record.cy, CAMPAIGN_CAPITAL_CROWN_SIZE)
    else
      HideObject(routes.capitalBadges[index])
    end
    return
  end
  -- Your pressed Settlement (decision 0111): an alert ring, red once besieged.
  local ring = record.threat and record.threat >= 2 and CAMPAIGN_THREAT_COLORS[record.threat]
  local hovered = record == Map.hoverCampaignFront
  local nodeSize = (active or ring) and CAMPAIGN_ACTIVE_SIZE or CAMPAIGN_NODE_SIZE
  local ringSize = CAMPAIGN_THREAT_RING_SIZE
  if hovered then nodeSize, ringSize = nodeSize + 4, ringSize + 4 end
  local x, y = record.cx, record.cy
  -- The painted pieces carry their own outline: the shadow texture only draws
  -- the alert ring, no extra dark halo that would thicken the node's border.
  if ring and shadow then
    shadow:SetVertexColor(ring[1], ring[2], ring[3], 1)
    PlaceCampaignTexture(shadow, frame, x, -y, ringSize)
  else
    HideObject(shadow)
  end
  PlaceCampaignTexture(track, frame, x, -y, nodeSize)
  PlaceCampaignTexture(center, frame, x, -y, nodeSize)
  -- A locked front is faded to grey-beige (user, 2026-11-14).
  local locked = record.state == "locked"
  GreyCampaignPiece(center, locked)
  GreyCampaignPiece(track, locked)
  if hovered then
    PlaceCampaignTexture(glow, frame, x, -y, nodeSize * CAMPAIGN_GLOW_SCALE)
  else
    HideObject(glow)
  end

  -- Capture ring: Alliance clockwise from the top, Horde anticlockwise from
  -- the top, the rest left as the empty track.
  local arcs = routes.arcs[index] or {}
  routes.arcs[index] = arcs
  local alliance, horde = CampaignNodeShares(record)
  local full = 2 * math.pi
  local used = LayoutCampaignArc(arcs, 0, frame, CAMPAIGN_RING_ALLIANCE_TEXTURE, x, y, nodeSize,
    0, full * math.min(1, alliance))
  used = LayoutCampaignArc(arcs, used, frame, CAMPAIGN_RING_HORDE_TEXTURE, x, y, nodeSize,
    full * (1 - math.min(1, horde)), full)
  for arc = used + 1, #arcs do HideObject(arcs[arc]) end

  if record.capital then
    Map.PaintCapitalCrown(routes, index, record, frame, x, y, nodeSize * CAMPAIGN_CAPITAL_CROWN_IN_DISC)
  else
    HideObject(routes.capitalBadges[index])
  end
  Map.PaintSiegeIcons(routes, index, record, frame, x, y)
  Map.PaintLockIcon(routes, index, record, frame, x, y, nodeSize)

  -- Numbers 1-9 are drawn from RouteNodeDigits (each digit's ink centred in
  -- the node layout), placed and sized exactly like the disc, so they always
  -- sit in its middle; a font string's glyph box cannot guarantee that.
  local value = not record.capital and record.index
  local digit = value and value <= 9
    and CampaignNodeTexture(routes.digits, index, frame, "OVERLAY", 1, CAMPAIGN_NODE_DIGITS_TEXTURE)
  if digit then
    local column, row = value % 4, mathFloor(value / 4)
    digit:SetTexCoord(column / 4, (column + 1) / 4, row / 4, (row + 1) / 4)
    digit:SetVertexColor(0.10, 0.06, 0.02, 1)
    PlaceCampaignTexture(digit, frame, x, -y, nodeSize)
    HideObject(label)
    return
  end
  HideObject(routes.digits[index])
  if not label then return end
  if not value then
    HideObject(label)
    return
  end
  label:ClearAllPoints()
  label:SetPoint("CENTER", frame, "TOPLEFT", x, -y)
  label:SetText(tostring(value))
  label:Show()
end

function Map:RefreshCampaignNodes()
  local routes = Map.campaignRoutes
  for index = 1, routes.nodeCount do PaintCampaignNode(routes, index, routes.records[index]) end
end

local function RotateCampaignTexture(texture, angle)
  if texture and type(texture.SetRotation) == "function" and math.atan2 then texture:SetRotation(angle) end
end

-- Line pieces: under every node and chevron (BACKGROUND), one textured pass
-- carrying the halo, outline and shaded core. Pixel snapping off, as Questie
-- does, so the stretched vertices do not jitter.
local function CampaignLineTexture(list, index, frame, sublevel)
  local texture = list[index]
  if texture then return texture end
  if type(frame.CreateTexture) ~= "function" then return nil end
  local ok, created = pcall(frame.CreateTexture, frame, nil, "BACKGROUND", nil, sublevel)
  if not ok or not created or type(created.SetVertexOffset) ~= "function" then return nil end
  if type(created.SetSnapToPixelGrid) == "function" then created:SetSnapToPixelGrid(false) end
  if type(created.SetTexelSnappingBias) == "function" then created:SetTexelSnappingBias(0) end
  -- 16 rows for a line about 18 screen px wide, filtered like the map canvas
  -- itself (Blizzard_MapCanvasDetailLayer uses "TRILINEAR"): no aliasing.
  created:SetTexture(CAMPAIGN_LINE_TEXTURE, "CLAMP", "CLAMP", "TRILINEAR")
  created:SetTexCoord(0, 1, 0, 1)
  list[index] = created
  return created
end

local function CampaignUnit(x, y)
  local length = math.sqrt(x * x + y * y)
  if length <= 0 then return 0, 0, 0 end
  return x / length, y / length, length
end

-- Tangent directions of a run of points: the bisector of the chords at each
-- inner node, and the mirror of the next tangent across the chord at the ends,
-- so a run bends evenly through its nodes and its end segments bow naturally.
local function CampaignTangents(run)
  local count, tx, ty = #run, {}, {}
  for index = 2, count - 1 do
    local ix, iy = CampaignUnit(run[index].px - run[index - 1].px, run[index].py - run[index - 1].py)
    local ox, oy = CampaignUnit(run[index + 1].px - run[index].px, run[index + 1].py - run[index].py)
    local x, y, length = CampaignUnit(ix + ox, iy + oy)
    if length <= 0 then x, y = ox, oy end
    tx[index], ty[index] = x, y
  end
  local function Mirror(chordX, chordY, nextX, nextY)
    local ux, uy = CampaignUnit(chordX, chordY)
    if not nextX then return ux, uy end
    local dot = ux * nextX + uy * nextY
    return 2 * dot * ux - nextX, 2 * dot * uy - nextY
  end
  tx[1], ty[1] = Mirror(run[2].px - run[1].px, run[2].py - run[1].py, tx[2], ty[2])
  tx[count], ty[count] = Mirror(run[count].px - run[count - 1].px, run[count].py - run[count - 1].py,
    tx[count - 1], ty[count - 1])
  return tx, ty
end

-- Route layout begin ---------------------------------------------------------
-- Each segment is one cubic Bezier between its two nodes (the join hides under
-- the node disc or emblem). A route that doubles back (Eastern Kingdoms: south,
-- north, then south again) makes the smooth through-curve cross itself and run
-- over other nodes, so each segment picks its bend: the Hermite through-curve
-- (shared tangents, the default look) or a bow of h0 / h1 chord lengths to the
-- left of the chord at its first / second control point, at most
-- LAYOUT_MAX_BOW (user, 2026-11-14: wider arcs read as detours). A hook moves
-- one control point past its node (LAYOUT_HOOK_ALONG) so the segment can wrap
-- around a node next to its end (user, 2026-11-14: Kalimdor 2 -> 3 runs west
-- of node 4 instead of crossing 4 -> 5); its length cost keeps it rare.
-- The layout cost is a sum of per-segment terms (extra length, leaving the
-- map, running over or near another node) and per-pair terms (crossings,
-- running along another line). A branch and bound over every segment's grid
-- bends, longest segments first, finds the cheapest layout; a fine local pass
-- then polishes each bend. Positions are fixed for a map size, so the result
-- is cached.
local LAYOUT_STEPS = 10
local LAYOUT_CLEAR = 25      -- canvas units kept from other nodes' centres
local LAYOUT_OVER = 13       -- closer than this, the line runs over the node
local LAYOUT_GAP = 10        -- canvas units kept from other lines
local LAYOUT_JOIN = 15       -- crossings this close to a shared node are joins
local LAYOUT_JOIN_GAP = 25   -- no line-gap cost this close to a shared node
local LAYOUT_SLACK = 1.06    -- length allowed before the length cost starts
local LAYOUT_EDGE = 12       -- canvas units kept inside the map's edges
local LAYOUT_GRID = { -0.5, -0.25, 0, 0.25, 0.5 }
local LAYOUT_HOOK_OTHER = { -0.25, 0, 0.25 }
local LAYOUT_FINE = { 0.125, 0.0625 }
local LAYOUT_MAX_BOW = 0.5
local LAYOUT_HOOK_ALONG = -1 / 3
local LAYOUT_HOOK = { -0.875, -0.75, -0.625, 0.625, 0.75, 0.875 }
local LAYOUT_MAX_HOOK = 0.875
local LAYOUT_POLISH = 8
local layoutCache, layoutCacheSize = {}, 0

-- Control points of segment k for bend (h0, h1), or the Hermite through-curve
-- when h0 is nil: a.px, a.py, c1x, c1y, c2x, c2y, b.px, b.py. s0 / s1 place
-- the control points along the chord (default a third in from each node).
local function LayoutControls(run, k, h0, h1, tx, ty, s0, s1)
  local a, b = run[k], run[k + 1]
  local cx, cy = b.px - a.px, b.py - a.py
  local length = math.sqrt(cx * cx + cy * cy)
  if not h0 or length <= 0 then
    return a.px, a.py, a.px + tx[k] * length / 3, a.py + ty[k] * length / 3,
      b.px - tx[k + 1] * length / 3, b.py - ty[k + 1] * length / 3, b.px, b.py
  end
  local nx, ny = -cy, cx -- left normal (y down), one chord long
  s0, s1 = s0 or 1 / 3, s1 or 1 / 3
  return a.px, a.py, a.px + cx * s0 + nx * h0, a.py + cy * s0 + ny * h0,
    b.px - cx * s1 + nx * h1, b.py - cy * s1 + ny * h1, b.px, b.py
end

-- Samples a Bezier into a line record: xs, ys (steps + 1 points) and its box.
local function LayoutLine(ax, ay, c1x, c1y, c2x, c2y, bx, by, steps)
  local xs, ys = {}, {}
  local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
  for i = 0, steps do
    local t = i / steps
    local u = 1 - t
    local w0, w1, w2, w3 = u * u * u, 3 * u * u * t, 3 * u * t * t, t * t * t
    local x = w0 * ax + w1 * c1x + w2 * c2x + w3 * bx
    local y = w0 * ay + w1 * c1y + w2 * c2y + w3 * by
    xs[i + 1], ys[i + 1] = x, y
    if x < minX then minX = x end
    if x > maxX then maxX = x end
    if y < minY then minY = y end
    if y > maxY then maxY = y end
  end
  return { xs = xs, ys = ys, minX = minX, minY = minY, maxX = maxX, maxY = maxY }
end

local function LayoutCrosses(x1, y1, x2, y2, x3, y3, x4, y4)
  local d1x, d1y, d2x, d2y = x2 - x1, y2 - y1, x4 - x3, y4 - y3
  local den = d1x * d2y - d1y * d2x
  if den == 0 then return false end
  local s = ((x3 - x1) * d2y - (y3 - y1) * d2x) / den
  local t = ((x3 - x1) * d1y - (y3 - y1) * d1x) / den
  return s > 0 and s < 1 and t > 0 and t < 1
end

-- Crossings of line with other, ignoring those within LAYOUT_JOIN of their
-- shared node (nil when the segments are not neighbours).
local function LayoutCrossCount(line, other, shared)
  local xs, ys, oxs, oys = line.xs, line.ys, other.xs, other.ys
  local count = 0
  for i = 1, #xs - 1 do
    local x1, y1, x2, y2 = xs[i], ys[i], xs[i + 1], ys[i + 1]
    local nearJoin = false
    if shared then
      local dx, dy = x1 - shared.px, y1 - shared.py
      nearJoin = dx * dx + dy * dy < LAYOUT_JOIN * LAYOUT_JOIN
    end
    if not nearJoin then
      local loX, hiX = mathMin(x1, x2), mathMax(x1, x2)
      local loY, hiY = mathMin(y1, y2), mathMax(y1, y2)
      for q = 1, #oxs - 1 do
        local x3, y3, x4, y4 = oxs[q], oys[q], oxs[q + 1], oys[q + 1]
        if mathMax(x3, x4) >= loX and mathMin(x3, x4) <= hiX and mathMax(y3, y4) >= loY
            and mathMin(y3, y4) <= hiY and LayoutCrosses(x1, y1, x2, y2, x3, y3, x4, y4) then
          count = count + 1
        end
      end
    end
  end
  return count
end

local function LayoutPointToLine(px, py, line)
  local xs, ys, best = line.xs, line.ys, math.huge
  for q = 1, #xs - 1 do
    local ax, ay = xs[q], ys[q]
    local dx, dy = xs[q + 1] - ax, ys[q + 1] - ay
    local l2 = dx * dx + dy * dy
    local t = 0
    if l2 > 0 then t = mathMax(0, mathMin(1, ((px - ax) * dx + (py - ay) * dy) / l2)) end
    local ex, ey = px - ax - t * dx, py - ay - t * dy
    local d2 = ex * ex + ey * ey
    if d2 < best then best = d2 end
  end
  return math.sqrt(best)
end

-- Per-segment cost of segment k drawn as line.
local function LayoutUnary(run, k, line, bent, width, height)
  local a, b = run[k], run[k + 1]
  local xs, ys = line.xs, line.ys
  local n = #xs
  local cx, cy = b.px - a.px, b.py - a.py
  local chord = math.sqrt(cx * cx + cy * cy)
  if chord <= 0 then return 0 end
  local length = 0
  for i = 1, n - 1 do
    local dx, dy = xs[i + 1] - xs[i], ys[i + 1] - ys[i]
    length = length + math.sqrt(dx * dx + dy * dy)
  end
  local cost = 1000 * mathMax(0, length / chord - LAYOUT_SLACK)
  if bent then cost = cost + 3 end
  if line.minX < LAYOUT_EDGE or line.minY < LAYOUT_EDGE
      or line.maxX > width - LAYOUT_EDGE or line.maxY > height - LAYOUT_EDGE then
    for i = 1, n do
      local x, y = xs[i], ys[i]
      if x < LAYOUT_EDGE or y < LAYOUT_EDGE or x > width - LAYOUT_EDGE or y > height - LAYOUT_EDGE then
        cost = cost + 300
      end
    end
  end
  for j = 1, #run do
    if j ~= k and j ~= k + 1 then
      local nx, ny = run[j].px, run[j].py
      if nx >= line.minX - LAYOUT_CLEAR and nx <= line.maxX + LAYOUT_CLEAR
          and ny >= line.minY - LAYOUT_CLEAR and ny <= line.maxY + LAYOUT_CLEAR then
        local d = LayoutPointToLine(nx, ny, line)
        -- Running over a node reads worse than a crossing.
        if d < LAYOUT_OVER then
          cost = cost + 3000
        elseif d < LAYOUT_CLEAR then
          local f = (LAYOUT_CLEAR - d) / (LAYOUT_CLEAR - LAYOUT_OVER)
          cost = cost + 100 * f * f
        end
      end
    end
  end
  return cost
end

-- Cost segment k (line) pays against segment m (other): crossings, and its
-- samples running within LAYOUT_GAP of other.
local function LayoutPairOneWay(run, k, line, m, other)
  if other.maxX + LAYOUT_GAP < line.minX or other.minX - LAYOUT_GAP > line.maxX
      or other.maxY + LAYOUT_GAP < line.minY or other.minY - LAYOUT_GAP > line.maxY then
    return 0
  end
  local shared = (m == k - 1 and run[k]) or (m == k + 1 and run[k + 1]) or nil
  local cost = 1000 * LayoutCrossCount(line, other, shared)
  local xs, ys = line.xs, line.ys
  for i = 2, #xs - 1 do
    local px, py = xs[i], ys[i]
    local skip = false
    if shared then
      local dx, dy = px - shared.px, py - shared.py
      skip = dx * dx + dy * dy < LAYOUT_JOIN_GAP * LAYOUT_JOIN_GAP
    end
    if not skip and px >= other.minX - LAYOUT_GAP and px <= other.maxX + LAYOUT_GAP
        and py >= other.minY - LAYOUT_GAP and py <= other.maxY + LAYOUT_GAP then
      local d = LayoutPointToLine(px, py, other)
      if d < LAYOUT_GAP then
        local f = (LAYOUT_GAP - d) / LAYOUT_GAP
        cost = cost + 40 * f * f
      end
    end
  end
  return cost
end

-- Bend choices of every segment of run: false for the through-curve, or
-- { h0, h1 [, s0, s1] }.
local function LayoutRun(run, tx, ty, width, height)
  local count = #run - 1
  local function Line(k, bend)
    local ax, ay, c1x, c1y, c2x, c2y, bx, by =
      LayoutControls(run, k, bend and bend[1], bend and bend[2], tx, ty, bend and bend[3],
        bend and bend[4])
    return LayoutLine(ax, ay, c1x, c1y, c2x, c2y, bx, by, LAYOUT_STEPS)
  end
  local bends = { false }
  for i = 1, #LAYOUT_GRID do
    for j = 1, #LAYOUT_GRID do bends[#bends + 1] = { LAYOUT_GRID[i], LAYOUT_GRID[j] } end
  end
  for i = 1, #LAYOUT_HOOK_OTHER do
    for j = 1, #LAYOUT_HOOK do
      bends[#bends + 1] = { LAYOUT_HOOK_OTHER[i], LAYOUT_HOOK[j], 1 / 3, LAYOUT_HOOK_ALONG }
      bends[#bends + 1] = { LAYOUT_HOOK[j], LAYOUT_HOOK_OTHER[i], LAYOUT_HOOK_ALONG, 1 / 3 }
    end
  end
  local lines, unary, minUnary = {}, {}, {}
  for k = 1, count do
    lines[k], unary[k], minUnary[k] = {}, {}, math.huge
    for c = 1, #bends do
      lines[k][c] = Line(k, bends[c])
      unary[k][c] = LayoutUnary(run, k, lines[k][c], bends[c] and true, width, height)
      if unary[k][c] < minUnary[k] then minUnary[k] = unary[k][c] end
    end
  end
  -- Pair costs, computed on demand: pairs[k][m][(c - 1) * #bends + d].
  local pairs = {}
  local function Pair(k, c, m, d)
    local key = (c - 1) * #bends + d
    local row = pairs[k * 64 + m]
    if not row then row = {}; pairs[k * 64 + m] = row end
    local value = row[key]
    if not value then
      value = LayoutPairOneWay(run, k, lines[k][c], m, lines[m][d])
        + LayoutPairOneWay(run, m, lines[m][d], k, lines[k][c])
      row[key] = value
    end
    return value
  end
  -- Longest segments first: they decide the layout and prune the most.
  local order = {}
  for k = 1, count do order[k] = k end
  local function Chord(k)
    local dx, dy = run[k + 1].px - run[k].px, run[k + 1].py - run[k].py
    return dx * dx + dy * dy
  end
  table.sort(order, function(a, b) return Chord(a) > Chord(b) end)
  local rest = {}
  rest[count + 1] = 0
  for depth = count, 1, -1 do rest[depth] = rest[depth + 1] + minUnary[order[depth]] end
  local assign, best, bestCost = {}, {}, 0
  -- Start bound: every segment on its through-curve.
  for depth = 1, count do
    local k = order[depth]
    bestCost = bestCost + unary[k][1]
    for e = 1, depth - 1 do bestCost = bestCost + Pair(k, 1, order[e], 1) end
    best[k] = 1
  end
  local function Search(depth, partial)
    if depth > count then
      bestCost = partial
      for k = 1, count do best[k] = assign[k] end
      return
    end
    local k = order[depth]
    local options = {}
    for c = 1, #bends do
      local value = unary[k][c]
      if partial + value + rest[depth + 1] < bestCost then
        for e = 1, depth - 1 do
          local m = order[e]
          value = value + Pair(k, c, m, assign[m])
          if partial + value + rest[depth + 1] >= bestCost then break end
        end
        if partial + value + rest[depth + 1] < bestCost then options[#options + 1] = { c, value } end
      end
    end
    table.sort(options, function(a, b) return a[2] < b[2] end)
    for i = 1, #options do
      local option = options[i]
      if partial + option[2] + rest[depth + 1] < bestCost then
        assign[k] = option[1]
        Search(depth + 1, partial + option[2])
      end
    end
  end
  Search(1, 0)
  -- Polish: move each bend by LAYOUT_FINE steps while the layout gets cheaper.
  local choice, current = {}, {}
  for k = 1, count do choice[k], current[k] = bends[best[k]], lines[k][best[k]] end
  local function Cost(k, line, bend)
    local cost = LayoutUnary(run, k, line, bend and true, width, height)
    for m = 1, count do
      if m ~= k then
        cost = cost + LayoutPairOneWay(run, k, line, m, current[m])
          + LayoutPairOneWay(run, m, current[m], k, line)
      end
    end
    return cost
  end
  for f = 1, #LAYOUT_FINE do
    local step = LAYOUT_FINE[f]
    for _ = 1, LAYOUT_POLISH do
      local moved = false
      for k = 1, count do
        local bend = choice[k]
        if bend then
          local pick, pickLine, pickCost = bend, current[k], Cost(k, current[k], bend)
          local max0 = bend[3] and bend[3] < 0 and LAYOUT_MAX_HOOK or LAYOUT_MAX_BOW
          local max1 = bend[4] and bend[4] < 0 and LAYOUT_MAX_HOOK or LAYOUT_MAX_BOW
          for di = -1, 1 do
            for dj = -1, 1 do
              local h0, h1 = bend[1] + di * step, bend[2] + dj * step
              if (di ~= 0 or dj ~= 0) and mathAbs(h0) <= max0 + 1e-6
                  and mathAbs(h1) <= max1 + 1e-6 then
                local candidate = { h0, h1, bend[3], bend[4] }
                local line = Line(k, candidate)
                local cost = Cost(k, line, candidate)
                if cost < pickCost - 1e-6 then pick, pickLine, pickCost = candidate, line, cost end
              end
            end
          end
          if pick ~= bend then moved = true end
          choice[k], current[k] = pick, pickLine
        end
      end
      if not moved then break end
    end
  end
  return choice
end

-- Bezier controls of every segment of run, cached by node positions and map size.
local function CampaignRunLayout(run, width, height)
  local tx, ty = CampaignTangents(run)
  local parts = {}
  for i = 1, #run do
    parts[#parts + 1] = mathFloor(run[i].px * 2 + 0.5) .. ":" .. mathFloor(run[i].py * 2 + 0.5)
  end
  parts[#parts + 1] = mathFloor(width + 0.5) .. "x" .. mathFloor(height + 0.5)
  local key = table.concat(parts, ",")
  local choice = layoutCache[key]
  if not choice then
    choice = #run > 2 and LayoutRun(run, tx, ty, width, height) or {}
    if layoutCacheSize >= 16 then layoutCache, layoutCacheSize = {}, 0 end
    layoutCache[key], layoutCacheSize = choice, layoutCacheSize + 1
  end
  local controls = {}
  for k = 1, #run - 1 do
    local bend = choice[k]
    controls[k] = { LayoutControls(run, k, bend and bend[1], bend and bend[2], tx, ty,
      bend and bend[3], bend and bend[4]) }
  end
  return controls
end
-- Route layout end -----------------------------------------------------------

-- Samples a run into one polyline of its segments' Bezier curves (see the
-- route layout above). segments[k] is the polyline index where segment k
-- (run[k] to run[k + 1]) starts; segments[#run] is the last point.
local function SampleCampaignRun(run, width, height)
  local controls = CampaignRunLayout(run, width, height)
  local points, segments = { { x = run[1].px, y = run[1].py } }, {}
  for index = 1, #run - 1 do
    local c = controls[index]
    segments[index] = #points
    -- Control polygon length: an upper bound of the curve's length.
    local hull = 0
    for p = 1, 5, 2 do
      local dx, dy = c[p + 2] - c[p], c[p + 3] - c[p + 1]
      hull = hull + math.sqrt(dx * dx + dy * dy)
    end
    local pieces = math.max(2, math.min(CAMPAIGN_CURVE_MAX_PIECES, math.ceil(hull / CAMPAIGN_CURVE_STEP)))
    for piece = 1, pieces do
      local t = piece / pieces
      local u = 1 - t
      local w0, w1, w2, w3 = u * u * u, 3 * u * u * t, 3 * u * t * t, t * t * t
      points[#points + 1] = {
        x = w0 * c[1] + w1 * c[3] + w2 * c[5] + w3 * c[7],
        y = w0 * c[2] + w1 * c[4] + w2 * c[6] + w3 * c[8],
      }
    end
  end
  segments[#run] = #points
  return points, segments
end

-- Left and right outline corners of the polyline at point index, half pixels
-- to each side: a miter on the bisector of the two chords, or the chord's own
-- normal at an end. Left is the side of the normal (-dy, dx).
local function CampaignCorner(points, index, half)
  local p = points[index]
  local ax, ay, bx, by = 0, 0, 0, 0
  if index > 1 then ax, ay = CampaignUnit(p.x - points[index - 1].x, p.y - points[index - 1].y) end
  if index < #points then bx, by = CampaignUnit(points[index + 1].x - p.x, points[index + 1].y - p.y) end
  local unitX, unitY, length = CampaignUnit(-(ay + by), ax + bx)
  if length <= 0 then unitX, unitY = -by, bx end
  local scale = half
  if index > 1 and index < #points and length > 0 then
    -- The miter grows by 1 / cos(turn / 2), cut at the limit.
    local cosHalf = unitX * -ay + unitY * ax
    scale = half / math.max(cosHalf, 1 / CAMPAIGN_MITER_LIMIT)
  end
  return p.x + unitX * scale, p.y + unitY * scale, p.x - unitX * scale, p.y - unitY * scale
end

-- Draws chords first..last of a sampled run at one width, untinted, after the
-- used textures of list; flip turns the texture's rows over so its pale edge
-- changes side. Returns the new count.
local function DrawCampaignChords(list, used, frame, sublevel, points, first, last, half, flip)
  local slx, sly, srx, sry = CampaignCorner(points, first, half)
  for index = first + 1, last do
    local elx, ely, erx, ery = CampaignCorner(points, index, half)
    if used >= CAMPAIGN_ROUTE_MAX_PIECES then return used end
    local texture = CampaignLineTexture(list, used + 1, frame, sublevel)
    if not texture then return used end
    used = used + 1
    texture:SetVertexColor(1, 1, 1, 1)
    if flip then texture:SetTexCoord(0, 1, 1, 0) else texture:SetTexCoord(0, 1, 0, 1) end
    DrawCampaignQuad(texture, frame, slx, sly, srx, sry, elx, ely, erx, ery)
    slx, sly, srx, sry = elx, ely, erx, ery
  end
  return used
end

-- The point at share t of the arc from points[first] to points[last], and the
-- direction there.
local function CampaignArcPoint(points, first, last, t)
  local total = 0
  for index = first + 1, last do
    local _, _, length = CampaignUnit(points[index].x - points[index - 1].x, points[index].y - points[index - 1].y)
    total = total + length
  end
  local goal = t * total
  for index = first + 1, last do
    local a, b = points[index - 1], points[index]
    local ux, uy, length = CampaignUnit(b.x - a.x, b.y - a.y)
    if goal <= length or index == last then
      return a.x + ux * goal, a.y + uy * goal, ux, uy
    end
    goal = goal - length
  end
  return points[first].x, points[first].y, 1, 0
end

-- chevrons: nil or a list of { reverse, lead, own, color, alpha }; a reverse chevron
-- points from the segment's end to its start; a lead one sits before the
-- start, along the curve's first direction, pointing at it.
local function LayoutCampaignChevrons(routes, frame, points, first, last, chevrons, arrowUsed)
  for index = 1, chevrons and #chevrons or 0 do
    local spec = chevrons[index]
    local arrow = CampaignNodeTexture(routes.arrows, arrowUsed + 1, frame, "OVERLAY", 0,
      CAMPAIGN_CHEVRON_TINT_TEXTURE)
    if arrow then
      arrowUsed = arrowUsed + 1
      local x, y, dx, dy
      if spec.lead then
        x, y, dx, dy = CampaignArcPoint(points, first, last, 0)
        x, y = x - dx * CAMPAIGN_CHEVRON_LEAD, y - dy * CAMPAIGN_CHEVRON_LEAD
      else
        x, y, dx, dy = CampaignArcPoint(points, first, last, spec.reverse and 0.38 or 0.62)
      end
      local angle = math.atan2 and math.atan2(-dy, dx) or 0
      local color = spec.color
      arrow:SetVertexColor(color[1], color[2], color[3], spec.alpha)
      PlaceCampaignTexture(arrow, frame, x, -y, CAMPAIGN_CHEVRON_SIZE)
      RotateCampaignTexture(arrow, spec.reverse and angle + math.pi or angle)
      -- Hover point (canvas pixels) for the chevron tooltip.
      local hits = routes.chevronHits
      hits[#hits + 1] = { x = x, y = y, side = spec.side, color = color,
        target = spec.target, key = spec.key }
    end
  end
  return arrowUsed
end

-- Draws every run of consecutive projected nodes of one route (points[1] to
-- points[total + 1], gaps where a node has no position): the textured line
-- of each segment, then its chevrons. Returns the counts used.
local function LayoutCampaignRoute(routes, frame, points, total, chevrons, width, height,
    lineUsed, arrowUsed, segmentUsed)
  local index = 1
  while index <= total + 1 do
    local run, firstIndex = {}, index
    while index <= total + 1 and points[index] do
      local record = points[index]
      record.px, record.py = record.x * width, record.y * height
      run[#run + 1] = record
      index = index + 1
    end
    if #run >= 2 then
      local polyline, segments = SampleCampaignRun(run, width, height)
      -- The texture's top rows (pale edge) lie on the left of the drawing
      -- direction. One choice per run, so the pale edge never jumps sides:
      -- it faces the upper left, as on the reference, for the run's overall
      -- direction (y down: left normal (-dy, dx) against (-1, -1)).
      local runX = run[#run].px - run[1].px
      local runY = run[#run].py - run[1].py
      local flip = runY - runX < 0
      for k = 1, #run - 1 do
        local first, last = segments[k], segments[k + 1]
        lineUsed = DrawCampaignChords(routes.lines, lineUsed, frame, 0, polyline, first, last,
          CAMPAIGN_LINE_QUAD_WIDTH / 2, flip)
        arrowUsed = LayoutCampaignChevrons(routes, frame, polyline, first, last,
          chevrons[firstIndex + k - 1], arrowUsed)
        segmentUsed = segmentUsed + 1
      end
    end
    if index == firstIndex then index = index + 1 end
  end
  return lineUsed, arrowUsed, segmentUsed
end

-- Digits, locks, capital badges and siege icons exist only for some nodes:
-- their lists have holes, where # can stop early and leave pieces of another
-- view on screen (2026-11-16: world-map numbers and locks stayed on the
-- continent map). pairs reaches every entry.
local function HideCampaignList(list, first)
  for index, object in pairs(list) do
    if type(index) == "number" and index >= first then HideObject(object) end
  end
end

function Map:HideCampaignRoutes()
  local routes = self.campaignRoutes
  HideCampaignList(routes.lines, 1)
  HideCampaignList(routes.arrows, 1)
  HideCampaignList(routes.nodeShadows, 1)
  HideCampaignList(routes.glows, 1)
  HideCampaignList(routes.tracks, 1)
  HideCampaignList(routes.centers, 1)
  for _, arcs in pairs(routes.arcs) do HideCampaignList(arcs, 1) end
  HideCampaignList(routes.labels, 1)
  HideCampaignList(routes.digits, 1)
  HideCampaignList(routes.capitalBadges, 1)
  HideCampaignList(routes.siegeCatapults, 1)
  HideCampaignList(routes.lockIcons, 1)
  HideObject(routes.frame)
  routes.lineCount, routes.arrowCount, routes.nodeCount, routes.segmentCount = 0, 0, 0, 0
  routes.records = {}
  routes.chevronHits = {}
  if (self.hoverCampaignFront or self.hoverCampaignChevron) and type(self.ClearHover) == "function" then
    self:ClearHover()
  end
end

-- WarfrontDev only (/wfd siege, through MainWindow:SetSimulatedSiege): fake
-- siege windows by route id, shaped like WF.Front's, drawn with the real ones
-- on the next refresh; nil clears them. Never saved nor sent.
function Map:SetSimulatedSiege(windows)
  self.simSiege = type(windows) == "table" and windows or nil
end

-- Display-only front preview (WarfrontDev /wfd video): route targets, POI
-- owners, half-captured icons (halves) and fallen capitals (capitals, by
-- route id: the winner's emblem) drawn instead of the live ones, seen
-- from neither faction. Gameplay never reads it; nothing is saved nor sent.
-- nil restores the live view.
function Map:SetSimulatedFront(sim)
  self.simFront = type(sim) == "table" and sim or nil
  self.refreshNow = true
end

function Map:FrontTargets(front, route)
  local sim = self.simFront and self.simFront.targets and self.simFront.targets[route.id]
  if sim then return sim[1], sim[2] end
  return front:Targets(route)
end

-- The siege window running on this node of the route now (real or simulated),
-- or nil.
function Map:SiegeRunning(route, id)
  local front = WF.Front
  if not route or not front or type(front.Window) ~= "function" then return nil end
  local rec = (self.simSiege and self.simSiege[route.id]) or front:Window(route.id)
  if rec and rec.seen and rec.node == id and front:Remaining(rec) > 0 then return rec end
  return nil
end

-- Steps the siege flipbooks (columns then rows of the 4 x 4 sheet) at a
-- fixed rate; called every tick while the map is open.
function Map:AnimateSieges()
  local routes = self.campaignRoutes
  local getTime = GetGlobal("GetTime")
  local clock = type(getTime) == "function" and getTime() or (self.ticks or 0) / 60
  local step = mathFloor(clock * CAMPAIGN_SIEGE_FPS) % CAMPAIGN_SIEGE_FRAMES
  if step == self.siegeStep then return end
  self.siegeStep = step
  local column, row = step % 4, mathFloor(step / 4)
  -- The list has holes (only besieged nodes get a catapult): # can stop
  -- before a capital's catapult and freeze it on its first frame.
  local left, right, top, bottom = column / 4, (column + 1) / 4, row / 4, (row + 1) / 4
  for _, texture in pairs(routes.siegeCatapults) do
    if texture and texture:IsShown() then
      texture.WarfrontFlip = true
      texture:SetTexCoord(left, right, top, bottom)
    end
  end
  for _, texture in pairs(self.zoneSiegeIcons) do
    if texture:IsShown() then
      texture.WarfrontFlip = true
      texture:SetTexCoord(left, right, top, bottom)
    end
  end
end

function Map:RefreshCampaignRoutes(continentKey, width, height)
  local front = WF.Front
  if not front or type(front.HasRoutes) ~= "function" or not front:HasRoutes()
      or type(front.Targets) ~= "function" then
    self:HideCampaignRoutes()
    return 0
  end
  local routes = self.campaignRoutes
  if not routes.frame then routes.frame = CreateGroup("WarfrontMapCampaignRoutes", 1, true) end
  local frame = routes.frame
  if not frame then return 0 end
  local lineUsed, arrowUsed, nodeUsed, segmentUsed = 0, 0, 0, 0
  local capture = WF.Capture
  local playerSide = not self.simFront and capture and type(capture.MyFaction) == "function"
    and capture:MyFaction()
  -- Live capture shares of the Active Front zones, shown by their node's ring.
  -- Secured zones show their faction emblem on the node's spot instead.
  local fronts, emblems = {}, {}
  local zones = self:FrontZones(continentKey)
  for index = 1, #zones do
    if zones[index].activeFront then fronts[zones[index].mapKey] = zones[index] end
    if zones[index].ownerKey then emblems[zones[index].mapKey] = true end
  end
  routes.records = {}
  routes.chevronHits = {}
  for routeIndex = 1, #(front.routes or {}) do
    local route = front.routes[routeIndex]
    local total = #route.nodes
    local forward, rear = self:FrontTargets(front, route)
    local points = {}
    for index = 1, total do
      local area = self.areas[route.nodes[index].id]
      local x, y = CampaignPoint(area, continentKey)
      if x then
        points[index] = {
          x = x, y = y, id = area.id, area = area, route = route, index = index,
          forward = forward, rear = rear,
          state = CampaignNodeState(route, index, forward, rear, total, false, playerSide),
        }
      end
    end
    local capital = self.areas[route.endpoint or ""]
    local capitalX, capitalY = CampaignPoint(capital, continentKey)
    if capitalX then
      -- A fallen capital exists only in the display-only preview.
      local fallen = self.simFront and self.simFront.capitals and self.simFront.capitals[route.id]
      points[total + 1] = {
        x = capitalX, y = capitalY, id = capital.id, area = capital, route = route,
        index = total + 1, forward = forward, rear = rear, capital = true,
        owner = fallen or (route.advancing == "H" and "A" or "H"),
        state = fallen and "locked"
          or CampaignNodeState(route, total + 1, forward, rear, total, true, playerSide),
      }
    end
    -- Decision 0111: each faction's chevron points at its own target in that
    -- faction's colour (Alliance blue, Horde red), the other faction's dimmed;
    -- your pressed Settlement carries its threat level.
    local threat, threatId, lost, links = 0, nil, 0, 0
    if playerSide and type(front.Threat) == "function" then
      threat, threatId, lost, links = front:Threat(route, playerSide)
    end
    for index = 1, total + 1 do
      local record = points[index]
      if record and threatId and record.id == threatId then
        record.threat, record.lost, record.links = threat, lost, links
      end
    end
    local chevrons = {}
    local function AddChevron(segment, reverse, side, targetIndex)
      -- Target at node 1: no segment before it, so the chevron leads in from
      -- outside the route on the first segment.
      local lead = segment == 0 and not reverse
      if lead then segment = 1 end
      if segment < 1 or segment > total then return end
      local own = not playerSide or side == playerSide
      local list = chevrons[segment] or {}
      chevrons[segment] = list
      local node = route.nodes[targetIndex]
      list[#list + 1] = {
        reverse = reverse, lead = lead, own = own, side = side,
        color = CAMPAIGN_ROUTE_COLORS[side],
        alpha = CAMPAIGN_CHEVRON_ALPHA,
        target = targetIndex > total and capital or node and self.areas[node.id],
        key = tostring(route.endpoint or routeIndex) .. ":" .. side,
      }
    end
    AddChevron(forward - 1, false, route.advancing, forward)
    AddChevron(rear, true, route.advancing == "H" and "A" or "H", rear)
    lineUsed, arrowUsed, segmentUsed = LayoutCampaignRoute(routes, frame, points, total,
      chevrons, width, height, lineUsed, arrowUsed, segmentUsed)
    for index = 1, total + 1 do
      local record = points[index]
      if record then
        nodeUsed = nodeUsed + 1
        routes.records[nodeUsed] = record
        record.cx, record.cy = record.x * width, record.y * height
        local zone = not record.capital and fronts[record.area.mapKey or ""]
        if zone then record.allianceShare, record.hordeShare = zone.allianceShare, zone.hordeShare end
        record.emblem = not record.capital and emblems[record.area.mapKey or ""] or nil
        record.siege = self:SiegeRunning(route, record.id)
        -- Every periodic refresh rebuilds the records: the hovered node passes
        -- to its new record, or it would shrink, lose its tooltip and be
        -- hovered again on each refresh, pulsing endlessly.
        local hovered = self.hoverCampaignFront
        if hovered and hovered ~= record and hovered.id == record.id and hovered.index == record.index
            and hovered.route and hovered.route.endpoint == route.endpoint then
          self.hoverCampaignFront = record
        end
        PaintCampaignNode(routes, nodeUsed, record)
      end
    end
  end
  HideCampaignList(routes.lines, lineUsed + 1)
  HideCampaignList(routes.arrows, arrowUsed + 1)
  HideCampaignList(routes.nodeShadows, nodeUsed + 1)
  HideCampaignList(routes.glows, nodeUsed + 1)
  HideCampaignList(routes.tracks, nodeUsed + 1)
  HideCampaignList(routes.centers, nodeUsed + 1)
  for index, arcs in pairs(routes.arcs) do
    if index > nodeUsed then HideCampaignList(arcs, 1) end
  end
  HideCampaignList(routes.labels, nodeUsed + 1)
  HideCampaignList(routes.digits, nodeUsed + 1)
  HideCampaignList(routes.capitalBadges, nodeUsed + 1)
  HideCampaignList(routes.siegeCatapults, nodeUsed + 1)
  HideCampaignList(routes.lockIcons, nodeUsed + 1)
  routes.lineCount, routes.arrowCount = lineUsed, arrowUsed
  routes.nodeCount, routes.segmentCount = nodeUsed, segmentUsed
  local canvas = GetCanvas()
  if canvas and type(frame.SetAllPoints) == "function" then frame:SetAllPoints(canvas) end
  if nodeUsed > 0 then frame:Show() else HideObject(frame) end
  return segmentUsed
end

function Map:DrawCampaignRoutes(continentKey, width, height)
  local ok, err = pcall(Map.RefreshCampaignRoutes, Map, continentKey, width, height)
  if ok then return end
  pcall(Map.HideCampaignRoutes, Map)
  if WF.RecordError then WF.RecordError("campaign map routes", err) end
end
end)()

function Map:HideAll()
  self:HideWarCamps()
  self:HideZoneBars()
  self:HideCampaignRoutes()
  self:HideRoutes()
  self:ClearHover()
  for index = 1, #self.order do
    local entry = self.groups[self.order[index]]
    if entry then HideEntry(entry) end
  end
  self.visibleCount = 0
  self.visiblePatches = 0
  self.visibleIcons = 0
end

local function ReapplyVisibleGroups()
  local canvas = GetCanvas()
  UpdateLabelLevel()
  for index = 1, #Map.order do
    local entry = Map.groups[Map.order[index]]
    if entry and entry.active and entry.frame then
      AnchorAndShow(entry.frame, canvas)
      -- Stocks and levels change between layouts: keep labels and icons current.
      local area = Map.areas[Map.order[index]]
      if area then
        RefreshLevelIcon(entry, area)
        PlaceStockLabel(entry, area)
        Map.PaintZoneSiege(entry, area)
      end
    end
  end
end

-- Below level 5 the player cannot speak on the channel (decision 0039): the
-- POI states they see would be stale or wrong, so the maps show nothing.
function Map:Locked()
  local capture = WF.Capture
  return capture and capture.CanTalk and not capture:CanTalk() and true or false
end

local function ShownMapID()
  local frame = GetGlobal("WorldMapFrame")
  if not frame or type(frame.GetMapID) ~= "function" then return nil end
  local ok, mapID = pcall(frame.GetMapID, frame)
  if ok and type(mapID) == "number" then return mapID end
  return nil
end

local function RecordCounts(self)
  local probe = self.probe
  probe.visible, probe.patches = self.visibleCount, self.visiblePatches
  probe.icons, probe.failures, probe.queued = self.visibleIcons, self.failures, self:BuildCount()
end

local function LevelFrame(frame, base)
  if not frame or not frame.wfLevelOffset or type(frame.SetFrameLevel) ~= "function" then
    return true
  end
  local want = GroupLevel(frame, base)
  local ok, level = pcall(frame.GetFrameLevel, frame)
  if ok and level == want then return true end
  return pcall(frame.SetFrameLevel, frame, want)
end

-- Moves every layer when the base level changes (OpenMap stitched on or
-- off, its art rebuilt, or the map's own level moved).
local function ApplyBaseLevel(canvas)
  local base = BaseLevel(canvas)
  if not base or base == Map.appliedBase then return end
  local done = LevelFrame(Map.routes and Map.routes.frame, base)
  done = LevelFrame(Map.campaignRoutes and Map.campaignRoutes.frame, base) and done
  done = LevelFrame(Map.zoneBars and Map.zoneBars.frame, base) and done
  done = LevelFrame(Map.warCamps and Map.warCamps.frame, base) and done
  for _, entry in pairs(Map.groups) do
    done = LevelFrame(entry.frame, base) and done
  end
  UpdateLabelLevel()
  for _, entry in pairs(Map.groups) do RaiseLabelFrame(entry) end
  -- A refused move (combat) is tried again on the next refresh.
  if done then Map.appliedBase = base end
end

-- The player's own capital area is never drawn (user, 2026-11-14): only the
-- enemy capitals show. Nil while the faction is unknown: every capital shows.
local OWN_CAPITAL_FACTIONS = { A = "ALLIANCE", H = "HORDE" }
local function OwnCapitalFaction()
  local capture = WF.Capture
  local mine = capture and type(capture.MyFaction) == "function" and capture:MyFaction()
  return mine and OWN_CAPITAL_FACTIONS[mine] or nil
end
Map.OwnCapitalFaction = OwnCapitalFaction

-- True for the player's own capital, hidden on the map and the minimap.
function Map.IsOwnCapital(area, ownCapital)
  return ownCapital ~= nil and area.type == "CAPITAL"
    and Map.CAPITAL_FACTIONS[area.mapKey] == ownCapital
end

-- Campaign routes and zone markers on OpenMap's stitched world (Campaign
-- routes filter); hides them on every other view or when the filter is off.
function Map:HideWarCamps()
  local camps = self.warCamps
  for index = 1, #camps.icons do HideObject(camps.icons[index]) end
  HideObject(camps.frame)
  camps.count, camps.records = 0, {}
  if self.hoverCamp then self:ClearHover() end
end

-- One icon per enabled War Camp the view shows, placed like the campaign
-- nodes (continent key, "world"); records feed the hover.
function Map:RefreshWarCamps(continentKey, width, height)
  local camps = self.warCamps
  if not camps.frame then camps.frame = CreateGroup("WarfrontMapWarCamps", 1, true) end
  local frame = camps.frame
  if not frame then return end
  local used = 0
  camps.records = {}
  for index = 1, #self.order do
    local area = self.areas[self.order[index]]
    if area and area.enabled and area.type == "WAR_CAMP" then
      local x, y = CampaignPoint(area, continentKey)
      local path, left, right, top, bottom, pw, ph
      if x then path, left, right, top, bottom, pw, ph = Map.GetIcon(area.type, area.colorKey, area.iconColumn) end
      if path then
        used = used + 1
        local icon = camps.icons[used]
        if not icon then
          icon = frame:CreateTexture(nil, "OVERLAY")
          camps.icons[used] = icon
        end
        icon:SetTexture(path)
        icon:SetTexCoord(left, right, top, bottom)
        -- 20 % smaller than on zone maps, still under the route nodes (user,
        -- 2026-11-16: 40 % was too small).
        local iconWidth, iconHeight = Map.FitIcon(IconSize(area.type) * 0.8, pw, ph)
        icon:SetWidth(iconWidth * Map.iconZoom)
        icon:SetHeight(iconHeight * Map.iconZoom)
        icon:ClearAllPoints()
        icon:SetPoint("CENTER", frame, "TOPLEFT", x * width, -y * height)
        icon:Show()
        camps.records[used] = { id = area.id, x = x, y = y }
      end
    end
  end
  for index = used + 1, #camps.icons do HideObject(camps.icons[index]) end
  camps.count = used
  local canvas = GetCanvas()
  if canvas and type(frame.SetAllPoints) == "function" then frame:SetAllPoints(canvas) end
  if used > 0 then frame:Show() else HideObject(frame) end
end

function Map:DrawWarCamps(show, continentKey, width, height)
  if not show then
    if self.warCamps.count > 0 then self:HideWarCamps() end
    return
  end
  local ok, err = pcall(Map.RefreshWarCamps, Map, continentKey, width, height)
  if ok then return end
  pcall(Map.HideWarCamps, Map)
  if WF.RecordError then WF.RecordError("map war camps", err) end
end

function Map:DrawStitchedCampaign(show, width, height)
  if self.warCamps.count > 0 then self:HideWarCamps() end
  if show then
    self:DrawCampaignRoutes("stitched", width, height)
    DrawZoneBars("stitched", width, height)
    return
  end
  if self.zoneBars.count > 0 then self:HideZoneBars() end
  if self.campaignRoutes.nodeCount > 0 then self:HideCampaignRoutes() end
end

function Map:Refresh(force)
  self.refreshes = (self.refreshes or 0) + 1
  local canvas = GetCanvas()
  ApplyBaseLevel(canvas)
  self:ApplyIconZoom()
  local mapName = GetCurrentMapFile()
  local mapKey = CanonicalMapName(mapName)
  local width, height = GetCanvasSize(canvas)
  local continentKey = not mapKey and CurrentContinentKey() or nil
  local stitchedAPI, stitchedHostID = StitchedHost()
  local stitchedMask = stitchedAPI and StitchedZoneMask(stitchedAPI, stitchedHostID) or nil
  self.stitchedAPI, self.stitchedHostID = stitchedAPI, stitchedHostID
  self.stitchedMask = stitchedMask
  local probe = self.probe
  probe.mapID, probe.mapName, probe.mapKey = ShownMapID(), mapName, mapKey
  probe.continent, probe.width, probe.height = continentKey, width, height
  probe.stitched, probe.stitchedHostID = stitchedAPI and true or false, stitchedHostID
  probe.stitchedMask = stitchedMask
  probe.branch = "off"
  local showCampaign, showUnits = not self:RoutesHidden(), not self:UnitsHidden()
  -- War Camps belong to the Points of interest filter.
  local showCamps = not self:Hidden()
  if not stitchedAPI and continentKey and self.enabled and (showCampaign or showUnits or showCamps)
      and not self:Locked() and canvas and width then
    probe.branch = "continent"
    -- Continent map: campaign route and zone markers (Campaign routes filter),
    -- travelling units (Scouts and armies filter, checked in DrawRoutes).
    if self.lastSignature ~= "continent" or self.lastSignatureKey ~= continentKey then
      self:HideAll()
      self.lastSignature, self.lastSignatureKey = "continent", continentKey
      self.currentMap = continentKey
    end
    if showCampaign then
      self:DrawCampaignRoutes(continentKey, width, height)
      DrawZoneBars(continentKey, width, height)
    else
      if self.campaignRoutes.nodeCount > 0 then self:HideCampaignRoutes() end
      if self.zoneBars.count > 0 then self:HideZoneBars() end
    end
    self:DrawWarCamps(showCamps, continentKey, width, height)
    Kit.DrawRoutes(continentKey, width, height)
    return true
  end
  if not stitchedAPI and not mapKey and not continentKey
      and self.enabled and (showCampaign or showUnits or showCamps) and not self:Locked()
      and canvas and width and IsWorldMap() then
    probe.branch = "world"
    -- World map: the campaign routes of both continents (Campaign routes
    -- filter) and the travelling units' routes between them.
    if self.lastSignature ~= "world" then
      self:HideAll()
      self.lastSignature = "world"
      self.currentMap = "world"
    end
    if showCampaign then
      self:DrawCampaignRoutes("world", width, height)
      DrawZoneBars("world", width, height)
    else
      if self.campaignRoutes.nodeCount > 0 then self:HideCampaignRoutes() end
      if self.zoneBars.count > 0 then self:HideZoneBars() end
    end
    self:DrawWarCamps(showCamps, "world", width, height)
    Kit.DrawRoutes("world", width, height)
    return true
  end
  -- Zone or OpenMap view with Points of interest unchecked: only the
  -- travelling scouts and armies.
  if self:Hidden() and (showUnits or (stitchedAPI and showCampaign)) and self.enabled
      and not self:Locked() and canvas and width and (stitchedAPI or mapKey) then
    probe.branch = "units"
    local unitsKey = stitchedAPI and stitchedHostID or mapKey
    if self.lastSignature ~= "units" or self.lastSignatureKey ~= unitsKey then
      self:HideAll()
      self.lastSignature, self.lastSignatureKey = "units", unitsKey
      self.currentMap = stitchedAPI and "OpenMap" or mapName
    end
    self:DrawStitchedCampaign(stitchedAPI and showCampaign, width, height)
    Kit.DrawRoutes(mapKey or continentKey or "world", width, height)
    return true
  end
  if not self.enabled or self:Hidden() or self:Locked() or not Contours or not canvas
      or (not stitchedAPI and not mapKey) or not width then
    self:HideAll()
    self.lastSignature = nil
    return false
  end
  self:DrawStitchedCampaign(stitchedAPI and showCampaign, width, height)
  local signature = stitchedAPI and "stitched" or "zone"
  local signatureKey = stitchedAPI and stitchedHostID or mapKey
  local routeMapKey = mapKey or continentKey or "world"
  probe.branch = signature

  local ownCapital = OwnCapitalFaction()

  -- Compare the layout inputs field by field: no new string every refresh.
  local same = self.lastSignature == signature and self.lastSignatureKey == signatureKey
    and self.lastWidth == width and self.lastHeight == height
    and self.lastRevision == self.revision and self.lastStitchedMask == stitchedMask
    and self.lastOwnCapital == ownCapital
  if not force and not self.dirty and same then
    ReapplyVisibleGroups()
    Kit.DrawRoutes(routeMapKey, width, height)
    RecordCounts(self)
    return true
  end

  self.dirty = false
  self.lastSignature, self.lastSignatureKey = signature, signatureKey
  self.lastWidth, self.lastHeight, self.lastRevision = width, height, self.revision
  self.lastStitchedMask = stitchedMask
  self.lastOwnCapital = ownCapital
  self.currentMap = stitchedAPI and "OpenMap" or mapName
  self:ClearHover()
  self.visibleCount = 0
  self.visiblePatches = 0
  self.visibleIcons = 0
  self.failures = 0
  UpdateLabelLevel()

  local matched = 0
  for index = 1, #self.order do
    local id = self.order[index]
    local area = self.areas[id]
    local entry = self.groups[id]
    local matches = area and area.enabled
      and not Map.IsOwnCapital(area, ownCapital) and (
      stitchedAPI and StitchedZoneVisible(stitchedMask, area.mapKey)
      or not stitchedAPI and area.mapKey == mapKey)
    if matches then
      matched = matched + 1
      entry = entry or GetEntry(id)
      if entry then
        local key = LayoutKey(area)
        if entry.layoutKey ~= key then
          local cached = self.cache[key]
          if cached then
            entry.layoutKey = key
            entry.pending = nil
            entry.records = BuildRecords(cached)
          else
            QueueBuild(entry, area, key)
          end
        end

        if entry.records then
          self.failures = self.failures
            + ApplyEntry(entry, area, width, height, stitchedAPI, stitchedHostID)
          self.visibleCount = self.visibleCount + 1
          self.visiblePatches = self.visiblePatches + #entry.records
          if entry.iconShown then self.visibleIcons = self.visibleIcons + 1 end
        else
          HideEntry(entry)
        end
      else
        self.failures = self.failures + 1
      end
    elseif entry then
      HideEntry(entry)
    end
  end
  Kit.DrawRoutes(routeMapKey, width, height)
  probe.matched = matched
  RecordCounts(self)
  return true
end

function Map:GetStatus()
  local building = 0
  for index = self.buildHead, self.buildTail do
    local entry = self.buildQueue[index]
    if entry and entry.pending then building = building + 1 end
  end
  local canvas = GetCanvas()
  local canvasVisible = false
  if canvas and type(canvas.IsVisible) == "function" then
    local ok, visible = pcall(canvas.IsVisible, canvas)
    canvasVisible = ok and visible and true or false
  end
  return {
    enabled = self.enabled,
    hidden = self:Hidden(),
    routesHidden = self:RoutesHidden(),
    unitsHidden = self:UnitsHidden(),
    locked = self:Locked(),
    registered = #self.order,
    map = self.currentMap,
    visible = self.visibleCount,
    patches = self.visiblePatches,
    icons = self.visibleIcons,
    building = building,
    failures = self.failures,
    cached = self.cacheCount,
    routes = self.routes.count,
    routeDots = self.routes.dotCount,
    zoneBars = self.zoneBars.count,
    campaignSegments = self.campaignRoutes.segmentCount,
    campaignNodes = self.campaignRoutes.nodeCount,
    warCamps = self.warCamps.count,
    probe = self.probe,
    ticks = self.ticks or 0,
    openTicks = self.openTicks or 0,
    refreshes = self.refreshes or 0,
    driverShown = self.driver and type(self.driver.IsShown) == "function"
      and self.driver:IsShown() or false,
    wakeHooked = self.wakeHooked and true or false,
    mapShows = self.mapShows or 0,
    showDriverVisible = self.showDriverVisible,
    showCanvasVisible = self.showCanvasVisible,
    canvas = canvas and true or false,
    canvasVisible = canvasVisible,
  }
end

Map.TYPE_NAMES = {
  WAR_CAMP = "War Camp",
  OUTPOST = "Outpost",
  SETTLEMENT = "Settlement",
  FOREST = "Forest",
  GOLD_MINE = "Gold Mine",
  FARM = "Farm",
  CAPITAL = "Capital",
}

Map.TYPE_HINTS = {
  WAR_CAMP = "Stay inside to capture it. Held War Camps speed your faction's scouts, armies and captures on this continent; recruit here while your faction holds it.",
  OUTPOST = "Stay inside the zone to capture it.",
  SETTLEMENT = "Capturable once every associated objective is controlled.",
  FOREST = "Harvest wood.",
  GOLD_MINE = "Harvest gold.",
  FARM = "Produce agricultural resources.",
  CAPITAL = "Its faction recruits here and sends armies and scouts from here.",
}

-- Canonical key of the zone the player stands in, as area.mapKey, or nil. A map
-- the addon does not name (a sub-map) stands for the first named parent.
function Map:PlayerZoneKey()
  local cmap = GetGlobal("C_Map")
  local keys = WF.Compat and WF.Compat.MAP_KEYS
  if type(cmap) ~= "table" or type(cmap.GetBestMapForUnit) ~= "function" or type(keys) ~= "table" then return nil end
  local current = cmap.GetBestMapForUnit("player")
  local safety = 0
  while type(current) == "number" and safety < 8 do
    local name = keys[current]
    if type(name) == "string" then return CanonicalMapName(name) end
    local info = type(cmap.GetMapInfo) == "function" and cmap.GetMapInfo(current) or nil
    current = info and info.parentMapID
    safety = safety + 1
  end
  return nil
end

-- Helpers for modules/map_routes.lua and modules/map_hover.lua.
Kit.CanonicalMapName = CanonicalMapName
Kit.Clamp = Clamp
Kit.Contours = Contours
Kit.CreateGroup = CreateGroup
Kit.CreatePatch = CreatePatch
Kit.FOREVER_ZONE_IDS = FOREVER_ZONE_IDS
Kit.GetCanvas = GetCanvas
Kit.GetCanvasSize = GetCanvasSize
Kit.GetGlobal = GetGlobal
Kit.GetIconPosition = GetIconPosition
Kit.HOVER_ALPHA = HOVER_ALPHA
Kit.HOVER_INTERVAL = HOVER_INTERVAL
Kit.HideHoverPatches = HideHoverPatches
Kit.HideObject = HideObject
Kit.ICON_HIT_RATIO = ICON_HIT_RATIO
Kit.IconSize = IconSize
Kit.MouseFocusGetter = MouseFocusGetter
Kit.POI_ICON_SIZE = POI_ICON_SIZE
Kit.PROFILE_TEXTURE = PROFILE_TEXTURE
Kit.PlacePatch = PlacePatch
Kit.ProjectAreaPoint = ProjectAreaPoint
Kit.REFRESH_INTERVAL = REFRESH_INTERVAL
Kit.StitchedZoneVisible = StitchedZoneVisible
Kit.TransformMapPoint = TransformMapPoint

local staticData = WF.POIData or {}
local ok, err = Map:RegisterAreas(staticData)
if not ok and WF.RecordError then WF.RecordError("map static POIs", err) end

local create = GetGlobal("CreateFrame")
if type(create) == "function" then
  -- UIParent is hidden while the fullscreen map is open, which stops its children's
  -- OnUpdate; WorldFrame keeps ticking so the open map refreshes and finishes builds.
  local driverParent = GetGlobal("WorldFrame") or UIParent
  local frameOk, driver = pcall(create, "Frame", "WarfrontMapDriver", driverParent)
  if frameOk and driver and type(driver.SetScript) == "function" then
    driver:SetScript("OnUpdate", function()
      local tickOk, tickError = pcall(Map.Tick, Map)
      if not tickOk and WF.RecordError then WF.RecordError("map driver", tickError) end
    end)
    Map.driver = driver
  elseif WF.RecordError then
    WF.RecordError("map driver", "unable to create OnUpdate driver")
  end
end

local mapFrame = GetGlobal("WorldMapFrame")
-- Opening the map wakes the driver that Map:Tick put to sleep.
if mapFrame and type(mapFrame.HookScript) == "function" then
  Map.wakeHooked = pcall(mapFrame.HookScript, mapFrame, "OnShow", function()
    Map:WakeDriver()
    -- Diagnostics for /wfd map: what the driver and canvas look like on open.
    Map.mapShows = (Map.mapShows or 0) + 1
    local driver = Map.driver
    local ok, visible = false, nil
    if driver and type(driver.IsVisible) == "function" then ok, visible = pcall(driver.IsVisible, driver) end
    Map.showDriverVisible = ok and visible and true or false
    Map.showCanvasVisible = Kit.CanvasVisible()
  end) and true or nil
end
-- Each zoom step (animated or not) refits POI icons and labels at once.
local hookSecure = GetGlobal("hooksecurefunc")
if mapFrame and type(hookSecure) == "function"
    and type(mapFrame.OnCanvasScaleChanged) == "function" then
  pcall(hookSecure, mapFrame, "OnCanvasScaleChanged", function()
    local zoomOk, zoomError = pcall(Map.ApplyIconZoom, Map)
    if not zoomOk and WF.RecordError then WF.RecordError("map icon zoom", zoomError) end
  end)
end
-- A continent, zone or world map change refreshes on the next frame instead
-- of waiting up to REFRESH_INTERVAL; the hook only sets a flag.
if mapFrame and type(hookSecure) == "function"
    and type(mapFrame.OnMapChanged) == "function" then
  pcall(hookSecure, mapFrame, "OnMapChanged", function()
    Map.refreshNow = true
    Map:WakeDriver()
  end)
end

-- Forever tags the map dropdown so addons can safely append their own filters:
-- a "Warfront" category with one checkbox per layer, each with a tooltip
-- like the client's own filters.
local MAP_FILTERS = {
  {
    text = "Points of interest",
    tooltip = "Show Outposts, Settlements, War Camps and resources on the map and minimap.",
    get = "Hidden", set = "SetHidden",
  },
  {
    text = "Scouts and armies",
    tooltip = "Show scouts and armies on their way, with their path.",
    get = "UnitsHidden", set = "SetUnitsHidden",
  },
  {
    text = "Campaign routes",
    tooltip = "Show the front line and captured zones on continent maps.",
    get = "RoutesHidden", set = "SetRoutesHidden",
  },
}

local function IsMapFilterChecked(filter)
  return not Map[filter.get](Map)
end

local function ToggleMapFilter(filter)
  local ok, err = pcall(Map[filter.set], Map, not Map[filter.get](Map))
  if not ok and WF.RecordError then WF.RecordError("map filter", err) end
end

local function AddMapFilter(rootDescription, filter)
  local checkbox = rootDescription:CreateCheckbox(WF.L(filter.text), IsMapFilterChecked, ToggleMapFilter, filter)
  if not checkbox or type(checkbox.SetOnEnter) ~= "function" then return end
  checkbox:SetOnEnter(function(button)
    local tooltip = GetGlobal("GameTooltip")
    if not tooltip then return end
    tooltip:ClearAllPoints()
    tooltip:SetPoint("RIGHT", button, "LEFT", -3, 0)
    tooltip:SetOwner(button, "ANCHOR_PRESERVE")
    tooltip:SetText(WF.L(filter.text), 1, 1, 1)
    tooltip:AddLine(WF.L(filter.tooltip), 1, 0.82, 0, true)
    tooltip:Show()
  end)
  if type(checkbox.SetOnLeave) == "function" then
    checkbox:SetOnLeave(function()
      local tooltip = GetGlobal("GameTooltip")
      if tooltip then tooltip:Hide() end
    end)
  end
end

local function RegisterMapFilter()
  local menu = GetGlobal("Menu")
  if type(menu) ~= "table" or type(menu.ModifyMenu) ~= "function" then return end
  local ok, handle = pcall(menu.ModifyMenu, "MENU_WORLD_MAP_TRACKING", function(_, rootDescription)
    if not rootDescription or type(rootDescription.CreateCheckbox) ~= "function" then return end
    if type(rootDescription.CreateDivider) == "function" then rootDescription:CreateDivider() end
    if type(rootDescription.CreateTitle) == "function" then rootDescription:CreateTitle("Warfront") end
    for index = 1, #MAP_FILTERS do AddMapFilter(rootDescription, MAP_FILTERS[index]) end
  end)
  if ok then
    Map.filterMenuHandle = handle
  elseif WF.RecordError then
    WF.RecordError("map filter registration", handle)
  end
end

RegisterMapFilter()
