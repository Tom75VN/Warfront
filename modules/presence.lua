-- Standard functions cached as locals: hot paths call them often.
local strFormat = string.format

Warfront = Warfront or {}

local WF = Warfront
local Contours = WF.AreaContours
local Map = WF.Map
local Presence = {
  current = nil,
  listeners = {},
  samples = 0,
}

WF.Presence = Presence

-- Local presence only: which POI shape holds the player right now. Capture,
-- eligibility and P2P announcements (docs/capture.md) build on this later.
local SAMPLE_INTERVAL = 0.5
local Y_SCALE = 2 / 3

local function GetGlobal(name)
  if WF.Compat and WF.Compat.Global then return WF.Compat.Global(name) end
  if _G then return _G[name] end
  return nil
end

local function Call(name, a, b)
  local fn = GetGlobal(name)
  if type(fn) ~= "function" then return false end
  return pcall(fn, a, b)
end

local function WorldMapShown()
  local frame = GetGlobal("WorldMapFrame")
  if not frame or type(frame.IsVisible) ~= "function" then return false end
  local ok, shown = pcall(frame.IsVisible, frame)
  return ok and shown and true or false
end

-- Reads the player's position on its own zone map, in percent (0..100) like
-- data/pois.lua. Returns nil with a reason when no zone position is available.
-- core/compat.lua reads the open map's selection, else the player's zone, live
-- on every call: a closed map never needs re-centring on Forever.
function Presence:ReadPosition()
  local mapShown = WorldMapShown()

  local infoOk, mapFile = Call("GetMapInfo")
  if not infoOk or type(mapFile) ~= "string" or mapFile == "" then
    return nil, "no zone map"
  end
  local zoneOk, zoneIndex = Call("GetCurrentMapZone")
  if zoneOk and type(zoneIndex) == "number" and zoneIndex == 0 then
    return nil, "continent map shown"
  end

  local posOk, x, y = Call("GetPlayerMapPosition", "player")
  if not posOk or type(x) ~= "number" or type(y) ~= "number" then
    return nil, "GetPlayerMapPosition unavailable"
  end
  -- 0,0 means the player is not on the viewed map (instance, or another zone
  -- browsed on the open map).
  if x == 0 and y == 0 then
    return nil, mapShown and "player not on the viewed map" or "no position"
  end
  return { map = mapFile, x = x * 100, y = y * 100, mapShown = mapShown }
end

-- Areas are never edited in place: the centre is computed once and kept.
local function AreaCenter(area)
  if area.shape then return area.shape.x, area.shape.y end
  if area.centerX then return area.centerX, area.centerY end
  local points = area.controlVertices or area.vertices or area.locations
  local sumX, sumY, total = 0, 0, #points
  for index = 1, total do
    sumX = sumX + points[index].x
    sumY = sumY + points[index].y
  end
  area.centerX, area.centerY = sumX / total, sumY / total
  return area.centerX, area.centerY
end

-- Every enabled POI of the zone that contains the point, topmost first (the
-- map draws later areas above earlier ones), and the nearest centre.
function Presence:FindAreas(mapFile, x, y)
  local found = {}
  local nearest, nearestDistance = nil, nil
  if not Map or not Contours or not Map.CanonicalMapName then return found end
  local mapKey = Map.CanonicalMapName(mapFile)
  local index = #Map.order
  while index >= 1 do
    local area = Map.areas[Map.order[index]]
    if area and area.enabled and area.mapKey == mapKey then
      if Contours.AreaContainsPoint(area, x, y) then
        found[#found + 1] = area
      end
      local cx, cy = AreaCenter(area)
      -- Compare squared distances; one square root for the winner only.
      local dx, dy = x - cx, (y - cy) * Y_SCALE
      local squared = dx * dx + dy * dy
      if not nearestDistance or squared < nearestDistance then
        nearest, nearestDistance = area, squared
      end
    end
    index = index - 1
  end
  if nearestDistance then nearestDistance = math.sqrt(nearestDistance) end
  return found, nearest, nearestDistance
end

local function AreaName(area)
  return tostring(area.label or area.id)
end

function Presence:OnChange(callback)
  if type(callback) == "function" then self.listeners[#self.listeners + 1] = callback end
end

function Presence:SetCurrent(area)
  local previous = self.current
  if previous == area then return end
  self.current = area
  -- No on-screen notice: the capture HUD shows when the player is in an outpost.
  if previous then
    if WF.Record then WF.Record("POI_EXIT", { id = previous.id, type = previous.type }) end
  end
  if area then
    if WF.Record then WF.Record("POI_ENTER", { id = area.id, type = area.type }) end
  end
  local index = 1
  while index <= #self.listeners do
    local ok, err = pcall(self.listeners[index], area, previous)
    if not ok then WF.RecordError("presence listener", err) end
    index = index + 1
  end
end

function Presence:Sample()
  self.samples = self.samples + 1
  local position, reason = self:ReadPosition()
  self.position = position
  self.reason = reason
  if not position then
    -- An open map showing another zone says nothing about the player: keep
    -- the last state instead of reporting a false exit.
    if reason ~= "player not on the viewed map" and reason ~= "continent map shown" then
      self:SetCurrent(nil)
    end
    return
  end
  local found = self:FindAreas(position.map, position.x, position.y)
  self:SetCurrent(found[1])
end

function Presence:Tick()
  local now = WF.Now and WF.Now() or 0
  if type(now) ~= "number" or now <= 0 then return end
  if self.lastSampleAt and now - self.lastSampleAt < SAMPLE_INTERVAL then return end
  self.lastSampleAt = now
  self:Sample()
end

function Presence:PrintStatus()
  self:Sample()
  local position = self.position
  if not position then
    WF.Print("where: no position (" .. tostring(self.reason) .. ")")
    return
  end
  WF.Print(strFormat("where: map=%s x=%.2f y=%.2f%s", position.map,
    position.x, position.y, position.mapShown and " (map open)" or ""))
  local found, nearest, distance = self:FindAreas(position.map, position.x, position.y)
  if #found == 0 then
    WF.Print("where: not inside any POI")
  end
  for index = 1, #found do
    WF.Print("where: inside " .. AreaName(found[index]) .. " (" .. found[index].type .. ")")
  end
  if nearest then
    local size = nearest.shape and strFormat(", radius %.2f", nearest.shape.radius) or ""
    WF.Print(strFormat("where: nearest %s at %.2f%s", AreaName(nearest), distance, size))
  else
    WF.Print("where: no POI registered for this map")
  end
end

local create = GetGlobal("CreateFrame")
if type(create) == "function" then
  -- WorldFrame keeps ticking while the fullscreen map hides UIParent.
  local parent = GetGlobal("WorldFrame") or UIParent
  local frameOk, driver = pcall(create, "Frame", "WarfrontPresenceDriver", parent)
  if frameOk and driver and type(driver.SetScript) == "function" then
    driver:SetScript("OnUpdate", function()
      local ok, err = pcall(Presence.Tick, Presence)
      if not ok and WF.RecordError then WF.RecordError("presence driver", err) end
    end)
    Presence.driver = driver
  elseif WF.RecordError then
    WF.RecordError("presence driver", "unable to create OnUpdate driver")
  end
end
