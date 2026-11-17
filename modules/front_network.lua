Warfront = Warfront or {}

local WF = Warfront
local FrontNetwork = {
  revision = nil,
  camps = {},
  totals = {},
}

WF.FrontNetwork = FrontNetwork

-- War Camps and the Front Network (decision 0123). A Front Network belongs to
-- one faction and one continent. It is never sent, saved or uploaded: every
-- value below is derived from the shipped POI catalog (the enabled War Camps
-- of the continent, in POI data order) and the accepted owner registry
-- (Capture.owners). Hints, cloud rows and provisional owners never count.
-- Capture, travel and the interface all read this one helper.
local TRAVEL_MAX = 30
local CAPTURE_MAX = 35
local FACTIONS = { H = true, A = true }
local CONTINENT_NAMES = { EK = "Eastern Kingdoms", KA = "Kalimdor" }
local CONTINENTS = { "EK", "KA" }

-- Continent of every catalog zone map, by canonical map key. Copied from the
-- POI review interface's Forever map frames, measured in game on 2026-11-12
-- (#dashboard-POIs/forever_geometry.py ZONES, /frp mapbounds). A zone missing
-- here (Riverglades, Shen'dralas, Zephras Isle: continent not recorded) has no
-- Front Network: a War Camp placed there counts for no continent. Every client
-- ships the same table, so the denominators agree everywhere.
local ZONE_CONTINENTS = {
  alterac = "EK", arathi = "EK", badlands = "EK", blastedlands = "EK", burningsteppes = "EK",
  deadwindpass = "EK", dunmorogh = "EK", duskwood = "EK", easternplaguelands = "EK", elwynn = "EK",
  hilsbrad = "EK", hinterlands = "EK", ironforge = "EK", lochmodan = "EK", redridge = "EK",
  searinggorge = "EK", silverpine = "EK", stormwindcity = "EK", stranglethorn = "EK",
  swampofsorrows = "EK", tirisfal = "EK", undercity = "EK", westernplaguelands = "EK",
  westfall = "EK", wetlands = "EK",
  ashenvale = "KA", aszhara = "KA", barrens = "KA", darkshore = "KA", darnassus = "KA",
  desolace = "KA", durotar = "KA", dustwallow = "KA", felwood = "KA", feralas = "KA",
  hyjal = "KA", moonglade = "KA", mulgore = "KA", orgrimmar = "KA", silithus = "KA",
  stonetalonmountains = "KA", tanaris = "KA", teldrassil = "KA", thousandneedles = "KA",
  thunderbluff = "KA", ungorocrater = "KA", winterspring = "KA",
}

FrontNetwork.TRAVEL_MAX = TRAVEL_MAX
FrontNetwork.CAPTURE_MAX = CAPTURE_MAX
FrontNetwork.CONTINENTS = CONTINENTS
FrontNetwork.CONTINENT_NAMES = CONTINENT_NAMES
FrontNetwork.ZONE_CONTINENTS = ZONE_CONTINENTS

-- round(maximum * sqrt(held / total)), halves upward, in exact integers: p
-- rises while (2p + 1)^2 * total <= 4 * maximum^2 * held (decision 0123 § 4).
-- Zero without a camp or without a held camp. Self-contained (simulations
-- load it alone).
function FrontNetwork.Percent(maximum, held, total)
  if type(total) ~= "number" or type(held) ~= "number" or total <= 0 or held <= 0 then return 0 end
  if held > total then held = total end
  local limit = 4 * maximum * maximum * held
  local p = 0
  while p < maximum and (2 * p + 1) * (2 * p + 1) * total <= limit do
    p = p + 1
  end
  return p
end

-- ceil(seconds * (100 - percent) / 100) in whole seconds, without floating
-- ambiguity for integer inputs.
function FrontNetwork.Reduce(seconds, percent)
  if not percent or percent <= 0 then return seconds end
  return math.floor((seconds * (100 - percent) + 99) / 100)
end

-- Continent code of an area or a canonical map key, or nil.
function FrontNetwork.Continent(area)
  local key = type(area) == "table" and area.mapKey or area
  return type(key) == "string" and ZONE_CONTINENTS[key] or nil
end

-- Rebuilds the per-continent camp lists when the catalog changes (the map
-- revision moves); reused afterwards, so a refresh allocates nothing.
local function Refresh(self)
  local map = WF.Map
  if not map then return false end
  local revision = (map.revision or 0) * 100000 + #map.order
  if self.revision == revision and self.catalogMap == map then return true end
  self.revision = revision
  self.catalogMap = map
  self.heldCache = nil
  for index = 1, #CONTINENTS do
    local list = self.camps[CONTINENTS[index]]
    if not list then
      list = {}
      self.camps[CONTINENTS[index]] = list
    end
    for slot = #list, 1, -1 do list[slot] = nil end
  end
  for index = 1, #map.order do
    local id = map.order[index]
    local area = map.areas[id]
    if type(area) == "table" and area.enabled and area.type == "WAR_CAMP" then
      local list = self.camps[ZONE_CONTINENTS[area.mapKey or ""] or ""]
      if list then list[#list + 1] = id end
    end
  end
  for index = 1, #CONTINENTS do
    self.totals[CONTINENTS[index]] = #self.camps[CONTINENTS[index]]
  end
  return true
end

-- The enabled War Camps of a continent, in POI data order (read only).
function FrontNetwork:Camps(continent)
  Refresh(self)
  return self.camps[continent or ""] or {}
end

-- Number of enabled War Camps placed on the continent (the denominator T).
function FrontNetwork:Total(continent)
  if not Refresh(self) then return 0 end
  return self.totals[continent or ""] or 0
end

-- Accepted registry owner of a camp: a faction code, or nil (neutral or
-- nothing accepted yet). Never a hint, cloud row or static colour.
function FrontNetwork:Owner(id)
  local capture = WF.Capture
  local entry = capture and capture.owners and capture.owners[id]
  if entry and FACTIONS[entry.owner or ""] then return entry.owner end
  return nil
end

-- Camps of the continent held by faction in the accepted registry (H).
function FrontNetwork:Held(continent, faction)
  if not FACTIONS[faction or ""] or not Refresh(self) then return 0 end
  local list = self.camps[continent or ""]
  if not list then return 0 end
  local capture = WF.Capture
  if capture and capture.ownerRevision ~= nil then
    local cached = self.heldCache
    if not cached or cached.owners ~= capture.owners or cached.revision ~= capture.ownerRevision
      or cached.catalog ~= self.revision then
      cached = { owners = capture.owners, revision = capture.ownerRevision, catalog = self.revision }
      for key, camps in pairs(self.camps) do
        local counts = { H = 0, A = 0 }
        for index = 1, #camps do
          local owner = self:Owner(camps[index])
          if owner then counts[owner] = counts[owner] + 1 end
        end
        cached[key] = counts
      end
      self.heldCache = cached
    end
    return cached[continent] and cached[continent][faction] or 0
  end
  local held = 0
  for index = 1, #list do
    if self:Owner(list[index]) == faction then held = held + 1 end
  end
  return held
end

-- total, held, travel percent, capture percent for (continent, faction).
function FrontNetwork:Get(continent, faction)
  local total = self:Total(continent)
  local held = self:Held(continent, faction)
  return total, held, FrontNetwork.Percent(TRAVEL_MAX, held, total), FrontNetwork.Percent(CAPTURE_MAX, held, total)
end

-- Capture reduction of faction at area: Outposts and Settlements only, never
-- War Camps or capitals (decision 0123 § 6).
function FrontNetwork:CapturePercent(area, faction)
  if not area or (area.type ~= "OUTPOST" and area.type ~= "SETTLEMENT") then return 0 end
  local continent = FrontNetwork.Continent(area)
  if not continent then return 0 end
  local _, _, _, capture = self:Get(continent, faction)
  return capture
end

-- Full-bar duration of an Outpost or Settlement push by faction: the garrison
-- base reduced by its Front Network, whole seconds.
function FrontNetwork:CaptureDuration(area, faction, base)
  return FrontNetwork.Reduce(base, self:CapturePercent(area, faction))
end

-- Travel of a scout or army toward target: the order's faction network on the
-- destination continent. Returns held (the departure snapshot) and total.
function FrontNetwork:TravelSnapshot(target, faction)
  local continent = FrontNetwork.Continent(target)
  if not continent then return 0, 0 end
  return self:Held(continent, faction), self:Total(continent)
end

-- Travel duration from the base travel time and a held count already checked
-- against the catalog total of the destination continent (decision 0123 § 5).
-- Nil when held is outside 0..total.
function FrontNetwork:TravelDuration(base, target, held)
  if type(base) ~= "number" or type(held) ~= "number" or held < 0 then return nil end
  local continent = FrontNetwork.Continent(target)
  local total = continent and self:Total(continent) or 0
  if held > total then return nil end
  return FrontNetwork.Reduce(base, FrontNetwork.Percent(TRAVEL_MAX, held, total))
end

-- The player's current outdoor continent, or nil.
function FrontNetwork:PlayerContinent()
  local map = WF.Map
  local key = map and map.PlayerZoneKey and map:PlayerZoneKey() or nil
  return FrontNetwork.Continent(key)
end
