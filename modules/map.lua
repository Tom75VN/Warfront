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
  -- What the last world map refresh saw, kept after the map closes for /wf map.
  probe = {},
}

WF.Map = Map

Map.COLORS = {
  HORDE = { 0.90, 0.12, 0.08 },
  ALLIANCE = { 0.10, 0.42, 1.00 },
  RESOURCE = { 1.00, 0.78, 0.05 },
  NEUTRAL = { 0.72, 0.72, 0.72 },
}

Map.POI_TYPES = {
  OUTPOST = true,
  SETTLEMENT = true,
  HUNTING_GROUNDS = true,
  FOREST = true,
  GOLD_MINE = true,
  FARM = true,
}

-- Resource POIs are harvested, never controlled: no faction owner (decision 0029).
Map.RESOURCE_TYPES = {
  FOREST = true,
  GOLD_MINE = true,
  FARM = true,
}

-- Every POI picture comes from one 512 x 512 RLE atlas of 72 px cells, built
-- by tools/make_poi_icon_atlas.py (this client draws large uncompressed TGA
-- atlases as diagonal bands). Rows: hunting grounds, outpost, Settlement levels
-- 1 to 3, resources. Columns: 0 neutral, 1 half Horde, 2 Horde, 3 half
-- Alliance, 4 Alliance.
local POI_ICON_ATLAS = "Interface\\AddOns\\Warfront\\media\\Textures\\Icons\\MapPOIIconAtlas"
local POI_ICON_ATLAS_SIZE = 512
local POI_ICON_CELL = 72

-- First row of each type; a Settlement adds its level minus one.
Map.POI_ICON_ROWS = {
  HUNTING_GROUNDS = 0,
  OUTPOST = 1,
  SETTLEMENT = 2,
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
local POI_ICON_SIZE = 28
-- Types drawn at another size than POI_ICON_SIZE, as a size multiplier.
local POI_ICON_SCALE = {
  SETTLEMENT = 1.15,
}
local function IconSize(poiType)
  return POI_ICON_SIZE * (POI_ICON_SCALE[poiType] or 1)
end
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

-- Creature IDs that must be killed to capture the area (HUNTING_GROUNDS).
-- Absent means no kill requirement; duplicates are dropped, order is kept.
local function CopyMobIds(ids)
  local output = {}
  if ids == nil then return output end
  if type(ids) ~= "table" then
    return nil, "requiredMobIds must be a list of creature IDs"
  end
  local seen = {}
  local index = 1
  local total = #ids
  while index <= total do
    local id = ids[index]
    if type(id) ~= "number" or id < 1 or mathFloor(id) ~= id then
      return nil, "requiredMobIds must contain positive integer creature IDs"
    end
    if not seen[id] then
      seen[id] = true
      output[#output + 1] = id
    end
    index = index + 1
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
    return nil, "type must be OUTPOST, SETTLEMENT, HUNTING_GROUNDS, FOREST, GOLD_MINE, or FARM"
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

  local requiredMobIds, mobError = CopyMobIds(definition.requiredMobIds)
  if not requiredMobIds then return nil, mobError end

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
    requiredMobIds = requiredMobIds,
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

-- Returns a copy of the creature IDs required to capture the area, or nil for an unknown area.
function Map:GetRequiredMobIds(id)
  local area = type(id) == "string" and self.areas[id] or nil
  if not area then return nil end
  local copy = {}
  local index = 1
  local total = #(area.requiredMobIds or {})
  while index <= total do
    copy[#copy + 1] = area.requiredMobIds[index]
    index = index + 1
  end
  return copy
end

-- Shows the captured owner (HORDE, ALLIANCE, or nil for the static colour) and a
-- half-captured icon for the challenger at 50 % or more. Returns true on change.
-- unconfirmed: the owner is only a hint of other players (decision 0038), drawn
-- halfway to grey.
function Map:SetCaptureView(id, ownerKey, halfKey, unconfirmed)
  local area = type(id) == "string" and self.areas[id] or nil
  if not area then return false end
  if area.baseColorKey == nil then
    area.baseColorKey = area.colorKey or false
    area.baseColor = area.color
  end
  local colorKey = area.baseColorKey or nil
  local color = area.baseColor
  local preset = ownerKey and Map.COLORS[ownerKey]
  if preset then
    colorKey = ownerKey
    color = { preset[1], preset[2], preset[3] }
    if unconfirmed then
      color = { (preset[1] + 0.5) / 2, (preset[2] + 0.5) / 2, (preset[3] + 0.5) / 2 }
    end
  end
  unconfirmed = preset and unconfirmed and true or nil
  local column = halfKey and Map.POI_ICON_HALF_COLUMNS[halfKey] or nil
  if area.colorKey == colorKey and area.iconColumn == column and area.unconfirmed == unconfirmed then
    return false
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

-- Player choice from the world map filter, saved in
-- WarfrontDB.settings.mapHidden. Hides the world map and minimap drawing.
function Map:Hidden()
  local settings = Settings()
  if settings then return settings.mapHidden and true or false end
  return self.hidden and true or false
end

function Map:SetHidden(hidden)
  self.hidden = hidden and true or false
  local settings = Settings()
  if settings then settings.mapHidden = self.hidden or nil end
  self.dirty = true
  if self.hidden then
    self:HideAll()
    self.lastSignature = nil
  else
    self:Refresh(true)
  end
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
local function BaseLevel(canvas)
  if not canvas or type(canvas.GetFrameLevel) ~= "function" then return nil end
  local ok, base = pcall(canvas.GetFrameLevel, canvas)
  if not ok or type(base) ~= "number" then return nil end

  -- Blizzard's exploration pin covers the canvas at its own high frame level.
  -- Keep Warfront above it while remaining below the native map's other POIs.
  local worldMap = GetGlobal("WorldMapFrame")
  if worldMap and type(worldMap.GetPinFrameLevelsManager) == "function" then
    local managerOk, manager = pcall(worldMap.GetPinFrameLevelsManager, worldMap)
    if managerOk and manager and type(manager.GetValidFrameLevel) == "function" then
      local levelOk, level = pcall(
        manager.GetValidFrameLevel,
        manager,
        "PIN_FRAME_LEVEL_MAP_EXPLORATION"
      )
      if levelOk and type(level) == "number" and level > base then base = level end
    end
  end

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

local function CreateGroup(name, levelOffset)
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
  local base = BaseLevel(canvas)
  if base and type(frame.SetFrameLevel) == "function" then
    pcall(frame.SetFrameLevel, frame, base + frame.wfLevelOffset)
  end
  HideObject(frame)
  return frame
end

local function GetEntry(id)
  local entry = Map.groups[id]
  if entry then return entry end
  local frame = CreateGroup()
  if not frame then return nil end
  entry = { frame = frame, textures = {}, visible = 0, active = false }
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

local function LevelText(area)
  local level = SettlementLevel(area)
  return level and ("Level " .. level) or nil
end

Map.SettlementLevel = SettlementLevel
Map.LevelText = LevelText

-- Settlement levels change between layouts: switch the icon row only when the
-- level does (the layout itself sets it in PlaceIcon).
local function RefreshLevelIcon(entry, area)
  if area.type ~= "SETTLEMENT" or not entry.iconShown or not entry.icon then return end
  local level = SettlementLevel(area)
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

-- Label under the icon of a resource POI (its stock) or of a held Settlement
-- (its level); anchored once to the icon, its text is set only when it
-- changes. Only a stock draws the bar.
local function PlaceStockLabel(entry, area)
  local text, share
  if entry.iconShown then
    text, share = StockText(area)
    if not text then text = LevelText(area) end
  end
  if not text then
    if entry.stockLabel then HideObject(entry.stockLabel) end
    HideStockBar(entry)
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
end

local function PlaceIcon(entry, area, width, height, stitchedAPI, hostID)
  local level = SettlementLevel(area)
  local path, left, right, top, bottom, pw, ph = Map.GetIcon(area.type, area.colorKey, area.iconColumn, level)
  entry.iconShown = false
  if not path then
    if entry.icon then HideObject(entry.icon) end
    if entry.stockLabel then HideObject(entry.stockLabel) end
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
    entry.icon:SetWidth(iconWidth)
    entry.icon:SetHeight(iconHeight)
    entry.icon:Show()
  end)
  entry.iconShown = ok and true or false
  PlaceStockLabel(entry, area)
  return entry.iconShown
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
    texture:SetVertexColor(color[1], color[2], color[3], alpha or PROFILE_ALPHA)
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

-- Scout routes (roadmap WP8, docs/scouting.md, decision 0051) ----------------
-- Every scout still travelling is drawn on the displayed zone map, for both
-- factions and without its sender: a dotted straight line from its origin to
-- its target and its icon at the share of the trip elapsed. A route between
-- two zones of one continent is drawn in continent coordinates and clipped to
-- the displayed zone, so each zone shows its own part; a route to another
-- continent (abstract sea crossing) and the continent maps show nothing.
-- Local display only: nothing is sent.
local ROUTE_TEXTURE = "Interface\\Buttons\\WHITE8X8"
local ROUTE_DOT_SIZE = 5
local ROUTE_DOT_GAP = 9
local ROUTE_DOT_ALPHA = 0.9
-- Dots this close to an endpoint would sit under its POI icon.
local ROUTE_ICON_CLEAR = POI_ICON_SIZE * ICON_HIT_RATIO
local ROUTE_MAX = 16
local ROUTE_MAX_DOTS = 800
local SCOUT_ICON_SIZE = 20
local SCOUT_ICON_DIR = "Interface\\AddOns\\Warfront\\media\\Textures\\Icons\\War3Units\\"
local SCOUT_ICONS = { A = SCOUT_ICON_DIR .. "BTNKnight", H = SCOUT_ICON_DIR .. "BTNRaider" }
-- Armies (decision 0052): the faction's basic soldier.
local ARMY_ICONS = { A = SCOUT_ICON_DIR .. "BTNFootman", H = SCOUT_ICON_DIR .. "BTNGrunt" }
local SCOUT_COLORS = { A = Map.COLORS.ALLIANCE, H = Map.COLORS.HORDE }
-- Zone rectangles on their continent in world yards: left, right, top,
-- bottom, continent (1.12 WorldMapArea, not measured on OctoWoW). Widths and
-- heights equal Scout.ZONES; tools/smoke.py checks both stay equal.
local ROUTE_ZONES = {
  elwynn = { 1535.4166, -1935.4166, -7939.5833, -10254.1666, "EK" },
  westfall = { 3016.6665, -1483.3334, -9400.0, -12400.0, "EK" },
  durotar = { -1962.4999, -7249.9995, 1808.3333, -1716.6666, "KA" },
  barrens = { 2622.9165, -7510.4165, 1612.4999, -5143.75, "KA" },
}

Map.ROUTE_ZONES = ROUTE_ZONES
Map.routes = { slots = {}, dots = {}, count = 0, dotCount = 0, iconCount = 0 }

-- An area's icon anchor in units of the displayed zone map (outside 0-1 when
-- it lies on another zone), or nil when the zones share no continent.
local function RoutePoint(area, mapKey)
  if not area or not area.enabled then return nil end
  local x, y = GetIconPosition(area)
  if not x or area.mapKey == mapKey then return x, y end
  local from, to = ROUTE_ZONES[area.mapKey or ""], ROUTE_ZONES[mapKey or ""]
  if not from or not to or from[5] ~= to[5] then return nil end
  local worldY = from[1] - x * (from[1] - from[2])
  local worldX = from[3] - y * (from[3] - from[4])
  return (to[1] - worldY) / (to[1] - to[2]), (to[3] - worldX) / (to[3] - to[4])
end

-- Continent maps and the world map (decision 0051 revision, 2026-11-01). The
-- view is a zone map key, "azeroth", "kalimdor" or "world". A zone's place on
-- its continent map is Map.CONTINENT_ZONES (measured); the continents' place
-- on the world map is the continent map's rectangle (left, top, width, height
-- in world map units), drawing only. Derived 2026-11-02 from the continent
-- map yard bounds (WorldMapArea) and the classic world map's extent in each
-- continent's yards (HereBeDragons data), which agrees with OctoWoW's
-- WorldMapContinent.dbc offsets and 0.75 scale; not measured on OctoWoW.
local WORLD_CONTINENTS = {
  azeroth = { 0.371483, 0.081501, 0.787673, 0.787599 },
  kalimdor = { -0.185892, 0.067677, 0.819985, 0.820069 },
}

Map.WORLD_CONTINENTS = WORLD_CONTINENTS

-- An area's icon anchor in units of the displayed view, or nil when the view
-- does not show it (a zone map of another continent, the other continent map).
local function ViewPoint(area, view)
  local continent = WORLD_CONTINENTS[view or ""]
  if not continent and view ~= "world" then return RoutePoint(area, view) end
  if not area or not area.enabled then return nil end
  local zone = Map.CONTINENT_ZONES[area.mapKey or ""]
  local x, y = GetIconPosition(area)
  if not zone or not x then return nil end
  if view ~= "world" and zone[1] ~= view then return nil end
  local cx, cy = zone[2] + x * zone[4], zone[3] + y * zone[5]
  if view ~= "world" then return cx, cy end
  local place = WORLD_CONTINENTS[zone[1]]
  if not place then return nil end
  return place[1] + cx * place[3], place[2] + cy * place[4]
end

-- One edge of the Liang-Barsky clip: keeps the shares t where p * t <= q.
local function ClipEdge(p, q, t0, t1)
  if p == 0 then
    if q < 0 then return nil end
    return t0, t1
  end
  local t = q / p
  if p < 0 then
    if t > t1 then return nil end
    if t > t0 then t0 = t end
  else
    if t < t0 then return nil end
    if t < t1 then t1 = t end
  end
  return t0, t1
end

-- The shares [t0, t1] of the segment inside the 0-1 map, or nil when none is.
local function ClipRoute(ax, ay, bx, by)
  local dx, dy = bx - ax, by - ay
  local t0, t1 = ClipEdge(-dx, ax, 0, 1)
  if t0 then t0, t1 = ClipEdge(dx, 1 - ax, t0, t1) end
  if t0 then t0, t1 = ClipEdge(-dy, ay, t0, t1) end
  if t0 then t0, t1 = ClipEdge(dy, 1 - ay, t0, t1) end
  if not t0 or t0 > t1 then return nil end
  return t0, t1
end

-- The texture list[key], created once on the route frame.
local function RouteTexture(list, key, frame, layer)
  local texture = list[key]
  if texture then return texture end
  if type(frame.CreateTexture) ~= "function" then return nil end
  local ok, created = pcall(frame.CreateTexture, frame, nil, layer)
  if not ok or not created then return nil end
  list[key] = created
  return created
end

-- The dots of the hovered route are lighter, opaque and a little larger.
local ROUTE_DOT_HOVER_SIZE = 7
local ROUTE_DOT_HOVER_LIGHTEN = 0.5

local function PaintDot(dot)
  local color = dot.WarfrontColor
  if not color then return end
  if dot.WarfrontRecord and dot.WarfrontRecord == Map.hoverRoute then
    local k = ROUTE_DOT_HOVER_LIGHTEN
    dot:SetVertexColor(color[1] + (1 - color[1]) * k, color[2] + (1 - color[2]) * k,
      color[3] + (1 - color[3]) * k, 1)
    dot:SetWidth(ROUTE_DOT_HOVER_SIZE)
    dot:SetHeight(ROUTE_DOT_HOVER_SIZE)
  else
    dot:SetVertexColor(color[1], color[2], color[3], ROUTE_DOT_ALPHA)
    dot:SetWidth(ROUTE_DOT_SIZE)
    dot:SetHeight(ROUTE_DOT_SIZE)
  end
end

local function RefreshRouteDots()
  local routes = Map.routes
  local index = 1
  while index <= routes.dotCount do
    if routes.dots[index] then PaintDot(routes.dots[index]) end
    index = index + 1
  end
end

-- Lays one route's dots from dot number first + 1; returns the last number used.
local function LayoutDots(frame, slot, first, width, height)
  local dots = Map.routes.dots
  local dx, dy = (slot.bx - slot.ax) * width, (slot.by - slot.ay) * height
  local length = math.sqrt(dx * dx + dy * dy)
  if length <= 0 then return first end
  local color = SCOUT_COLORS[slot.record.fac]
  local step = ROUTE_DOT_GAP / length
  local k = math.ceil(slot.t0 / step)
  local t = k * step
  local used = first
  while t <= slot.t1 and used < ROUTE_MAX_DOTS do
    if t * length >= ROUTE_ICON_CLEAR and (1 - t) * length >= ROUTE_ICON_CLEAR then
      local dot = RouteTexture(dots, used + 1, frame, "ARTWORK")
      if not dot then return used end
      used = used + 1
      if not dot.WarfrontPath then
        -- The round white dot of the atlas, tinted below; a plain square without it.
        local atlas = WF.UIAtlas
        local piece = atlas and atlas.pieces["route.dot"]
        if piece then
          dot:SetTexture(atlas.pages[piece.p])
          dot:SetTexCoord(piece.x / atlas.page, (piece.x + piece.w) / atlas.page, piece.y / atlas.page,
            (piece.y + piece.h) / atlas.page)
          dot.WarfrontPath = atlas.pages[piece.p]
        else
          dot:SetTexture(ROUTE_TEXTURE)
          dot.WarfrontPath = ROUTE_TEXTURE
        end
      end
      dot.WarfrontColor = color
      dot.WarfrontRecord = slot.record
      PaintDot(dot)
      dot:ClearAllPoints()
      dot:SetPoint("CENTER", frame, "TOPLEFT", slot.ax * width + t * dx, -(slot.ay * height + t * dy))
      dot:Show()
    end
    k = k + 1
    t = k * step
  end
  return used
end

local function HideDots(from)
  local routes = Map.routes
  local index = from
  while index <= routes.dotCount do
    HideObject(routes.dots[index])
    index = index + 1
  end
  if from - 1 < routes.dotCount then routes.dotCount = from - 1 end
end

-- Hides the slots from number first on and forgets their records.
local function ReleaseSlots(first)
  local slots = Map.routes.slots
  local index = first
  while index <= #slots do
    HideObject(slots[index].icon)
    slots[index].record = nil
    slots[index].iconShown = false
    index = index + 1
  end
end

function Map:HideRoutes()
  local routes = self.routes
  HideDots(1)
  ReleaseSlots(1)
  HideObject(routes.frame)
  routes.count = 0
  routes.iconCount = 0
  routes.layoutMap = nil
end

-- The side of a zone or continent map facing the other continent: Kalimdor
-- lies west of the Eastern Kingdoms, so an Eastern Kingdoms map looks left and
-- a Kalimdor map right.
local function SeaSide(code)
  if code == "EK" then return 0 end
  return 1
end

-- The segment of a sea crossing shown on the displayed zone or continent map:
-- from the origin icon to that side during the first half of the trip, from
-- the side to the target icon during the second. Returns ax, ay, bx, by and
-- the trip shares where the segment starts and ends, or nil when the view
-- shows neither end. The world map shows the whole crossing as one line.
local function SeaLeg(from, to, view)
  if not from or not to then return nil end
  local fromZone, toZone = ROUTE_ZONES[from.mapKey or ""], ROUTE_ZONES[to.mapKey or ""]
  if not fromZone or not toZone or fromZone[5] == toZone[5] then return nil end
  -- A zone map shows only its own end; zones overlap their neighbors, a
  -- neighbor's POI is not drawn as an end.
  local zoneView = not WORLD_CONTINENTS[view or ""]
  local x, y
  if not zoneView or from.mapKey == view then x, y = ViewPoint(from, view) end
  if x then return x, y, SeaSide(fromZone[5]), y, 0, 0.5 end
  if not zoneView or to.mapKey == view then x, y = ViewPoint(to, view) end
  if x then return SeaSide(toZone[5]), y, x, y, 0.5, 1 end
  return nil
end

-- One travelling record (a scout or an army) placed in the next route slot
-- if its line crosses the displayed zone. Returns the new count and whether
-- the slot changed record.
local function PlaceRoute(map, slots, count, r, path, mapKey, now, kind)
  if count >= ROUTE_MAX or type(r) ~= "table" or not path or type(r.depart) ~= "number"
      or type(r.dur) ~= "number" or r.dur <= 0 or r.depart + r.dur <= now then
    return count, false
  end
  local from, to = map.areas[r.origin or ""], map.areas[r.target or ""]
  local ax, ay = ViewPoint(from, mapKey)
  local bx, by = ViewPoint(to, mapKey)
  local s0, s1 = 0, 1
  if not (ax and bx) then
    -- Another continent: the first half of the trip leaves the origin zone
    -- toward the sea, the second half enters the target zone from it.
    ax, ay, bx, by, s0, s1 = SeaLeg(from, to, mapKey)
  end
  local t0, t1
  if ax and bx then t0, t1 = ClipRoute(ax, ay, bx, by) end
  if not t0 then return count, false end
  count = count + 1
  local slot = slots[count]
  if not slot then
    slot = {}
    slots[count] = slot
  end
  local changed = false
  if slot.record ~= r then
    changed = true
    slot.record = r
  end
  slot.path = path
  slot.kind = kind
  slot.ax, slot.ay, slot.bx, slot.by, slot.t0, slot.t1 = ax, ay, bx, by, t0, t1
  slot.s0, slot.s1 = s0, s1
  return count, changed
end

-- Draws the scouts and armies travelling on the displayed zone (decisions
-- 0051, 0052). The dots are laid out again only when the routes, the map, the
-- canvas or the areas change; the icons move on every refresh. Returns the
-- number of routes drawn.
function Map:RefreshRoutes(mapKey, width, height)
  local routes = self.routes
  local scout = WF.Scout
  local attack = WF.Attack
  local now = WF.Now and WF.Now() or 0
  local scouts = scout and type(scout.records) == "table"
  local armies = attack and type(attack.Marching) == "function"
  if (not scouts and not armies) or type(now) ~= "number" then
    self:HideRoutes()
    return 0
  end

  local slots = routes.slots
  local count = 0
  local changed = routes.layoutMap ~= mapKey or routes.layoutWidth ~= width
    or routes.layoutHeight ~= height or routes.layoutRevision ~= self.revision
  local moved
  local key, r
  if scouts then
    for key, r in pairs(scout.records) do
      count, moved = PlaceRoute(self, slots, count, r, type(r) == "table" and SCOUT_ICONS[r.fac], mapKey, now, "scout")
      if moved then changed = true end
    end
  end
  if armies then
    local list = attack:Marching(now)
    for index = 1, #list do
      r = list[index]
      count, moved = PlaceRoute(self, slots, count, r, ARMY_ICONS[r.fac], mapKey, now, "army")
      if moved then changed = true end
    end
  end
  if count ~= routes.count then changed = true end
  ReleaseSlots(count + 1)
  routes.count = count
  if count == 0 then
    self:HideRoutes()
    return 0
  end

  if not routes.frame then routes.frame = CreateGroup("WarfrontMapRoutes", 2) end
  local frame = routes.frame
  if not frame then return 0 end
  local index
  if changed then
    routes.layoutMap, routes.layoutWidth, routes.layoutHeight = mapKey, width, height
    routes.layoutRevision = self.revision
    local used = 0
    index = 1
    while index <= count do
      used = LayoutDots(frame, slots[index], used, width, height)
      index = index + 1
    end
    HideDots(used + 1)
    routes.dotCount = used
  end

  local icons = 0
  index = 1
  while index <= count do
    local slot = slots[index]
    local record = slot.record
    -- Share of this segment covered (the whole trip on one continent).
    local t = (Clamp((now - record.depart) / record.dur, 0, 1) - slot.s0) / (slot.s1 - slot.s0)
    local icon = nil
    if t >= slot.t0 and t <= slot.t1 then icon = RouteTexture(slot, "icon", frame, "OVERLAY") end
    if icon then
      local path = slot.path
      if icon.WarfrontPath ~= path then
        icon:SetTexture(path)
        icon.WarfrontPath = path
        icon:SetWidth(SCOUT_ICON_SIZE)
        icon:SetHeight(SCOUT_ICON_SIZE)
      end
      slot.iconX = slot.ax + t * (slot.bx - slot.ax)
      slot.iconY = slot.ay + t * (slot.by - slot.ay)
      icon:ClearAllPoints()
      icon:SetPoint("CENTER", frame, "TOPLEFT", slot.iconX * width, -slot.iconY * height)
      icon:Show()
      slot.iconShown = true
      icons = icons + 1
    else
      HideObject(slot.icon)
      slot.iconShown = false
    end
    index = index + 1
  end
  routes.iconCount = icons
  local canvas = GetCanvas()
  if canvas and type(frame.SetAllPoints) == "function" then frame:SetAllPoints(canvas) end
  frame:Show()
  return count
end

local function DrawRoutes(mapKey, width, height)
  local ok, err = pcall(Map.RefreshRoutes, Map, mapKey, width, height)
  if ok then return end
  pcall(Map.HideRoutes, Map)
  if WF.RecordError then WF.RecordError("map routes", err) end
end

-- Zone capture bars on the continent maps -----------------------------------
-- On a continent map, each zone holding controlled POIs (Outposts,
-- Settlements, Hunting Grounds) shows the Capture HUD bar at the middle of
-- the zone: same textures, Alliance blue from the left, Horde red from the
-- right, grey for the neutral rest, percents inside, faction badges on each
-- side. Shares are the number of POIs each faction holds, from the owner color
-- the zone map shows. Local display only: nothing is sent.
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
-- The HUD bar at 40 % of its 176 px width (map.bar.frame, the hud.bar.frame
-- sprite redrawn 70 px wide so the stroke keeps its weight) with the HUD's
-- 16 x 19 badges, scaled down as one frame.
local ZONE_BAR_WIDTH = 70
local ZONE_BAR_HEIGHT = 12
local ZONE_BAR_INSET = 2
local ZONE_BAR_INNER = ZONE_BAR_WIDTH - 2 * ZONE_BAR_INSET
local ZONE_BAR_SCALE = 0.75
local ZONE_BADGE_WIDTH, ZONE_BADGE_HEIGHT = 16, 19
local ZONE_BAR_NEUTRAL = { 0.45, 0.45, 0.45 }
Map.zoneBars = { slots = {}, count = 0 }

local foreverZoneCenters = {}

local function ForeverZoneCenter(mapKey)
  if not C_Map or type(C_Map.GetMapChildrenInfo) ~= "function"
      or type(C_Map.GetMapRectOnMap) ~= "function" then return nil end
  local frame = GetGlobal("WorldMapFrame")
  if not frame or type(frame.GetMapID) ~= "function" then return nil end
  local ok, topMapID = pcall(frame.GetMapID, frame)
  if not ok or type(topMapID) ~= "number" then return nil end
  foreverZoneCenters[topMapID] = foreverZoneCenters[topMapID] or {}
  local cached = foreverZoneCenters[topMapID][mapKey]
  if cached then return cached[1], cached[2] end
  local zoneID = FOREVER_ZONE_IDS[mapKey]
  if not zoneID then return nil end
  local children = C_Map.GetMapChildrenInfo(topMapID, nil, true)
  local index = 1
  while type(children) == "table" and index <= #children do
    local child = children[index]
    if child and child.mapID == zoneID then
      local minX, maxX, minY, maxY = C_Map.GetMapRectOnMap(child.mapID, topMapID)
      if type(minX) == "number" and type(maxX) == "number"
          and type(minY) == "number" and type(maxY) == "number" then
        local center = { (minX + maxX) / 2, (minY + maxY) / 2 }
        foreverZoneCenters[topMapID][mapKey] = center
        return center[1], center[2]
      end
    end
    index = index + 1
  end
  return nil
end

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
  if not CONTINENT_KEYS[continentKey or ""] then return list end
  local zones = {}
  local index = 1
  for index = 1, #self.order do
    local area = self.areas[self.order[index]]
    local zone = area and area.enabled and CONTINENT_ZONES[area.mapKey or ""]
    if zone and zone[1] == continentKey and Map.POI_TYPES[area.type]
        and not Map.RESOURCE_TYPES[area.type] then
      local entry = zones[area.mapKey]
      if not entry then
        local foreverX, foreverY = ForeverZoneCenter(area.mapKey)
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

-- Applies the part x0..x1 of an atlas piece, or the plain color when the
-- skin or the piece is missing. False when no atlas piece was used.
local function ZoneBarPiece(texture, piece, color, x0, x1)
  local skin = WF.Skin
  if skin and type(skin.Apply) == "function" and skin:Apply(texture, piece, x0, x1) then
    return true
  end
  texture:SetTexture(ZONE_BAR_TEXTURE)
  texture:SetTexCoord(0, 1, 0, 1)
  if color then texture:SetVertexColor(color[1], color[2], color[3], color[4] or 1) end
  return false
end

local function ZoneBarFillTexture(frame, layer, piece, color, fromRight)
  local texture = frame:CreateTexture(nil, layer)
  ZoneBarPiece(texture, piece, color)
  texture:SetHeight(ZONE_BAR_HEIGHT - 2 * ZONE_BAR_INSET)
  texture.fillPiece = piece
  texture.fillColor = color
  texture.fillFromRight = fromRight
  if fromRight then
    texture:SetPoint("RIGHT", frame, "RIGHT", -ZONE_BAR_INSET, 0)
  else
    texture:SetPoint("LEFT", frame, "LEFT", ZONE_BAR_INSET, 0)
  end
  return texture
end

-- Percents inside the bar, like the HUD, outlined to stay readable on the map.
local function ZoneBarText(frame, point, x)
  local text = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  text:SetPoint(point, frame, point, x, 0.5)
  if text.SetJustifyH then text:SetJustifyH(point) end
  if text.GetFont and text.SetFont then
    local path, size = text:GetFont()
    if path and type(size) == "number" then text:SetFont(path, size, "OUTLINE") end
  end
  return text
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

local function ZoneBarSlot(bars, index)
  local slot = bars.slots[index]
  if slot then return slot end
  if not bars.frame then bars.frame = CreateGroup("WarfrontMapZoneBars", 3) end
  local group = bars.frame
  local create = GetGlobal("CreateFrame")
  if not group or type(create) ~= "function" then return nil end
  local ok = pcall(function()
    -- An unscaled 1 px holder takes the map position; the scaled bar sits on
    -- it with no offset, so the position never depends on the bar's scale.
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
    -- 1.12 has no texture sublevels: grey base, then the frame, then the fills.
    local neutral = ZoneBarFillTexture(frame, "BACKGROUND", "fill.grey", ZONE_BAR_NEUTRAL)
    neutral:SetWidth(ZONE_BAR_INNER)
    local border = frame:CreateTexture(nil, "BORDER")
    border:SetAllPoints(frame)
    if not ZoneBarPiece(border, "map.bar.frame") then border:SetVertexColor(0, 0, 0, 0) end
    slot = {
      holder = holder, frame = frame, border = border, neutral = neutral,
      alliance = ZoneBarFillTexture(frame, "ARTWORK", "fill.blue", Map.COLORS.ALLIANCE),
      horde = ZoneBarFillTexture(frame, "ARTWORK", "fill.red", Map.COLORS.HORDE, true),
      left = ZoneBarText(frame, "LEFT", 7),
      right = ZoneBarText(frame, "RIGHT", -7),
      badgeA = ZoneBarBadge(frame, "badge.alliance", "RIGHT", "LEFT", -1),
      badgeH = ZoneBarBadge(frame, "badge.horde", "LEFT", "RIGHT", 1),
    }
  end)
  if not ok or not slot then return nil end
  bars.slots[index] = slot
  return slot
end

-- Fill width for a share, cropping the atlas piece (as the HUD does) so the
-- gradient is not squeezed.
local function ZoneBarFill(texture, share)
  if share <= 0.001 then
    HideObject(texture)
    return
  end
  share = mathMin(1, share)
  texture:SetWidth(mathMax(1, ZONE_BAR_INNER * share))
  local skin = WF.Skin
  local piece = skin and type(skin.Piece) == "function" and skin:Piece(texture.fillPiece)
  if piece then
    local shown = piece.w * share
    if texture.fillFromRight then
      ZoneBarPiece(texture, texture.fillPiece, texture.fillColor, piece.w - shown, piece.w)
    else
      ZoneBarPiece(texture, texture.fillPiece, texture.fillColor, 0, shown)
    end
  end
  texture:Show()
end

local function ZoneBarPercent(share)
  if share <= 0.001 then return "" end
  return mathFloor(share * 100 + 0.5) .. "%"
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
  local zones = self:ZoneShares(continentKey)
  local canvas = GetCanvas()
  local used = 0
  local index = 1
  while index <= #zones do
    local zone = zones[index]
    local slot = ZoneBarSlot(bars, used + 1)
    if not slot then break end
    used = used + 1
    slot.mapKey = zone.mapKey
    slot.x, slot.y = zone.x, zone.y
    slot.allianceShare, slot.hordeShare = zone.allianceShare, zone.hordeShare
    slot.holder:ClearAllPoints()
    slot.holder:SetPoint("CENTER", bars.frame, "TOPLEFT", zone.x * width, -zone.y * height)
    ZoneBarFill(slot.alliance, zone.allianceShare)
    ZoneBarFill(slot.horde, zone.hordeShare)
    slot.left:SetText(ZoneBarPercent(zone.allianceShare))
    slot.right:SetText(ZoneBarPercent(zone.hordeShare))
    if slot.badgeA.skinned then slot.badgeA:Show() else HideObject(slot.badgeA) end
    if slot.badgeH.skinned then slot.badgeH:Show() else HideObject(slot.badgeH) end
    slot.frame:Show()
    slot.holder:Show()
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

function Map:HideAll()
  self:HideZoneBars()
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

-- Hides every group before the client hides the map, so its recursive hide
-- never walks our regions (crash 007A2452, docs/decisions/0021). The next
-- Refresh rebuilds the visible state.
function Map:SuspendForClose()
  self:HideAll()
  HideObject(self.toggle)
  self.dirty = true
  self.lastSignature = nil
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
  local want = base + frame.wfLevelOffset
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
  done = LevelFrame(Map.zoneBars and Map.zoneBars.frame, base) and done
  for _, entry in pairs(Map.groups) do
    done = LevelFrame(entry.frame, base) and done
  end
  UpdateLabelLevel()
  for _, entry in pairs(Map.groups) do RaiseLabelFrame(entry) end
  -- A refused move (combat) is tried again on the next refresh.
  if done then Map.appliedBase = base end
end

function Map:Refresh(force)
  self.refreshes = (self.refreshes or 0) + 1
  local canvas = GetCanvas()
  ApplyBaseLevel(canvas)
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
  if not stitchedAPI and continentKey and self.enabled and not self:Hidden() and not self:Locked()
      and canvas and width then
    probe.branch = "continent"
    -- Continent map: the zone bars and the routes; the zone groups hide once.
    if self.lastSignature ~= "continent" or self.lastSignatureKey ~= continentKey then
      self:HideAll()
      self.lastSignature, self.lastSignatureKey = "continent", continentKey
      self.currentMap = continentKey
    end
    DrawZoneBars(continentKey, width, height)
    DrawRoutes(continentKey, width, height)
    return true
  end
  if not stitchedAPI and not mapKey and not continentKey
      and self.enabled and not self:Hidden() and not self:Locked()
      and canvas and width and IsWorldMap() then
    probe.branch = "world"
    -- World map: only the routes between the continents.
    if self.lastSignature ~= "world" then
      self:HideAll()
      self.lastSignature = "world"
      self.currentMap = "world"
    end
    DrawRoutes("world", width, height)
    return true
  end
  if not self.enabled or self:Hidden() or self:Locked() or not Contours or not canvas
      or (not stitchedAPI and not mapKey) or not width then
    self:HideAll()
    self.lastSignature = nil
    return false
  end
  if self.zoneBars.count > 0 then self:HideZoneBars() end
  local signature = stitchedAPI and "stitched" or "zone"
  local signatureKey = stitchedAPI and stitchedHostID or mapKey
  local routeMapKey = mapKey or continentKey or "world"
  probe.branch = signature

  -- Compare the layout inputs field by field: no new string every refresh.
  local same = self.lastSignature == signature and self.lastSignatureKey == signatureKey
    and self.lastWidth == width and self.lastHeight == height
    and self.lastRevision == self.revision and self.lastStitchedMask == stitchedMask
  if not force and not self.dirty and same then
    ReapplyVisibleGroups()
    DrawRoutes(routeMapKey, width, height)
    RecordCounts(self)
    return true
  end

  self.dirty = false
  self.lastSignature, self.lastSignatureKey = signature, signatureKey
  self.lastWidth, self.lastHeight, self.lastRevision = width, height, self.revision
  self.lastStitchedMask = stitchedMask
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
    local matches = area and area.enabled and (
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
  DrawRoutes(routeMapKey, width, height)
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
  OUTPOST = "Outpost",
  SETTLEMENT = "Settlement",
  HUNTING_GROUNDS = "Hunting Grounds",
  FOREST = "Forest",
  GOLD_MINE = "Gold Mine",
  FARM = "Farm",
}

Map.TYPE_HINTS = {
  OUTPOST = "Stay inside the zone to capture it.",
  SETTLEMENT = "Capturable once every associated objective is controlled.",
  HUNTING_GROUNDS = "Kill the required creatures to capture it.",
  FOREST = "Harvest wood.",
  GOLD_MINE = "Harvest gold.",
  FARM = "Produce agricultural resources.",
}

local OWNER_CODES = { HORDE = "H", ALLIANCE = "A" }
local FACTION_LABELS = {
  H = { "Horde", 0.90, 0.25, 0.20 },
  A = { "Alliance", 0.25, 0.55, 1.00 },
  N = { "Neutral", 0.70, 0.70, 0.70 },
}

local function CursorOnCanvas(canvas, width, height)
  local getCursor = GetGlobal("GetCursorPosition")
  if type(getCursor) ~= "function" or type(canvas.GetEffectiveScale) ~= "function"
      or type(canvas.GetLeft) ~= "function" or type(canvas.GetTop) ~= "function" then
    return nil
  end
  local ok, cursorX, cursorY, scale, left, top = pcall(function()
    local x, y = getCursor()
    return x, y, canvas:GetEffectiveScale(), canvas:GetLeft(), canvas:GetTop()
  end)
  if not ok or type(cursorX) ~= "number" or type(cursorY) ~= "number"
      or type(scale) ~= "number" or scale <= 0
      or type(left) ~= "number" or type(top) ~= "number" then
    return nil
  end
  local x = ((cursorX / scale) - left) / width * 100
  local y = (top - (cursorY / scale)) / height * 100
  if x < 0 or x > 100 or y < 0 or y > 100 then return nil end
  return x, y
end

local function ShowHoverPatches(entry, area, width, height, stitchedAPI, hostID)
  if not entry.records then return end
  entry.hoverTextures = entry.hoverTextures or {}
  local total = #entry.records
  local index = 1
  while index <= total do
    if not entry.hoverTextures[index] then entry.hoverTextures[index] = CreatePatch(entry) end
    if not PlacePatch(entry, entry.hoverTextures[index], entry.records[index],
        width, height, area.color, HOVER_ALPHA, area, stitchedAPI, hostID) then
      HideObject(entry.hoverTextures[index])
    end
    index = index + 1
  end
  while index <= #entry.hoverTextures do
    HideObject(entry.hoverTextures[index])
    index = index + 1
  end
end

local function FormatDuration(seconds)
  seconds = math.ceil(seconds)
  if seconds < 60 then return seconds .. "s" end
  return strFormat("%dm %02ds", mathFloor(seconds / 60), (seconds % 60))
end

local function AddFactionLine(tooltip, left, code, suffix)
  local label = FACTION_LABELS[code] or FACTION_LABELS.N
  tooltip:AddDoubleLine(left, label[1] .. (suffix or ""), 0.8, 0.8, 0.8,
    label[2], label[3], label[4])
end

-- Forever's world map is a UIParent window (Blizzard_WorldMap.xml) with no
-- WorldMapTooltip, so GameTooltip stays visible over it.
local function MapTooltip()
  local tooltip = GetGlobal("GameTooltip")
  if tooltip and type(tooltip.SetOwner) == "function" then return tooltip, "GameTooltip" end
  return nil, "none"
end

-- Route tooltip: offset from the cursor and font size reduction. Declared before
-- the functions below, which would otherwise read them as nil globals.
local ROUTE_TOOLTIP_OFFSET = 15
local ROUTE_TOOLTIP_FONT_DELTA = 3

-- The route tooltip uses smaller fonts on the shared map tooltip; every other tooltip
-- gets the original fonts back first.
local function HideTooltipIcons(tooltip)
  local pool = tooltip.WarfrontIcons
  if not pool then return end
  local index = 1
  while index <= #pool do
    pool[index].icon:Hide()
    pool[index].count:Hide()
    index = index + 1
  end
end

local function RestoreTooltipFonts(tooltip)
  HideTooltipIcons(tooltip)
  local saved = tooltip.WarfrontFonts
  if not saved then return end
  tooltip.WarfrontFonts = nil
  for index = 1, #saved do
    local entry = saved[index]
    pcall(entry[1].SetFont, entry[1], entry[2], entry[3], entry[4])
  end
end

-- Shrinks every line by ROUTE_TOOLTIP_FONT_DELTA; the caller shows the tooltip
-- afterwards so its size and background are computed with the new fonts.
local function ShrinkTooltipFonts(tooltip)
  local name = tooltip:GetName()
  if not name then return end
  local saved = {}
  local lines = tooltip:NumLines()
  local index = 1
  while index <= lines do
    local side = 1
    while side <= 2 do
      local text = GetGlobal(name .. (side == 1 and "TextLeft" or "TextRight") .. index)
      if text and type(text.GetFont) == "function" then
        local path, size, flags = text:GetFont()
        if path and type(size) == "number" then
          saved[#saved + 1] = { text, path, size, flags }
          text:SetFont(path, size - ROUTE_TOOLTIP_FONT_DELTA, flags)
        end
      end
      side = side + 1
    end
    index = index + 1
  end
  tooltip.WarfrontFonts = saved
end

-- The shared tooltip keeps the changed fonts and icons of an area tooltip until the
-- next map tooltip: put them back when it hides, so no other tooltip inherits them.
local function HookTooltipHide(tooltip)
  if tooltip.WarfrontHideHook or type(tooltip.GetScript) ~= "function" then return end
  tooltip.WarfrontHideHook = true
  local previous = tooltip:GetScript("OnHide")
  tooltip:SetScript("OnHide", function(self, ...)
    RestoreTooltipFonts(self)
    if previous then previous(self, ...) end
  end)
end

-- Area tooltip rows: 1.12 has no inline pictures, so a tall blank line reserves the
-- room of a row of unit icons and DrawTooltipRows lays them over it after Show.
local TOOLTIP_ICON_SIZE = 24
local TOOLTIP_ICON_GAP = 8
local TOOLTIP_HINT_SIZE_DELTA = 2
local TOOLTIP_GAP_FONT_SIZE = 5

-- Changes the font size of one left line; RestoreTooltipFonts puts it back.
local function RestyleLine(tooltip, index, size, shrink)
  local name = tooltip:GetName()
  local text = name and GetGlobal(name .. "TextLeft" .. index)
  if not text or type(text.GetFont) ~= "function" then return end
  local path, current, flags = text:GetFont()
  if not path or type(current) ~= "number" then return end
  tooltip.WarfrontFonts = tooltip.WarfrontFonts or {}
  tooltip.WarfrontFonts[#tooltip.WarfrontFonts + 1] = { text, path, current, flags }
  text:SetFont(path, size or (current - shrink), flags)
end

-- Reserves a line for `units` ({ key, count, faded }) and queues it for drawing.
local function AddUnitRow(tooltip, rows, units, faction)
  if #units == 0 then return end
  tooltip:AddLine(" ")
  local line = tooltip:NumLines()
  RestyleLine(tooltip, line, TOOLTIP_ICON_SIZE)
  rows[#rows + 1] = { line = line, units = units, faction = faction }
end

local function DrawTooltipRows(tooltip, rows)
  local window = WF.MainWindow
  local name = tooltip:GetName()
  if not name or not window or not window.UnitIcon then return end
  tooltip.WarfrontIcons = tooltip.WarfrontIcons or {}
  local pool = tooltip.WarfrontIcons
  local used = 0
  local widest = 0
  for rowIndex = 1, #rows do
    local row = rows[rowIndex]
    local line = GetGlobal(name .. "TextLeft" .. row.line)
    local unitIndex = 1
    while line and unitIndex <= #row.units do
      local unit = row.units[unitIndex]
      used = used + 1
      local slot = pool[used]
      if not slot then
        slot = {
          icon = tooltip:CreateTexture(nil, "ARTWORK"),
          count = tooltip:CreateFontString(nil, "OVERLAY", "NumberFontNormal"),
        }
        slot.icon:SetWidth(TOOLTIP_ICON_SIZE)
        slot.icon:SetHeight(TOOLTIP_ICON_SIZE)
        pool[used] = slot
      end
      local x = (unitIndex - 1) * (TOOLTIP_ICON_SIZE + TOOLTIP_ICON_GAP)
      window.UnitIcon(slot.icon, unit.key, row.faction)
      slot.icon:SetAlpha(unit.faded and 0.4 or 1)
      slot.icon:ClearAllPoints()
      slot.icon:SetPoint("LEFT", line, "LEFT", x, 0)
      slot.icon:Show()
      slot.count:SetText(tostring(unit.count))
      slot.count:ClearAllPoints()
      slot.count:SetPoint("BOTTOMRIGHT", slot.icon, "BOTTOMRIGHT", 1, 0)
      slot.count:Show()
      if x + TOOLTIP_ICON_SIZE > widest then widest = x + TOOLTIP_ICON_SIZE end
      unitIndex = unitIndex + 1
    end
  end
  -- Tooltip text insets are 10 px on each side.
  if widest > 0 and tooltip:GetWidth() < widest + 20 then tooltip:SetWidth(widest + 20) end
end

local function ShowAreaTooltip(canvas, area)
  local tooltip = MapTooltip()
  if not tooltip then return nil end
  RestoreTooltipFonts(tooltip)
  HookTooltipHide(tooltip)
  local typeName = Map.TYPE_NAMES[area.type] or area.type
  local info = WF.Capture and WF.Capture.TooltipInfo and WF.Capture:TooltipInfo(area.id)
  local rows = {}
  local ok = pcall(function()
    tooltip:SetOwner(canvas, "ANCHOR_CURSOR")
    tooltip:ClearLines()
    -- A locked siege is a badge at the top right; its reason stays below.
    local _, _, lockReason = string.find((info and info.detail) or "", "^Siege locked: (.*)$")
    if lockReason then
      tooltip:AddDoubleLine(area.label or typeName, "Siege locked", 1, 0.82, 0, 1, 0.35, 0.3)
    else
      tooltip:AddLine(area.label or typeName, 1, 0.82, 0)
    end
    if area.label then tooltip:AddLine(typeName, 1, 1, 1) end
    -- Capturable areas follow the owner registry; others keep their drawn color.
    if not Map.RESOURCE_TYPES[area.type] then
      AddFactionLine(tooltip, "Confirmed owner", info and info.owner or OWNER_CODES[area.colorKey or ""] or "N")
    end
    if info and info.hint then
      AddFactionLine(tooltip, "Unconfirmed owner", info.hint.owner, " (" .. info.hint.count .. " player(s), "
        .. FormatDuration(info.hint.age) .. " ago)")
      -- Decision 0046: an optional recommendation, never a requirement.
      if not info.cloud and WF.Companion and WF.Companion.ShownHint and WF.Companion:ShownHint() then
        tooltip:AddLine("Optional: the Warfront Companion adds the cloud's last known owner.", 0.6, 0.6, 0.6, 1)
      end
    end
    -- Cloud owner (decision 0060): shown only, never an owner for gameplay.
    if info and info.cloud and WF.Capture then
      local label, code, detail = WF.Capture.CloudLine(info.cloud)
      if code then
        AddFactionLine(tooltip, label, code, detail and (" (" .. detail .. ")") or nil)
      else
        tooltip:AddDoubleLine(label, detail, 0.8, 0.8, 0.8, 0.8, 0.8, 0.8)
      end
    end
    if info and info.challenger then
      AddFactionLine(tooltip, "Capture", info.challenger, " " .. info.percent .. "%")
    end
    if info and info.status then
      local status = info.status
      if info.remaining then status = status .. " (" .. FormatDuration(info.remaining) .. ")" end
      tooltip:AddLine(status, 1, 1, 1)
    end
    -- Outpost capture time or Settlement siege prerequisites (decision 0053).
    if lockReason then
      tooltip:AddLine(lockReason, 0.8, 0.8, 0.8)
    elseif info and info.detail then
      tooltip:AddLine(info.detail, 0.8, 0.8, 0.8)
    end
    if info and (info.nH or 0) + (info.nA or 0) > 0 then
      tooltip:AddDoubleLine("Players inside", "|cffe64033" .. info.nH .. " Horde|r  |cff408cff"
        .. info.nA .. " Alliance|r", 0.8, 0.8, 0.8, 1, 1, 1)
    end
    if info and info.here then tooltip:AddLine("You are here", 0.3, 1, 0.3) end
    -- Resource POIs: their shared stock, never an owner (decision 0048).
    local stock = WF.Stock and WF.Stock.TooltipInfo and WF.Stock:TooltipInfo(area.id)
    if stock then
      tooltip:AddDoubleLine(stock.name .. " stock", stock.level .. " / " .. stock.capacity, 0.8, 0.8, 0.8, 1, 1, 1)
      tooltip:AddLine(stock.status, 1, 1, 1)
      if stock.here then tooltip:AddLine("You are here", 0.3, 1, 0.3) end
    end
    -- Scouting (decision 0050): the enemy sees a scout coming, never its sender.
    local scout = WF.Scout and WF.Scout.TooltipInfo and WF.Scout:TooltipInfo(area.id)
    if scout then
      if scout.discovered then
        tooltip:AddDoubleLine("Discovered", FormatDuration(scout.discovered) .. " left", 0.8, 0.8, 0.8, 0.3, 1, 0.3)
        local view = scout.garrison
        local units = {}
        for index = 1, #WF.Garrison.UNIT_ORDER do
          local key = WF.Garrison.UNIT_ORDER[index]
          units[#units + 1] = { key = key, count = view and view[key] or "?", faded = not view or view[key] == 0 }
        end
        tooltip:AddDoubleLine("Garrison", view and ("seen " .. FormatDuration(scout.seen) .. " ago") or "unknown",
          0.8, 0.8, 0.8, 0.8, 0.8, 0.8)
        local side = view and (view.owner == "H" or view.owner == "A") and view.owner
          or WF.Capture and WF.Capture:MyFaction()
        AddUnitRow(tooltip, rows, units, side)
      end
      if scout.allied then
        tooltip:AddDoubleLine("Allied scout", "arrives in " .. FormatDuration(scout.allied), 0.8, 0.8, 0.8, 1, 1, 1)
      end
      if scout.enemy then
        tooltip:AddDoubleLine("Enemy scout", "arrives in " .. FormatDuration(scout.enemy), 0.8, 0.8, 0.8, 1, 0.4, 0.4)
      end
      if scout.exposed then
        tooltip:AddDoubleLine("Scouted by the enemy", FormatDuration(scout.exposed) .. " left", 0.8, 0.8, 0.8, 1, 0.4, 0.4)
      end
    end
    -- Armies (decision 0052): the exact composition only for one's own faction.
    local attack = WF.Attack and WF.Attack.TooltipInfo and WF.Attack:TooltipInfo(area.id)
    if attack then
      if attack.allied then
        tooltip:AddDoubleLine("Allied army", "arrives in " .. FormatDuration(attack.allied.left), 0.8, 0.8, 0.8, 1, 1, 1)
        local units = {}
        for index = 1, #WF.Attack.UNIT_ORDER do
          local key = WF.Attack.UNIT_ORDER[index]
          local count = attack.allied.counts[key]
          if count > 0 then units[#units + 1] = { key = key, count = count } end
        end
        AddUnitRow(tooltip, rows, units, WF.Capture and WF.Capture:MyFaction())
      end
      if attack.enemy then
        tooltip:AddDoubleLine("Enemy army", "arrives in " .. FormatDuration(attack.enemy), 0.8, 0.8, 0.8, 1, 0.4, 0.4)
      end
      if attack.pending then tooltip:AddLine("Battle waiting to be resolved", 1, 0.8, 0.3) end
      if attack.locked then
        tooltip:AddDoubleLine("Reinforcements locked", FormatDuration(attack.locked) .. " left", 0.8, 0.8, 0.8, 1, 0.8, 0.3)
      end
    end
    local hint = Map.TYPE_HINTS[area.type]
    local mobs = #(area.requiredMobIds or {})
    if mobs > 0 then
      tooltip:AddLine("Required creatures: " .. mobs, 1, 1, 1)
    end
    -- The hint is the quietest line: a gap above it, smaller and dimmer than the rest.
    if hint then
      tooltip:AddLine(" ")
      RestyleLine(tooltip, tooltip:NumLines(), TOOLTIP_GAP_FONT_SIZE)
      tooltip:AddLine(hint, 0.6, 0.6, 0.6, 1)
      RestyleLine(tooltip, tooltip:NumLines(), nil, TOOLTIP_HINT_SIZE_DELTA)
    end
    tooltip:Show()
    DrawTooltipRows(tooltip, rows)
  end)
  return ok and tooltip or nil
end

-- Tooltip of a scout or army icon: route and time left for everyone; the sender and
-- the composition only when the order belongs to the player's faction.
local function ShowRouteTooltip(canvas, slot)
  local tooltip = MapTooltip()
  if not tooltip then return nil end
  local module = slot.kind == "army" and WF.Attack or WF.Scout
  local now = WF.Now and WF.Now()
  if not module or type(module.RouteInfo) ~= "function" or type(now) ~= "number" then return nil end
  local info = module:RouteInfo(slot.record, now)
  if not info then return nil end
  RestoreTooltipFonts(tooltip)
  local ok, tooltipError = pcall(function()
    -- ANCHOR_CURSOR ignores offsets on this client: anchor by hand, up and right of the cursor.
    tooltip:SetOwner(canvas, "ANCHOR_NONE")
    local getCursor = GetGlobal("GetCursorPosition")
    local parent = GetGlobal("UIParent")
    local cx, cy = nil, nil
    if type(getCursor) == "function" then cx, cy = getCursor() end
    local scale = tooltip:GetEffectiveScale()
    tooltip:ClearAllPoints()
    if cx and cy and parent and scale and scale > 0 then
      tooltip:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", cx / scale + ROUTE_TOOLTIP_OFFSET, cy / scale + ROUTE_TOOLTIP_OFFSET)
    else
      tooltip:SetPoint("BOTTOMLEFT", canvas, "CENTER", ROUTE_TOOLTIP_OFFSET, ROUTE_TOOLTIP_OFFSET)
    end
    tooltip:ClearLines()
    local name = slot.kind == "army" and "army" or "scout"
    if info.allied then
      tooltip:AddLine("Allied " .. name, 0.3, 1, 0.3)
    else
      tooltip:AddLine("Enemy " .. name, 1, 0.4, 0.4)
    end
    if info.owner then tooltip:AddDoubleLine("Sent by", info.owner, 0.8, 0.8, 0.8, 1, 1, 1) end
    tooltip:AddDoubleLine("From", info.from, 0.8, 0.8, 0.8, 1, 1, 1)
    tooltip:AddDoubleLine("To", info.to, 0.8, 0.8, 0.8, 1, 1, 1)
    tooltip:AddDoubleLine("Arrives in", FormatDuration(mathMax(info.left, 0)), 0.8, 0.8, 0.8, 1, 1, 1)
    if info.army then tooltip:AddLine(info.army, 1, 1, 1) end
    ShrinkTooltipFonts(tooltip)
    tooltip:Show()
  end)
  if not ok and WF.RecordError then WF.RecordError("map route tooltip", tooltipError) end
  return ok and tooltip or nil
end

-- The route slot whose icon is under the cursor (x, y in percent of the canvas).
-- Half-size, in canvas pixels, of the hover square of a scout or army icon: wider
-- than the 20 px icon because it moves. The icon already hovered keeps its tooltip
-- a little further out, so the tooltip does not flicker at the edge.
local ROUTE_HIT_HALF = 15
local ROUTE_KEEP_HALF = 22

function Map:FindRouteAt(x, y, width, height)
  local routes = self.routes
  local best, bestDistance = nil, nil
  local index = 1
  while index <= routes.count do
    local slot = routes.slots[index]
    if slot and slot.iconShown and slot.record and slot.iconX then
      local dx = mathAbs(x / 100 - slot.iconX) * width
      local dy = mathAbs(y / 100 - slot.iconY) * height
      local held = slot.record == self.hoverRoute
      if held and dx <= ROUTE_KEEP_HALF and dy <= ROUTE_KEEP_HALF then return slot end
      if dx <= ROUTE_HIT_HALF and dy <= ROUTE_HIT_HALF then
        -- Overlapping icons: the one nearest the cursor wins.
        local distance = dx * dx + dy * dy
        if not bestDistance or distance < bestDistance then best, bestDistance = slot, distance end
      end
    end
    index = index + 1
  end
  return best
end

function Map:ClearHover()
  local id = self.hoverId
  self.hoverId = nil
  local hadRoute = self.hoverRoute
  self.hoverRoute = nil
  self.routeSecond = nil
  if hadRoute then RefreshRouteDots() end
  self.cursorX = nil
  self.cursorY = nil
  local entry = id and self.groups[id]
  if entry then HideHoverPatches(entry) end
  local tooltip = self.tooltipShown
  if tooltip then
    self.tooltipShown = nil
    if type(tooltip.Hide) == "function" then pcall(tooltip.Hide, tooltip) end
    RestoreTooltipFonts(tooltip)
  end
end

local function AreaMatchesView(self, area, mapKey)
  if self.stitchedAPI then return StitchedZoneVisible(self.stitchedMask, area.mapKey) end
  return area.mapKey == mapKey
end

local function AreaContainsCanvasPoint(self, area, x, y)
  if not self.stitchedAPI then return Contours.AreaContainsPoint(area, x, y) end
  local sourceID = FOREVER_ZONE_IDS[area.mapKey]
  local sourceX, sourceY = TransformMapPoint(
    self.stitchedAPI, self.stitchedHostID, sourceID, x / 100, y / 100)
  if not sourceX or not sourceY then return false end
  return Contours.AreaContainsPoint(area, sourceX * 100, sourceY * 100)
end

function Map:FindAreaAt(x, y, width, height)
  local mapKey = CanonicalMapName(self.currentMap)
  local index
  -- Icons draw above every area and may overhang their own zone (the bounding-box
  -- middle can fall outside a concave one), so the cursor on an icon picks it first.
  if width and height then
    index = #self.order
    while index >= 1 do
      local id = self.order[index]
      local area = self.areas[id]
      local entry = self.groups[id]
      if area and entry and entry.active and entry.iconShown
          and AreaMatchesView(self, area, mapKey) then
        local reach = IconSize(area.type) * ICON_HIT_RATIO
        local reachX = reach / width * 100
        local reachY = reach / height * 100
        local iconX, iconY = GetIconPosition(area)
        iconX, iconY = ProjectAreaPoint(
          self.stitchedAPI, self.stitchedHostID, area, iconX, iconY)
        if iconX and mathAbs(x - iconX * 100) <= reachX
            and mathAbs(y - iconY * 100) <= reachY then
          return id
        end
      end
      index = index - 1
    end
  end
  index = #self.order
  -- Later areas draw above earlier ones, so test them first.
  while index >= 1 do
    local id = self.order[index]
    local area = self.areas[id]
    local entry = self.groups[id]
    if area and entry and entry.active and entry.records
        and AreaMatchesView(self, area, mapKey)
        and AreaContainsCanvasPoint(self, area, x, y) then
      return id
    end
    index = index - 1
  end
  return nil
end

-- True when the mouse is over the map itself: the canvas, or a frame that holds it
-- (WorldMapDetailFrame, WorldMapFrame). WorldFrame (the 3D world, reported over
-- parts of the open map) and Blizzard's landmark buttons (WorldMapFramePOI<n>,
-- 32x32, they only rename the area label) count as the map: measured on OctoWoW,
-- they swallowed most of the hover over EFST01, EFGM04 and EFFA09. Unit dots
-- (WorldMapPlayer, party, raid) share WorldMapTooltip and still block the hover,
-- as do unrelated frames above the map.
local function MapHasFocus(canvas, focus)
  if focus == canvas then return true end
  if not focus then return false end
  if focus == GetGlobal("WorldFrame") then return true end
  if type(focus.GetName) == "function" then
    local nameOk, name = pcall(focus.GetName, focus)
    if nameOk and type(name) == "string" and string.find(name, "^WorldMapFramePOI%d+$") then
      return true
    end
  end
  local node = canvas
  local depth = 0
  while node and depth < 10 do
    if type(node.GetParent) ~= "function" then return false end
    local ok, parent = pcall(node.GetParent, node)
    if not ok then return false end
    if parent == focus then return true end
    node = parent
    depth = depth + 1
  end
  return false
end

local function FrameLabel(frame)
  if not frame then return "none" end
  if type(frame.GetName) == "function" then
    local ok, name = pcall(frame.GetName, frame)
    if ok and name then return tostring(name) end
  end
  return "unnamed"
end

-- Taken when a tooltip opens, for /wf map hover (chat cannot be typed with the map open).
local function TooltipProbe(tooltip)
  local _, name = MapTooltip()
  if not tooltip then return "tooltip=" .. name .. " not shown" end
  local function Ask(frame, method)
    if not frame or type(frame[method]) ~= "function" then return "n/a" end
    local ok, value = pcall(frame[method], frame)
    return ok and tostring(value) or "error"
  end
  local parent = nil
  if type(tooltip.GetParent) == "function" then
    local ok, frame = pcall(tooltip.GetParent, tooltip)
    if ok then parent = frame end
  end
  return "tooltip=" .. name .. " parent=" .. FrameLabel(parent)
    .. " visible=" .. Ask(tooltip, "IsVisible") .. " lines=" .. Ask(tooltip, "NumLines")
    .. " strata=" .. Ask(tooltip, "GetFrameStrata")
    .. " UIParent.visible=" .. Ask(GetGlobal("UIParent"), "IsVisible")
end

function Map:UpdateHover()
  local canvas = GetCanvas()
  local width, height = GetCanvasSize(canvas)
  local canvasShown = true
  if canvas and type(canvas.IsVisible) == "function" then
    local shownOk, shown = pcall(canvas.IsVisible, canvas)
    canvasShown = not shownOk or shown and true or false
  end
  if not width or not canvasShown then
    if self.hoverId then self:ClearHover() end
    return
  end

  local getFocus = MouseFocusGetter()
  local focus = nil
  local focusOk = false
  if type(getFocus) == "function" then focusOk, focus = pcall(getFocus) end
  local x, y = CursorOnCanvas(canvas, width, height)
  -- This client can report no focused frame over the open map, so only a frame that
  -- is reported and unrelated to the map (a button, a window) blocks the hover.
  local overMap = not focus or MapHasFocus(canvas, focus)
  -- Keep the raw sample; Map:HoverDebug builds the text only when asked.
  local sample = self.hoverSample
  if not sample then
    sample = {}
    self.hoverSample = sample
  end
  sample.focus, sample.getFocus, sample.focusOk, sample.overMap = focus, type(getFocus), focusOk, overMap
  sample.x, sample.y, sample.visible, sample.map, sample.hover =
    x, y, self.visibleCount, self.currentMap, self.hoverId

  -- A scout or army icon under the cursor takes the hover before any area.
  local slot = self.enabled and overMap and x and height and self:FindRouteAt(x, y, width, height)
  if slot then
    local second = mathFloor(WF.Now and WF.Now() or 0)
    if self.hoverRoute ~= slot.record then self:ClearHover() end
    if self.hoverRoute ~= slot.record or self.routeSecond ~= second then
      self.hoverRoute, self.routeSecond = slot.record, second
      RefreshRouteDots()
      self.tooltipShown = ShowRouteTooltip(canvas, slot)
    end
    return
  end
  if self.hoverRoute then self:ClearHover() end

  if not self.enabled or not Contours or not overMap or not x
      or self.visibleCount == 0 or not self.currentMap then
    if self.hoverId then self:ClearHover() end
    return
  end
  if self.cursorX == x and self.cursorY == y then return end

  local id = self:FindAreaAt(x, y, width, height)
  if id == self.hoverId then
    self.cursorX, self.cursorY = x, y
    return
  end

  self:ClearHover()
  self.cursorX, self.cursorY = x, y
  if not id then return end

  local area = self.areas[id]
  local entry = self.groups[id]
  self.hoverId = id
  ShowHoverPatches(entry, area, width, height, self.stitchedAPI, self.stitchedHostID)
  self.tooltipShown = ShowAreaTooltip(canvas, area)
  self.tooltipDebug = id .. " " .. TooltipProbe(self.tooltipShown)
end

-- The last hover sample as text, for the debug command; nil before any sample.
function Map:HoverDebug()
  local sample = self.hoverSample
  if not sample then return nil end
  return "focus=" .. FrameLabel(sample.focus) .. " getFocus=" .. sample.getFocus
    .. " focusOk=" .. tostring(sample.focusOk) .. " overMap=" .. tostring(sample.overMap)
    .. " cursor=" .. (sample.x and string.format("%.1f,%.1f", sample.x, sample.y) or "off-canvas")
    .. " visible=" .. tostring(sample.visible) .. " map=" .. tostring(sample.map)
    .. " hover=" .. tostring(sample.hover)
end

-- Hover probe (/wf map hover probe | report | probe off). While on, each hover
-- sample with the cursor inside a drawn shape is counted for that area, and a
-- sample whose hover differs from the shape under the cursor keeps its reason.
-- Bounded, and saved in WarfrontDB.hoverProbe so /reload makes it readable.
local HOVER_PROBE_SAMPLES = 150

local function ShapeAreaAt(self, x, y)
  local mapKey = CanonicalMapName(self.currentMap)
  local index = #self.order
  while index >= 1 do
    local id = self.order[index]
    local area = self.areas[id]
    if area and area.enabled and AreaMatchesView(self, area, mapKey)
        and AreaContainsCanvasPoint(self, area, x, y) then
      return id
    end
    index = index - 1
  end
  return nil
end

local function ProbeFocusLabel(focus)
  local label = FrameLabel(focus)
  if focus and label == "unnamed" and type(focus.GetParent) == "function" then
    local ok, parent = pcall(focus.GetParent, focus)
    if ok and parent then label = "unnamed<" .. FrameLabel(parent) end
  end
  return label
end

local function Round2(value)
  return mathFloor(value * 100 + 0.5) / 100
end

function Map:SetHoverProbe(enabled)
  if not enabled then
    self.hoverProbe = nil
    return
  end
  local probe = { areas = {}, samples = {}, dropped = 0 }
  self.hoverProbe = probe
  local db = WF.Storage and WF.Storage.GetDB and WF.Storage:GetDB()
  if type(db) == "table" then db.hoverProbe = probe end
end

local function HoverMissReason(self, canvas, focus, shapeId, x, y, width, height)
  local hoverId = self.hoverId
  if focus and not MapHasFocus(canvas, focus) then return "focus:" .. ProbeFocusLabel(focus) end
  if not shapeId then return "outsideShape:" .. tostring(hoverId) end
  local entry = self.groups[shapeId]
  if not entry then return "noEntry" end
  if not entry.active then return "inactive" end
  if not entry.records then return entry.pending and "building" or "noRecords" end
  local found = self:FindAreaAt(x, y, width, height)
  if hoverId and found == hoverId then return "icon:" .. hoverId end
  if found == shapeId then return "notApplied:" .. tostring(hoverId) end
  return "found:" .. tostring(found) .. ":" .. tostring(hoverId)
end

function Map:ProbeHover()
  local probe = self.hoverProbe
  local canvas = GetCanvas()
  local width, height = GetCanvasSize(canvas)
  if not probe or not width or not self.currentMap or not Contours then return end
  local x, y = CursorOnCanvas(canvas, width, height)
  if not x then return end
  local shapeId = ShapeAreaAt(self, x, y)
  local hoverId = self.hoverId
  if not shapeId and not hoverId then return end

  local key = shapeId or hoverId
  local stats = probe.areas[key]
  if not stats then
    stats = { inside = 0, hovered = 0, missed = 0, reasons = {} }
    probe.areas[key] = stats
  end
  if shapeId then stats.inside = stats.inside + 1 end
  if shapeId == hoverId then
    stats.hovered = stats.hovered + 1
    return
  end

  local getFocus = MouseFocusGetter()
  local focus = nil
  if type(getFocus) == "function" then
    local ok, frame = pcall(getFocus)
    if ok then focus = frame end
  end
  local reason = HoverMissReason(self, canvas, focus, shapeId, x, y, width, height)
  stats.missed = stats.missed + 1
  stats.reasons[reason] = (stats.reasons[reason] or 0) + 1

  -- One sample per reason and cursor spot, so a still cursor fills nothing.
  if probe.lastReason == reason and probe.lastArea == key
      and mathAbs(probe.lastX - x) < 0.5 and mathAbs(probe.lastY - y) < 0.5 then
    return
  end
  probe.lastReason, probe.lastArea, probe.lastX, probe.lastY = reason, key, x, y
  if #probe.samples >= HOVER_PROBE_SAMPLES then
    probe.dropped = probe.dropped + 1
    return
  end
  table.insert(probe.samples, {
    area = key, reason = reason, x = Round2(x), y = Round2(y),
    focus = ProbeFocusLabel(focus), map = self.currentMap,
    width = Round2(width), height = Round2(height),
  })
end

-- Chat lines for /wf map hover report: per area, cursor samples inside its
-- shape, how many showed its hover, and the most frequent miss reasons.
function Map:HoverProbeReport()
  local probe = self.hoverProbe
  if not probe then return { "hover probe is off (/wf map hover probe)" } end
  local lines = {}
  for id, stats in pairs(probe.areas) do
    local reasons = {}
    for reason, count in pairs(stats.reasons) do
      reasons[#reasons + 1] = { reason, count }
    end
    table.sort(reasons, function(a, b) return a[2] > b[2] end)
    local text = id .. " inside=" .. stats.inside .. " hovered=" .. stats.hovered
      .. " missed=" .. stats.missed
    local index = 1
    while index <= 3 and reasons[index] do
      text = text .. " " .. reasons[index][1] .. "=" .. reasons[index][2]
      index = index + 1
    end
    lines[#lines + 1] = text
  end
  table.sort(lines)
  if #lines == 0 then
    lines[#lines + 1] = "no sample inside an area yet (open the map, move the cursor)"
  end
  table.insert(lines, "samples kept=" .. #probe.samples .. " dropped=" .. probe.dropped
    .. " (/reload saves them)")
  return lines
end

-- A hidden frame gets no OnUpdate: hiding the driver stops Map:Tick.
function Map:WakeDriver()
  local driver = self.driver
  if driver and type(driver.Show) == "function" then pcall(driver.Show, driver) end
end

function Map:SleepDriver()
  local driver = self.driver
  if driver and type(driver.Hide) == "function" then pcall(driver.Hide, driver) end
end

local function CanvasVisible()
  local canvas = GetCanvas()
  if not canvas then return false end
  if type(canvas.IsVisible) ~= "function" then return true end
  local ok, visible = pcall(canvas.IsVisible, canvas)
  return not ok or visible and true or false
end

function Map:Tick()
  self.ticks = (self.ticks or 0) + 1
  self:StepBuildQueue()
  -- A closed map needs no hover or refresh (the OnHide hook already hid
  -- everything); one last hover pass clears its tooltip, and the first tick
  -- after reopening refreshes at once.
  if not CanvasVisible() then
    if self.canvasWasVisible then
      self.canvasWasVisible = false
      local hoverOk, hoverError = pcall(self.UpdateHover, self)
      if not hoverOk and WF.RecordError then WF.RecordError("map hover", hoverError) end
    end
    -- Nothing left to do while closed: stop the per-frame driver. The map's
    -- OnShow hook and QueueBuild wake it (only once that hook is in place).
    if self.wakeHooked and self:BuildCount() == 0 then self:SleepDriver() end
    return
  end
  self.openTicks = (self.openTicks or 0) + 1
  if not self.canvasWasVisible then
    self.canvasWasVisible = true
    self.lastRefreshAt, self.fallbackTicks = nil, 15
  end
  local now = WF.Now and WF.Now() or 0
  if type(now) == "number" and now > 0
      and (not self.lastHoverAt or now - self.lastHoverAt >= HOVER_INTERVAL) then
    self.lastHoverAt = now
    local hoverOk, hoverError = pcall(self.UpdateHover, self)
    if not hoverOk and WF.RecordError then WF.RecordError("map hover", hoverError) end
    if self.hoverProbe then
      local probeOk, probeError = pcall(self.ProbeHover, self)
      if not probeOk and WF.RecordError then WF.RecordError("map hover probe", probeError) end
    end
  end
  if type(now) == "number" and now > 0 then
    if not self.lastRefreshAt or now - self.lastRefreshAt >= REFRESH_INTERVAL then
      self.lastRefreshAt = now
      self:Refresh()
    end
  else
    self.fallbackTicks = (self.fallbackTicks or 0) + 1
    if self.fallbackTicks >= 15 then
      self.fallbackTicks = 0
      self:Refresh()
    end
  end
end

-- Diagnostic squares for the area-patch texture, built like a real area group.
-- Each square isolates one suspect, left to right:
-- 1 white WHITE8X8 (control), 2 profile fill, 3 the same fill with mirrored u
-- (every real patch has u1 > u2), 4 the fill stacked from 48 strips 0.83 units
-- tall (the real patch height), 5 the whole profile strip (border gradient).
local PROBE_SIZE = 40
local PROBE_STRIPS = 48

function Map:ShowProbe(enabled)
  if self.probe then
    HideObject(self.probe)
    self.probe = nil
  end
  if not enabled then return true, "probe removed" end

  local canvas = GetCanvas()
  local create = GetGlobal("CreateFrame")
  if not canvas or type(create) ~= "function" then return false, "no WorldMapButton" end
  local ok, frame = pcall(create, "Frame", nil, canvas)
  if not ok or not frame then return false, "CreateFrame failed" end
  frame:SetAllPoints(canvas)
  frame:EnableMouse(false)
  frame:SetFrameLevel(canvas:GetFrameLevel() + 1)
  self.probe = frame

  local results = {}
  local function Square(index, path, u1, u2, v1, v2, top, height)
    local texture = frame:CreateTexture(nil, "ARTWORK")
    local loaded = texture:SetTexture(path)
    texture:SetTexCoord(u1, u2, v1, v2)
    texture:SetVertexColor(1, 0.2, 0.8, 1)
    texture:SetPoint("TOPLEFT", frame, "TOPLEFT",
      40 + (index - 1) * (PROBE_SIZE + 12), -(40 + top))
    texture:SetWidth(PROBE_SIZE)
    texture:SetHeight(height)
    texture:Show()
    return loaded
  end

  results[1] = Square(1, "Interface\\Buttons\\WHITE8X8", 0, 1, 0, 1, 0, PROBE_SIZE)
  results[2] = Square(2, PROFILE_TEXTURE, 0.95, 0.99, 0.25, 0.75, 0, PROBE_SIZE)
  results[3] = Square(3, PROFILE_TEXTURE, 0.99, 0.95, 0.25, 0.75, 0, PROBE_SIZE)
  local strip = PROBE_SIZE / PROBE_STRIPS
  local index = 1
  while index <= PROBE_STRIPS do
    results[4] = Square(4, PROFILE_TEXTURE, 0.95, 0.99, 0.25, 0.75,
      (index - 1) * strip, strip)
    index = index + 1
  end
  results[5] = Square(5, PROFILE_TEXTURE, 0, 1, 0, 1, 0, PROBE_SIZE)
  frame:Show()
  return true, "SetTexture white=" .. tostring(results[1])
    .. " profile=" .. tostring(results[2])
end

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

local function SuspendSafely()
  local suspendOk, suspendError = pcall(Map.SuspendForClose, Map)
  if not suspendOk and WF.RecordError then WF.RecordError("map close", suspendError) end
end

local mapFrame = GetGlobal("WorldMapFrame")
if mapFrame and type(mapFrame.GetScript) == "function"
    and type(mapFrame.SetScript) == "function" then
  local previousOnHide = mapFrame:GetScript("OnHide")
  mapFrame:SetScript("OnHide", function(self, ...)
    SuspendSafely()
    if previousOnHide then previousOnHide(self, ...) end
  end)
end
-- Opening the map wakes the driver that Map:Tick put to sleep.
if mapFrame and type(mapFrame.HookScript) == "function" then
  Map.wakeHooked = pcall(mapFrame.HookScript, mapFrame, "OnShow", function()
    Map:WakeDriver()
    -- Diagnostics for /wf map: what the driver and canvas look like on open.
    Map.mapShows = (Map.mapShows or 0) + 1
    local driver = Map.driver
    local ok, visible = false, nil
    if driver and type(driver.IsVisible) == "function" then ok, visible = pcall(driver.IsVisible, driver) end
    Map.showDriverVisible = ok and visible and true or false
    Map.showCanvasVisible = CanvasVisible()
  end) and true or nil
end

-- Forever tags the map dropdown so addons can safely append their own filters.
local function IsMapFilterChecked()
  return not Map:Hidden()
end

local function ToggleMapFilter()
  local ok, err = pcall(Map.SetHidden, Map, not Map:Hidden())
  if not ok and WF.RecordError then WF.RecordError("map filter", err) end
end

local function RegisterMapFilter()
  local menu = GetGlobal("Menu")
  if type(menu) ~= "table" or type(menu.ModifyMenu) ~= "function" then return end
  local ok, handle = pcall(menu.ModifyMenu, "MENU_WORLD_MAP_TRACKING", function(_, rootDescription)
    if rootDescription and type(rootDescription.CreateCheckbox) == "function" then
      rootDescription:CreateCheckbox("Warfront", IsMapFilterChecked, ToggleMapFilter)
    end
  end)
  if ok then
    Map.filterMenuHandle = handle
  elseif WF.RecordError then
    WF.RecordError("map filter registration", handle)
  end
end

RegisterMapFilter()
