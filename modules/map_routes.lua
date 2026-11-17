local WF = Warfront
local Map = WF.Map

-- World map, scout and army routes (modules/map.lua loads first and shares
-- its helpers through Map.Kit). Keep every map file far below Lua 5.1's
-- limit of 200 active locals (.claude/forever-compatibility.md).
local Kit = Map.Kit
local CanonicalMapName = Kit.CanonicalMapName
local Clamp = Kit.Clamp
local CreateGroup = Kit.CreateGroup
local FOREVER_ZONE_IDS = Kit.FOREVER_ZONE_IDS
local GetCanvas = Kit.GetCanvas
local GetGlobal = Kit.GetGlobal
local GetIconPosition = Kit.GetIconPosition
local HideObject = Kit.HideObject
local ICON_HIT_RATIO = Kit.ICON_HIT_RATIO
local POI_ICON_SIZE = Kit.POI_ICON_SIZE

-- Scout routes (roadmap WP8, docs/scouting.md, decision 0051) ----------------
-- Every scout still travelling is drawn on the displayed zone map, for both
-- factions and without its sender: a dotted straight line from its origin to
-- its target and its icon at the share of the trip elapsed. A route between
-- two zones of one continent is drawn in continent coordinates and clipped to
-- the displayed zone, so each zone shows its own part; a route to another
-- continent (abstract sea crossing) and the continent maps show nothing.
-- Local display only: nothing is sent.
local ROUTE_TEXTURE = "Interface\\Buttons\\WHITE8X8"
-- 4 and 5.6 hovered (5 and 7 until 2026-11-14, reduced 20% by the user).
local ROUTE_DOT_SIZE = 4
local ROUTE_DOT_GAP = 9
-- The saved path opacity defaults to 40%; hovered dots stay opaque.
-- Dots this close to an endpoint would sit under its POI icon.
local ROUTE_ICON_CLEAR = POI_ICON_SIZE * ICON_HIT_RATIO
local ROUTE_MAX = 16
local ROUTE_MAX_DOTS = 800
local SCOUT_ICON_SIZE = 20
local SCOUT_ICON_DIR = "Interface\\AddOns\\Warfront\\media\\Textures\\Icons\\War3Units\\"
local SCOUT_ICONS = { A = SCOUT_ICON_DIR .. "BTNKnight", H = SCOUT_ICON_DIR .. "BTNRaider" }
-- Armies (decision 0052): the faction's basic soldier.
local ARMY_ICONS = { A = SCOUT_ICON_DIR .. "BTNFootman", H = SCOUT_ICON_DIR .. "BTNGrunt" }
local RIFLEMAN_ICONS = { A = SCOUT_ICON_DIR .. "BTNRifleman", H = SCOUT_ICON_DIR .. "BTNHeadhunter" }
local MORTAR_ICONS = { A = SCOUT_ICON_DIR .. "BTNMortarTeam", H = SCOUT_ICON_DIR .. "BTNDemolisher" }

-- An allied army shows its most numerous unit (ties: footman, then
-- rifleman); an enemy army keeps the basic soldier, as its tooltip hides its
-- composition (2026-11-14).
local function ArmyIcon(r, mine)
  local fac = r.fac
  if fac ~= mine then return ARMY_ICONS[fac] end
  local f, rifle, mortar = r.f or 0, r.r or 0, r.m or 0
  if rifle > f and rifle >= mortar then return RIFLEMAN_ICONS[fac] end
  if mortar > f and mortar > rifle then return MORTAR_ICONS[fac] end
  return ARMY_ICONS[fac]
end
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

-- A zone's rectangle on its continent map: left, top, width, height, continent
-- key ("azeroth", "kalimdor") and continent uiMapID. Forever's
-- C_Map.GetMapRectOnMap on the zone's parent continent, as the War tab's
-- distances (modules/main_window.lua), covers every catalog zone; the fixed
-- Map.CONTINENT_ZONES (6 zones) is the fallback. Successes are cached.
local zoneOnContinent = {}

local function ZoneOnContinent(mapKey)
  local cached = zoneOnContinent[mapKey or ""]
  if cached then return cached[1], cached[2], cached[3], cached[4], cached[5], cached[6] end
  local cmap = GetGlobal("C_Map")
  local zoneID = FOREVER_ZONE_IDS[mapKey or ""]
  local keys = WF.Compat and WF.Compat.MAP_KEYS
  if zoneID and type(keys) == "table" and type(cmap) == "table"
      and type(cmap.GetMapInfo) == "function" and type(cmap.GetMapRectOnMap) == "function" then
    local current, continentID, safety = zoneID, nil, 0
    while type(current) == "number" and safety < 8 do
      local name = keys[current]
      if name == "Azeroth" or name == "Kalimdor" then
        continentID = current
        break
      end
      local ok, info = pcall(cmap.GetMapInfo, current)
      current = ok and type(info) == "table" and info.parentMapID or nil
      safety = safety + 1
    end
    if continentID and continentID ~= zoneID then
      local ok, minX, maxX, minY, maxY = pcall(cmap.GetMapRectOnMap, zoneID, continentID)
      if ok and type(minX) == "number" and type(maxX) == "number" and type(minY) == "number"
          and type(maxY) == "number" and maxX > minX and maxY > minY then
        cached = { minX, minY, maxX - minX, maxY - minY, CanonicalMapName(keys[continentID]), continentID }
        zoneOnContinent[mapKey] = cached
        return cached[1], cached[2], cached[3], cached[4], cached[5], cached[6]
      end
    end
  end
  local zone = Map.CONTINENT_ZONES and Map.CONTINENT_ZONES[mapKey or ""]
  if zone then return zone[2], zone[3], zone[4], zone[5], zone[1], nil end
  return nil
end

Map.ZoneOnContinent = ZoneOnContinent

-- An area's icon anchor in units of the displayed zone map (outside 0-1 when
-- it lies on another zone), or nil when the zones share no continent.
local function RoutePoint(area, mapKey)
  if not area or not area.enabled then return nil end
  local x, y = GetIconPosition(area)
  if not x or area.mapKey == mapKey then return x, y end
  -- Through the continent map, which every zone of the continent shares.
  local al, at, aw, ah, ac, aid = ZoneOnContinent(area.mapKey)
  local bl, bt, bw, bh, bc, bid = ZoneOnContinent(mapKey)
  if al and bl and aid == bid then
    if ac ~= bc then return nil end
    return (al + x * aw - bl) / bw, (at + y * ah - bt) / bh
  end
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

-- A continent's rectangle on the world map: Forever's C_Map.GetMapRectOnMap
-- on its parent world map (as ZoneOnContinent), so nodes sit on the art the
-- client draws (2026-11-16: the estimate put them in the wrong places on
-- Forever's world map). WORLD_CONTINENTS stays the fallback. Successes are
-- cached per continent uiMapID.
local worldPlaces = {}

local function WorldPlace(continentKey, continentID)
  local cached = continentID and worldPlaces[continentID]
  if cached then return cached end
  local cmap = GetGlobal("C_Map")
  local keys = WF.Compat and WF.Compat.MAP_KEYS
  if type(continentID) == "number" and type(keys) == "table" and type(cmap) == "table"
      and type(cmap.GetMapInfo) == "function" and type(cmap.GetMapRectOnMap) == "function" then
    local ok, info = pcall(cmap.GetMapInfo, continentID)
    local worldID = ok and type(info) == "table" and info.parentMapID or nil
    if type(worldID) == "number" and keys[worldID] == "World" then
      local rectOk, minX, maxX, minY, maxY = pcall(cmap.GetMapRectOnMap, continentID, worldID)
      if rectOk and type(minX) == "number" and type(maxX) == "number" and type(minY) == "number"
          and type(maxY) == "number" and maxX > minX and maxY > minY then
        cached = { minX, minY, maxX - minX, maxY - minY }
        worldPlaces[continentID] = cached
        return cached
      end
    end
  end
  return WORLD_CONTINENTS[continentKey or ""]
end

Map.WorldPlace = WorldPlace

-- An area's icon anchor in units of the displayed view, or nil when the view
-- does not show it (a zone map of another continent, the other continent map).
local function ViewPoint(area, view)
  local continent = WORLD_CONTINENTS[view or ""]
  if not continent and view ~= "world" then return RoutePoint(area, view) end
  if not area or not area.enabled then return nil end
  local left, top, width, height, continentKey, continentID = ZoneOnContinent(area.mapKey)
  local x, y = GetIconPosition(area)
  if not left or not x then return nil end
  if view ~= "world" and continentKey ~= view then return nil end
  local cx, cy = left + x * width, top + y * height
  if view ~= "world" then return cx, cy end
  local place = WorldPlace(continentKey, continentID)
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
local ROUTE_DOT_HOVER_SIZE = 5.6
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
      dot:SetVertexColor(color[1], color[2], color[3], Map:PathOpacity())
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
    local clear = ROUTE_ICON_CLEAR * Map:IconScale()
    if t * length >= clear and (1 - t) * length >= clear then
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

-- Developer-only (WarfrontDev /wfd sim): records shaped like scout or army
-- records ({ kind, fac, origin, target, depart, dur, owner, f, r, m }) drawn
-- with the real ones on the next refresh; nil clears them. Never saved nor sent.
function Map:SetSimulatedRoutes(list)
  self.simRoutes = type(list) == "table" and list or nil
end

-- The side of a zone or continent map facing the other continent: Kalimdor
-- lies west of the Eastern Kingdoms, so an Eastern Kingdoms map looks left and
-- a Kalimdor map right.
local function SeaSide(continentKey)
  if continentKey == "azeroth" then return 0 end
  return 1
end

-- The segment of a sea crossing shown on the displayed zone or continent map:
-- from the origin icon to that side during the first half of the trip, from
-- the side to the target icon during the second. Returns ax, ay, bx, by and
-- the trip shares where the segment starts and ends, or nil when the view
-- shows neither end. The world map shows the whole crossing as one line.
local function SeaLeg(from, to, view)
  if not from or not to then return nil end
  local fromContinent = select(5, ZoneOnContinent(from.mapKey))
  local toContinent = select(5, ZoneOnContinent(to.mapKey))
  if not fromContinent or not toContinent or fromContinent == toContinent then return nil end
  -- A zone map shows only its own end; zones overlap their neighbors, a
  -- neighbor's POI is not drawn as an end.
  local zoneView = not WORLD_CONTINENTS[view or ""]
  local x, y
  if not zoneView or from.mapKey == view then x, y = ViewPoint(from, view) end
  if x then return x, y, SeaSide(fromContinent), y, 0, 0.5 end
  if not zoneView or to.mapKey == view then x, y = ViewPoint(to, view) end
  if x then return SeaSide(toContinent), y, x, y, 0.5, 1 end
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

-- Developer-only (WarfrontDev /wfd sim debug): for each simulated route, its
-- zones, continents, time left and the segment each view would draw.
function Map:RouteDebug()
  local lines = {}
  local now = WF.Now and WF.Now() or 0
  local function Fmt(value)
    if type(value) ~= "number" then return "nil" end
    return string.format("%.2f", value)
  end
  lines[1] = "last view=" .. tostring(self.routes.layoutMap) .. " drawn=" .. tostring(self.routes.count)
    .. " branch=" .. tostring(self.probe and self.probe.branch)
    .. " continent=" .. tostring(self.probe and self.probe.continent)
    .. " stitched=" .. tostring(self.probe and self.probe.stitched)
  local sims = self.simRoutes or {}
  for index = 1, #sims do
    local r = sims[index]
    local from, to = self.areas[r.origin or ""], self.areas[r.target or ""]
    local text = index .. " " .. tostring(r.origin) .. "(" .. tostring(from and from.mapKey) .. ","
      .. tostring(from and select(5, ZoneOnContinent(from.mapKey))) .. ") > " .. tostring(r.target)
      .. "(" .. tostring(to and to.mapKey) .. "," .. tostring(to and select(5, ZoneOnContinent(to.mapKey)))
      .. ") left=" .. math.floor(r.depart + r.dur - now) .. "s"
    local views = { "kalimdor", "azeroth", "world" }
    for v = 1, #views do
      local view = views[v]
      local ax, ay = ViewPoint(from, view)
      local bx, by = ViewPoint(to, view)
      local sea = ""
      if not (ax and bx) then
        ax, ay, bx, by = SeaLeg(from, to, view)
        sea = "sea"
      end
      local t0, t1
      if ax and bx then t0, t1 = ClipRoute(ax, ay, bx, by) end
      text = text .. " | " .. view .. sea .. " " .. Fmt(ax) .. "," .. Fmt(ay) .. ">" .. Fmt(bx) .. "," .. Fmt(by)
        .. " clip=" .. Fmt(t0) .. "-" .. Fmt(t1)
    end
    lines[#lines + 1] = text
  end
  if #sims == 0 then lines[#lines + 1] = "no simulated route (/wfd sim)" end
  return lines
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
  local mine = WF.Capture and type(WF.Capture.MyFaction) == "function" and WF.Capture:MyFaction() or nil
  if armies then
    local list = attack:Marching(now)
    for index = 1, #list do
      r = list[index]
      count, moved = PlaceRoute(self, slots, count, r, ArmyIcon(r, mine), mapKey, now, "army")
      if moved then changed = true end
    end
  end
  -- Simulated routes (WarfrontDev /wfd sim): drawing only, never saved nor sent.
  local sims = self.simRoutes
  if type(sims) == "table" then
    for index = 1, #sims do
      r = sims[index]
      local kind = type(r) == "table" and r.kind == "army" and "army" or "scout"
      local path = type(r) == "table" and (kind == "army" and ArmyIcon(r, mine) or SCOUT_ICONS[r.fac])
      count, moved = PlaceRoute(self, slots, count, r, path, mapKey, now, kind)
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

  if not routes.frame then routes.frame = CreateGroup("WarfrontMapRoutes", 2, true) end
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
  -- "Scouts and armies" map filter.
  if Map:UnitsHidden() then
    if Map.routes.count > 0 then pcall(Map.HideRoutes, Map) end
    return
  end
  local ok, err = pcall(Map.RefreshRoutes, Map, mapKey, width, height)
  if ok then return end
  pcall(Map.HideRoutes, Map)
  if WF.RecordError then WF.RecordError("map routes", err) end
end

Kit.DrawRoutes = DrawRoutes
Kit.ViewPoint = ViewPoint
Kit.RouteTexture = RouteTexture
Kit.RefreshRouteDots = RefreshRouteDots
