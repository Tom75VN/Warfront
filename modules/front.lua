local WF = Warfront

-- Active Fronts (decisions 0079, 0098, 0100 and 0101).
--   * Routes are shipped data (data/fronts.lua); Settlements start neutral.
--   * Each faction attacks from its own end of the route the first Settlement
--     past the unbroken run it holds. The targets therefore follow the owner
--     registry, its total order and its catch-up; nothing else is sent.
--   * One three-hour siege window per route. It opens when a capture event
--     (Capture:HandleEvent, one per POI and generation) gives the eligible
--     faction the last linked Outpost of its node, or, when a window closes,
--     for a faction already holding them. Only its start travels: FW carries
--     the seconds elapsed since it, on a relative clock (rule R10); the first
--     copy known wins, as for scouts (decision 0050). FQ asks for it.
--   * Closing is derived by every client: the node is no longer eligible (the
--     front moved), or the deadline plus GRACE passed, which sets the linked
--     Outposts neutral at the next generation (Capture:Neutralize).
--   * Capital siege (decision 0103 § 2): when the advancing faction holds
--     every Settlement of its route, a 24-hour window opens on the route's
--     capital, in the same window slot, so it travels and closes the same way.
--     While it runs, every Outpost and Settlement of the route is locked for
--     both factions. Expired, the last Settlement and its linked Outposts held
--     by the besieger go neutral. A capture ends the campaign (WF.Campaign).
local Front = {
  windows = {}, last = {}, ready = {},
  received = 0, rejected = 0, opened = 0, expired = 0, answers = 0, skew = 0,
}
WF.Front = Front

local OTHER = { H = "A", A = "H" }
local SIDES = { H = true, A = true }
local FACTION_KEYS = { H = "HORDE", A = "ALLIANCE" }
local WINDOW = 10800
local CAPITAL_WINDOW = 86400
-- Observers wait this long after the deadline before setting Outposts neutral,
-- so a capture completed just before it reaches them first.
local GRACE = 300
-- A route ready with no known window opens one after SOFT_AFTER s, with an
-- unknown start, so a front never stalls when nobody can tell its start.
local SOFT_AFTER = 300
-- A window learned before its Outposts are known here waits this long.
local PENDING_TTL = 600
-- Two windows of one route learned within TIE_GAP s: the forward one wins.
local TIE_GAP = 60
local REPEAT_AFTER = 10
-- Catch-up like scouts: one request per join, answered late and cancellably
-- (rule R14); a whispered request answered to its asker alone.
local QUERY_DELAY, QUERY_GAP = 15, 60
local REPLY_MIN, REPLY_SPREAD, REPLY_MATCHES, REPLY_ANY = 0.5, 2.5, 2, 4
local ADDRESSED_TARGETS = 2

Front.WINDOW, Front.GRACE, Front.SOFT_AFTER = WINDOW, GRACE, SOFT_AFTER
Front.CAPITAL_WINDOW = CAPITAL_WINDOW

local function Now()
  local now = WF.Now and WF.Now() or 0
  if type(now) ~= "number" then return 0 end
  return now
end

local function Epoch()
  local epoch = WF.Epoch and WF.Epoch() or 0
  if type(epoch) ~= "number" then return 0 end
  return epoch
end

local function Floor(value)
  return math.floor(value + 0.0000001)
end

local function Int(text, maximum)
  if type(text) ~= "string" or not string.find(text, "^%d+$") or #text > 9 then return nil end
  local value = tonumber(text)
  if not value or value > maximum then return nil end
  return value
end

-- Routes -----------------------------------------------------------------------

local function ServerTime()
  if type(GetServerTime) ~= "function" then return 0 end
  local ok, value = pcall(GetServerTime)
  if not ok or type(value) ~= "number" then return 0 end
  return value
end

-- The route set of campaign n started at server time s (decision 0103 § 5):
-- the last rotation whose from is at or before s, then sets[(n mod #sets) + 1].
-- Without a campaign number (no WF.Campaign: tools), the first set of the last
-- rotation already started. Returns the set id and the set, or nil.
function Front.SetOf(data, n, s)
  if type(data) ~= "table" or data.schema ~= 2 or type(data.rotations) ~= "table"
      or type(data.routeSets) ~= "table" then
    return nil
  end
  local at, rotation = s or ServerTime(), nil
  for r = 1, #data.rotations do
    local entry = data.rotations[r]
    if type(entry) == "table" and type(entry.from) == "number" and entry.from <= at
        and type(entry.sets) == "table" and #entry.sets > 0 then
      rotation = entry
    end
  end
  if not rotation then return nil end
  local index = 1
  if type(n) == "number" and n >= 0 then index = n - math.floor(n / #rotation.sets) * #rotation.sets + 1 end
  local id = rotation.sets[index]
  local set = type(id) == "string" and data.routeSets[id]
  if type(set) ~= "table" or type(set.routes) ~= "table" then return nil end
  return id, set
end

-- The running campaign's set: none before the first campaign (0103 § 3). With
-- no first start shipped, campaigns are not numbered: the legacy choice above.
local function CurrentSet(data)
  local campaign = WF.Campaign
  local n, s
  if campaign and type(campaign.Current) == "function" then n, s = campaign:Current() end
  if n == nil then return Front.SetOf(data) end
  if n < 1 then return nil end
  return Front.SetOf(data, n, s)
end

-- Campaigns share the POI catalog; only their routes differ (decision 0106).
-- An Outpost or Settlement whose zone holds no node of the running campaign is
-- out of play: disabled like an area the catalog turns off, so the map, the
-- captures, the orders and the lists all skip it. Resource POIs never change.
local OFF_FRONT_TYPES = { OUTPOST = true, SETTLEMENT = true }

local function DisableOffFront(self, map)
  local count = 0
  for _, area in pairs(map.areas) do
    if type(area) == "table" and OFF_FRONT_TYPES[area.type] and area.enabled
        and not self.byMap[area.map] then
      area.enabled = false
      area.offFront = true
      count = count + 1
    end
  end
  if count > 0 and type(map.revision) == "number" then
    map.revision = map.revision + 1
    map.dirty = true
  end
  self.offFront = count
end

-- Indexes the routes of the running campaign once the catalog is known, then
-- takes the zones off its routes out of play. A route naming a Settlement the
-- catalog lacks is left out whole: its zones are then out of play too.
-- The route's endpoint, a CAPITAL POI id (decisions 0103, 0107): kept only when
-- enabled and held by the faction the route advances against; its zone map gives
-- its faction (Map.CAPITAL_FACTIONS, area.colorKey). No endpoint, no capital.
local function RouteCapital(map, route)
  local id = route.endpoint
  if type(id) ~= "string" or id == "" then return nil end
  local area = map.areas[id]
  if type(area) == "table" and area.type == "CAPITAL" and area.enabled
      and area.colorKey == FACTION_KEYS[OTHER[route.advancing]] then
    return id
  end
  return nil
end

local function Build(self)
  if self.built then return end
  local map = WF.Map
  if not map or not map.areas or next(map.areas) == nil then return end
  self.built = true
  self.routes, self.bySettlement, self.byMap, self.byId = {}, {}, {}, {}
  self.byCapital, self.capitalOf = {}, {}
  local setId, set = CurrentSet(WF.FrontData)
  self.campaignId, self.campaignName = setId, set and set.name
  self.campaignRev = set and set.rev
  local routes = set and set.routes or {}
  for r = 1, #routes do
    local route = routes[r]
    local valid = type(route) == "table" and route.enabled ~= false and type(route.nodes) == "table"
      and #route.nodes > 0 and SIDES[route.advancing]
    if valid then
      for n = 1, #route.nodes do
        local area = map.areas[route.nodes[n].id]
        if not area or area.type ~= "SETTLEMENT" then valid = false end
      end
    end
    if valid then
      self.routes[#self.routes + 1] = route
      self.byId[route.id] = route
      for n = 1, #route.nodes do
        local id = route.nodes[n].id
        self.bySettlement[id] = { route = route, index = n }
        self.byMap[map.areas[id].map] = { route = route, index = n }
      end
      local capital = RouteCapital(map, route)
      if capital and not self.byCapital[capital] then
        self.byCapital[capital] = { route = route, index = #route.nodes + 1, capital = true }
        self.capitalOf[route.id] = capital
      end
    end
  end
  DisableOffFront(self, map)
end

function Front:HasRoutes()
  Build(self)
  return self.routes ~= nil and #self.routes > 0
end

-- A new campaign may run another route set (decision 0103 § 5): the areas this
-- module took out of play come back, the windows go, and the routes are read
-- again. Owners are untouched here (the campaign reset clears them).
function Front:Rebuild()
  for _, route in ipairs(self.routes or {}) do route.targetCache = nil end
  local map = WF.Map
  if map and type(map.areas) == "table" then
    local count = 0
    for _, area in pairs(map.areas) do
      if type(area) == "table" and area.offFront then
        area.enabled, area.offFront = true, nil
        count = count + 1
      end
    end
    if count > 0 and type(map.revision) == "number" then
      map.revision = map.revision + 1
      map.dirty = true
    end
  end
  self.built = nil
  self.windows, self.last, self.ready = {}, {}, {}
  self.replyAt, self.replyAny, self.replyMatch, self.queryAt = nil, nil, nil, nil
  self.dirty = true
  Build(self)
end

-- The route node of a Settlement or of a route's capital.
local function Node(self, id)
  Build(self)
  return self.bySettlement and self.bySettlement[id] or self.byCapital and self.byCapital[id]
end

-- The faction holding a zone's in-play Settlement of the running campaign
-- (decision 0117): "H" or "A"; nil for a neutral Settlement or a zone on no
-- route. Read by the gathering bonus on enemy-held ground.
function Front:ZoneOwner(mapKey)
  Build(self)
  local node = self.byMap and type(mapKey) == "string" and self.byMap[mapKey]
  if not node then return nil end
  local id = node.route.nodes[node.index].id
  local area = WF.Map and WF.Map.areas[id]
  if not area or not area.enabled or not WF.Capture then return nil end
  local owner = WF.Capture:GetOwner(id)
  if SIDES[owner] then return owner end
  return nil
end

function Front:IsCapital(id)
  Build(self)
  return self.byCapital ~= nil and self.byCapital[id] ~= nil
end

-- A window's length: three hours, a day for a capital (decision 0103 § 2).
local function Length(rec)
  return rec.capital and CAPITAL_WINDOW or WINDOW
end
Front.Length = Length

-- No capital siege starts in the campaign's last day (decision 0103 § 2).
function Front:CapitalAllowed(now)
  local campaign = WF.Campaign
  if not campaign or type(campaign.Left) ~= "function" then return true end
  local left = campaign:Left()
  return left == nil or left >= CAPITAL_WINDOW
end

-- The owner the map shows: confirmed, or provisional (Capture:SiegeOwner).
local function Owner(id, now)
  local capture = WF.Capture
  if not capture then return nil end
  if type(capture.SiegeOwner) == "function" then return (capture:SiegeOwner(id, now)) end
  return (capture:GetOwner(id))
end

-- Each faction advances from its own end of the route (decision 0101): the
-- advancing faction from node 1, the defender from the last node. A faction
-- may only attack the first node past the unbroken run it holds from its end,
-- so it never skips a Settlement. Returns the advancing faction's target index
-- and the defender's; either may fall outside the route.
function Front:Targets(route, now)
  local count = #route.nodes
  if not WF.Capture then return 1, count end
  now = now or Now()
  local capture, map = WF.Capture, WF.Map
  local cached = route.targetCache
  -- Exact clock, never a rounded TTL: a hint expiring in this frame must be
  -- reconsidered. A revisionless test/provider deliberately uses the old path.
  if capture.queryRevision ~= nil and cached and cached.now == now
    and cached.revision == capture.queryRevision and cached.owners == capture.owners
    and cached.hints == capture.hints and cached.cloud == capture.cloud
    and cached.mapRevision == (map and map.revision) and cached.nodes == route.nodes
    and cached.count == count and cached.advancing == route.advancing then
    return cached.forward, cached.rear
  end
  local forward = 1
  while forward <= count and Owner(route.nodes[forward].id, now) == route.advancing do
    forward = forward + 1
  end
  local defender = OTHER[route.advancing]
  local rear = count
  while rear >= 1 and Owner(route.nodes[rear].id, now) == defender do
    rear = rear - 1
  end
  if capture.queryRevision ~= nil then
    cached = cached or {}
    cached.now, cached.revision = now, capture.queryRevision
    cached.owners, cached.hints, cached.cloud = capture.owners, capture.hints, capture.cloud
    cached.mapRevision, cached.nodes, cached.count = map and map.revision, route.nodes, count
    cached.advancing, cached.forward, cached.rear = route.advancing, forward, rear
    route.targetCache = cached
  end
  return forward, rear
end

-- The defender's target (rear) and the advancing faction's (forward).
function Front:Pair(route, now)
  local forward, rear = self:Targets(route, now)
  local rearNode, forwardNode = route.nodes[rear], route.nodes[forward]
  return rearNode and rearNode.id or nil, forwardNode and forwardNode.id or nil
end

-- May side besiege this Settlement now? Both may when it is the one neutral
-- Settlement left between their lines.
function Front:CanBesiege(id, side, now)
  local node = Node(self, id)
  if not node then return false end
  local forward, rear = self:Targets(node.route, now)
  if node.capital then
    -- Only the advancing faction, once it holds every Settlement of the route,
    -- and only while the capital is still its defender's (decision 0103 § 2).
    return side == node.route.advancing and forward > #node.route.nodes
      and not (WF.Capture and WF.Capture:GetOwner(id) == side)
  end
  if side == node.route.advancing then return node.index == forward end
  if side == OTHER[node.route.advancing] then return node.index == rear end
  return false
end

-- Every linked Outpost of the Settlement held by side; a capital has none.
function Front:Ready(id, side, now)
  local capture = WF.Capture
  if not capture then return false end
  local node = Node(self, id)
  if node and node.capital then return self:CanBesiege(id, side, now) end
  local links = capture:LinkedObjectives(id)
  if #links == 0 then return false end
  for index = 1, #links do
    if Owner(links[index], now) ~= side then return false end
  end
  return true
end

-- How hard the other faction presses side's Settlement on this route
-- (decision 0111): 0 none, 1 targeted, 2 a linked Outpost lost, 3 its siege
-- runs. Also returns the Settlement (or capital) id, Outposts lost and total.
function Front:Threat(route, side, now)
  if not route or not SIDES[side] then return 0 end
  now = now or Now()
  local enemy = OTHER[side]
  local rec = self.windows[route.id]
  if rec and rec.capital and rec.side == enemy and self:CapitalSiege(route, now) then
    return 3, rec.node, 0, 0
  end
  local forward, rear = self:Targets(route, now)
  local node = route.nodes[enemy == route.advancing and forward or rear]
  if not node or Owner(node.id, now) ~= side then return 0 end
  if rec and rec.seen and not rec.capital and rec.side == enemy and rec.node == node.id
      and now < rec.start + Length(rec) then
    return 3, node.id, 0, 0
  end
  local links = WF.Capture and WF.Capture:LinkedObjectives(node.id) or {}
  local lost = 0
  for index = 1, #links do
    if Owner(links[index], now) == enemy then lost = lost + 1 end
  end
  return lost > 0 and 2 or 1, node.id, lost, #links
end

-- side's own attack waits while the other faction's siege runs on this route
-- (decision 0101: one siege per front, its Outposts frozen).
function Front:Paused(route, side, now)
  local rec = route and SIDES[side] and self.windows[route.id]
  if not rec or not rec.seen or rec.side ~= OTHER[side] then return false end
  return (now or Now()) < rec.start + Length(rec)
end

-- Windows ----------------------------------------------------------------------

function Front:Window(routeId)
  return self.windows[routeId]
end

-- The node (route entry) of an Outpost's zone, and its Settlement id.
local function OutpostNode(self, id)
  Build(self)
  local area = WF.Map and WF.Map.areas[id]
  local node = area and area.type == "OUTPOST" and self.byMap and self.byMap[area.map]
  if not node then return nil end
  return node, node.route.nodes[node.index].id
end

-- The route's capital siege, while it runs (deadline plus grace), or nil.
function Front:CapitalSiege(route, now)
  local rec = route and self.windows[route.id]
  if not rec or not rec.capital or not rec.seen then return nil end
  if (now or Now()) >= rec.start + CAPITAL_WINDOW + GRACE then return nil end
  return rec
end

-- Whether this capital has its capture bar now: its siege window is known
-- and runs, grace included (Capture:Outpost).
function Front:CapitalLive(id, now)
  local node = self.byCapital and self.byCapital[id]
  local rec = node and self:CapitalSiege(node.route, now)
  return rec ~= nil and rec.node == id
end

-- A linked Outpost of a running window, or any Outpost of a route whose
-- capital is besieged (decision 0103 § 2): shown, never captured, until the
-- window closes (decision 0079).
function Front:Locked(id, now)
  local node, settlement = OutpostNode(self, id)
  if not node then return false end
  local rec = self.windows[node.route.id]
  now = now or Now()
  if rec ~= nil and rec.capital then return self:CapitalSiege(node.route, now) ~= nil end
  return rec ~= nil and rec.seen and rec.node == settlement and now < rec.start + WINDOW + GRACE
end

-- The running siege of the other faction that keeps side from attacking this
-- Outpost's zone: while it runs, side defends and cannot start retaking the
-- previous front of the route (decision 0101). Returns the window or nil.
function Front:Frozen(id, side, now)
  local node = OutpostNode(self, id)
  if not node then return nil end
  local rec = self.windows[node.route.id]
  now = now or Now()
  if not rec or rec.capital or not rec.seen or rec.side == side or now >= rec.start + WINDOW + GRACE then
    return nil
  end
  local forward, rear = self:Targets(node.route, now)
  local target = side == node.route.advancing and forward or rear
  if node.index ~= target then return nil end
  return rec
end

-- May this faction open a capture of this Outpost? An Outpost off every route
-- is out of play (Build), so Capture:Capturable refuses it before this.
function Front:OutpostOpen(id, side, now)
  local node = OutpostNode(self, id)
  if not node then return true end
  now = now or Now()
  if self:Locked(id, now) or self:Frozen(id, side, now) then return false end
  local forward, rear = self:Targets(node.route, now)
  if side == node.route.advancing then return node.index <= forward end
  return node.index >= rear
end

-- A siege of this Settlement (or capital) by side may open now.
function Front:SiegeOpen(id, side, now)
  local node = Node(self, id)
  if not node then return false end
  now = now or Now()
  local rec = self.windows[node.route.id]
  return rec ~= nil and rec.seen and rec.node == id and rec.side == side
    and now < rec.start + Length(rec) and self:CanBesiege(id, side, now)
end

-- A running siege of this Settlement (or capital) by side must stop: the
-- front moved, its window's deadline passed, or the route's capital is
-- besieged (decision 0103 § 2). An unknown window stops nothing.
function Front:SiegeEnded(id, side, now)
  local node = Node(self, id)
  if not node then return false end
  now = now or Now()
  if not self:CanBesiege(id, side, now) then return true end
  local rec = self.windows[node.route.id]
  if rec and rec.capital and not node.capital and self:CapitalSiege(node.route, now) then return true end
  return rec ~= nil and rec.node == id and rec.side == side and now >= rec.start + Length(rec)
end

-- Why side cannot open a siege window item, for the checklist.
function Front:SiegeWhy(id, side, now)
  if self:SiegeOpen(id, side, now) then return nil end
  local node = Node(self, id)
  local rec = node and self.windows[node.route.id]
  if rec and rec.capital and rec.node ~= id then return "the front is locked during a capital siege" end
  if rec and rec.node ~= id then return "another siege is under way on this front" end
  if rec and rec.side == side and (now or Now()) >= rec.start + Length(rec) then return "the siege time is over" end
  if node and node.capital and side == node.route.advancing and not self:CapitalAllowed(now) then
    return "too late in the campaign"
  end
  return "the siege has not begun"
end

-- Seconds left in a window, 0 once over.
function Front:Remaining(rec, now)
  local left = rec.start + Length(rec) - (now or Now())
  if left < 0 then return 0 end
  return Floor(left)
end

-- Player-facing text ------------------------------------------------------------

local FACTION_NAMES = { H = "Horde", A = "Alliance" }

-- H:MM:SS, for the three-hour countdown.
function Front.Clock(seconds)
  seconds = Floor(math.max(0, seconds or 0))
  local hours = math.floor(seconds / 3600)
  local minutes = math.floor((seconds - hours * 3600) / 60)
  return string.format("%d:%02d:%02d", hours, minutes, seconds - hours * 3600 - minutes * 60)
end

local function Label(id)
  local area = WF.Map and WF.Map.areas and WF.Map.areas[id]
  return area and area.label or tostring(id)
end

local function Notify(text, title, side, sound)
  if WF.Alerts and WF.Alerts.Push then
    WF.Alerts:Push("sieges", text, { title = title or "Siege update", side = side, sound = sound })
  elseif WF.Print then
    WF.Print(text)
  end
end

-- The running siege of this Settlement or capital, for the HUD and map
-- tooltip; a Settlement locked by its route's capital siege says so.
function Front:SiegeText(id, now)
  local node = Node(self, id)
  local rec = node and self.windows[node.route.id]
  if not rec or not rec.seen then return nil end
  if rec.node ~= id then
    if rec.capital and self:CapitalSiege(node.route, now) then
      return "Locked during the siege of " .. Label(rec.node) .. " (" .. Front.Clock(self:Remaining(rec, now)) .. " left)"
    end
    return nil
  end
  local left = self:Remaining(rec, now)
  if left <= 0 then return "The " .. FACTION_NAMES[rec.side] .. " siege time is over" end
  return "Siege by the " .. FACTION_NAMES[rec.side] .. ": " .. Front.Clock(left) .. " left"
end

-- A linked Outpost of a running siege, or any Outpost of a besieged capital's route.
function Front:LockText(id, now)
  local node, settlement = OutpostNode(self, id)
  if not node or not self:Locked(id, now) then return nil end
  local rec = self.windows[node.route.id]
  local place = rec.capital and rec.node or settlement
  return "Locked during the siege of " .. Label(place) .. " (" .. Front.Clock(self:Remaining(rec, now)) .. " left)"
end

-- An Outpost side cannot attack while the other faction's siege runs.
function Front:FrozenText(id, side, now)
  local rec = self:Frozen(id, side, now)
  if not rec then return nil end
  return "Closed during the siege of " .. Label(rec.node) .. " (" .. Front.Clock(self:Remaining(rec, now)) .. " left)"
end

-- One line per continent for the War tab.
function Front:Lines(now)
  local lines = {}
  -- The campaign's name and remaining time first (decision 0103 § 3).
  local campaign = WF.Campaign
  local left = campaign and type(campaign.LeftText) == "function" and campaign:LeftText()
  local name = self.campaignName
  if name and left then lines[1] = name .. ": " .. left
  elseif left or name then lines[1] = left or name end
  if not self:HasRoutes() then return lines end
  now = now or Now()
  for r = 1, #self.routes do
    local route = self.routes[r]
    local rec = self.windows[route.id]
    local text
    if rec and rec.seen then
      text = Label(rec.node) .. " besieged by the " .. FACTION_NAMES[rec.side] .. ", "
        .. Front.Clock(self:Remaining(rec, now)) .. " left"
    else
      local rear, forward = self:Pair(route, now)
      local forwardIndex, rearIndex = self:Targets(route, now)
      if forwardIndex <= rearIndex then
        text = "the " .. FACTION_NAMES[route.advancing] .. " marches on " .. Label(forward)
          .. ", the " .. FACTION_NAMES[OTHER[route.advancing]] .. " on " .. Label(rear)
      else
        text = "front between " .. (rear and Label(rear) or "the start") .. " and "
          .. (forward and Label(forward) or (route.capital or "the capital"))
      end
    end
    lines[#lines + 1] = (route.name or route.id) .. ": " .. text
  end
  return lines
end

local function Create(self, route, node, side, start, now, soft)
  local capital = self.byCapital and self.byCapital[node] ~= nil or nil
  local rec = { node = node, side = side, start = start, learned = now, seen = true, soft = soft or nil,
    capital = capital }
  self.windows[route.id] = rec
  self.ready[route.id] = nil
  self.opened = self.opened + 1
  self.dirty = true
  if capital then
    Notify("The siege of " .. Label(node) .. " has begun: the " .. FACTION_NAMES[side] .. " has "
      .. Front.Clock(self:Remaining(rec, now)) .. " to take it.", "Siege started", side, true)
    if WF.Campaign and type(WF.Campaign.NoteCapitalWindow) == "function" then
      WF.Campaign:NoteCapitalWindow(node, side, rec.start, now)
    end
  else
    Notify("Siege of " .. Label(node) .. ": the " .. FACTION_NAMES[side] .. " has "
      .. Front.Clock(self:Remaining(rec, now)) .. " to take it.", "Siege started", side, true)
  end
  return rec
end

local function Close(self, route, rec, reason, now)
  self.windows[route.id] = nil
  self.last[route.id] = { node = rec.node, side = rec.side, reason = reason, at = now }
  self.dirty = true
  if reason == "fallen" then
    -- The campaign end is announced once accepted (WF.Campaign).
    return
  elseif rec.capital and reason == "expired" then
    Notify(Label(rec.node) .. " held: the siege has failed.", "Siege ended", rec.side)
  elseif reason == "moved" then
    Notify("The " .. (route.name or route.id) .. " front moves: the siege of " .. Label(rec.node)
      .. " is over.", "Siege ended", rec.side)
  elseif reason == "expired" then
    local area = WF.Map and WF.Map.areas[rec.node]
    Notify("The siege of " .. Label(rec.node) .. " failed: the Outposts of "
      .. (area and area.map or "its zone") .. " are neutral again.", "Siege ended", rec.side)
  end
end

-- Forward first, then rear: the node whose faction holds every linked Outpost;
-- past the last node, the capital while a capital siege may still start.
function Front:Candidate(route, now)
  local rear, forward = self:Pair(route, now)
  if forward and self:Ready(forward, route.advancing, now) then return forward, route.advancing end
  local capital = self.capitalOf and self.capitalOf[route.id]
  if not forward and capital and self:CanBesiege(capital, route.advancing, now) and self:CapitalAllowed(now) then
    return capital, route.advancing
  end
  local defender = OTHER[route.advancing]
  if rear and self:Ready(rear, defender, now) then return rear, defender end
  return nil
end

-- The deadline passed with the Settlement not taken: its linked Outposts held
-- by the besieger go neutral at the next generation, on every client alike.
-- A failed capital siege does the same with the route's last Settlement and
-- its linked Outposts (decision 0103 § 2).
function Front:Expire(rec, now)
  local capture = WF.Capture
  if not capture then return end
  local settlement = rec.node
  if rec.capital then
    local node = self.byCapital[rec.node]
    local last = node and node.route.nodes[#node.route.nodes]
    settlement = last and last.id
    if settlement and Owner(settlement, now) == rec.side then capture:Neutralize(settlement, now) end
  end
  local links = settlement and capture:LinkedObjectives(settlement) or {}
  for index = 1, #links do
    if Owner(links[index], now) == rec.side then capture:Neutralize(links[index], now) end
  end
  self.expired = self.expired + 1
end

function Front:Evaluate(now)
  if not self:HasRoutes() then return end
  for r = 1, #self.routes do
    local route = self.routes[r]
    local rec = self.windows[route.id]
    local closed = false
    if rec then
      local eligible = self:CanBesiege(rec.node, rec.side, now)
      if not rec.seen and eligible and self:Ready(rec.node, rec.side, now) then
        rec.seen = true
        self.dirty = true
        if rec.capital then
          Notify("The siege of " .. Label(rec.node) .. " is under way: the " .. FACTION_NAMES[rec.side]
            .. " has " .. Front.Clock(self:Remaining(rec, now)) .. " left to take it.",
            "Siege started", rec.side, true)
          if WF.Campaign and type(WF.Campaign.NoteCapitalWindow) == "function" then
            WF.Campaign:NoteCapitalWindow(rec.node, rec.side, rec.start, now)
          end
        else
          Notify("Siege of " .. Label(rec.node) .. ": the " .. FACTION_NAMES[rec.side] .. " has "
            .. Front.Clock(self:Remaining(rec, now)) .. " left to take it.", "Siege started", rec.side, true)
        end
      end
      if not eligible then
        if rec.seen or now - rec.learned > PENDING_TTL then
          local reason = rec.seen and "moved" or "dropped"
          if rec.capital and rec.seen and WF.Capture and WF.Capture:GetOwner(rec.node) == rec.side then
            reason = "fallen"
          end
          Close(self, route, rec, reason, now)
          closed = rec.seen
        end
      elseif now >= rec.start + Length(rec) + GRACE then
        if rec.seen then self:Expire(rec, now) end
        Close(self, route, rec, rec.seen and "expired" or "dropped", now)
        closed = rec.seen
      elseif not rec.seen and now - rec.learned > PENDING_TTL then
        Close(self, route, rec, "dropped", now)
      end
    end
    if not self.windows[route.id] then
      local node, side = self:Candidate(route, now)
      if not node then
        self.ready[route.id] = nil
      elseif closed then
        -- The window just closed and the next faction already holds its
        -- Outposts (decision 0098): every client opens it at this moment.
        Create(self, route, node, side, now, now)
      else
        local key = node .. side
        local ready = self.ready[route.id]
        if not ready or ready.key ~= key then
          self.ready[route.id] = { key = key, since = now }
        elseif now - ready.since >= SOFT_AFTER then
          Create(self, route, node, side, now, now, true)
        end
      end
    end
  end
end

-- A capture event (Capture:HandleEvent, once per POI and generation). The
-- capture of a route's last Settlement closes its window, and Evaluate then
-- opens the capital siege at this moment on every client (decision 0103 § 2).
function Front:OnCaptured(id, side, now)
  if not self:HasRoutes() then return end
  local area = WF.Map and WF.Map.areas[id]
  if not area then return end
  if area.type ~= "OUTPOST" then
    self:Evaluate(now)
    return
  end
  local node, settlement = OutpostNode(self, id)
  if not node or self.windows[node.route.id] then return end
  if not self:CanBesiege(settlement, side, now) or not self:Ready(settlement, side, now) then return end
  local rec = Create(self, node.route, settlement, side, now, now)
  -- The capture's own authority announces it; everyone else saw the event.
  local st = WF.Capture.states and WF.Capture.states[id]
  if st and st.authority and st.authority == WF.Capture:Me() then
    self:Announce(rec, now)
    rec.repeatAt = now + REPEAT_AFTER
  end
end

-- Wire -------------------------------------------------------------------------

-- FW <node>,<side>,<elapsed>,<answer>,<rev>: node a Settlement or a route's
-- capital; answer 0 from the capture's authority, 1 in reply to FQ; rev the
-- running route set's revision (decision 0102 § 5).
local function Body(rec, now, answer)
  local elapsed = Floor(now - rec.start)
  local most = Length(rec) + GRACE
  if elapsed < 0 then elapsed = 0 end
  if elapsed > most then elapsed = most end
  return rec.node .. "," .. rec.side .. "," .. elapsed .. "," .. (answer and "1" or "0") .. ","
    .. tostring(Front.campaignRev or 0)
end
Front.Body = Body

function Front:Announce(rec, now)
  -- An event: no replacement key, sent with priority (rule R12).
  return WF.Capture and WF.Capture:Send("FW", Body(rec, now, false), nil, true)
end

function Front:Reject(reason, sender)
  self.rejected = self.rejected + 1
  self.lastReject = reason
  if WF.Capture and WF.Capture.Reject then return WF.Capture:Reject(reason, sender) end
  return false
end

-- Which of two windows of one route wins (rule R5): within TIE_GAP the forward
-- node, otherwise the earlier start.
local function Beats(self, route, newNode, newStart, rec, now)
  if math.abs(newStart - rec.start) <= TIE_GAP then
    local _, forward = self:Pair(route, now)
    return newNode == forward and rec.node ~= forward
  end
  return newStart < rec.start
end

-- Returns whether the copy matched what we know.
function Front:Learn(id, side, elapsed, now)
  local node = Node(self, id)
  local route = node.route
  local start = now - elapsed
  local rec = self.windows[route.id]
  if rec then
    if rec.node == id and rec.side == side then
      if rec.soft then
        rec.start, rec.soft = start, nil
        self.dirty = true
        if rec.capital and rec.seen and WF.Campaign and type(WF.Campaign.NoteCapitalWindow) == "function" then
          WF.Campaign:NoteCapitalWindow(rec.node, rec.side, rec.start, now)
        end
      end
      return true
    end
    if not Beats(self, route, id, start, rec, now) then return false end
  end
  -- A late copy of a window already closed here never opens it again.
  local last = self.last[route.id]
  if last and last.node == id and last.side == side and start <= last.at then return false end
  self.windows[route.id] = { node = id, side = side, start = start, learned = now, seen = false,
    capital = node.capital or nil }
  self.dirty = true
  self:Evaluate(now)
  return false
end

function Front:SeeReply(sender, matches)
  if not self.replyAt then return end
  self.replyAny = self.replyAny or {}
  self.replyMatch = self.replyMatch or {}
  self.replyAny[sender] = true
  if matches then self.replyMatch[sender] = true end
  local any, match = 0, 0
  for _ in pairs(self.replyAny) do any = any + 1 end
  for _ in pairs(self.replyMatch) do match = match + 1 end
  if match >= REPLY_MATCHES or any >= REPLY_ANY then
    self.replyAt, self.replyAny, self.replyMatch = nil, nil, nil
  end
end

-- Windows worth telling others: seen and not soft.
local function Known(self)
  local list = {}
  if not self.routes then return list end
  for r = 1, #self.routes do
    local rec = self.windows[self.routes[r].id]
    if rec and rec.seen and not rec.soft then list[#list + 1] = rec end
  end
  return list
end

-- Routed by Capture:OnMessage after echo, identity, quota and admission.
function Front:ParseWindow(parts)
    if #parts ~= 5 then return nil, "bad FW field count" end
    local id, side = parts[1], parts[2]
    local node = Node(self, id)
    if not node then return nil, "unknown front node" end
    local elapsed = Int(parts[3], (node.capital and CAPITAL_WINDOW or WINDOW) + GRACE)
    local answer, rev = parts[4], Int(parts[5], 999999)
    if not SIDES[side] or not elapsed or (answer ~= "0" and answer ~= "1") or not rev then
      return nil, "bad FW"
    end
    return { id = id, side = side, elapsed = elapsed, answer = answer, rev = rev }
end

function Front:OnMessage(kind, parts, sender, now)
  self.received = self.received + 1
  if not self:HasRoutes() then return self:Reject("no front", sender) end
  if kind == "FW" then
    local f, err = self:ParseWindow(parts)
    if not f then return self:Reject(err, sender) end
    local id, side, elapsed, answer, rev = f.id, f.side, f.elapsed, f.answer, f.rev
    -- Another revision of the route set (decision 0102 § 5): not applied, not
    -- a reject; the sender sees other routes than ours.
    if rev ~= (self.campaignRev or 0) then
      self.skew = self.skew + 1
      return true
    end
    local matches = self:Learn(id, side, elapsed, now)
    if answer == "1" then self:SeeReply(sender, matches) end
    return true
  elseif kind == "FQ" then
    if #parts ~= 1 or parts[1] ~= "*" then return self:Reject("bad FQ", sender) end
    local known = Known(self)
    local asker = WF.Capture and WF.Capture.addressedFrom
    if asker then
      local transport = WF.Transport
      if #known > 0 and transport and type(transport.MayAnswer) == "function"
          and transport:MayAnswer("FQ", asker, now) then
        for index = 1, #known do
          if WF.Capture:SendTo(asker, "FW", Body(known[index], now, true),
              "FW:" .. asker .. ":" .. known[index].node) then
            self.answers = self.answers + 1
          end
        end
      end
      return true
    end
    if #known > 0 and not self.replyAt then
      self.replyAt = now + REPLY_MIN + math.random() * REPLY_SPREAD
      self.replyAny, self.replyMatch = nil, nil
    end
    return true
  end
  return self:Reject("unknown kind", sender)
end

-- Channel join (modules/p2ptest.lua): one request a little later.
function Front:OnJoined(now)
  now = now or Now()
  if self.askedAt and now - self.askedAt < QUERY_GAP then return false end
  self.askedAt = now
  self.queryAt = now + QUERY_DELAY
  return true
end

-- The same request whispered to a few guild peers or contacts.
function Front:PullAddressed(now)
  now = now or Now()
  if self.pulledAt and now - self.pulledAt < QUERY_GAP then return false end
  local transport, capture = WF.Transport, WF.Capture
  if not transport or type(transport.PullTargets) ~= "function" or not capture then return false end
  local targets = transport:PullTargets(ADDRESSED_TARGETS, now)
  if #targets == 0 then return false end
  self.pulledAt = now
  local sent = 0
  for index = 1, #targets do
    if capture:SendTo(targets[index], "FQ", "*") then sent = sent + 1 end
  end
  return sent > 0
end

-- Storage ----------------------------------------------------------------------

-- Saved in the captures bucket of the scope and level (Capture:Bucket), with
-- the wall clock so a restart keeps the remaining time.
local function Store()
  local bucket = WF.Capture and WF.Capture:Bucket()
  if not bucket then return nil end
  if type(bucket.front) ~= "table" then bucket.front = {} end
  return bucket.front
end

function Front:Save(now)
  local store = Store()
  if not store then return end
  local wall = Epoch()
  for key in pairs(store) do store[key] = nil end
  for routeId, rec in pairs(self.windows) do
    store[routeId] = { node = rec.node, side = rec.side, wall = wall - Floor(now - rec.start),
      seen = rec.seen or nil, soft = rec.soft or nil, minuteWarned = rec.minuteWarned or nil }
  end
  self.dirty = false
end

function Front:Load(now)
  self.loaded = true
  local store = Store()
  if not store then return end
  local wall = Epoch()
  for routeId, saved in pairs(store) do
    local route = self.byId and self.byId[routeId]
    local node = type(saved) == "table" and Node(self, saved.node)
    local age = type(saved) == "table" and type(saved.wall) == "number" and wall - saved.wall
    if route and node and node.route == route and SIDES[saved.side] and age and age >= 0
        and age <= CAPITAL_WINDOW + GRACE + 86400 * 30 then
      self.windows[routeId] = { node = saved.node, side = saved.side, start = now - age,
        learned = now, seen = saved.seen and true or false, soft = saved.soft and true or nil,
        capital = node.capital or nil, minuteWarned = saved.minuteWarned and true or nil }
    end
  end
end

-- Driver -----------------------------------------------------------------------

function Front:Tick(now)
  if not self:HasRoutes() then return end
  if not self.loaded then
    if not (WF.Capture and WF.Capture.loaded) then return end
    self:Load(now)
  end
  if self.queryAt and now >= self.queryAt then
    self.queryAt = nil
    WF.Capture:Send("FQ", "*")
    self:PullAddressed(now)
  end
  if self.replyAt and now >= self.replyAt then
    self.replyAt, self.replyAny, self.replyMatch = nil, nil, nil
    local known = Known(self)
    for index = 1, #known do
      -- Replaceable answers, rebuilt now so the elapsed time is current.
      if WF.Capture:Send("FW", Body(known[index], now, true), "FW," .. known[index].node) then
        self.answers = self.answers + 1
      end
    end
  end
  for r = 1, #self.routes do
    local rec = self.windows[self.routes[r].id]
    if rec and rec.seen and not rec.minuteWarned then
      local left = self:Remaining(rec, now)
      if left > 0 and left <= 60 then
        rec.minuteWarned = true
        self.dirty = true
        Notify("The siege of " .. Label(rec.node) .. " has one minute left.",
          "Siege ending", rec.side, true)
      end
    end
    if rec and rec.repeatAt and now >= rec.repeatAt then
      rec.repeatAt = nil
      self:Announce(rec, now)
    end
  end
  self:Evaluate(now)
  if self.dirty then self:Save(now) end
end

-- Settlements of the catalog this faction holds now.
function Front:HeldSettlements(side)
  local count = 0
  local map = WF.Map
  if not map or not map.areas or not WF.Capture then return count end
  for id, area in pairs(map.areas) do
    if type(area) == "table" and area.enabled and area.type == "SETTLEMENT"
        and WF.Capture:GetOwner(id) == side then
      count = count + 1
    end
  end
  return count
end

-- /wfd front: diagnostics, WarfrontDev addon.
function Front:PrintStatus()
  local print = WF.Print or print
  local now = Now()
  local hasRoutes = self:HasRoutes()
  if WF.Campaign and type(WF.Campaign.PrintStatus) == "function" then WF.Campaign:PrintStatus() end
  print("front: route set " .. tostring(self.campaignId) .. " rev " .. tostring(self.campaignRev)
    .. " (" .. tostring(self.campaignName) .. ") off-route POIs " .. tostring(self.offFront))
  if not hasRoutes then
    print("front: no route")
    return
  end
  for r = 1, #self.routes do
    local route = self.routes[r]
    local rear, forward = self:Pair(route, now)
    local rec = self.windows[route.id]
    local line = "front " .. route.id .. ": rear " .. tostring(rear) .. " forward " .. tostring(forward)
    if rec then
      line = line .. " | window " .. rec.node .. " " .. rec.side .. " left " .. self:Remaining(rec, now)
        .. (rec.seen and "" or " pending") .. (rec.soft and " soft" or "")
    end
    print(line)
  end
  for routeId, capital in pairs(self.capitalOf or {}) do
    print("front " .. routeId .. ": capital " .. capital .. (self:CapitalAllowed(now) and "" or " (too late to besiege)"))
  end
  print("front: opened " .. self.opened .. " expired " .. self.expired .. " received " .. self.received
    .. " rejected " .. self.rejected .. " answers " .. self.answers .. " rev skew " .. self.skew
    .. (self.lastReject and (" last reject " .. self.lastReject) or ""))
end

-- The static catalog is registered by modules/map.lua, loaded before this file:
-- take the zones off the campaign's routes out of play before anything draws,
-- captures or loads saved owners (decision 0106).
Build(Front)
