local WF = Warfront

WF.Compat = WF.Compat or {}
local Compat = WF.Compat

-- The original addon targeted the 1.12 Lua environment. Keep harmless helpers
-- local to the compatibility boundary while the gameplay code is migrated.
if not table.getn then
  table.getn = function(value) return #value end
end

if not math.mod then
  math.mod = function(value, divisor) return value % divisor end
end

if not unpack and table.unpack then
  unpack = table.unpack
end

if not getglobal then
  function getglobal(name) return _G[name] end
end

if not setglobal then
  function setglobal(name, value) _G[name] = value end
end

-- 1.12-shaped functions rebuilt on Forever APIs. They live in Compat.api only,
-- never in _G, so other addons never see Warfront's legacy return shapes.
-- Modules resolve them by name with Compat.Global(name).
local api = {}
Compat.api = api

function Compat.Global(name)
  local fn = api[name]
  if fn ~= nil then return fn end
  if _G then return _G[name] end
  return nil
end

if C_ChatInfo and C_ChatInfo.SendAddonMessage then
  api.SendAddonMessage = function(prefix, message, chatType, target)
    if target ~= nil then target = tostring(target) end
    return C_ChatInfo.SendAddonMessage(prefix, message, chatType, target)
  end
end

if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
  api.RegisterAddonMessagePrefix = function(prefix)
    return C_ChatInfo.RegisterAddonMessagePrefix(prefix)
  end
end

if C_ChatInfo and C_ChatInfo.SendChatMessage then
  api.SendChatMessage = function(message, chatType, languageID, target)
    if target ~= nil then target = tostring(target) end
    return C_ChatInfo.SendChatMessage(message, chatType, languageID, target)
  end
end

-- Forever FrameXML joins text channels through JoinPermanentChannel.
if JoinPermanentChannel then
  api.JoinChannelByName = function(name, password, chatFrameID)
    if chatFrameID == nil and DEFAULT_CHAT_FRAME and type(DEFAULT_CHAT_FRAME.GetID) == "function" then
      chatFrameID = DEFAULT_CHAT_FRAME:GetID()
    end
    return JoinPermanentChannel(name, password, chatFrameID, 1)
  end
end

-- 1.12 map file names by Forever uiMapID. Map names are localized, so maps
-- are matched by ID (UiMap.db2, build 1.60.1.69913; checked in-game on a
-- frFR client, 2026-11-07). 947 "Azeroth" is the world map; 1463 and 1464
-- are the second continent maps that UiMap.db2 also lists.
local MAP_KEYS = {
  [947] = "World",
  [1414] = "Kalimdor",
  [1464] = "Kalimdor",
  [1415] = "Azeroth",
  [1463] = "Azeroth",
  [1411] = "Durotar",
  [1413] = "Barrens",
  [1417] = "Arathi",
  [1424] = "Hilsbrad",
  [1429] = "Elwynn",
  [1436] = "Westfall",
}
Compat.MAP_KEYS = MAP_KEYS

-- The map the open world map shows, or nil when the world map is hidden.
local function DisplayedMapID()
  if WorldMapFrame and type(WorldMapFrame.IsShown) == "function" and WorldMapFrame:IsShown()
      and type(WorldMapFrame.GetMapID) == "function" then
    local ok, mapID = pcall(WorldMapFrame.GetMapID, WorldMapFrame)
    if ok and type(mapID) == "number" then return mapID end
  end
  return nil
end

local function PlayerMapID()
  if C_Map and C_Map.GetBestMapForUnit then
    local mapID = C_Map.GetBestMapForUnit("player")
    if type(mapID) == "number" then return mapID end
  end
  return nil
end

-- 1.12 read every map function from one "current map": the open map's
-- selection, else the player's zone. Forever reads it live on every call, so
-- a zone change can never leave a stale map behind.
local function CurrentMapID()
  return DisplayedMapID() or PlayerMapID()
end

local function MapInfo(mapID)
  if not mapID or not C_Map or not C_Map.GetMapInfo then return nil end
  return C_Map.GetMapInfo(mapID)
end

local function MapName(mapID)
  if mapID and MAP_KEYS[mapID] then return MAP_KEYS[mapID] end
  local info = MapInfo(mapID)
  if not info or type(info.name) ~= "string" then return nil end
  return info.name
end

-- Legacy callers re-centre a closed map on the player. The current map is
-- already live, so these only report it.
api.SetMapToCurrentZone = function()
  return CurrentMapID()
end

api.SetMapZoom = function()
  return CurrentMapID() ~= nil
end

api.GetMapInfo = function()
  return MapName(CurrentMapID())
end

api.GetCurrentMapZone = function()
  local info = MapInfo(CurrentMapID())
  if not info then return 0 end
  local continent = Enum and Enum.UIMapType and Enum.UIMapType.Continent or 1
  local cosmic = Enum and Enum.UIMapType and Enum.UIMapType.Cosmic or 0
  local world = Enum and Enum.UIMapType and Enum.UIMapType.World or 0
  if info.mapType == continent or info.mapType == cosmic or info.mapType == world then return 0 end
  return 1
end

api.GetCurrentMapContinent = function()
  local mapID = CurrentMapID()
  local safety = 0
  while mapID and mapID > 0 and safety < 8 do
    local key = MAP_KEYS[mapID]
    if key == "Kalimdor" then return 1 end
    if key == "Azeroth" then return 2 end
    local info = MapInfo(mapID)
    if not info then break end
    mapID = info.parentMapID
    safety = safety + 1
  end
  return 0
end

-- Position on the current map, 0..1. Like 1.12, 0, 0 when the unit is not on
-- that map (for example while the open map shows another zone).
api.GetPlayerMapPosition = function(unit)
  if not C_Map or not C_Map.GetPlayerMapPosition then return 0, 0 end
  local mapID = CurrentMapID()
  if not mapID then return 0, 0 end
  local position = C_Map.GetPlayerMapPosition(mapID, unit or "player")
  if not position then return 0, 0 end
  local x, y
  if type(position.GetXY) == "function" then
    x, y = position:GetXY()
  else
    x, y = position.x, position.y
  end
  if type(x) ~= "number" or type(y) ~= "number" then return 0, 0 end
  return x, y
end

function Compat.GetWorldMapCanvas()
  if WorldMapFrame and type(WorldMapFrame.GetCanvas) == "function" then
    local ok, canvas = pcall(WorldMapFrame.GetCanvas, WorldMapFrame)
    if ok and canvas then return canvas end
  end
  if WorldMapFrame and WorldMapFrame.ScrollContainer then
    return WorldMapFrame.ScrollContainer.Child
  end
  return nil
end
