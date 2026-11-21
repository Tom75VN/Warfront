-- Standard functions cached as locals: hot paths call them often.
local mathAbs = math.abs
local mathMax = math.max
local mathMin = math.min

Warfront = Warfront or {}

local WF = Warfront
local Map = WF.Map

-- POI areas of the player's zone on the minimap (docs/map-pois.md § Minimap,
-- decision 0054): the world map's records and colours, placed around the
-- player and clipped to the active minimap shape. Local display only.
local MinimapAreas = {
  patches = {},
  icons = {},
  iconKeys = {},
  used = 0,
  iconsUsed = 0,
  elapsed = 0,
  sinceLayout = 0,
  indoorDirty = true,
}

WF.MinimapAreas = MinimapAreas

-- Fallback diameters for clients without C_Minimap.GetViewRadius. Forever's
-- live view radius takes precedence.
local OUTDOOR_YARDS = { 466.6667, 400, 333.3333, 266.6667, 200, 133.3333 }
local INDOOR_YARDS = { 300, 240, 180, 120, 80, 50 }
local UPDATE_INTERVAL = 0.05
local REFRESH_INTERVAL = 1
local MOVE_PIXELS = 0.5
-- Height of the bands a patch crossing the minimap edge is cut into.
local BAND = 2
local EDGE_INSET = 1
local MAX_PATCHES = 1500
-- Lighter than the world map so the terrain and blips stay readable.
local DEFAULT_ALPHA = 0.6
local BASE_ICON_SIZE = 23

function MinimapAreas:Opacity()
  return WF.Preferences and WF.Preferences:Get("minimapAreaOpacity") or DEFAULT_ALPHA
end

function MinimapAreas:IconSize()
  local scale = WF.Preferences and WF.Preferences:Get("minimapIconScale") or 1
  return BASE_ICON_SIZE * scale
end

function MinimapAreas:ApplyPreferences()
  self.sinceLayout = REFRESH_INTERVAL
  for _, texture in ipairs(self.patches) do texture.WarfrontOpacity = nil end
end

local function WorldMapShown()
  local frame = WorldMapFrame
  return frame and type(frame.IsVisible) == "function" and frame:IsVisible() and true or false
end

-- Map file and position (0..1) of the player on the zone map the client
-- holds; modules/presence.lua re-centres a closed map on the player's zone.
local function ReadPlayer()
  local Compat = WF.Compat
  local GetMapInfo = Compat.Global("GetMapInfo")
  local GetPlayerMapPosition = Compat.Global("GetPlayerMapPosition")
  local GetCurrentMapZone = Compat.Global("GetCurrentMapZone")
  if type(GetMapInfo) ~= "function" or type(GetPlayerMapPosition) ~= "function" then
    return nil
  end
  local mapFile = GetMapInfo()
  if type(mapFile) ~= "string" or mapFile == "" then return nil end
  if type(GetCurrentMapZone) == "function" and GetCurrentMapZone() == 0 then return nil end
  local x, y = GetPlayerMapPosition("player")
  if type(x) ~= "number" or type(y) ~= "number" or (x == 0 and y == 0) then return nil end
  return mapFile, x, y
end

-- The client saves the outdoor and indoor zooms separately; when they differ,
-- the current zoom tells which one applies. Equal or unreadable: outdoor.
local function ReadIndoor(zoom)
  if type(GetCVar) ~= "function" then return false end
  local outsideOk, outside = pcall(GetCVar, "minimapZoom")
  local insideOk, inside = pcall(GetCVar, "minimapInsideZoom")
  outside = outsideOk and tonumber(outside) or nil
  inside = insideOk and tonumber(inside) or nil
  if not outside or not inside or outside == inside then return false end
  return zoom == inside
end

-- Same shape test as the minimap button (FlareUI, legacy PandaUI, then the
-- GetMinimapShape hook). Unknown keeps round clipping.
local function SquareMinimap()
  local button = WF.MinimapButton
  if type(button) ~= "table" or type(button.IsSquare) ~= "function" then return false end
  return button:IsSquare() == true
end

local function Hide(object)
  if object and type(object.Hide) == "function" then object:Hide() end
end

-- Zone size in yards (width, height). Forever's C_Map.GetMapWorldSize covers
-- every catalog zone (knowledge base, Map: mapbounds); the four fixed
-- Map.ROUTE_ZONES rectangles are the fallback. Successes are cached.
local zoneYards = {}
local function ZoneYards(mapKey)
  local cached = zoneYards[mapKey]
  if cached then return cached[1], cached[2] end
  local ids = Map.Kit and Map.Kit.FOREVER_ZONE_IDS
  local zoneID = ids and ids[mapKey]
  local cmap = C_Map
  if zoneID and type(cmap) == "table" and type(cmap.GetMapWorldSize) == "function" then
    local ok, width, height = pcall(cmap.GetMapWorldSize, zoneID)
    if ok and type(width) == "number" and type(height) == "number" and width > 0 and height > 0 then
      zoneYards[mapKey] = { width, height }
      return width, height
    end
  end
  local zone = Map.ROUTE_ZONES and Map.ROUTE_ZONES[mapKey]
  if zone then return zone[1] - zone[2], zone[3] - zone[4] end
  return nil
end

function MinimapAreas:Create()
  local minimap = Minimap
  if self.frame or not minimap or type(CreateFrame) ~= "function" then return self.frame end
  local frame = CreateFrame("Frame", "WarfrontMinimapAreas", minimap)
  if not frame then return nil end
  if type(frame.SetAllPoints) == "function" then frame:SetAllPoints(minimap) end
  if type(frame.EnableMouse) == "function" then frame:EnableMouse(false) end
  frame:SetScript("OnUpdate", function(_, elapsed)
    -- Same throttle as MinimapAreas:Tick, checked before paying for a pcall.
    local total = (MinimapAreas.elapsed or 0) + (elapsed or 0)
    if total < UPDATE_INTERVAL then
      MinimapAreas.elapsed = total
      return
    end
    local ok, err = pcall(MinimapAreas.Tick, MinimapAreas, elapsed)
    if not ok and WF.RecordError then WF.RecordError("minimap areas", err) end
  end)
  if type(frame.RegisterEvent) == "function" then
    frame:RegisterEvent("MINIMAP_UPDATE_ZOOM")
    frame:RegisterEvent("ZONE_CHANGED")
    frame:RegisterEvent("ZONE_CHANGED_INDOORS")
    frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    frame:RegisterEvent("PLAYER_ENTERING_WORLD")
    frame:SetScript("OnEvent", function()
      MinimapAreas.indoorDirty = true
      MinimapAreas.sinceLayout = REFRESH_INTERVAL
    end)
  end
  self.frame, self.minimap = frame, minimap
  return frame
end

local function Patch(self, index)
  local texture = self.patches[index]
  if not texture then
    texture = self.frame:CreateTexture(nil, "ARTWORK")
    texture:SetTexture(Map.PROFILE_TEXTURE)
    self.patches[index] = texture
  end
  return texture
end

-- One rectangle in minimap pixels from its centre (y downwards).
local function Draw(self, left, top, right, bottom, u1, u2, color)
  if self.used >= MAX_PATCHES then return end
  self.used = self.used + 1
  local texture = Patch(self, self.used)
  texture:SetTexCoord(u1, u2, 0.25, 0.75)
  local opacity = self:Opacity()
  if texture.WarfrontColor ~= color or texture.WarfrontOpacity ~= opacity then
    texture:SetVertexColor(color[1], color[2], color[3], opacity)
    texture.WarfrontColor = color
    texture.WarfrontOpacity = opacity
  end
  texture:ClearAllPoints()
  texture:SetPoint("TOPLEFT", self.frame, "CENTER", left, -top)
  texture:SetWidth(right - left)
  texture:SetHeight(bottom - top)
  texture:Show()
end

-- Round minimaps use chord-clipped bands; square minimaps clip directly to
-- their visible rectangle.
local function PlaceRecord(self, record, view, color)
  local left = (record[1] - view.x) * view.width
  local right = (record[3] - view.x) * view.width
  local top = (record[2] - view.y) * view.height
  local bottom = (record[4] - view.y) * view.height
  local halfWidth, halfHeight = view.halfWidth, view.halfHeight
  if right <= -halfWidth or left >= halfWidth or bottom <= -halfHeight or top >= halfHeight then return end
  if view.square then
    local l, r = mathMax(left, -halfWidth), mathMin(right, halfWidth)
    local slope = (record[6] - record[5]) / (right - left)
    Draw(self, l, mathMax(top, -halfHeight), r, mathMin(bottom, halfHeight),
      record[5] + slope * (l - left), record[5] + slope * (r - left), color)
    return
  end
  local radius = view.radius
  local farX = mathMax(mathAbs(left), mathAbs(right))
  local farY = mathMax(mathAbs(top), mathAbs(bottom))
  if farX * farX + farY * farY <= radius * radius then
    Draw(self, left, top, right, bottom, record[5], record[6], color)
    return
  end
  local u1, span = record[5], right - left
  local slope = (record[6] - u1) / span
  local y = mathMax(top, -radius)
  local last = mathMin(bottom, radius)
  while y < last do
    local y2 = mathMin(y + BAND, last)
    local middle = (y + y2) / 2
    local half = math.sqrt(mathMax(0, radius * radius - middle * middle))
    local l = mathMax(left, -half)
    local r = mathMin(right, half)
    if r > l then
      Draw(self, l, y, r, y2, u1 + slope * (l - left), u1 + slope * (r - left), color)
    end
    y = y2
  end
end

local function PlaceIcon(self, area, view)
  local x, y = Map.IconPosition(area)
  if not x then return end
  local size = self:IconSize()
  local dx, dy = (x - view.x) * view.width, (y - view.y) * view.height
  local reach = view.radius - size / 2
  if view.square then
    if mathAbs(dx) > view.halfWidth - size / 2 or mathAbs(dy) > view.halfHeight - size / 2 then return end
  elseif reach <= 0 or dx * dx + dy * dy > reach * reach then return end
  self.iconsUsed = self.iconsUsed + 1
  local index = self.iconsUsed
  local icon = self.icons[index]
  if not icon then
    icon = self.frame:CreateTexture(nil, "OVERLAY")
    self.icons[index] = icon
  end
  local keys = self.iconKeys[index]
  if not keys then
    keys = {}
    self.iconKeys[index] = keys
  end
  local level = Map.SettlementLevel(area)
  if keys.type ~= area.type or keys.color ~= area.colorKey or keys.column ~= area.iconColumn
      or keys.level ~= level then
    local path, left, right, top, bottom, w, h = Map.GetIcon(area.type, area.colorKey, area.iconColumn, level)
    if not path then
      icon:Hide()
      return
    end
    icon:SetTexture(path)
    icon:SetTexCoord(left, right, top, bottom)
    local width, height = Map.FitIcon(size, w, h)
    icon:SetWidth(width)
    icon:SetHeight(height)
    keys.type, keys.color, keys.column, keys.level = area.type, area.colorKey, area.iconColumn, level
  end
  if keys.size ~= size then
    local _, _, _, _, _, width, height = Map.GetIcon(area.type, area.colorKey, area.iconColumn, level)
    local iconWidth, iconHeight = Map.FitIcon(size, width, height)
    icon:SetWidth(iconWidth)
    icon:SetHeight(iconHeight)
    keys.size = size
  end
  icon:ClearAllPoints()
  icon:SetPoint("CENTER", self.frame, "CENTER", dx, -dy)
  icon:Show()
end

-- Bounding box of a records table, kept on it (records never change once built).
local function Bounds(records)
  local bounds = records.WarfrontBounds
  if bounds then return bounds end
  bounds = { 1, 1, 0, 0 }
  for index = 1, #records do
    local record = records[index]
    if record[1] < bounds[1] then bounds[1] = record[1] end
    if record[2] < bounds[2] then bounds[2] = record[2] end
    if record[3] > bounds[3] then bounds[3] = record[3] end
    if record[4] > bounds[4] then bounds[4] = record[4] end
  end
  records.WarfrontBounds = bounds
  return bounds
end

local function Overlaps(bounds, view)
  local radius = view.radius
  return (bounds[3] - view.x) * view.width > -radius
    and (bounds[1] - view.x) * view.width < radius
    and (bounds[4] - view.y) * view.height > -radius
    and (bounds[2] - view.y) * view.height < radius
end

function MinimapAreas:HideRest(fromPatch, fromIcon)
  local index = fromPatch
  while self.patches[index] do
    Hide(self.patches[index])
    index = index + 1
  end
  index = fromIcon
  while self.icons[index] do
    Hide(self.icons[index])
    index = index + 1
  end
end

function MinimapAreas:Clear()
  if self.used > 0 or self.iconsUsed > 0 then self:HideRest(1, 1) end
  self.used, self.iconsUsed, self.mapKey, self.lastX = 0, 0, nil, nil
end

function MinimapAreas:Layout(view)
  self.used, self.iconsUsed = 0, 0
  self.pending = false
  local mapKey, order = view.mapKey, Map.order
  local ownCapital = Map.OwnCapitalFaction()
  for index = 1, #order do
    local area = Map.areas[order[index]]
    if area and area.enabled and area.mapKey == mapKey and not Map.IsOwnCapital(area, ownCapital) then
      local records = Map:GetAreaRecords(area)
      if records and Overlaps(Bounds(records), view) then
        local color = area.color or Map.COLORS.NEUTRAL
        local total = #records
        local recordIndex = 1
        while recordIndex <= total do
          PlaceRecord(self, records[recordIndex], view, color)
          recordIndex = recordIndex + 1
        end
      elseif not records then
        self.pending = true
      end
      if Map.POI_ICON_ROWS[area.type] then PlaceIcon(self, area, view) end
    end
  end
  self:HideRest(self.used + 1, self.iconsUsed + 1)
end

-- Scratch table reused on every tick: no allocation while the player moves.
local view = {}

function MinimapAreas:Tick(elapsed)
  self.elapsed = self.elapsed + (elapsed or 0)
  if self.elapsed < UPDATE_INTERVAL then return end
  self.sinceLayout = self.sinceLayout + self.elapsed
  self.elapsed = 0
  local minimap = self.minimap
  -- The world map checkbox (Map:Hidden) hides the minimap areas too.
  if not Map.enabled or Map:Locked() or Map:Hidden() or not minimap then
    self:Clear()
    return
  end

  local mapFile, x, y = ReadPlayer()
  if not mapFile then
    -- A windowed world map browsing another zone keeps the last drawing.
    if not WorldMapShown() then self:Clear() end
    return
  end
  if mapFile ~= self.mapFile then
    self.mapFile = mapFile
    self.fileKey = Map.CanonicalMapName(mapFile)
  end
  local zoneWidth, zoneHeight
  if self.fileKey then zoneWidth, zoneHeight = ZoneYards(self.fileKey) end
  local zoom = type(minimap.GetZoom) == "function" and minimap:GetZoom() or 0
  if self.indoorDirty or zoom ~= self.zoom then
    self.indoor = ReadIndoor(zoom)
    self.indoorDirty = false
  end
  local yards
  if C_Minimap and type(C_Minimap.GetViewRadius) == "function" then
    local radius = C_Minimap.GetViewRadius()
    if type(radius) == "number" and radius > 0 then yards = radius * 2 end
  end
  yards = yards or (self.indoor and INDOOR_YARDS or OUTDOOR_YARDS)[zoom + 1]
  local size, height = minimap:GetWidth(), minimap:GetHeight()
  if not zoneWidth or not yards or type(size) ~= "number" or size <= 0 or type(height) ~= "number" or height <= 0 then
    self:Clear()
    return
  end
  local square = SquareMinimap()

  local scale = size / yards
  local width, mapHeight = zoneWidth * scale, zoneHeight * scale
  local moved = self.lastX and mathMax(mathAbs(x - self.lastX) * width,
    mathAbs(y - self.lastY) * mapHeight) or MOVE_PIXELS
  if self.mapKey == self.fileKey and zoom == self.zoom and yards == self.yards
      and size == self.size and height == self.height and square == self.square
      and moved < MOVE_PIXELS and not self.pending and self.revision == Map.revision
      and self.sinceLayout < REFRESH_INTERVAL then
    return
  end

  self.mapKey, self.zoom, self.yards, self.size, self.height, self.square, self.revision =
    self.fileKey, zoom, yards, size, height, square, Map.revision
  self.lastX, self.lastY, self.sinceLayout = x, y, 0
  view.mapKey, view.x, view.y = self.fileKey, x, y
  view.width, view.height = width, mapHeight
  view.halfWidth, view.halfHeight = size / 2 - EDGE_INSET, height / 2 - EDGE_INSET
  view.radius, view.square = mathMin(view.halfWidth, view.halfHeight), square
  self:Layout(view)
end

function MinimapAreas:GetStatus()
  return { patches = self.used, icons = self.iconsUsed, zone = self.mapKey, indoor = self.indoor }
end

MinimapAreas:Create()
