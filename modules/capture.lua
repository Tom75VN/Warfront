-- Standard functions cached as locals: hot paths call them often.
local mathFloor = math.floor
local mathAbs = math.abs
local mathMax = math.max
local mathMin = math.min
local strFormat = string.format
local strSub = string.sub

Warfront = Warfront or {}

local WF = Warfront
local Capture = {
  states = {},
  owners = {},
  presence = {},
  quotas = {},
  quotaCount = 0,
  alerts = {},
  captured = {},
  hints = {},
  -- Cloud owners of the import (decision 0060): one entry per POI, apart from
  -- the P2P hints, never persisted nor sent.
  cloud = {},
  ownerRevision = 0,
  queryRevision = 0,
  mapDirty = {},
  -- Sender faction for the hint quorum. Only the chat language may fill it,
  -- once risk B12 is measured on OctoWoW; empty until then (decision 0038).
  senderFactions = {},
  promoted = 0,
  listeners = {},
  here = nil,
  sent = 0,
  sendFailures = 0,
  rejected = 0,
  received = 0,
  ignored = 0,
  duplicates = 0,
  -- AC-2 measurement (decision 0093): relayer -> tally; diagnostics only.
  relayTally = {},
  relayTallyCount = 0,
}

WF.Capture = Capture

-- OUTPOST and SETTLEMENT capture (docs/capture.md, decisions 0012, 0053).
-- Progress is in thousandths of the challenger's share. Modes: R rest, P push,
-- C contested or frozen, D return.
local CAPTURE_DURATION = 180
local DECAY_DURATION = 360
-- Each attempt carries its current full-bar duration in S. The authority
-- recomputes it from occupied Garrison Capacity whenever the garrison changes,
-- without changing the current capture percentage (decision 0082).
local OUTPOST_MAX_DURATION = 480
local SETTLEMENT_DURATION = 600
local SETTLEMENT_MAX_DURATION = 1080
-- A capital attempt (decision 0103 § 2): 30 minutes, no garrison, so fixed.
local CAPITAL_DURATION = 1800
local MAX_DURATION = CAPITAL_DURATION
-- A War Camp attempt (decision 0123 § 3): always 3 minutes, no garrison, no
-- Front Network reduction; only the layer arena's half speed doubles it.
local WAR_CAMP_DURATION = 180
-- Defensive Coordination (decision 0123 § 6): the moving faction's Front
-- Network shortens an Outpost or Settlement push by up to 35 %, so the fastest
-- accepted durations are ceil(180 * 0.65) and ceil(600 * 0.65).
local OUTPOST_MIN_DURATION = 117
local SETTLEMENT_MIN_DURATION = 390
-- A Settlement attempt needs two attackers to open and to advance.
local SIEGE_ATTACKERS = 2
-- A capital attempt needs five (decision 0103 § 2).
local CAPITAL_ATTACKERS = 5
-- Plausibility bound: the fastest attempt, an Outpost at the full Front
-- Network reduction (decision 0123 § 6).
local MAX_RATE = 1000 / OUTPOST_MIN_DURATION
-- Scoreboard credit (decision 0126 § 2): a player counted inside during the
-- last CREDIT_RECENT seconds of an attempt shares its capture or defense; a
-- defense needs the attempt to have reached DEFENSE_MIN_PROGRESS thousandths.
-- recentIn keeps at most MAX_RECENT_IN players per POI (R9). Local only.
local CREDIT_RECENT = 60
local DEFENSE_MIN_PROGRESS = 250
local MAX_RECENT_IN = 64
local PRESENCE_INTERVAL = 10
local PRESENCE_TTL = 25
-- A defender of an idle POI it owns, with no rival in sight, slows down; each
-- P names its cadence so receivers keep it alive long enough (decision 0033).
local PRESENCE_REST_INTERVAL = 30
local PRESENCE_REST_TTL = 75
-- Alone at rest, nobody counts on it but distant observers (decision 0034).
local PRESENCE_LONE_INTERVAL = 60
local PRESENCE_LONE_TTL = 150
-- A Settlement no faction can siege: no presence there moves a bar, W
-- every 60 s once it stayed so for QUIET_SETTLE, so every client learned the
-- owners that made it quiet before the first W (decision 0058).
local PRESENCE_QUIET_INTERVAL = 60
local PRESENCE_QUIET_TTL = 150
local QUIET_SETTLE = 30
-- A busy authority repeats its S every 30 s, and at once on a transition or a
-- recount; no 5 % steps (decision 0041). Three intervals of silence, as before.
local STATE_INTERVAL = 30
local MIN_BROADCAST_GAP = 1
local AUTHORITY_SILENCE = 90
local ENTRY_GRACE = 3.5
local TICK_INTERVAL = 0.25
local ELIGIBILITY_INTERVAL = 1
local MAP_INTERVAL = 1
local ALERT_COOLDOWN = 60
local PLAUSIBILITY_SLACK = 30
local MAX_PRESENCE_PER_POI = 40
-- Incoming quota per sender and 10 s window (decision 0029). The total equals
-- what a plain 0.25 s gate could emit (40) plus 20 % for delivery jitter, above
-- the current gate (6 sends then a 1.1 s pause, ~26, decision 0040): an honest
-- client is never refused. The per-kind limits
-- bound the kinds a liar could abuse: kills (risk B11) and requests, whose
-- answers every peer prepares (risk B8).
local QUOTA_WINDOW = 10
local QUOTA_TOTAL = 48
-- X: shared stock of a resource POI (modules/stock.lua, decision 0048).
-- G, GD, GQ: garrison state, pledge request and query (modules/garrison.lua,
-- decision 0049).
-- SC, SQ, SL: scouting order, catch-up request and relayed scout
-- (modules/scout.lua, decision 0050).
-- AC, AQ, AL, AR: attack order, catch-up request, relayed attack and battle
-- result (modules/attack.lua, decision 0052).
local QUOTA_BY_KIND = {
  S = 40, P = 20, Q = 6, HQ = 6, H = 10, K = 20, OD = 4, OL = 12, X = 20, G = 20, GD = 6, GQ = 6,
  SC = 6, SQ = 6, SL = 20, AC = 6, AQ = 6, AL = 20, AR = 10,
  -- FW, FQ: siege window start and its request (modules/front.lua, decision 0098).
  FW = 6, FQ = 6,
  -- T, TQ: membership ticket and its request (modules/ticket.lua, decision 0061).
  T = 6, TQ = 6,
  -- Board copies (decision 0110): a holder sends one piece per 4 s at most.
  BP = 4, BD = 2, BQ = 2,
  -- LJ, LN: a request to join a layer and its refusal (decision 0119 step 4).
  LJ = 2, LN = 4,
  -- CE, CQ, CL: campaign end, its request and answers (modules/campaign.lua,
  -- decision 0103 § 4b): two CE per confirmation, one CQ a minute, CL one a
  -- second and at most 8 per request.
  CE = 6, CQ = 4, CL = 10,
}
-- Owner claims nobody here saw happen (decision 0038): relayed S and H, OL
-- catch-up lines, K beyond the next capture. They are hints, never confirmed
-- until enough distinct senders agree. Values proposed, not measured.
local HINT_SENDERS = 4
local HINT_TTL = 900
local HINT_JUMP = 10
-- A hint is promoted at most this far above the registry (decision 0089): far
-- beyond any honest gap, so walking a forged generation up needs many quorums.
local PROMOTE_JUMP = 100000
-- Generation floor (decision 0060): cloud entries and hints near 1,000,000, the
-- bound of catch-up lines and the cloud, are ignored.
local FLOOR_MAX = 990000
-- Wire bound of a generation in S lines (decision 0089): far beyond honest reach.
local MAX_GENERATION = 999999999
-- A live S may raise the generation at most LIVE_JUMP above the local floor,
-- and jump more than HINT_JUMP once per JUMP_COOLDOWN seconds (decision 0089
-- B2): a far-behind client still catches up, a forged value cannot be walked up.
local LIVE_JUMP = 100000
local JUMP_COOLDOWN = 600
local CLOUD_RANKS = { U = 0, C = 1, Q = 2, W = 3, D = 4 }
-- Rule R14 with two answers: a pending reply waits for two matching answers
-- from distinct senders, or four of any kind, before it is dropped.
local REPLY_MATCHES = 2
local REPLY_ANY = 4
local MAX_QUOTA_SENDERS = 200
local SCHEMA = 1
local MAX_ARCHIVED_LEVELS = 3
local CAMPAIGN = "permanent"

Capture.CAPTURE_DURATION = CAPTURE_DURATION
Capture.DECAY_DURATION = DECAY_DURATION
Capture.MAX_DURATION = MAX_DURATION
Capture.OUTPOST_MAX_DURATION = OUTPOST_MAX_DURATION
Capture.SETTLEMENT_DURATION = SETTLEMENT_DURATION
Capture.SETTLEMENT_MAX_DURATION = SETTLEMENT_MAX_DURATION
Capture.SIEGE_ATTACKERS = SIEGE_ATTACKERS
Capture.CAPITAL_DURATION = CAPITAL_DURATION
Capture.CAPITAL_ATTACKERS = CAPITAL_ATTACKERS
Capture.WAR_CAMP_DURATION = WAR_CAMP_DURATION
Capture.OUTPOST_MIN_DURATION = OUTPOST_MIN_DURATION
Capture.SETTLEMENT_MIN_DURATION = SETTLEMENT_MIN_DURATION

local FACTION_KEYS = { H = "HORDE", A = "ALLIANCE" }
local FACTION_CODES = { HORDE = "H", ALLIANCE = "A" }
-- Saved owners: a faction, or NEUTRAL above generation 0 after a failed siege
-- (decision 0098).
local OWNER_CODES = { HORDE = "H", ALLIANCE = "A", NEUTRAL = "N" }
local OWNER_KEYS = { H = "HORDE", A = "ALLIANCE", N = "NEUTRAL" }
local FACTION_NAMES = { H = "Horde", A = "Alliance", N = "Neutral" }
local OWNERS = { N = true, H = true, A = true }
local SIDES = { ["-"] = true, H = true, A = true }
local MODES = { R = true, P = true, C = true, D = true }
-- One-letter wire codes for presence statuses and state events (decision 0027).
local STATUS_CODES = { IN = "I", NC = "N", OUT = "O" }
local CODE_STATUSES = { I = "IN", N = "NC", O = "OUT" }
local EVENT_CODES = { START = "S", CAPTURED = "C" }
local CODE_EVENTS = { ["-"] = "-", S = "START", C = "CAPTURED" }
-- Presence cadence: F every 10 s, R at rest every 30 s (decision 0033), L
-- alone at rest every 60 s (decision 0034), W in a quiet neutral Settlement
-- every 60 s (decision 0058). Lifetime = 2.5 intervals.
local CADENCE_TTLS = { F = PRESENCE_TTL, R = PRESENCE_REST_TTL, L = PRESENCE_LONE_TTL, W = PRESENCE_QUIET_TTL }
local CADENCE_INTERVALS = {
  F = PRESENCE_INTERVAL, R = PRESENCE_REST_INTERVAL, L = PRESENCE_LONE_INTERVAL, W = PRESENCE_QUIET_INTERVAL,
}
local CADENCE_RANKS = { F = 1, R = 2, L = 3, W = 3 }

Capture.FACTION_NAMES = FACTION_NAMES

-- Forever provides IsMounted, IsStealthed and UnitIsAFK. Legacy DLL and
-- chat-system fallbacks remain bounded below. The 1.12 buff-icon fallback is
-- gone: Forever aura icons are FileDataIDs, not texture names.
-- The server refuses channel chat below this level: such a player could not
-- share anything, so it takes no part in any capture (decision 0039).
local MIN_CHANNEL_LEVEL = 5
Capture.LEVEL_REASON = "reach level " .. MIN_CHANNEL_LEVEL .. " to take part"

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

local function Now()
  local now = WF.Now and WF.Now() or 0
  if type(now) ~= "number" then return 0 end
  return now
end

-- Wall clock, for timestamps that must survive a client restart.
local function Epoch()
  local epoch = WF.Epoch and WF.Epoch() or 0
  if type(epoch) ~= "number" then return 0 end
  return epoch
end

local function Floor(value)
  return mathFloor(value + 0.0000001)
end

local function Record(kind, fields)
  if WF.Record then WF.Record(kind, fields) end
end

local function Print(text)
  if WF.Print then WF.Print(text) end
end

local function Split(text, separator)
  local parts = {}
  local start = 1
  while true do
    local position = string.find(text, separator, start, true)
    if not position then
      parts[#parts + 1] = strSub(text, start)
      return parts
    end
    parts[#parts + 1] = strSub(text, start, position - 1)
    start = position + 1
  end
end

local function Int(text, maximum)
  if type(text) ~= "string" or not string.find(text, "^%d+$") or #text > 9 then
    return nil
  end
  local value = tonumber(text)
  if not value or value > maximum then return nil end
  return value
end

local ArenaToken
local function Copy(st)
  return {
    id = st.id, owner = st.owner, generation = st.generation,
    challenger = st.challenger, progress = st.progress, mode = st.mode, dir = st.dir,
    nH = st.nH, nA = st.nA, epoch = st.epoch, seq = st.seq, dur = st.dur, siege = st.siege,
    capital = st.capital, arena = st.arena, slowed = st.slowed,
  }
end

-- Copy into an existing table (every field, nil included), for hot loops.
local function CopyInto(view, st)
  view.id, view.owner, view.generation = st.id, st.owner, st.generation
  view.challenger, view.progress, view.mode, view.dir = st.challenger, st.progress, st.mode, st.dir
  view.nH, view.nA, view.epoch, view.seq = st.nH, st.nA, st.epoch, st.seq
  view.dur, view.siege, view.capital = st.dur, st.siege, st.capital
  view.arena, view.slowed = st.arena, st.slowed
  return view
end

-- Scratch tables reused by Capture:SaveProgress every second.
local saveView, saveKeep = {}, {}

-- Full-bar speed of the attempt, in thousandths per second.
local function Rate(st)
  return 1000 / (st.dur or CAPTURE_DURATION)
end

local function HalfRate(st)
  return 500 / (st.dur or CAPTURE_DURATION)
end

-- Moves a state forward by dt seconds in its current mode. Observers pass
-- allowCapture=false: only the authority completes a capture. A Settlement
-- (siege) never opens an attempt here: only its authority does, once the
-- prerequisites hold (Capture:SiegeMode, decision 0053).
local function Advance(st, dt, allowCapture)
  local event = nil
  local guard = 0
  local rate, half = Rate(st), HalfRate(st)
  while dt > 0 and guard < 4 do
    guard = guard + 1
    if st.mode == "P" and FACTION_KEYS[st.dir] then
      local side = st.dir
      if st.challenger == "-" then
        if side == st.owner or st.siege then return event end
        st.challenger = side
        st.progress = 0
      end
      if st.challenger == side then
        local need = (1000 - st.progress) / rate
        if dt < need then
          st.progress = st.progress + rate * dt
          return event
        end
        if not allowCapture then
          st.progress = 1000
          return event
        end
        dt = dt - need
        st.owner = side
        st.generation = Capture:NextGeneration(st.id, st.generation)
        st.challenger = "-"
        st.progress = 0
        event = "CAPTURED"
      else
        -- The owner defends, or on a neutral POI the other faction must first
        -- bring the challenger back to 0 before building its own share.
        local need = st.progress / rate
        if dt < need then
          st.progress = st.progress - rate * dt
          return event
        end
        dt = dt - need
        st.challenger = "-"
        st.progress = 0
      end
    elseif st.mode == "D" then
      if st.challenger ~= "-" then
        local need = st.progress / half
        if dt < need then
          st.progress = st.progress - half * dt
          return event
        end
      end
      st.challenger = "-"
      st.progress = 0
      st.mode = "R"
      return event
    else
      return event
    end
  end
  return event
end

Capture.Advance = Advance

local function ModeFromCounts(nH, nA, st)
  if nH > nA then return "P", "H" end
  if nA > nH then return "P", "A" end
  if nH > 0 then return "C", "-" end
  if st.challenger == "-" then return "R", "-" end
  return "D", "-"
end

local function IsIdle(st)
  if st.challenger ~= "-" then return false end
  return not (st.mode == "P" and st.dir ~= st.owner)
end

-- Signed position on the bar within one owner: Horde share positive.
local function Position(st)
  if st.challenger == "H" then return st.progress end
  if st.challenger == "A" then return -st.progress end
  return 0
end

-- Identity ------------------------------------------------------------------

local function Realm()
  local ok, realm = Call("GetRealmName")
  if ok and type(realm) == "string" and realm ~= "" then return realm end
  return "unknown"
end

-- Realm-free "First Surname" (decision 0096): see core/names.lua.
function Capture.Identity(name)
  return WF.Names.Identity(name)
end

-- Our identity as every peer computes it from our chat lines. Kept once the
-- client gives the full name; until then recomputed on each call.
function Capture:Me()
  if not self.me then
    local name, complete = WF.Names.Mine()
    local identity = name and Capture.Identity(name)
    if identity and complete then self.me = identity end
    return identity
  end
  return self.me
end

function Capture:MyFaction()
  local ok, faction = Call("UnitFactionGroup", "player")
  if ok and faction == "Horde" then return "H" end
  if ok and faction == "Alliance" then return "A" end
  return nil
end

-- Catalogue and ownership -----------------------------------------------------

-- A POI with the timed presence bar: an OUTPOST or, since decision 0053, a
-- SETTLEMENT (its attempts gated by Capture:SiegeMode). A CAPITAL has it only
-- while its siege window runs (decision 0103 § 2), so a busy city sends no
-- presence the rest of the time. A WAR_CAMP (decision 0123) uses the Outpost
-- bar with a fixed duration, active on and off the campaign routes.
local TIMED_TYPES = { OUTPOST = true, SETTLEMENT = true, WAR_CAMP = true }
-- Owner registry: a CAPITAL always, held by its faction outside a fall.
local OWNED_TYPES = { OUTPOST = true, SETTLEMENT = true, CAPITAL = true, WAR_CAMP = true }

local function CapitalLive(id)
  local front = WF.Front
  return front ~= nil and type(front.CapitalLive) == "function" and front:CapitalLive(id, Now())
end

function Capture:Outpost(id)
  local map = WF.Map
  local area = map and type(id) == "string" and map.areas[id] or nil
  if area and area.enabled and (TIMED_TYPES[area.type] or (area.type == "CAPITAL" and CapitalLive(id))) then
    return area
  end
  return nil
end

-- OUTPOST, SETTLEMENT and CAPITAL share one owner registry; the first two
-- the timed capture bar.
function Capture:Capturable(id)
  -- Unsupported rulesets (RP, Hardcore, unknown) capture nothing (decision 0072).
  if WF.Ruleset and not WF.Ruleset:Supported() then return nil end
  local map = WF.Map
  local area = map and type(id) == "string" and map.areas[id] or nil
  if area and area.enabled and OWNED_TYPES[area.type] then
    return area
  end
  return nil
end

-- Objectives linked to a Settlement (decision 0091): every enabled OUTPOST of
-- its map, sorted by id.
function Capture:LinkedObjectives(id)
  local links = {}
  local map = WF.Map
  local settlement = map and map.areas[id]
  if not settlement or settlement.type ~= "SETTLEMENT" then return links end
  for other, area in pairs(map.areas) do
    if type(area) == "table" and area.enabled and area.map == settlement.map
        and area.type == "OUTPOST" then
      links[#links + 1] = other
    end
  end
  table.sort(links)
  return links
end

-- Full-bar duration from occupied Garrison Capacity (decision 0082). Equal
-- occupancy always gives equal capture resistance; composition remains a
-- battle concern. Empty/full are exactly 3/8 min or 10/18 min.
function Capture.DurationFor(area, used, capacity)
  if area and area.type == "CAPITAL" then return CAPITAL_DURATION end
  if area and area.type == "WAR_CAMP" then return WAR_CAMP_DURATION end
  local base, maximum = CAPTURE_DURATION, OUTPOST_MAX_DURATION
  if area and area.type == "SETTLEMENT" then
    base, maximum = SETTLEMENT_DURATION, SETTLEMENT_MAX_DURATION
  end
  capacity = Floor(tonumber(capacity) or 0)
  if capacity <= 0 then return base end
  used = mathMin(capacity, mathMax(0, Floor(tonumber(used) or 0)))
  return base + mathFloor((maximum - base) * used / capacity)
end

-- Occupancy of the garrison as this client knows it, read
-- without creating or wiping a garrison record; an older generation is empty.
function Capture:GarrisonOccupancy(id)
  local garrison = WF.Garrison
  local units = WF.Army and WF.Army.UNITS
  local area = self:Outpost(id)
  -- A capital never holds a garrison (decision 0103 § 2), nor a War Camp (0123 § 7).
  if not garrison or not units or not area or area.type == "CAPITAL" or area.type == "WAR_CAMP" then
    return 0, 0
  end
  local g = garrison.states and garrison.states[id]
  local _, generation = self:GetOwner(id)
  local capacity = garrison:Capacity(area, g and g.gold or 0, g and g.wood or 0)
  if not g or g.gen ~= generation then return 0, capacity end
  local used = g.f * units.FOOTMAN.size + g.r * units.RIFLEMAN.size + g.m * units.MORTAR.size
  return used, capacity
end

-- Current full-bar duration of this POI. During an attempt, only the authority
-- publishes changes; observers keep following the duration carried by S.
function Capture:AttemptDuration(id)
  local area = self:Outpost(id)
  if not area then return CAPTURE_DURATION end
  local used, capacity = self:GarrisonOccupancy(id)
  return Capture.DurationFor(area, used, capacity)
end

-- Owner used only by the linked-objective gate of a Settlement siege. During
-- testing and launch, a newer unconfirmed P2P or companion owner is accepted
-- without entering the confirmed registry (decision 0062).
function Capture:SiegeOwner(id, now)
  local owner = self:GetOwner(id)
  local hint = self:BestHint(id, now or Now())
  local cloud = self:CloudHint(id)
  if cloud and cloud.o and (not hint or cloud.g > hint.generation) then
    return cloud.o, false
  end
  if hint then return hint.owner, false end
  return owner, true
end

-- Owner used by scouting and attacks: the confirmed owner, or, while the
-- registry holds no faction, the provisional owner the map shows (same choice
-- as SiegeOwner, decision 0067). Returns owner, generation, confirmed. It never
-- enters the registry, a garrison nor a capture state.
function Capture:TargetOwner(id, now)
  local owner, generation = self:GetOwner(id)
  if FACTION_KEYS[owner or ""] then return owner, generation, true end
  local hint = self:BestHint(id, now or Now())
  local cloud = self:CloudHint(id)
  if cloud and FACTION_KEYS[cloud.o or ""] and (not hint or cloud.g > hint.generation) then
    return cloud.o, cloud.g, false
  end
  if hint and FACTION_KEYS[hint.owner or ""] then return hint.owner, hint.generation, false end
  return owner, generation, true
end

-- The Settlement prerequisites for faction side (decisions 0053, 0062 and
-- 0082), in the order SiegeBlocked checks them: every linked objective held or
-- provisionally reported by side and, when the other faction holds it, a valid
-- discovery by side. A garrison adds time but never blocks the attempt.
-- Each item { ok, text, why }: why is the refusal when ok is false. The two
-- attackers are counted by SiegeMode. A local reading only (gameplay UI).
function Capture:SiegeChecklist(id, side, now)
  local list = {}
  local area = WF.Map and WF.Map.areas[id]
  if area and area.type == "CAPITAL" then
    -- Only the day-long siege window (decision 0103 § 2): no garrison, no
    -- scouting, no linked Outposts.
    local front = WF.Front
    local reason = "the siege has not begun"
    if front and front:HasRoutes() then reason = front:SiegeWhy(id, side, now) end
    local text = "Capital siege under way"
    if reason == nil then
      local node = front.byCapital[id]
      text = text .. " (" .. front.Clock(front:Remaining(front:Window(node.route.id), now)) .. " left)"
    end
    table.insert(list, { ok = reason == nil, why = reason, text = text })
    return list
  end
  -- Only the faction the Active Front names may besiege this Settlement (0098).
  if WF.Front and WF.Front:HasRoutes() then
    local open = WF.Front:CanBesiege(id, side)
    table.insert(list, { ok = open, text = "On the active front",
      why = not open and ("not on the " .. FACTION_NAMES[side] .. " front") or nil })
  end
  local links = self:LinkedObjectives(id)
  local held, provisional, missing = 0, 0, nil
  for index = 1, #links do
    local objectiveOwner, confirmed = self:SiegeOwner(links[index], now)
    if objectiveOwner == side then
      held = held + 1
      if not confirmed then provisional = provisional + 1 end
    elseif not missing then
      missing = links[index]
    end
  end
  local why
  if missing then
    why = (WF.Map.areas[missing].label or missing) .. " is not held by the " .. FACTION_NAMES[side]
  end
  local accepted = provisional > 0 and (", " .. provisional .. " unconfirmed accepted") or ""
  table.insert(list, { key = "outposts", ok = not missing, why = why,
    text = "Every Outpost of the zone held (" .. held .. "/" .. #links
      .. accepted .. ")" })
  -- The three-hour window those Outposts opened (decisions 0079 and 0098).
  if WF.Front and WF.Front:HasRoutes() then
    local reason = WF.Front:SiegeWhy(id, side, now)
    local text = "Siege under way"
    if reason == nil then
      local node = WF.Front.bySettlement[id]
      text = text .. " (" .. WF.Front.Clock(WF.Front:Remaining(WF.Front:Window(node.route.id), now)) .. " left)"
    end
    table.insert(list, { key = "siege", ok = reason == nil, why = reason, text = text })
  end
  if FACTION_KEYS[self:GetOwner(id)] then
    local found = WF.Scout and WF.Scout:Discovery(id, side, now)
    table.insert(list, { ok = found and true or false, text = "Scouted in the last hour",
      why = not found and ("not scouted by the " .. FACTION_NAMES[side]) or nil })
  end
  return list
end

-- Why faction side cannot open a Settlement attempt now, or nil: the first
-- failed item of SiegeChecklist. Checked only when an attempt opens.
function Capture:SiegeBlocked(id, side, now)
  -- With no confirmed owner, the provisional one (companion or players) counts:
  -- a faction never besieges a Settlement it is reported to hold.
  local owner = self:TargetOwner(id, now)
  if owner == side then return "already held by the " .. FACTION_NAMES[side] end
  local list = self:SiegeChecklist(id, side, now)
  for index = 1, #list do
    if not list[index].ok then return list[index].why end
  end
  return nil
end

-- A Settlement, neutral or held, with no attempt and that no faction can siege
-- (decision 0058): no presence there can open or move a bar, so W is allowed
-- and receivers keep its 150 s. SiegeBlocked refuses the owner's own faction,
-- so only a possible siege by another faction ends it. A state not known yet
-- counts as idle: distant receivers have none, and an attempt only opens once
-- a siege is possible. A known state whose owner differs from the registry is
-- not quiet: one of them is behind, the fast cadence stays until they agree.
function Capture:SettlementQuiet(id, now)
  local area = self:Outpost(id)
  if not area or (area.type ~= "SETTLEMENT" and area.type ~= "CAPITAL") then return false end
  local st = self.states[id]
  if st and st.known and (st.owner ~= self:GetOwner(id) or not IsIdle(st)) then return false end
  return self:SiegeBlocked(id, "H", now) ~= nil and self:SiegeBlocked(id, "A", now) ~= nil
end

-- Mode and direction of a Settlement's bar (decisions 0053, 0065 and 0100).
-- A neutral Settlement needs one attacker; a held one needs two. During an
-- attempt, the same threshold advances it, a smaller attacking force freezes,
-- defenders ahead push back at full speed, a non-zero tie freezes, and an
-- empty area returns.
function Capture:SiegeMode(id, st, nH, nA, now)
  local counts = { H = nH, A = nA }
  local required = st.capital and CAPITAL_ATTACKERS or st.owner == "N" and 1 or SIEGE_ATTACKERS
  if st.challenger == "-" then
    local side = nil
    if nH > nA then side = "H" elseif nA > nH then side = "A" end
    if side and side ~= st.owner and counts[side] >= required
        and not self:SiegeBlocked(id, side, now) then
      return "P", side
    end
    if nH > 0 and nH == nA then return "C", "-" end
    return "R", "-"
  end
  local attacker = st.challenger
  local defender = attacker == "H" and "A" or "H"
  local a, d = counts[attacker], counts[defender]
  if a > d then
    if a >= required then return "P", attacker end
    return "C", "-"
  end
  if d > a then return "P", defender end
  if a > 0 then return "C", "-" end
  return "D", "-"
end

-- Mode of an Outpost under the front rules (decision 0098): a faction outside
-- its front zones opens nothing there, and its majority only freezes another
-- faction's attempt. The owner always defends. A War Camp ignores the front
-- (decision 0123 § 2): any strict majority moves its bar.
function Capture:OutpostMode(id, st, nH, nA)
  local mode, dir = ModeFromCounts(nH, nA, st)
  if mode ~= "P" or dir == st.owner or not WF.Front or st.camp or WF.Front:OutpostOpen(id, dir) then
    return mode, dir
  end
  if st.challenger == "-" then return "R", "-" end
  return "C", "-"
end

local function StaticOwner(area)
  local key = area.baseColorKey
  if key == nil then key = area.colorKey end
  return FACTION_CODES[key or ""] or "N"
end

function Capture:GetOwner(id)
  local entry = self.owners[id]
  if entry then return entry.owner, entry.generation, entry.source end
  local area = self:Capturable(id)
  -- A War Camp always starts neutral, whatever colour the catalog gives it (0123 § 2).
  local owner = area and area.type ~= "WAR_CAMP" and StaticOwner(area) or "N"
  -- ParseState pairs generation 0 with a neutral owner. A confirmed capture
  -- starts at generation 1 (decision 0100).
  return owner, owner == "N" and 0 or 1, "STATIC"
end

-- Equal generations only diverge after a network partition: Horde or Alliance
-- by a fair draw, both before a neutral reset (decisions 0098, 0122). The draw
-- depends only on the POI and the generation, so nobody can steer it; the
-- Worker computes the same (owners.ts drawOwner, contract/vectors/owner-draw.json).
-- Self-contained: the simulations load this function alone.
local function OwnerWins(id, owner, generation, currentOwner, currentGeneration)
  if generation ~= currentGeneration then return generation > currentGeneration end
  if owner == currentOwner then return false end
  local faction = owner == "H" or owner == "A"
  if not (faction and (currentOwner == "H" or currentOwner == "A")) then return faction end
  local h = 5381
  for index = 1, string.len(id) do
    h = (h * 33 + string.byte(id, index)) % 1000003
  end
  h = (h * 33 + generation % 1000003) % 1000003
  h = (h * 33 + math.floor(generation / 1000003)) % 1000003
  return (h % 2 == 0 and "H" or "A") == owner
end

-- The faction the draw gives at generation of id (tests and diagnostics).
function Capture.Draw(id, generation)
  return OwnerWins(id, "H", generation, "A", generation) and "H" or "A"
end

-- The sections of a scope's captures table (Capture:Bucket).
local SECTIONS = { "pois", "progress", "hunting", "front" }

-- Captures are kept per channel compatibility level WF<n> (decision 0029):
-- owners agreed on by another level's network never enter this one, and
-- nothing is erased (rule R7). The sections of other levels wait in archive;
-- data saved before levels existed follows the same rules as level 2. The
-- captures table is one ruleset scope's (decision 0072).
function Capture.SelectLevel(captures, level)
  if type(level) ~= "number" then return end
  local current = tonumber(captures.level)
  if not current then
    captures.level = level
    return
  end
  if current == level then return end
  if type(captures.archive) ~= "table" then captures.archive = {} end
  local held = {}
  for _, key in ipairs(SECTIONS) do
    held[key] = captures[key]
    captures[key] = nil
  end
  captures.archive[current] = held
  local restored = captures.archive[level]
  captures.archive[level] = nil
  if type(restored) == "table" then
    for _, key in ipairs(SECTIONS) do captures[key] = restored[key] end
  end
  captures.level = level
  -- Bounded (rule R9): only the most recent other levels are kept.
  while true do
    local count, lowest = 0, nil
    for key in pairs(captures.archive) do
      count = count + 1
      if type(key) ~= "number" then
        lowest = key
        break
      end
      if not lowest or key < lowest then lowest = key end
    end
    if count <= MAX_ARCHIVED_LEVELS then break end
    captures.archive[lowest] = nil
  end
  Record("CAPTURE_LEVEL_SWITCH", { from = current, to = level })
end

-- The ruleset scope's bucket (decision 0072: shared by every realm and region of
-- the scope): stable owners (pois), in-progress bars (progress) and hunting.
function Capture:Bucket()
  local captures = WF.Ruleset and WF.Ruleset:Module("captures")
  if not captures then return nil end
  if type(captures.schema) == "number" and captures.schema > SCHEMA then
    return nil
  end
  if captures.schema ~= SCHEMA then
    captures.schema = SCHEMA
    captures.campaignId = CAMPAIGN
  end
  Capture.SelectLevel(captures, WF.channelLevel)
  if type(captures.pois) ~= "table" then captures.pois = {} end
  if type(captures.progress) ~= "table" then captures.progress = {} end
  if type(captures.hunting) ~= "table" then captures.hunting = {} end
  if type(captures.front) ~= "table" then captures.front = {} end
  if not captures.realmAdopted then
    local ok, realm = Call("GetRealmName")
    local db = WF.Storage and WF.Storage:GetDB()
    if ok then Capture.AdoptRealm(captures, db, realm) end
  end
  return captures
end

-- Copies one entry (two levels at most: saved entries are flat records).
local function CopyEntry(entry, depth)
  local copy = {}
  for key, value in pairs(entry) do
    if type(value) == "table" then
      if depth < 2 then copy[key] = CopyEntry(value, depth + 1) end
    else
      copy[key] = value
    end
  end
  return copy
end

-- Decision 0073: once per scope, the captures an older build saved for the
-- current realm (WarfrontDB.captures.realms[realm], before decision 0072) are
-- copied into the scope. The current realm's record chose this scope, so no
-- other realm is read. Same level only; an entry the scope holds is kept; the
-- realm archive is never changed. LoadOwners validates what was copied.
function Capture.AdoptRealm(captures, db, realm)
  if captures.realmAdopted then return 0 end
  if type(realm) ~= "string" or realm == "" then return 0 end
  captures.realmAdopted = true
  local legacy = type(db) == "table" and db.captures
  local realms = type(legacy) == "table" and legacy.realms
  local old = type(realms) == "table" and realms[realm]
  if type(old) ~= "table" then return 0 end
  -- Data saved before levels existed follows level 2 (Capture.SelectLevel).
  if (tonumber(legacy.level) or 2) ~= tonumber(captures.level) then return 0 end
  local count = 0
  for _, key in ipairs(SECTIONS) do
    local from, into = old[key], captures[key]
    if type(from) == "table" and type(into) == "table" then
      for id, entry in pairs(from) do
        if type(id) == "string" and type(entry) == "table" and into[id] == nil then
          into[id] = CopyEntry(entry, 1)
          count = count + 1
        end
      end
    end
  end
  Record("CAPTURE_REALM_ADOPTED", { count = count })
  return count
end

function Capture:Store()
  local bucket = self:Bucket()
  return bucket and bucket.pois or nil
end

function Capture:LoadOwners()
  local bucket = self:Bucket()
  if not bucket then return false end
  local pois = bucket.pois
  self.loaded = true
  self.ownerRevision = (self.ownerRevision or 0) + 1
  self.queryRevision = (self.queryRevision or 0) + 1
  self.mapOwners = nil
  local stale = {}
  for id, entry in pairs(pois) do
    local owner = type(entry) == "table" and OWNER_CODES[entry.owner or ""]
    local generation = type(entry) == "table" and tonumber(entry.generation)
    local area = WF.Map and WF.Map.areas[id]
    if type(area) == "table" and area.offFront then
      -- Out of play in this campaign (decision 0106): kept as saved, not loaded,
      -- so a route edit that brings the zone back finds its owner again.
    elseif not self:Capturable(id) or not owner or not generation or generation < 1
        or generation > MAX_GENERATION or Floor(generation) ~= generation then
      stale[#stale + 1] = id
    else
      local source = entry.source == "LOCAL" and "LOCAL" or "PEER"
      local currentOwner, currentGeneration = self:GetOwner(id)
      if OwnerWins(id, owner, generation, currentOwner, currentGeneration) then
        self.owners[id] = { owner = owner, generation = generation, source = source }
      end
      if generation > (self.captured[id] or 0) then self.captured[id] = generation end
    end
  end
  for index = 1, #stale do
    pois[stale[index]] = nil
  end
  -- Presence is sampled before the first tick: after a /reload inside a POI its
  -- state was created with the static owner. Unknown states follow the registry.
  for id, st in pairs(self.states) do
    local owner, generation = self:GetOwner(id)
    if not st.known and generation > st.generation then
      st.owner, st.generation = owner, generation
      st.challenger, st.progress = "-", 0
      st.mode, st.dir = "R", "-"
    end
  end
  self:RestoreProgress(bucket)
  self:PromoteCloud(Now())
  return true
end

-- Bars saved at logout, /reload or disconnect (decision 0017). Nobody is assumed
-- present while away, so the bar returns at the decay rate for that time. The
-- state stays unknown: Q is still sent and any peer state replaces it.
function Capture:RestoreProgress(bucket)
  local saved = bucket.progress
  bucket.progress = {}
  local now, epoch = Now(), Epoch()
  for id, entry in pairs(saved) do
    local st = self.states[id]
    if type(entry) == "table" and self:Outpost(id) and not (st and st.known) then
      local owner, generation = self:GetOwner(id)
      local progress = tonumber(entry.progress)
      local at = tonumber(entry.at)
      local savedEpoch = tonumber(entry.epoch)
      -- Saves from before decision 0053 carry no duration. A duration from the
      -- former 3..20 minute defense formula is clamped into decision 0082's
      -- area-specific range; the authority will recompute it from the loaded
      -- garrison before publishing another state.
      local dur = tonumber(entry.dur or CAPTURE_DURATION)
      local area = self:Outpost(id)
      local minimum = area.type == "SETTLEMENT" and SETTLEMENT_DURATION or CAPTURE_DURATION
      local maximum = area.type == "SETTLEMENT" and SETTLEMENT_MAX_DURATION or OUTPOST_MAX_DURATION
      if area.type == "CAPITAL" then minimum, maximum = CAPITAL_DURATION, CAPITAL_DURATION end
      if area.type == "WAR_CAMP" then minimum, maximum = WAR_CAMP_DURATION, WAR_CAMP_DURATION end
      -- Nobody is assumed present, so the bar returns empty, at the unmodified
      -- garrison base saved with it (decision 0123 § 6): no Front Network
      -- reduction, no layer doubling (0119), which the saved dur may carry, up
      -- to a slowed capital's 3,600 s. A bar saved without that base falls
      -- back to its duration clamped into the area's range.
      local base = tonumber(entry.base)
      if entry.owner == owner and tonumber(entry.generation) == generation
          and (entry.challenger == "H" or entry.challenger == "A") and entry.challenger ~= owner
          and progress and progress > 0 and progress < 1000 and at and at <= epoch
          and savedEpoch and savedEpoch >= 0 and savedEpoch <= WF.Serial.MAX
          and dur and dur >= OUTPOST_MIN_DURATION and dur <= CAPITAL_DURATION * 2 then
        if base and base == Floor(base) and base >= minimum and base <= maximum then
          dur = base
        else
          dur = mathMin(maximum, mathMax(minimum, Floor(dur)))
        end
        local left = progress - HalfRate({ dur = dur }) * (epoch - at)
        if left > 0 then
          st = self:GetState(id)
          st.owner, st.generation = owner, generation
          st.challenger, st.progress, st.dur = entry.challenger, left, dur
          st.mode, st.dir, st.nH, st.nA = "D", "-", 0, 0
          -- The state is not known yet: its 0 means "no epoch", so the saved
          -- one is taken as it is (decision 0083).
          st.epoch = Floor(savedEpoch)
          st.at, st.lastStateAt = now, now
          -- Our own timer before a reload (risk B13, decision 0087): taken back
          -- while nobody announces a newer epoch, within the usual 90 s.
          if entry.held == true and epoch - at <= AUTHORITY_SILENCE then
            st.heldEpoch, st.heldUntil = st.epoch, now + AUTHORITY_SILENCE - (epoch - at)
          end
          bucket.progress[id] = entry
          Record("CAPTURE_RESTORED", { id = id, progress = Floor(left) })
        end
      end
    end
  end
end

-- Rewrites the saved bars from the extrapolated states; idle POIs drop out.
function Capture:SaveProgress(now)
  if not self.loaded then return end
  local bucket = self:Bucket()
  if not bucket then return end
  -- Runs every second: update the saved entries in place, with one reused
  -- view, instead of a new copy and a new table per state.
  local progress = bucket.progress
  local view, keep = saveView, saveKeep
  local epoch = Epoch()
  local me = self:Me()
  for id, st in pairs(self.states) do
    CopyInto(view, st)
    Advance(view, (now or Now()) - st.at, false)
    if view.challenger ~= "-" and view.progress > 0 and view.progress < 1000 then
      local entry = progress[id]
      if type(entry) ~= "table" then
        entry = {}
        progress[id] = entry
      end
      entry.owner, entry.generation, entry.challenger = view.owner, view.generation, view.challenger
      entry.progress, entry.epoch, entry.at, entry.dur = Floor(view.progress), st.epoch, epoch, view.dur
      -- The unmodified garrison base the restored bar returns at.
      entry.base = self:AttemptDuration(id)
      entry.held = (me ~= nil and st.authority == me) or nil
      keep[id] = true
    end
  end
  for id in pairs(progress) do
    if not keep[id] then progress[id] = nil end
  end
  for id in pairs(keep) do keep[id] = nil end
end

function Capture:MergeOwner(id, owner, generation, source)
  if not OWNER_KEYS[owner] or generation < 1 then return false end
  local currentOwner, currentGeneration = self:GetOwner(id)
  if not OwnerWins(id, owner, generation, currentOwner, currentGeneration) then return false end
  self.owners[id] = { owner = owner, generation = generation, source = source }
  self.ownerRevision = (self.ownerRevision or 0) + 1
  self.queryRevision = (self.queryRevision or 0) + 1
  self.mapDirty = self.mapDirty or {}
  self.mapDirty[id] = true
  local pois = self:Store()
  if pois then
    pois[id] = { owner = OWNER_KEYS[owner], generation = generation, source = source }
  end
  return true
end

-- A failed siege (decision 0098): the Outpost goes neutral at the next
-- generation, on every client that saw the window close. The same numbering
-- as a capture, so a later capture is numbered above it.
function Capture:Neutralize(id, now)
  if not self:Capturable(id) then return false end
  local _, generation = self:GetOwner(id)
  local nextGeneration = self:NextGeneration(id, generation)
  if not self:MergeOwner(id, "N", nextGeneration, "LOCAL") then return false end
  Record("CAPTURE_NEUTRALIZED", { id = id, generation = nextGeneration })
  -- For the cloud owner ledger: this client's own report (decision 0098).
  if WF.Witness then WF.Witness:Note(self:Me(), "NEUTRAL", id, nextGeneration, "N") end
  local st = self.states[id]
  if st and nextGeneration > st.generation then
    st.owner, st.generation = "N", nextGeneration
    st.challenger, st.progress, st.mode, st.dir = "-", 0, "R", "-"
    if st.authority and st.authority == self:Me() then self:AuthorityStep(id, now or Now(), true) end
  end
  return true
end

-- Owner hints (decision 0038) ----------------------------------------------------
-- Per POI, at most HINT_SENDERS claims { sender, generation, owner, at }, at in
-- local time only. Never persisted, never sent, never used to refuse a state.

local function Beats(id, owner, generation)
  local currentOwner, currentGeneration = Capture:GetOwner(id)
  return OwnerWins(id, owner, generation, currentOwner, currentGeneration)
end

function Capture:ClearHints(id)
  self.queryRevision = (self.queryRevision or 0) + 1
  self.mapDirty = self.mapDirty or {}
  self.mapDirty[id] = true
  self.hints[id] = nil
end

-- Drops the claims the confirmed registry caught up with, and the expired ones.
function Capture:PruneHints(id, now)
  local list = self.hints[id]
  if not list then return end
  local kept = {}
  for index = 1, #list do
    local claim = list[index]
    if Beats(id, claim.owner, claim.generation) and (not now or now - claim.at < HINT_TTL) then
      kept[#kept + 1] = claim
    end
  end
  self.hints[id] = #kept > 0 and kept or nil
  if #kept ~= #list then
    self.queryRevision = (self.queryRevision or 0) + 1
    self.mapDirty = self.mapDirty or {}
    self.mapDirty[id] = true
  end
end

-- One claim of `sender`, read from the chat event (rule R1). A sender replaces
-- its own claim; a full table drops the oldest one.
function Capture:NoteHint(id, sender, owner, generation, now)
  if not self:Capturable(id) or not OWNER_KEYS[owner] or type(generation) ~= "number"
      or generation < 1 or not sender or sender == self:Me() then
    return false
  end
  -- A relayed claim counts once per relayer (decision 0068): a bridge, not the
  -- server, wrote its origin, so one bridge can never make a quorum alone.
  if self.relayVia then sender = "relay:" .. self.relayVia end
  self.queryRevision = (self.queryRevision or 0) + 1
  self.mapDirty = self.mapDirty or {}
  self.mapDirty[id] = true
  local list = self.hints[id] or {}
  local index = 1
  while index <= #list do
    if list[index].sender == sender then
      table.remove(list, index)
    else
      index = index + 1
    end
  end
  if not Beats(id, owner, generation) then
    self.hints[id] = #list > 0 and list or nil
    return false
  end
  list[#list + 1] = { sender = sender, owner = owner, generation = generation, at = now }
  while #list > HINT_SENDERS do
    -- The list keeps arrival order: at equal time, the first arrived leaves.
    local oldest = 1
    index = 2
    for index = 2, #list do
      if list[index].at < list[oldest].at then oldest = index end
    end
    table.remove(list, oldest)
  end
  self.hints[id] = list
  self:PromoteHint(id, owner, generation, now)
  return true
end

-- Q1: two distinct senders of two known factions; Q2: three distinct senders.
-- A jump of more than HINT_JUMP generations needs one sender more.
function Capture:Quorum(id, owner, generation)
  -- A witnessed cloud owner within HINT_JUMP of the registry needs no live
  -- sender: a partition never provides one (decision 0122 § 4).
  local witnessed = self.cloud[id]
  if witnessed and witnessed.t == "W" and witnessed.o == owner and witnessed.g == generation then
    local _, registry = self:GetOwner(id)
    if generation - registry <= HINT_JUMP then return true end
  end
  local list = self.hints[id]
  if not list then return false end
  local count, factions = 0, {}
  local index = 1
  for index = 1, #list do
    local claim = list[index]
    if claim.owner == owner and claim.generation == generation then
      count = count + 1
      local faction = self.senderFactions[claim.sender]
      if faction then factions[faction] = true end
    end
  end
  local _, currentGeneration = self:GetOwner(id)
  local extra = generation - currentGeneration > HINT_JUMP and 1 or 0
  if factions.H and factions.A and count >= 2 + extra then return true end
  if count >= 3 + extra then return true end
  -- A witnessed cloud owner is one vote: one live sender other than its
  -- capturer confirms it (decision 0060).
  local cloud = self.cloud[id]
  if cloud and cloud.t == "W" and cloud.o == owner and cloud.g == generation then
    local others = 0
    index = 1
    for index = 1, #list do
      local claim = list[index]
      if claim.owner == owner and claim.generation == generation and claim.sender ~= cloud.c then
        others = others + 1
      end
    end
    return others >= 1 + extra
  end
  return false
end

-- A promoted hint enters the registry as PEER, without any effect (rule R4).
function Capture:PromoteHint(id, owner, generation, now)
  local _, registry = self:GetOwner(id)
  if generation > registry + PROMOTE_JUMP then return false end
  if not self:Quorum(id, owner, generation) then return false end
  if not self:MergeOwner(id, owner, generation, "PEER") then return false end
  self.promoted = self.promoted + 1
  Record("CAPTURE_HINT_PROMOTED", { id = id, owner = owner, generation = generation })
  self:PruneHints(id, nil)
  return true
end

-- The most supported claim that beats the registry: owner, count, age.
function Capture:BestHint(id, now)
  local list = self.hints[id]
  if not list then return nil end
  local bestOwner, bestGeneration, bestCount, bestAt
  for index = 1, #list do
    local claim = list[index]
    if Beats(id, claim.owner, claim.generation) and now - claim.at < HINT_TTL then
      local count, newest = 0, claim.at
      for other = 1, #list do
        local peer = list[other]
        if peer.owner == claim.owner and peer.generation == claim.generation then
          count = count + 1
          if peer.at > newest then newest = peer.at end
        end
      end
      if not bestCount or count > bestCount or (count == bestCount
          and OwnerWins(id, claim.owner, claim.generation, bestOwner, bestGeneration)) then
        bestOwner, bestGeneration, bestCount, bestAt = claim.owner, claim.generation, count, newest
      end
    end
  end
  if not bestOwner then return nil end
  return { owner = bestOwner, generation = bestGeneration, count = bestCount, age = Floor(now - bestAt) }
end

-- Cloud owners (decision 0060) --------------------------------------------------
-- From the validated import only: { g, o (H/A, nil when disputed), t (C claimed,
-- Q disputed claims, W witnessed, D disputed witnessed), c (capturer or nil) }.
-- Shown, raising the generation floor, and one vote for a witnessed owner;
-- never an owner for gameplay, never sent (rule R16 as amended).

function Capture:SetCloud(owners, now)
  self.queryRevision = (self.queryRevision or 0) + 1
  self.cloud = {}
  if type(owners) ~= "table" then return end
  -- Generations restart with each campaign (decision 0103 § 3): cloud rows of
  -- another campaign never enter this one.
  if WF.Campaign and not WF.Campaign:CloudAllowed(WF.Import and WF.Import.data) then return end
  for id, e in pairs(owners) do
    if self:Capturable(id) and type(e) == "table" and CLOUD_RANKS[e.t] and type(e.g) == "number" and e.g >= 1 then
      -- N: neutral after a failed siege, shown like a faction's cloud owner.
      local owner = OWNER_KEYS[e.o] and e.o or nil
      self.cloud[id] = { g = e.g, o = owner, t = e.t, c = owner and e.c or nil }
    end
  end
  self:PromoteCloud(now)
end

-- Witnessed cloud owners enter the registry once it is loaded: before that, a
-- merge would compare against an empty registry and overwrite the saved one.
function Capture:PromoteCloud(now)
  if not self.loaded then return end
  for id, e in pairs(self.cloud) do
    if e.t == "W" and e.o then self:PromoteHint(id, e.o, e.g, now or Now()) end
  end
end

-- The cloud entry worth showing: after the confirmed registry in the owner
-- order, a tie included (decision 0122 § 4).
function Capture:CloudHint(id)
  local entry = self.cloud[id]
  if not entry then return nil end
  local owner, generation = self:GetOwner(id)
  if entry.t == "U" and generation > 0 then return nil end
  if entry.g < generation then return nil end
  if entry.g == generation and not (entry.o and OwnerWins(id, entry.o, entry.g, owner, generation)) then
    return nil
  end
  return entry
end

-- The largest generation known for id: registry, current state, cloud entry,
-- and P2P hints at most HINT_JUMP above the registry. A capture is numbered one
-- above it, so it wins over every capture its author did not see.
function Capture:Floor(id, current)
  local _, registry = self:GetOwner(id)
  local best = registry
  if type(current) == "number" and current > best then best = current end
  local entry = self.cloud[id]
  if entry and entry.t ~= "U" and entry.g > best and entry.g <= FLOOR_MAX then best = entry.g end
  local list = self.hints[id]
  if list then
    for index = 1, #list do
      local g = list[index].generation
      if g > best and g <= registry + HINT_JUMP and g <= FLOOR_MAX then best = g end
    end
  end
  return best
end

-- Display of a cloud entry: label, owner code (nil when disputed), detail.
function Capture.CloudLine(entry)
  if entry.t == "U" and entry.o then return "Unconfirmed owner", entry.o, nil end
  if entry.t == "W" then return "Unconfirmed owner", entry.o, "seen by 3+ players" end
  if entry.t == "C" then
    local name = string.gsub(entry.c or "?", "@.*$", "")
    return "Unconfirmed owner", entry.o, "claimed by " .. name
  end
  return "Unconfirmed owner", nil, "Reports disagree"
end

function Capture:NextGeneration(id, current)
  if not id then return current + 1 end
  return self:Floor(id, current) + 1
end

-- Rule R14 with two answers: `matches` says whether the answer seen carries the
-- same (generation, owner) as the reply we hold.
function Capture:SeeReply(st, sender, matches)
  if not st.replyAt then return end
  st.replyAny = st.replyAny or {}
  st.replyMatch = st.replyMatch or {}
  st.replyAny[sender] = true
  if matches then st.replyMatch[sender] = true end
  local any, match = 0, 0
  for name in pairs(st.replyAny) do any = any + 1 end
  for name in pairs(st.replyMatch) do match = match + 1 end
  if match >= REPLY_MATCHES or any >= REPLY_ANY then
    st.replyAt, st.replyAny, st.replyMatch = nil, nil, nil
  end
end

function Capture:ScheduleReply(st, at)
  st.replyAt, st.replyAny, st.replyMatch = at, nil, nil
end

-- States ----------------------------------------------------------------------

function Capture:GetState(id)
  local st = self.states[id]
  if st then return st end
  local owner, generation = self:GetOwner(id)
  local area = self:Outpost(id)
  local capital = area ~= nil and area.type == "CAPITAL" or nil
  local siege = area ~= nil and (area.type == "SETTLEMENT" or capital) or nil
  local camp = area ~= nil and area.type == "WAR_CAMP" or nil
  st = {
    id = id, owner = owner, generation = generation, challenger = "-", progress = 0,
    mode = "R", dir = "-", nH = 0, nA = 0, epoch = 0, seq = 0,
    dur = capital and CAPITAL_DURATION or siege and SETTLEMENT_DURATION or CAPTURE_DURATION, siege = siege,
    capital = capital, camp = camp,
    at = Now(), lastStateAt = -1000, lastBroadcastAt = -1000, known = false,
  }
  self.states[id] = st
  return st
end

-- The state extrapolated to now, without completing a capture.
function Capture:GetView(id, now)
  local st = self.states[id]
  if not st then return nil end
  local view = Copy(st)
  Advance(view, (now or Now()) - st.at, false)
  return view
end

-- Owner from the monotonic registry, plus the challenger's half-captured icon.
function Capture:GetDisplay(id, now)
  local owner = self:GetOwner(id)
  local view = self:GetView(id, now)
  local half = nil
  if view and view.owner == owner and view.challenger ~= "-" and view.progress >= 500 then
    half = view.challenger
  end
  return owner, half, view
end

-- Presence ------------------------------------------------------------------

function Capture:PresenceList(id)
  local list = self.presence[id]
  if not list then
    list = { entries = {}, count = 0 }
    self.presence[id] = list
  end
  return list
end

-- Who was counted inside a POI recently, by faction (decision 0126 § 2, § 3):
-- an IN presence (ours included) is remembered CREDIT_RECENT seconds, even
-- after an OUT or a death. Local memory only, never sent nor saved; at most
-- MAX_RECENT_IN players per POI, the oldest out (R9).
function Capture:NoteRecentIn(id, identity, faction, now)
  if type(identity) ~= "string" or (faction ~= "H" and faction ~= "A") then return end
  if not self.recentIn then self.recentIn = {} end
  local list = self.recentIn[id]
  if not list then
    list = {}
    self.recentIn[id] = list
  end
  local count, oldest, oldestAt = 0, nil, nil
  for key, seen in pairs(list) do
    if now - seen.at > CREDIT_RECENT or seen.at > now then
      list[key] = nil
    elseif key ~= identity then
      count = count + 1
      if not oldestAt or seen.at < oldestAt then oldest, oldestAt = key, seen.at end
    end
  end
  if count >= MAX_RECENT_IN and oldest then list[oldest] = nil end
  local seen = list[identity]
  if not seen then
    seen = {}
    list[identity] = seen
  end
  seen.at, seen.faction = now, faction
end

-- Whether this identity was counted inside the POI for that faction within
-- the last CREDIT_RECENT seconds.
function Capture:RecentlyIn(id, identity, faction, now)
  local list = self.recentIn and self.recentIn[id]
  local seen = list and identity and list[identity]
  return seen ~= nil and seen.faction == faction and seen.at <= now and now - seen.at <= CREDIT_RECENT
end

-- The players of a faction counted inside within the last CREDIT_RECENT
-- seconds, sorted, at most 40: the participants a witness lists with a
-- capture (decision 0126 § 3).
function Capture:Participants(id, faction, now)
  local names = {}
  local list = self.recentIn and self.recentIn[id]
  if not list then return names end
  for identity, seen in pairs(list) do
    if seen.faction == faction and seen.at <= now and now - seen.at <= CREDIT_RECENT then
      names[#names + 1] = identity
    end
  end
  table.sort(names)
  while #names > 40 do table.remove(names) end
  return names
end

-- Notes this client as counted inside where it stands, so its own presence
-- shares the same memory as received ones.
function Capture:NoteSelfIn(now)
  local here = self.here
  local faction = self:MyFaction()
  if here and here.status == "IN" and faction then self:NoteRecentIn(here.id, self:Me(), faction, now) end
end

-- ttl is the sender's announced lifetime (CADENCE_TTLS), PRESENCE_TTL if absent.
function Capture:SetPresence(id, identity, faction, status, now, ttl, layer)
  local list = self:PresenceList(id)
  local entry = list.entries[identity]
  if status == "OUT" then
    if entry then
      list.entries[identity] = nil
      list.count = list.count - 1
    end
    return
  end
  if not entry then
    if list.count >= MAX_PRESENCE_PER_POI then
      -- Never the local client, the authority or the epoch holder (B3): an
      -- expired entry goes first, then one that cannot count (NC), then the oldest.
      local st = self.states[id]
      local authority, holder = st and st.authority, st and st.epochHolder
      local me = self:Me()
      local oldestId, oldestRank, oldestAt = nil, nil, nil
      for key, value in pairs(list.entries) do
        if key ~= me and key ~= authority and key ~= holder then
          local rank = now > value.expireAt and 0 or (value.status == "NC" and 1 or 2)
          if not oldestRank or rank < oldestRank or (rank == oldestRank and value.at < oldestAt) then
            oldestId, oldestRank, oldestAt = key, rank, value.at
          end
        end
      end
      if not oldestId then return end
      list.entries[oldestId] = nil
      list.count = list.count - 1
    end
    entry = {}
    list.entries[identity] = entry
    list.count = list.count + 1
  end
  entry.faction = faction
  entry.status = status
  entry.layer = layer
  entry.at = now
  if status == "IN" then self:NoteRecentIn(id, identity, faction, now) end
  entry.expireAt = now + (ttl or PRESENCE_TTL)
  -- A rival in the POI ends the slow cadences: no entry outlives the normal
  -- lifetime from now, so a silent defender is not counted 50 s too long.
  -- A second player ends the lone one: nobody outlives the rest lifetime.
  -- Idempotent: repeating a presence never lengthens what this shortened.
  -- A quiet Settlement caps nothing: no presence there can move a bar. Once a
  -- siege is possible it caps as below, here every second on a present client,
  -- on the next P elsewhere (decision 0058).
  local owner = self:GetOwner(id)
  local cap = nil
  if self:SettlementQuiet(id, now) then
    cap = nil
  elseif self:HasRival(id, owner, now) then
    cap = PRESENCE_TTL
  elseif self:LiveCount(id, now) > 1 then
    cap = PRESENCE_REST_TTL
  end
  if cap then
    local limit = now + cap
    for key, value in pairs(list.entries) do
      if value.expireAt > limit then value.expireAt = limit end
    end
  end
end

local function Live(entry, identity, me, now)
  return identity == me or now <= entry.expireAt
end

-- World layer (decision 0119 step 2): our key `server:zoneUID`, or nil while
-- unknown (modules/layer.lua). On the wire it is `server.zoneUID`, the fifth
-- field of P; a P without it states an unknown layer.
local function MyLayer()
  local layer = WF.Layer
  return layer and layer.Current and layer:Current() or nil
end

local function WireLayer(key)
  return key and (string.gsub(key, ":", ".", 1)) or nil
end

-- "6867.2" -> "6867:2"; nil when malformed (each part 1-9 digits).
local function ParseLayer(text)
  if type(text) ~= "string" then return nil end
  local server, zone = string.match(text, "^(%d+)%.(%d+)$")
  if not server or #server > 9 or #zone > 9 then return nil end
  return server .. ":" .. zone
end

-- Arena (decision 0119 § 3-6, step 3) -------------------------------------------
-- The layer where a POI's fight happens, computed by every client from the
-- layers its presences carry (P fifth field). Without any known layer among
-- the counted players there is no arena and today's rules apply unchanged.
local ARENA_SWITCH = 10
local OTHER_SIDE = { H = "A", A = "H" }

-- Is layer `a` (row ra) a better arena than `b` (row rb)? Most counted
-- players; ties: the layer of the side that is not the owner, then on a
-- neutral POI the side that is not the challenger, then the current arena,
-- then the smallest key, so every client picks the same one.
local function BetterArena(a, ra, b, rb, st, current)
  if ra.n ~= rb.n then return ra.n > rb.n end
  if st.owner == "H" or st.owner == "A" then
    local xa, xb = ra.n - ra[st.owner], rb.n - rb[st.owner]
    if xa ~= xb then return xa > xb end
  elseif st.challenger == "H" or st.challenger == "A" then
    local xa, xb = ra.n - ra[st.challenger], rb.n - rb[st.challenger]
    if xa ~= xb then return xa > xb end
  end
  if a == current or b == current then return a == current end
  return a < b
end

-- Keeps the arena of a POI: a better layer takes it once it has stayed better
-- for ARENA_SWITCH s; the first arena is set at once. Returns its key or nil.
function Capture:UpdateArena(id, st, rows, now)
  local arenas = self.arenas
  if not arenas then arenas = {}; self.arenas = arenas end
  local a = arenas[id]
  if not a then a = {}; arenas[id] = a end
  local empty = { n = 0, H = 0, A = 0 }
  local best, bestRow = nil, nil
  for key, row in pairs(rows) do
    if not best or BetterArena(key, row, best, bestRow, st, a.key) then best, bestRow = key, row end
  end
  if not best then
    a.key, a.pending = nil, nil
    return nil
  end
  if not a.key then
    a.key, a.pending = best, nil
    Record("CAPTURE_ARENA", { id = id, arena = best })
  elseif best == a.key or not BetterArena(best, bestRow, a.key, rows[a.key] or empty, st, a.key) then
    a.pending = nil
  elseif a.pending ~= best then
    a.pending, a.pendingAt = best, now
  elseif now - a.pendingAt >= ARENA_SWITCH then
    Record("CAPTURE_ARENA", { id = id, before = a.key, arena = best })
    a.key, a.pending = best, nil
  end
  return a.key
end

-- S field 15 (decision 0119): the authority's arena `server.zoneUID` with "*"
-- while its push runs at half speed, or "-" without an arena. Observers follow
-- this arena instead of their own guess.
ArenaToken = function(st)
  if not st.arena then return "-" end
  return (string.gsub(st.arena, ":", ".", 1)) .. (st.slowed and "*" or "")
end

local function ParseArenaToken(text)
  if text == "-" then return nil, false end
  if type(text) ~= "string" then return nil, nil end
  local server, zone, star = string.match(text, "^(%d+)%.(%d+)(%*?)$")
  if not server or #server > 9 or #zone > 9 then return nil, nil end
  return server .. ":" .. zone, star == "*"
end

-- Counts under the arena rule: counted players on the arena layer or with an
-- unknown layer; enemies counted on another known layer only slow the other
-- side's push (slowed[side] = true). Candidates: arena players, or players
-- with an unknown layer when no arena player is present, or everybody when
-- neither is. Returns nH, nA, candidates, arena, slowed.
function Capture:ArenaCount(id, now, given)
  local nH, nA, candidates = self:Count(id, now)
  local st, list = self.states[id], self.presence[id]
  if not st or not list then return nH, nA, candidates, nil, nil end
  local rows = {}
  for _, entry in pairs(list.entries) do
    if entry.status == "IN" and entry.layer and (entry.faction == "H" or entry.faction == "A") then
      local row = rows[entry.layer]
      if not row then row = { n = 0, H = 0, A = 0 }; rows[entry.layer] = row end
      row.n = row.n + 1
      row[entry.faction] = row[entry.faction] + 1
    end
  end
  local arena = self:UpdateArena(id, st, rows, now)
  -- An observer follows the arena its authority announced (S field 15).
  if given then arena = given end
  if not arena then return nH, nA, candidates, nil, nil end
  nH, nA = 0, 0
  local slowed, known, unknown = {}, {}, {}
  for identity, entry in pairs(list.entries) do
    local here = entry.layer == nil or entry.layer == arena
    if entry.status == "IN" then
      if here then
        if entry.faction == "H" then nH = nH + 1 elseif entry.faction == "A" then nA = nA + 1 end
      elseif OTHER_SIDE[entry.faction] then
        slowed[OTHER_SIDE[entry.faction]] = true
      end
    end
    if entry.layer == arena then known[#known + 1] = identity
    elseif entry.layer == nil then unknown[#unknown + 1] = identity end
  end
  local pick = #known > 0 and known or #unknown > 0 and unknown or candidates
  if pick ~= candidates then table.sort(pick) end
  return nH, nA, pick, arena, slowed
end

-- Live counted (IN) presences of the other faction whose known layer differs
-- from ours; 0 while our layer is unknown. Display only: no rule uses it yet.
function Capture:OtherLayerRivals(id, now)
  local mine, faction = MyLayer(), self:MyFaction()
  local list = self.presence[id]
  if not mine or not faction or not list then return 0 end
  local me, count = self:Me(), 0
  for identity, entry in pairs(list.entries) do
    if identity ~= me and entry.faction ~= faction and entry.status == "IN" and entry.layer
      and entry.layer ~= mine and Live(entry, identity, me, now) then
      count = count + 1
    end
  end
  return count
end

function Capture:HasPresence(id, identity, now)
  local list = self.presence[id]
  local entry = list and list.entries[identity]
  return entry ~= nil and Live(entry, identity, self:Me(), now)
end

-- A live presence, IN or NC, of a faction other than the given one.
function Capture:HasRival(id, faction, now)
  local list = self.presence[id]
  if not list then return false end
  local me = self:Me()
  for identity, entry in pairs(list.entries) do
    if entry.faction ~= faction and Live(entry, identity, me, now) then return true end
  end
  return false
end

-- Live presences in a POI, the local player included.
function Capture:LiveCount(id, now)
  local list = self.presence[id]
  if not list then return 0 end
  local me = self:Me()
  local count = 0
  for identity, entry in pairs(list.entries) do
    if Live(entry, identity, me, now) then count = count + 1 end
  end
  return count
end

-- An accepted live S proves its producer is still there as much as a P does:
-- it extends, never shortens, the producer's presence (decision 0034).
function Capture:RefreshPresence(id, identity, now)
  local list = self.presence[id]
  local entry = list and list.entries[identity]
  if not entry then return end
  entry.at = now
  if entry.expireAt < now + PRESENCE_TTL then entry.expireAt = now + PRESENCE_TTL end
end

-- Counted players per faction and sorted candidates; drops expired entries.
function Capture:Count(id, now)
  local list = self:PresenceList(id)
  local nH, nA = 0, 0
  local candidates = {}
  local me = self:Me()
  local entries = list.entries
  -- Lua 5.1 allows clearing an existing field during pairs: expired entries
  -- go in the same pass, without a second list.
  for identity, entry in pairs(entries) do
    if not Live(entry, identity, me, now) then
      entries[identity] = nil
      list.count = list.count - 1
    else
      candidates[#candidates + 1] = identity
      if entry.status == "IN" then
        if entry.faction == "H" then nH = nH + 1 elseif entry.faction == "A" then nA = nA + 1 end
      end
    end
  end
  table.sort(candidates)
  return nH, nA, candidates
end

-- Unique counted players of one faction across a local set of POIs. The caller
-- owns `seen`, so a UI refresh allocates nothing; expired presences are pruned
-- exactly as in Count. This is a read-only local view and sends nothing.
function Capture:CountFront(ids, faction, now, seen)
  if type(ids) ~= "table" or not FACTION_KEYS[faction or ""] then return 0 end
  seen = seen or {}
  for identity in pairs(seen) do seen[identity] = nil end
  local me = self:Me()
  local count = 0
  for index = 1, #ids do
    local list = self.presence[ids[index]]
    if list then
      for identity, entry in pairs(list.entries) do
        if not Live(entry, identity, me, now) then
          list.entries[identity] = nil
          list.count = list.count - 1
        elseif entry.status == "IN" and entry.faction == faction and not seen[identity] then
          seen[identity] = true
          count = count + 1
        end
      end
    end
  end
  return count
end

-- Local eligibility -----------------------------------------------------------

local function Flag(name, fallback)
  local fn = GetGlobal(name)
  if type(fn) == "function" then
    local ok, value = pcall(fn, "player")
    if ok then return value and value ~= 0 and true or false end
  end
  if fallback then return fallback() end
  return false
end

-- Optional DLLs give exact answers: nampower's GetUnitField reads the mount
-- display and the aura spell IDs, whose aura type GetSpellRecField resolves;
-- VanillaHelpers' UnitDisplayInfo also returns the mount display.
-- SPELL_AURA_MOD_STEALTH and SPELL_AURA_MOD_INVISIBILITY in the 1.12 server enum.
local STEALTH_AURA_TYPES = { [16] = true, [18] = true }
local stealthSpells = {}

local function MountedByDll()
  local modern = GetGlobal("IsMounted")
  if type(modern) == "function" then
    local ok, mounted = pcall(modern)
    if ok then return mounted and true or false, "Forever API" end
  end
  local field = GetGlobal("GetUnitField")
  if type(field) == "function" then
    local ok, mount = pcall(field, "player", "mountDisplayId")
    if ok and type(mount) == "number" then return mount > 0, "nampower" end
  end
  local display = GetGlobal("UnitDisplayInfo")
  if type(display) == "function" then
    local ok, _, _, mount = pcall(display, "player")
    if ok and type(mount) == "number" then return mount > 0, "VanillaHelpers" end
  end
  return nil
end

local function IsStealthSpell(record, spellId)
  local known = stealthSpells[spellId]
  if known ~= nil then return known end
  local stealth = false
  local ok, auraTypes = pcall(record, spellId, "effectApplyAuraName")
  if ok and type(auraTypes) == "table" then
    local index = 1
    while index <= 3 do
      if STEALTH_AURA_TYPES[auraTypes[index]] then stealth = true end
      index = index + 1
    end
  end
  stealthSpells[spellId] = stealth
  return stealth
end

local function StealthedByDll()
  local modern = GetGlobal("IsStealthed")
  if type(modern) == "function" then
    local ok, stealthed = pcall(modern)
    if ok then return stealthed and true or false end
  end
  local field = GetGlobal("GetUnitField")
  local record = GetGlobal("GetSpellRecField")
  if type(field) ~= "function" or type(record) ~= "function" then return nil end
  local ok, auras = pcall(field, "player", "aura")
  if not ok or type(auras) ~= "table" then return nil end
  local index = 1
  while index <= 48 do
    local spellId = auras[index]
    if type(spellId) == "number" and spellId > 0 and IsStealthSpell(record, spellId) then return true end
    index = index + 1
  end
  return false
end

local function AlwaysTrue() return true end

-- False below level 5 (an unknown level, no API or 0 while loading, does not
-- block). The legacy companion is optional on Forever. Second result: why.
-- Local only: it gates what this client sends, never how a message is accepted.
function Capture:CanTalk()
  local ok, level = Call("UnitLevel", "player")
  if ok and type(level) == "number" and level > 0 and level < MIN_CHANNEL_LEVEL then
    return false, self.LEVEL_REASON, "level"
  end
  return true
end

-- Why the player cannot take part right now, or nil.
function Capture:LockReason()
  local _, reason = self:CanTalk()
  return reason
end

-- "level" or nil.
function Capture:LockKind()
  local _, _, kind = self:CanTalk()
  return kind
end

-- True for a reason set by CanTalk (the HUD shows it as a hard block).
function Capture:IsLockReason(reason)
  if reason == nil then return false end
  if reason == self.LEVEL_REASON then return true end
  return false
end

function Capture:Eligibility()
  if Flag("UnitIsDeadOrGhost") then return "NC", "dead" end
  if Flag("UnitIsAFK") or Capture.afk then return "NC", "AFK" end
  if not Flag("UnitIsPVP", AlwaysTrue) then
    -- The flag is gone: the next toggle can only turn PvP back on.
    Capture.pvpOff = nil
    return "NC", "not PvP flagged"
  end
  -- PvP turned off: GetPVPDesired when it answers, else the tracked toggle.
  local off = Capture.pvpOff
  local desiredOk, desired = Call("GetPVPDesired")
  if desiredOk then off = not desired end
  -- /pvp off keeps the flag about five minutes while the PvP timer runs.
  -- A flag the zone holds (PvP realm contested territory) has no timer and
  -- counts. An unknown timer keeps the block.
  if off then
    local timerOk, running = Call("IsPVPTimerRunning")
    if not timerOk or running then return "NC", "PvP toggled off" end
  end
  local mounted, source = MountedByDll()
  if mounted == nil then mounted, source = false, "unavailable" end
  Capture.mountSource = source
  if mounted then return "NC", "mounted" end
  local stealthed = StealthedByDll()
  Capture.stealthSource = stealthed == nil and "unavailable" or "Forever API/DLL"
  if stealthed == nil then stealthed = false end
  if stealthed then return "NC", "stealthed or invisible" end
  return "IN", nil
end

local function AfkPrefix(name, fallback)
  local text = GetGlobal(name)
  if type(text) ~= "string" then return fallback end
  local cut = string.find(text, "%", 1, true)
  if cut then text = strSub(text, 1, cut - 1) end
  return text
end

-- Server answers to /pvp; the client strings win over these fallbacks.
local PVP_MESSAGES = {
  ERR_PVP_TOGGLE_OFF = "PvP combat toggled off",
  ERR_PVP_TOGGLE_ON = "PvP combat toggled on",
  PVP_TOGGLE_OFF_VERBOSE = "You will be unflagged for PvP combat",
  PVP_TOGGLE_ON_VERBOSE = "You are now flagged for PvP combat",
}

function Capture:OnSystemMessage(message)
  if type(message) ~= "string" then return end
  local marked = AfkPrefix("MARKED_AFK", "You are now AFK")
  local cleared = AfkPrefix("CLEARED_AFK", "You are no longer AFK")
  if cleared ~= "" and string.find(message, cleared, 1, true) == 1 then
    self.afk = false
  elseif marked ~= "" and string.find(message, marked, 1, true) == 1 then
    self.afk = true
  end
  for name, text in pairs(PVP_MESSAGES) do
    local wanted = GetGlobal(name)
    if type(wanted) ~= "string" then wanted = text end
    if string.find(message, wanted, 1, true) == 1 then
      self:SetPvpOff(string.find(name, "_OFF", 1, true) ~= nil)
      return
    end
  end
end

function Capture:OnPvpToggle()
  local getPvpDesired = GetGlobal("GetPVPDesired")
  if type(getPvpDesired) == "function" then
    local ok, desired = pcall(getPvpDesired)
    if ok then
      self:SetPvpOff(not desired)
      return
    end
  end
  if self.pvpOff then
    self:SetPvpOff(false)
  else
    self:SetPvpOff(Flag("UnitIsPVP") and true or false)
  end
end

-- The HUD and the presence follow on the next tick, not a second later.
function Capture:SetPvpOff(off)
  self.pvpOff = off or nil
  self.lastEligibilityAt = nil
  if WF.Stock then WF.Stock.lastEligibilityAt = nil end
end

-- Forever's /pvp calls C_PvP.TogglePVP at run time (SlashCommands.lua), so a
-- secure post-hook on that field sees every slash toggle. Eligibility still
-- reads GetPVPDesired, which also covers toggles made elsewhere.
function Capture:HookPvpToggle()
  if self.pvpHooked then return end
  local pvp = GetGlobal("C_PvP")
  local hook = GetGlobal("hooksecurefunc")
  if type(pvp) ~= "table" or type(pvp.TogglePVP) ~= "function" or type(hook) ~= "function" then return end
  self.pvpHooked = true
  hook(pvp, "TogglePVP", function() pcall(Capture.OnPvpToggle, Capture) end)
end

-- Transport -------------------------------------------------------------------

-- kind is the event id (P, S, Q, K, H, HQ), body its comma-separated fields;
-- key lets the send gate replace a queued message that this one supersedes;
-- priority marks an event message, dropped last by a full send queue.
function Capture:Send(kind, body, key, priority)
  local talk, lockReason = self:CanTalk()
  if not talk then
    self.sendFailures = self.sendFailures + 1
    self.lastSendError = lockReason
    return false
  end
  local p2p = WF.P2PTest
  if not p2p or type(p2p.SendChannelEvent) ~= "function" then
    self.sendFailures = self.sendFailures + 1
    self.lastSendError = "P2P transport unavailable"
    return false
  end
  local ok, accepted, err = pcall(p2p.SendChannelEvent, kind, body, key, priority)
  if ok and accepted then
    self.sent = self.sent + 1
    return true
  end
  self.sendFailures = self.sendFailures + 1
  self.lastSendError = tostring(ok and err or accepted)
  return false
end

-- A line addressed to one player (decision 0077 step 3): the owner catch-up
-- digest and its answers between guild peers. Same talk gate as Send; the
-- copy passes WF.SendQueue in modules/transport.lua (rule R12, as amended).
function Capture:SendTo(target, kind, body, key)
  local talk, lockReason = self:CanTalk()
  if not talk then
    self.sendFailures = self.sendFailures + 1
    self.lastSendError = lockReason
    return false
  end
  local transport = WF.Transport
  if not transport or type(transport.SendTo) ~= "function" then
    self.sendFailures = self.sendFailures + 1
    self.lastSendError = "addressed transport unavailable"
    return false
  end
  local ok, accepted, err = pcall(transport.SendTo, transport, target, kind, body, key)
  if ok and accepted then
    self.sent = self.sent + 1
    return true
  end
  self.sendFailures = self.sendFailures + 1
  self.lastSendError = tostring(ok and err or accepted)
  return false
end

-- Cross-faction relay class of a capture line (decision 0068): "C" critical
-- (redundant, acknowledged), "S" replaceable state with its coalescing key,
-- nil never relayed. Tickets, requests and catch-up answers stay in their faction.
Capture.RELAY_CLASS = {
  K = "C", AC = "C", AR = "C", SC = "C", GD = "C", FW = "C", CE = "C",
  P = "S", S = "S", H = "S", X = "S", G = "S",
}

function Capture:RelayClass(kind, data)
  if type(kind) ~= "string" or type(data) ~= "string" then return nil end
  local class = Capture.RELAY_CLASS[kind]
  if class ~= "S" then return class end
  local parts = Split(data, ",")
  local id = parts[1]
  if id == "" then return nil end
  if kind == "S" then
    local event = (#parts == 14 or #parts == 15) and CODE_EVENTS[parts[13]] or nil
    if not event then return nil end
    if event ~= "-" then return "C" end
  elseif kind == "G" and parts[14] ~= "0" then
    -- Relay 1: an answer to GQ, not the keeper's own state.
    return nil
  end
  return "S", kind .. "," .. id
end

function Capture:SendPresence(id, status, cadence)
  local faction = self:MyFaction()
  if not faction then return false end
  local body = id .. "," .. faction .. "," .. STATUS_CODES[status] .. "," .. (cadence or "F")
  -- Our layer, when known, on an Outpost, Settlement or capital (decision 0119
  -- step 2); never on OUT nor on a resource POI, whose P keeps four fields.
  local layer = status ~= "OUT" and not (WF.Stock and WF.Stock:Resource(id)) and WireLayer(MyLayer()) or nil
  if layer then body = body .. "," .. layer end
  return self:Send("P", body)
end

-- R only for a defender of an idle POI its faction owns, with no rival
-- presence: nothing can start there until a rival's P arrives, which ends it.
-- L for the same defender when nobody else is live in the POI. W for anyone in
-- a quiet Settlement (UpdateEligibility waits QUIET_SETTLE first).
function Capture:PresenceCadence(id, faction, now)
  local st = self.states[id]
  if not st or not st.known or not IsIdle(st) then return "F" end
  if self:SettlementQuiet(id, now) then return "W" end
  if st.owner ~= faction or self:GetOwner(id) ~= faction then return "F" end
  if self:HasRival(id, faction, now) then return "F" end
  if self:LiveCount(id, now) <= 1 then return "L" end
  return "R"
end

-- A state carrying an event is never superseded and is dropped last by a full
-- send queue, so START and CAPTURED survive.
function Capture:SendState(st, event, age)
  local key
  if not event then key = "S," .. st.id end
  return self:Send("S", st.id .. "," .. st.epoch .. "," .. st.seq .. "," .. st.owner
    .. "," .. st.generation .. "," .. st.challenger .. "," .. Floor(st.progress)
    .. "," .. st.mode .. "," .. st.dir .. "," .. st.nH .. "," .. st.nA .. "," .. Floor(st.dur or CAPTURE_DURATION)
    .. "," .. (event and EVENT_CODES[event] or "-") .. "," .. Floor(age or 0)
    .. "," .. ArenaToken(st), key, event ~= nil)
end

-- Events ----------------------------------------------------------------------

function Capture:OnEvent(callback)
  if type(callback) == "function" then self.listeners[#self.listeners + 1] = callback end
end

function Capture:Emit(kind, id, side, previousOwner)
  local index = 1
  while index <= #self.listeners do
    local ok, err = pcall(self.listeners[index], kind, id, side, previousOwner)
    if not ok and WF.RecordError then WF.RecordError("capture listener", err) end
    index = index + 1
  end
end

-- generation: the POI generation the event belongs to. A capture is identified
-- by (POI, generation), so it is announced once even when two authorities or a
-- repeated state report it again.
function Capture:HandleEvent(id, event, side, now, generation, previousOwner)
  if event == "START" then
    local mine = self:MyFaction()
    if not mine or side == mine then return end
    local key = id .. ":" .. side
    local last = self.alerts[key]
    if last and now - last < ALERT_COOLDOWN then return end
    self.alerts[key] = now
    Record("CAPTURE_ALERT", { id = id, attacker = side })
    self:Emit("ALERT", id, side)
  elseif event == "CAPTURED" then
    if not generation or generation <= (self.captured[id] or 0) then
      self.duplicates = self.duplicates + 1
      Record("CAPTURE_DUPLICATE", { id = id, owner = side, generation = generation })
      return
    end
    self.captured[id] = generation
    Record("CAPTURE_DONE", { id = id, owner = side, generation = generation })
    self:Emit("CAPTURED", id, side, previousOwner)
    -- Scoreboard credit (decision 0088): a player counted inside for the
    -- winning faction at the capture or within its last CREDIT_RECENT
    -- seconds (decision 0126 § 2), once per POI and hour (decision 0109 § 3).
    -- A capture ends any defense watched there.
    local here = self.here
    if self.defending then self.defending[id] = nil end
    local inside = here and here.id == id and here.status == "IN"
    if WF.WarRecord and self:MyFaction() == side
        and (inside or self:RecentlyIn(id, self:Me(), side, now)) then
      local area = self:Outpost(id)
      if area then WF.WarRecord:CreditPoi("capture", id, area.type) end
    end
    -- The Active Front reads the same once-per-generation event (decision 0098).
    if WF.Front then
      local ok, err = pcall(WF.Front.OnCaptured, WF.Front, id, side, now)
      if not ok and WF.RecordError then WF.RecordError("front capture", err) end
    end
    -- A capital fall ends the campaign once confirmed (decision 0103 § 4).
    local area = WF.Map and WF.Map.areas[id]
    if area and area.type == "CAPITAL" and WF.Campaign then
      local inside = here ~= nil and here.id == id and here.status ~= nil
      local st = self.states[id]
      local ok, err = pcall(WF.Campaign.OnCapitalCaptured, WF.Campaign, id, side, generation,
        st and st.authority, inside, now)
      if not ok and WF.RecordError then WF.RecordError("campaign capital", err) end
    end
  end
end

-- Authority -------------------------------------------------------------------

function Capture:AuthorityStep(id, now, force)
  local st = self.states[id]
  local previousOwner = st.owner
  local nH, nA, _, arena, slowed = self:ArenaCount(id, now)
  -- Our layer is no longer the arena's (decision 0119 § 6): hand over like an
  -- explicit OUT; an arena player takes over with a higher epoch.
  local mine = MyLayer()
  if arena and mine and mine ~= arena then
    Advance(st, now - st.at, true)
    st.at = now
    st.authority = nil
    Record("CAPTURE_AUTHORITY_ARENA", { id = id, arena = arena, mine = mine })
    return
  end
  -- An attempt by the faction the map reports as holder (restored or opened
  -- before the owner was known) ends at once.
  local reset = false
  if st.siege and st.challenger ~= "-" and self:TargetOwner(id, now) == st.challenger then
    st.challenger, st.progress, st.mode, st.dir = "-", 0, "R", "-"
    reset = true
  end
  -- Likewise an Outpost attempt by a faction its front no longer allows there
  -- (or locked by a siege), and a siege whose front moved or whose three
  -- hours are over: the capture must finish strictly before the deadline.
  if st.challenger ~= "-" and WF.Front and not st.camp then
    local stop
    if st.siege then
      stop = WF.Front:SiegeEnded(id, st.challenger, now)
    else
      stop = not WF.Front:OutpostOpen(id, st.challenger, now)
    end
    if stop then
      st.challenger, st.progress, st.mode, st.dir = "-", 0, "R", "-"
      reset = true
    end
  end
  local event = Advance(st, now - st.at, true)
  st.at = now
  if event == "CAPTURED" then
    self:MergeOwner(id, st.owner, st.generation, "LOCAL")
  end
  local mode, dir
  if st.siege then
    mode, dir = self:SiegeMode(id, st, nH, nA, now)
  else
    mode, dir = self:OutpostMode(id, st, nH, nA)
  end
  if not event and mode == "P" and dir ~= st.owner and not (st.mode == "P" and st.dir == dir) then
    event = "START"
  end
  local transition = reset or event ~= nil or mode ~= st.mode or dir ~= st.dir
  -- The authoritative duration follows occupied Garrison Capacity even while
  -- an attempt runs. Progress is already a percentage (0..1000), so changing
  -- dur preserves the bar exactly (decision 0082).
  local dur = self:AttemptDuration(id)
  -- Defensive Coordination (decision 0123 § 6): the faction moving the bar,
  -- attacker or defender pushing back, shortens it by its Front Network
  -- (Outposts and Settlements only). A tie keeps the current duration; an
  -- empty return uses the unmodified base. Garrison base, then Front Network,
  -- then the layer slowdown below.
  if mode == "C" and st.dur then
    dur = st.dur
  elseif mode == "P" and FACTION_KEYS[dir] and (st.challenger ~= "-" or dir ~= st.owner) and WF.FrontNetwork then
    dur = WF.FrontNetwork:CaptureDuration(self:Outpost(id), dir, dur)
  end
  -- Enemies counted on another layer slow this push to half speed: the
  -- full-bar duration doubles while it lasts (decision 0119 § 4).
  if mode == "P" and slowed and slowed[dir] then dur = dur * 2 end
  if dur ~= st.dur then
    Record("CAPTURE_DURATION_CHANGED", { id = id, before = st.dur, after = dur, progress = Floor(st.progress) })
    st.dur = dur
    transition = true
  end
  -- Only the authority opens a Settlement attempt, prerequisites checked.
  if st.siege and mode == "P" and st.challenger == "-" and dir ~= st.owner then
    st.challenger, st.progress = dir, 0
    Record("SIEGE_OPENED", { id = id, attacker = dir })
  end
  local recounted = nH ~= st.nH or nA ~= st.nA
  local half = mode == "P" and slowed ~= nil and slowed[dir] == true
  if arena ~= st.arena or half ~= (st.slowed == true) then transition = true end
  st.arena, st.slowed = arena, half or nil
  st.mode, st.dir, st.nH, st.nA = mode, dir, nH, nA
  st.lastStateAt = now

  -- Busy POIs repeat every 30 s; once idle, one confirmation follows so a lost
  -- transition (for example CAPTURED) does not leave observers stale.
  local elapsed = now - st.lastBroadcastAt
  local due
  if IsIdle(st) then
    due = not st.settled and elapsed >= STATE_INTERVAL
  else
    st.settled = false
    due = elapsed >= STATE_INTERVAL
  end
  if force or transition or (recounted and elapsed >= MIN_BROADCAST_GAP) or due then
    if IsIdle(st) and not transition and not force and due then st.settled = true end
    st.seq = st.seq + 1
    st.lastBroadcastAt = now
    self:SendState(st, event, 0)
  end
  if event == "START" then
    self:HandleEvent(id, "START", dir, now)
  elseif event == "CAPTURED" then
    self:NoteSelfIn(now)
    self:HandleEvent(id, "CAPTURED", st.owner, now, st.generation, previousOwner)
    -- Our own capture: a claim for the cloud owner ledger (decision 0060),
    -- with the participants we counted (decision 0126 § 3).
    if WF.Witness then
      WF.Witness:Note(self:Me(), "CAPTURED", id, st.generation, st.owner, self:Participants(id, st.owner, now))
    end
  end
end

function Capture:AuthorityLost(st, now, arena)
  local me = self:Me()
  if st.authority and st.authority == me then return false end
  if st.authority then
    if not self:HasPresence(st.id, st.authority, now) then return true end
    -- An authority off the arena's layer counts as an explicit OUT (0119 § 6).
    local list = arena and self.presence[st.id]
    local entry = list and list.entries[st.authority]
    if entry and entry.layer and entry.layer ~= arena then return true, true end
    if not IsIdle(st) and now - st.lastStateAt > AUTHORITY_SILENCE then return true end
    return false
  end
  if st.explicitOut then return true end
  -- A relayed push may still have a live authority we have not heard yet.
  if (st.mode == "P" or st.mode == "C") and now - st.lastStateAt <= AUTHORITY_SILENCE then
    return false
  end
  return true
end

function Capture:TakeOver(id, now)
  local st = self.states[id]
  Advance(st, now - st.at, false)
  st.at = now
  local owner, generation = self:GetOwner(id)
  if generation > st.generation then
    st.owner, st.generation = owner, generation
    if st.challenger == owner then
      st.challenger, st.progress = "-", 0
    end
  end
  st.epoch = WF.Serial.Next(st.epoch)
  st.seq = 0
  st.authority = self:Me()
  st.epochHolder = st.authority
  st.heldEpoch, st.heldUntil = nil, nil
  st.known = true
  st.takeoverAt = nil
  st.explicitOut = nil
  st.replyAt = nil
  Record("CAPTURE_AUTHORITY", { id = id, epoch = st.epoch })
  self:AuthorityStep(id, now, true)
end

-- Local presence --------------------------------------------------------------

function Capture:Enter(id, now)
  self.here = { id = id, enterAt = now, lastPresenceAt = -1000 }
  local st = self:GetState(id)
  self:UpdateEligibility(now, true)
  if not st.known then
    self.here.queried = true
    self:Send("Q", id)
  end
end

function Capture:Leave(id, now)
  local here = self.here
  self.here = nil
  local me = self:Me()
  if me then self:SetPresence(id, me, nil, "OUT", now) end
  local st = self.states[id]
  if st and me and st.authority == me then
    -- The last state goes out before OUT so peers still accept it.
    self:AuthorityStep(id, now, true)
    st.authority = nil
  end
  if st then st.takeoverAt = nil end
  if here and here.status then self:SendPresence(id, "OUT") end
end

function Capture:OnPresenceChange(area, previous)
  local now = Now()
  if previous and self.here and self.here.id == previous.id then
    self:Leave(previous.id, now)
  end
  if area and self:Outpost(area.id) then
    self:Enter(area.id, now)
  end
end

-- A capital gains or loses its bar while the player stands in it (its siege
-- window opens or closes, decision 0103 § 2): enter or leave it then. A
-- capital state left after its window is dropped with its presences.
function Capture:SyncCapital(now)
  local current = WF.Presence and WF.Presence.current
  if type(current) == "table" and current.type == "CAPITAL" then
    local live = self:Outpost(current.id) ~= nil
    local inside = self.here ~= nil and self.here.id == current.id
    if live and not inside then
      self:Enter(current.id, now)
    elseif not live and inside then
      self:Leave(current.id, now)
    end
  end
  for id, st in pairs(self.states) do
    if st.capital and not self:Outpost(id) and not (self.here and self.here.id == id) then
      self.states[id] = nil
      self.presence[id] = nil
    end
  end
end

function Capture:UpdateEligibility(now, force)
  local here = self.here
  if not here then return end
  local me = self:Me()
  local faction = self:MyFaction()
  if not me or not faction then
    here.status, here.reason = nil, "faction unknown"
    return
  end
  -- No status: no presence, never a candidate for authority (Maintain).
  local talk, lockReason = self:CanTalk()
  if not talk then
    here.status, here.reason = nil, lockReason
    return
  end
  local status, reason = self:Eligibility()
  local changed = status ~= here.status
  -- A new or lost layer goes out at once (decision 0119 step 2).
  local layer = MyLayer()
  if layer ~= here.layer then changed = true end
  here.status, here.reason, here.layer = status, reason, layer
  here.faction = faction
  self:SetPresence(here.id, me, faction, status, now, nil, layer)
  local cadence = self:PresenceCadence(here.id, faction, now)
  -- W only after QUIET_SETTLE of quiet in a row: a receiver still behind on
  -- the owner change that made it quiet would cap it to 25 s (decision 0058).
  if cadence == "W" then
    if not here.quietSince then here.quietSince = now end
    if now - here.quietSince < QUIET_SETTLE then cadence = "F" end
  else
    here.quietSince = nil
  end
  -- A faster cadence goes out at once: receivers then expect the next P
  -- sooner. A slower one waits for the P due under the previous cadence.
  local last = here.cadence or "F"
  local woken = CADENCE_RANKS[cadence] < CADENCE_RANKS[last]
  -- A busy authority keeps its periodic P: its S every 30 s would outlast the
  -- 25 s presence a rival caps it to (decision 0041, reverts part of 0034).
  local due = now - here.lastPresenceAt >= CADENCE_INTERVALS[last]
  if force or changed or woken or due then
    here.lastPresenceAt = now
    here.cadence = cadence
    self:SendPresence(here.id, status, cadence)
  end
end

-- Incoming messages -----------------------------------------------------------

function Capture:Reject(reason, sender)
  self.rejected = self.rejected + 1
  self.lastReject = reason
  Record("CAPTURE_REJECTED", { reason = reason, sender = sender })
  return false
end

Capture.QUOTA_WINDOW = QUOTA_WINDOW
Capture.QUOTA_TOTAL = QUOTA_TOTAL
Capture.QUOTA_BY_KIND = QUOTA_BY_KIND

-- A full table drops expired windows first, then the oldest one; it is never
-- emptied at once, so quotas keep working with many senders (risk B7).
function Capture:EvictQuota(now)
  local oldest, oldestStart
  for sender, quota in pairs(self.quotas) do
    if now - quota.start >= QUOTA_WINDOW then
      oldest = sender
      break
    end
    if not oldestStart or quota.start < oldestStart then
      oldest, oldestStart = sender, quota.start
    end
  end
  if not oldest then return false end
  self.quotas[oldest] = nil
  self.quotaCount = self.quotaCount - 1
  return true
end

function Capture:AllowSender(sender, kind, now)
  local quota = self.quotas[sender]
  if not quota then
    while self.quotaCount >= MAX_QUOTA_SENDERS do
      if not self:EvictQuota(now) then self.quotaCount = 0 end
    end
    quota = { start = now, count = 0, kinds = {} }
    self.quotas[sender] = quota
    self.quotaCount = self.quotaCount + 1
  end
  if now - quota.start >= QUOTA_WINDOW then
    quota.start, quota.count, quota.kinds = now, 0, {}
  end
  quota.count = quota.count + 1
  local kindCount = (quota.kinds[kind] or 0) + 1
  quota.kinds[kind] = kindCount
  return quota.count <= QUOTA_TOTAL and kindCount <= (QUOTA_BY_KIND[kind] or QUOTA_TOTAL)
end

-- Removes a remote player from a POI; if it held the timer, that is an explicit OUT.
function Capture:DropPresence(id, sender, now)
  self:SetPresence(id, sender, nil, "OUT", now)
  local st = self.states[id]
  if st and st.authority == sender then
    st.authority = nil
    st.explicitOut = true
    st.takeoverAt = nil
  end
  -- The same presence table counts gatherers: release a stock authority too.
  if WF.Stock then WF.Stock:OnDrop(id, sender) end
  if WF.Garrison then WF.Garrison:OnDrop(id, sender) end
end

function Capture:OnPresenceMessage(sender, id, faction, status, now, cadence, layer)
  if status == "OUT" then
    self:DropPresence(id, sender, now)
    return true
  end
  -- A player stands in one POI at a time: even if its OUT was lost, it is never
  -- counted in two POIs, nor kept as the authority of the one it left.
  for other, list in pairs(self.presence) do
    if other ~= id and list.entries[sender] then self:DropPresence(other, sender, now) end
  end
  self:SetPresence(id, sender, faction, status, now, CADENCE_TTLS[cadence], layer)
  return true
end

function Capture:OnQuery(sender, id, now)
  local st = self.states[id]
  -- A provisional state came from a relay: never relayed again (decision 0038).
  if not st or not st.known or st.provisional then return true end
  if st.authority and st.authority == self:Me() then
    self:AuthorityStep(id, now, true)
  elseif not st.replyAt then
    self:ScheduleReply(st, now + 0.5 + math.random() * 2.5)
  end
  return true
end

function Capture:CheckPlausible(st, f, now)
  local elapsed = mathMax(0, now - st.lastStateAt)
  local reach = MAX_RATE * elapsed + PLAUSIBILITY_SLACK
  if f.owner ~= st.owner then
    -- A neutral reset at a higher generation comes with no capture bar: the
    -- authority applied a failed siege before us (decision 0098).
    if f.owner == "N" and f.generation > st.generation then return true end
    -- Any generation above ours: the authority numbers a capture above every
    -- generation it knows, which may be more than ours (decision 0060).
    if f.generation <= st.generation or st.challenger ~= f.owner
        or st.progress + reach < 1000 then
      return false, "implausible owner change"
    end
    return true
  end
  if f.generation ~= st.generation then return false, "generation changed without owner" end
  if mathAbs(Position(f) - Position(st)) > reach then
    return false, "implausible progress jump"
  end
  return true
end

-- AC-2 measurement (decision 0093): per relayer, accepted live states with a new
-- epoch or a higher generation, and the most seen in 60 s and 600 s from the last
-- 64 times of each kind. 32 relayers at most. Never sent, saved or read by a rule.
local RELAY_TALLY = { MAX = 32, RECENT = 64, SHORT = 60, LONG = 600 }

local function TallyKind(entry, kind, now)
  local times = entry[kind]
  times[#times + 1] = now
  if #times > RELAY_TALLY.RECENT then table.remove(times, 1) end
  local short, long = 0, 0
  for i = 1, #times do
    local age = now - times[i]
    if age < RELAY_TALLY.LONG then long = long + 1 end
    if age < RELAY_TALLY.SHORT then short = short + 1 end
  end
  entry.total[kind] = entry.total[kind] + 1
  if short > entry.max60[kind] then entry.max60[kind] = short end
  if long > entry.max600[kind] then entry.max600[kind] = long end
end

function Capture:TallyRelayed(via, newEpoch, ownerChange, now)
  if not newEpoch and not ownerChange then return end
  local tally = self.relayTally
  local entry = tally[via]
  if not entry then
    if self.relayTallyCount >= RELAY_TALLY.MAX then
      local oldest, at
      for name, e in pairs(tally) do
        if not at or e.at < at then oldest, at = name, e.at end
      end
      tally[oldest] = nil
      self.relayTallyCount = self.relayTallyCount - 1
    end
    entry = { epochs = {}, owners = {}, total = { epochs = 0, owners = 0 },
      max60 = { epochs = 0, owners = 0 }, max600 = { epochs = 0, owners = 0 } }
    tally[via] = entry
    self.relayTallyCount = self.relayTallyCount + 1
  end
  entry.at = now
  if newEpoch then TallyKind(entry, "epochs", now) end
  if ownerChange then TallyKind(entry, "owners", now) end
end

function Capture:OnStateMessage(sender, f, now)
  local id = f.id
  local st = self:GetState(id)
  local me = self:Me()
  local live = f.age == 0
  local jumped = false

  if live then
    if not self:HasPresence(id, sender, now) then return self:Reject("state without presence", sender) end
    -- Like a P, even if a rule below refuses the state: a refused authority
    -- must not also lose its presence (decision 0034).
    self:RefreshPresence(id, sender, now)
    -- Generation jumps (risk B76, decision 0089 B2): at most LIVE_JUMP above
    -- everything known here, and one jump above HINT_JUMP per JUMP_COOLDOWN.
    -- A deliberate exception to R6, out of honest reach.
    local base = self:Floor(id, st.generation)
    if f.generation > base + HINT_JUMP then
      if f.generation > base + LIVE_JUMP then return self:Reject("implausible generation", sender) end
      if st.jumpAt and now - st.jumpAt < JUMP_COOLDOWN then
        return self:Reject("generation jump too soon", sender)
      end
      jumped = true
    end
    -- A provisional state never refuses a live one (decision 0038).
    if st.known and not st.provisional then
      if WF.Serial.Newer(st.epoch, f.epoch) then return self:Reject("old epoch", sender) end
      if f.epoch == st.epoch then
        -- The producer of the epoch is kept after it leaves, so its late or
        -- repeated states stay ordered; unknown (relayed) epochs are ordered too.
        local holder = st.authority or st.epochHolder
        if holder and holder ~= sender then
          if not (sender < holder) then return self:Reject("authority conflict lost", sender) end
        else
          if f.seq <= st.seq then return self:Reject("sequence already seen", sender) end
          local ok, reason = self:CheckPlausible(st, f, now)
          if not ok then return self:Reject(reason, sender) end
        end
      end
    end
  else
    -- A relayed answer is a hint (decision 0038): it never enters the registry,
    -- never replaces a known state nor its authority, and never has an effect.
    self:SeeReply(st, sender, f.owner == st.owner and f.generation == st.generation)
    if FACTION_KEYS[f.owner] then self:NoteHint(id, sender, f.owner, f.generation, now) end
    local owner, generation = self:GetOwner(id)
    if st.known or f.owner ~= owner or f.generation ~= generation then return true end
    -- Unknown POI, same confirmed owner: a provisional bar for display only.
    st.owner, st.generation = owner, generation
    st.challenger, st.progress = f.challenger, f.progress
    st.mode, st.dir, st.nH, st.nA, st.dur = f.mode, f.dir, f.nH, f.nA, f.dur
    st.arena, st.slowed = f.arena, f.slowed or nil
    st.epoch, st.seq = f.epoch, f.seq
    st.at = now - f.age
    st.lastStateAt = now - f.age
    st.known, st.provisional = true, true
    st.authority, st.epochHolder = nil, nil
    return true
  end

  local wasMine = st.authority ~= nil and st.authority == me
  local previousOwner = st.owner
  if jumped then st.jumpAt = now end
  if self.relayVia then
    self:TallyRelayed(self.relayVia, not st.known or st.provisional or f.epoch ~= st.epoch,
      f.generation > st.generation, now)
  end
  -- A capture whose C line was lost (risk B5, decision 0086): we held a live
  -- attempt by the faction that now owns the POI, seen at most 90 s ago, and
  -- the generation rose.
  local missed = f.event == nil and st.known and not st.provisional and FACTION_KEYS[f.owner] ~= nil
    and st.challenger == f.owner and f.generation > st.generation
    and now - st.lastStateAt <= AUTHORITY_SILENCE
  st.owner, st.generation = f.owner, f.generation
  st.challenger, st.progress = f.challenger, f.progress
  st.mode, st.dir, st.nH, st.nA, st.dur = f.mode, f.dir, f.nH, f.nA, f.dur
  st.arena, st.slowed = f.arena, f.slowed or nil
  st.epoch, st.seq = f.epoch, f.seq
  st.at = now - f.age
  st.lastStateAt = now - f.age
  st.known, st.provisional = true, nil
  st.authority = sender
  st.epochHolder = st.authority
  st.takeoverAt = nil
  st.explicitOut = nil
  st.replyAt = nil
  if wasMine then Record("CAPTURE_STEP_DOWN", { id = id, winner = sender }) end

  local present = self.here and self.here.id == id
  self:MergeOwner(id, f.owner, f.generation, present and "LOCAL" or "PEER")
  -- A live state of a present authority replaces every hint (decision 0038).
  self:ClearHints(id)
  if f.event == "START" then
    self:HandleEvent(id, "START", f.dir, now)
  elseif f.event == "CAPTURED" then
    self:NoteSelfIn(now)
    self:HandleEvent(id, "CAPTURED", f.owner, now, f.generation, previousOwner)
    -- The authority's own announce, accepted above; never a relayed answer.
    -- It lists the participants this client counted (decision 0126 § 3).
    if WF.Witness then
      WF.Witness:Note(sender, "CAPTURED", id, f.generation, f.owner, self:Participants(id, f.owner, now))
    end
  elseif missed then
    -- Not a witness: we never received the authority's announce.
    self:HandleEvent(id, "CAPTURED", f.owner, now, f.generation, previousOwner)
  end
  return true
end

-- parts: the S fields after the event id, starting with the POI.
function Capture:ParseState(parts, catalogArea)
  -- Field 15, the arena, is absent in a line without it (decision 0119).
  if #parts ~= 14 and #parts ~= 15 then return nil, "bad S field count" end
  local f = {
    id = parts[1],
    epoch = Int(parts[2], WF.Serial.MAX),
    seq = Int(parts[3], 100000000),
    owner = parts[4],
    generation = Int(parts[5], MAX_GENERATION),
    challenger = parts[6],
    progress = Int(parts[7], 1000),
    mode = parts[8],
    dir = parts[9],
    nH = Int(parts[10], MAX_PRESENCE_PER_POI),
    nA = Int(parts[11], MAX_PRESENCE_PER_POI),
    dur = Int(parts[12], MAX_DURATION * 2),
    event = CODE_EVENTS[parts[13]],
    age = Int(parts[14], 3600),
  }
  f.arena, f.slowed = nil, false
  if parts[15] then
    f.arena, f.slowed = ParseArenaToken(parts[15])
    if f.slowed == nil then return nil, "bad S arena" end
  end
  if not f.epoch or not f.seq or not f.generation or not f.progress or not f.nH or not f.nA
      or not f.dur or not f.age then
    return nil, "bad S number"
  end
  -- Attempt duration (decision 0082): 180..480 s for an Outpost and
  -- 600..1,080 s for a Settlement, down to 117 and 390 s with the moving
  -- faction's Front Network (decision 0123 § 6); exactly 1,800 s for a capital
  -- (0103) and 180 s for a War Camp (0123 § 3).
  local area = catalogArea or self:Outpost(f.id)
  local minimum = area and area.type == "SETTLEMENT" and SETTLEMENT_MIN_DURATION or OUTPOST_MIN_DURATION
  local maximum = area and area.type == "SETTLEMENT" and SETTLEMENT_MAX_DURATION or OUTPOST_MAX_DURATION
  if area and area.type == "CAPITAL" then minimum, maximum = CAPITAL_DURATION, CAPITAL_DURATION end
  if area and area.type == "WAR_CAMP" then minimum, maximum = WAR_CAMP_DURATION, WAR_CAMP_DURATION end
  -- A push slowed by enemies on another layer doubles it (decision 0119 § 4).
  -- A capital or War Camp has no garrison and no Front Network reduction: its
  -- only durations are the fixed base and, slowed, exactly its double.
  if minimum == maximum then
    if f.dur ~= minimum and f.dur ~= minimum * 2 then return nil, "bad S duration" end
  elseif f.dur < minimum or f.dur > maximum * 2 then
    return nil, "bad S duration"
  end
  if not OWNERS[f.owner] or not SIDES[f.challenger] or not MODES[f.mode] or not SIDES[f.dir]
      or not f.event then
    return nil, "bad S value"
  end
  -- A faction owner is never generation 0; a neutral one may be above it
  -- after a failed siege (decision 0098).
  if (f.owner ~= "N" and f.generation == 0) or f.challenger == f.owner
      or (f.challenger == "-" and f.progress ~= 0) or ((f.mode == "P") ~= (f.dir ~= "-")) then
    return nil, "inconsistent S"
  end
  if f.event == "-" then f.event = nil end
  return f
end

-- Forwarding validates shape/catalog rules, not this receiver's epoch,
-- presence or private battle snapshot. Reuse gameplay parsers (0131).
function Capture:ValidateForward(kind, data)
  if type(data) ~= "string" or not self:RelayClass(kind, data) then return false end
  local p = Split(data, ",")
  local id = p[1]
  if kind == "P" then
    if WF.Stock and WF.Stock:Resource(id) then
      return #p == 4 and FACTION_KEYS[p[2]] ~= nil and CODE_STATUSES[p[3]] ~= nil and p[4] == "F"
    end
    local area = self:Capturable(id)
    return area ~= nil and (#p == 4 or (#p == 5 and ParseLayer(p[5]) ~= nil))
      and FACTION_KEYS[p[2]] ~= nil and CODE_STATUSES[p[3]] ~= nil and CADENCE_TTLS[p[4]] ~= nil
      and (p[4] ~= "W" or area.type == "SETTLEMENT" or area.type == "CAPITAL")
  elseif kind == "S" then
    -- A bridge may not have learned the capital window yet. Validate against
    -- the catalog; the receiving gameplay handler still applies its own gate.
    local area = self:Capturable(id)
    return area ~= nil and self:ParseState(p, area) ~= nil
  elseif kind == "X" then
    return WF.Stock ~= nil and WF.Stock:ParseState(p) ~= nil
  elseif kind == "G" or kind == "GD" then
    local module = WF.Garrison
    local area = module and module:Area(id)
    if not area then return false end
    if kind == "G" then return module:ParseState(p, area) ~= nil end
    return module:ParseRequest(p, area) ~= nil
  elseif kind == "SC" then
    return #p == 8 and WF.Scout ~= nil and WF.Scout:Parse(p, 0) ~= nil
  elseif kind == "AC" then
    return #p == 11 and WF.Attack ~= nil and WF.Attack:Parse(p, 0) ~= nil
  elseif kind == "AR" then
    return WF.Attack ~= nil and WF.Attack:ParseResult(p) ~= nil
  elseif kind == "FW" then
    return WF.Front ~= nil and WF.Front:HasRoutes() and WF.Front:ParseWindow(p) ~= nil
  elseif kind == "CE" then
    return WF.Campaign ~= nil and WF.Campaign.Parse(p, kind) ~= nil
  end
  return false
end

function Capture:Ignore(reason, senderName)
  self.ignored = self.ignored + 1
  self.lastIgnore = reason .. " from " .. tostring(senderName)
  return false
end

-- A packet of the other faction carried by the relay (decision 0068). Its origin
-- stays the sender, so presence and authority keep their meaning, but a bridge
-- wrote it: tickets never cross, a relayed P must state the relay's faction,
-- owner hints count once per relayer (NoteHint) and the witness journal skips it.
function Capture:OnRelayedMessage(kind, data, senderName, relay)
  local via = type(relay) == "table" and relay.via or nil
  if type(via) ~= "string" or via == "" or not FACTION_KEYS[relay.faction] then
    return self:Ignore("bad relay", senderName)
  end
  if self.relayVia then return self:Reject("nested relay", via) end
  if kind == "T" or kind == "TQ" then return self:Reject("relayed ticket", via) end
  if not self:RelayClass(kind, data) then return self:Reject("not relayable", via) end
  -- A relayed presence or kill speaks for the relay's faction only (AC-15).
  if (kind == "P" or kind == "K") and Split(data, ",")[2] ~= relay.faction then
    return self:Reject("relayed " .. kind .. " faction", via)
  end
  self.relayedIn = (self.relayedIn or 0) + 1
  self.relayVia = via
  -- B from a Battle.net link, C an R line of our group, W the chain (decision
  -- 0103 § 4b counts only bridge copies).
  self.relayHop = relay.hop
  local ok, result = pcall(self.OnMessage, self, kind, data, senderName, false)
  self.relayVia, self.relayHop = nil, nil
  if not ok then error(result, 0) end
  return result
end

-- Entry point for capture events received on the visible channel: kind is the
-- event id, data its comma-separated fields, POI first (decision 0027). relay:
-- { via, faction } when the relay carried it from the other faction.
function Capture:OnMessage(kind, data, senderName, isEcho, relay)
  self.forwardable = nil -- This synchronous call only; never saved.
  if relay ~= nil then return self:OnRelayedMessage(kind, data, senderName, relay) end
  self.received = self.received + 1
  if isEcho then return self:Ignore("session echo", senderName) end
  if type(kind) ~= "string" or type(data) ~= "string" then return self:Ignore("non-string data", senderName) end
  local sender = Capture.Identity(senderName)
  if not sender then return self:Ignore("no sender", senderName) end
  if sender == self:Me() then return self:Ignore("own identity", senderName) end
  local now = Now()
  -- Last time another Warfront player was heard (companion hint, decision 0046).
  self.heardAt = now
  if not self:AllowSender(sender, kind, now) then return self:Reject("quota " .. kind, sender) end

  local parts = Split(data, ",")
  -- Membership tickets (decision 0061): T and TQ before any routing. Step 4b
  -- drops a revoked character's messages as if they were lost; in the OBSERVE
  -- mode nothing else is ever dropped for a missing ticket.
  if kind == "T" or kind == "TQ" then
    if not WF.Ticket then return self:Reject("tickets unavailable", sender) end
    local handled, err = WF.Ticket:OnMessage(kind, parts, sender, now)
    if not handled then return self:Reject(err or ("bad " .. kind), sender) end
    return true
  end
  local relayed = self.relayVia ~= nil
  if WF.Ticket and not WF.Ticket:Admit(sender, kind, now, relayed) then
    return self:Ignore("revoked character", senderName)
  end
  self.forwardable = self:ValidateForward(kind, data)
  -- Strict parsing and admission precede every forwarded copy. Local order
  -- below decides application here, independently of usefulness to a peer.
  if self.forwardable and not relayed and WF.Relay and WF.Relay.BridgeLocal then
    local bridged, bridgeError = pcall(WF.Relay.BridgeLocal, WF.Relay, sender, kind, now)
    if not bridged then WF.RecordError("relay bridge", bridgeError) end
  end
  local id = parts[1]
  if kind == "K" or kind == "H" or kind == "HQ" then
    return self:Reject("retired event", sender)
  end
  if kind == "OD" or kind == "OL" then
    if not WF.Catchup then return self:Reject("catch-up unavailable", sender) end
    return WF.Catchup:OnMessage(kind, parts, sender, now)
  end
  if kind == "G" or kind == "GD" or kind == "GQ" then
    if not WF.Garrison then return self:Reject("garrison unavailable", sender) end
    return WF.Garrison:OnMessage(kind, parts, sender, now)
  end
  if kind == "SC" or kind == "SQ" or kind == "SL" then
    if not WF.Scout then return self:Reject("scouting unavailable", sender) end
    return WF.Scout:OnMessage(kind, parts, sender, now)
  end
  if kind == "FW" or kind == "FQ" then
    if not WF.Front then return self:Reject("front unavailable", sender) end
    return WF.Front:OnMessage(kind, parts, sender, now)
  end
  if kind == "CE" or kind == "CQ" or kind == "CL" then
    if not WF.Campaign then return self:Reject("campaigns unavailable", sender) end
    return WF.Campaign:OnMessage(kind, parts, sender, now)
  end
  if kind == "AC" or kind == "AQ" or kind == "AL" or kind == "AR" then
    if not WF.Attack then return self:Reject("attacks unavailable", sender) end
    return WF.Attack:OnMessage(kind, parts, sender, now)
  end
  -- Resource POIs: P, Q and X go to the shared stocks (decision 0048).
  if kind == "X" or (WF.Stock and WF.Stock:Resource(id)) then
    if not WF.Stock then return self:Reject("stock unavailable", sender) end
    return WF.Stock:OnMessage(kind, parts, sender, now)
  end
  if not self:Outpost(id) then return self:Reject("unknown outpost", sender) end

  if kind == "P" then
    local status = CODE_STATUSES[parts[3]]
    -- Fifth field: the sender's layer (decision 0119 step 2), absent when unknown.
    local layer = parts[5] and ParseLayer(parts[5]) or nil
    if (#parts ~= 4 and #parts ~= 5) or (#parts == 5 and not layer) or not FACTION_KEYS[parts[2]]
      or not status or not CADENCE_TTLS[parts[4]] then
      return self:Reject("bad P", sender)
    end
    -- W exists only in a Settlement or a capital (static type, the same for
    -- every client).
    local placeType = self:Outpost(id).type
    if parts[4] == "W" and placeType ~= "SETTLEMENT" and placeType ~= "CAPITAL" then
      return self:Reject("bad P", sender)
    end
    -- Counted only (OBSERVE mode): a verified member stating the other faction.
    if WF.Ticket then WF.Ticket:NoteFaction(sender, parts[2]) end
    return self:OnPresenceMessage(sender, id, parts[2], status, now, parts[4], layer)
  elseif kind == "Q" then
    if #parts ~= 1 then return self:Reject("bad Q", sender) end
    return self:OnQuery(sender, id, now)
  elseif kind == "S" then
    local f, err = self:ParseState(parts)
    if not f then return self:Reject(err, sender) end
    return self:OnStateMessage(sender, f, now)
  end
  return self:Reject("unknown kind", sender)
end

-- Driver ----------------------------------------------------------------------

function Capture:Maintain(id, st, now)
  local me = self:Me()
  if st.authority and st.authority == me then
    self:AuthorityStep(id, now, false)
    return
  end
  if st.replyAt and now >= st.replyAt then
    st.replyAt = nil
    self:SendState(st, nil, mathMax(1, Floor(now - st.at)))
  end
  local present = self.here and self.here.id == id and self.here.status and me
  -- Our own timer before a reload (risk B13, decision 0087): free for us while
  -- no authority was heard since and nobody announced a newer epoch.
  local held = false
  if st.heldEpoch then
    if not st.authority and st.epoch == st.heldEpoch and now <= st.heldUntil then
      held = present and true or false
    else
      st.heldEpoch, st.heldUntil = nil, nil
    end
  end
  local _, _, candidates, arena = self:ArenaCount(id, now, st.authority and st.arena or nil)
  local lost, offArena = self:AuthorityLost(st, now, arena)
  if not held and not lost then
    st.takeoverAt = nil
    return
  end
  if present then
    if not st.takeoverAt then
      -- Only a candidate takes over: off the arena's layer we never do (0119 § 3).
      local rank = nil
      for index = 1, #candidates do
        if candidates[index] == me then rank = index - 1 end
      end
      if not rank then return end
      local delay = 2 + 3 * rank
      if (st.explicitOut or offArena) and rank == 0 then delay = 0 end
      local earliest = now + delay
      if self.here.queried and earliest < self.here.enterAt + ENTRY_GRACE then
        earliest = self.here.enterAt + ENTRY_GRACE
      end
      st.takeoverAt = earliest
    elseif now >= st.takeoverAt then
      self:TakeOver(id, now)
    end
  elseif st.mode == "P" or st.mode == "C" then
    -- The authority vanished and nobody we know of holds the POI: return.
    Advance(st, now - st.at, false)
    st.at = now
    st.mode = st.challenger == "-" and "R" or "D"
    st.dir, st.nH, st.nA = "-", 0, 0
    st.authority = nil
  end
end

-- Defense credit (decision 0109 § 3), local only: a POI held by our faction
-- where we stood counted inside while an enemy attempt ran is noted, with the
-- attempt's highest progress and the last time we were inside; when that
-- attempt ends without a capture (same owner and generation, challenger gone)
-- and an authority is known, the defense is credited once if the attempt
-- reached DEFENSE_MIN_PROGRESS and we were inside within its last
-- CREDIT_RECENT seconds (decision 0126 § 2); WarRecord:CreditPoi then allows
-- one per siege. A capture, a new owner or generation, or DEFENSE_KEEP seconds
-- forget the note. Memory only, one note per POI.
local DEFENSE_KEEP = 7200

function Capture:WatchDefense(now)
  local mine = self:MyFaction()
  if not mine then return end
  local defending = self.defending
  if not defending then
    defending = {}
    self.defending = defending
  end
  local here = self.here
  self:NoteSelfIn(now)
  if here and here.status == "IN" then
    local st = self.states[here.id]
    if st and st.owner == mine and st.challenger ~= "-" and st.challenger ~= mine then
      local note = defending[here.id]
      if not note or note.generation ~= st.generation or note.side ~= st.challenger then
        note = { generation = st.generation, side = st.challenger, at = now, peak = 0 }
        defending[here.id] = note
      end
      note.seenAt = now
    end
  end
  for id, note in pairs(defending) do
    local st = self.states[id]
    if not st or st.owner ~= mine or st.generation ~= note.generation or now - note.at > DEFENSE_KEEP then
      defending[id] = nil
    elseif st.challenger ~= note.side then
      if st.authority then
        defending[id] = nil
        -- A real threat, defended to its end (decision 0126 § 2).
        local area = self:Outpost(id)
        if area and WF.WarRecord and note.peak >= DEFENSE_MIN_PROGRESS
            and note.seenAt and now - note.seenAt <= CREDIT_RECENT then
          WF.WarRecord:CreditPoi("defense", id, area.type)
        end
      end
    elseif type(st.progress) == "number" and st.progress > note.peak then
      note.peak = st.progress
    end
  end
end

function Capture:UpdateMap(now)
  local map = WF.Map
  if not map or type(map.SetCaptureView) ~= "function" then return end
  local dirty = self.mapDirty
  local full = self.mapCatalog ~= map or self.mapRevision ~= map.revision or self.mapCount ~= #map.order
    or self.mapOwners ~= self.owners or self.mapCloud ~= self.cloud or self.mapStates ~= self.states
  if full then
    self.mapCapitals = {}
    for index = 1, #map.order do
      local id = map.order[index]
      dirty[id] = true
      if map.areas[id] and map.areas[id].type == "CAPITAL" then self.mapCapitals[id] = true end
    end
    self.mapCatalog, self.mapRevision, self.mapCount = map, map.revision, #map.order
    self.mapOwners, self.mapCloud, self.mapStates = self.owners, self.cloud, self.states
  end
  -- Only moving bars, hints awaiting expiry and the two capital gates need a
  -- clock. Previously moving bars get one final repaint when they stop.
  self.mapActive = self.mapActive or {}
  for id in pairs(self.mapActive) do dirty[id] = true self.mapActive[id] = nil end
  for id, st in pairs(self.states) do
    if st.challenger ~= "-" then dirty[id], self.mapActive[id] = true, true end
  end
  for id in pairs(self.hints) do dirty[id] = true end
  for id in pairs(self.mapCapitals) do dirty[id] = true end
  for id in pairs(dirty) do
    if self:Outpost(id) then
      local owner, half = self:GetDisplay(id, now)
      local hint = self:BestHint(id, now)
      local cloud = self:CloudHint(id)
      if cloud and hint and hint.generation >= cloud.g then cloud = nil end
      if cloud and cloud.o then
        map:SetCaptureView(id, FACTION_KEYS[cloud.o], nil, true)
      elseif hint then
        map:SetCaptureView(id, FACTION_KEYS[hint.owner], nil, true)
      else
        map:SetCaptureView(id, FACTION_KEYS[owner], half and FACTION_KEYS[half] or nil)
      end
    end
    dirty[id] = nil
  end
end

function Capture:TickModule(name, now)
  local module = WF[name]
  if not module then return true end
  local ok, err = pcall(module.Tick, module, now)
  if not ok and WF.RecordError then WF.RecordError(name .. " tick", err) end
  return ok
end

function Capture:Tick()
  local now = Now()
  if now <= 0 then return end
  if self.lastTickAt and now - self.lastTickAt < TICK_INTERVAL then return end
  self.lastTickAt = now
  -- The campaign first (decision 0103 § 3): a campaign change resets owners
  -- and may change the routes before they are loaded or used.
  if not self:TickModule("Campaign", now) then return end
  if not self.loaded then self:LoadOwners() end

  if not self.lastCapitalSyncAt or now - self.lastCapitalSyncAt >= ELIGIBILITY_INTERVAL then
    self.lastCapitalSyncAt = now
    self:SyncCapital(now)
  end
  if self.here and (not self.lastEligibilityAt or now - self.lastEligibilityAt >= ELIGIBILITY_INTERVAL) then
    self.lastEligibilityAt = now
    self:UpdateEligibility(now, false)
  end
  for id, st in pairs(self.states) do
    self:Maintain(id, st, now)
  end
  self:WatchDefense(now)
  if not self.lastMapAt or now - self.lastMapAt >= MAP_INTERVAL then
    self.lastMapAt = now
    for hinted in pairs(self.hints) do self:PruneHints(hinted, now) end
    self:UpdateMap(now)
    -- Every second, so a disconnect without PLAYER_LOGOUT loses at most that.
    self:SaveProgress(now)
  end
  self:TickModule("Catchup", now)
  local frontOK = self:TickModule("Front", now)
  self:TickModule("Stock", now)
  if frontOK then
    local garrisonOK = self:TickModule("Garrison", now)
    self:TickModule("Scout", now)
    if garrisonOK then self:TickModule("Attack", now) end
  end
end

-- Display helpers ---------------------------------------------------------------

function Capture:Remaining(view)
  if not view then return nil end
  if view.mode == "P" then
    local side = view.dir
    local rate = Rate(view)
    if view.challenger == "-" then
      if side == view.owner then return nil end
      return 1000 / rate
    end
    if view.challenger == side then return (1000 - view.progress) / rate end
    local back = view.progress / rate
    if view.owner == "N" and not view.siege then back = back + 1000 / rate end
    return back
  elseif view.mode == "D" then
    return view.progress / HalfRate(view)
  end
  return nil
end

-- A Settlement attempt held by one attacker, or a capital attempt held by
-- fewer than five, with no defender (decisions 0053, 0103).
local function Frozen(view)
  if not view.siege or view.mode ~= "C" or view.challenger == "-" then return false end
  local attackers = view.challenger == "H" and view.nH or view.nA
  local defenders = view.challenger == "H" and view.nA or view.nH
  if view.capital then return attackers > 0 and attackers < CAPITAL_ATTACKERS and defenders == 0 end
  return attackers == 1 and defenders == 0
end

local function Clock(seconds)
  seconds = Floor(seconds)
  local minutes = mathFloor(seconds / 60)
  return strFormat("%d:%02d", minutes, seconds - minutes * 60)
end

function Capture:ModeText(view)
  local owner = FACTION_NAMES[view.owner]
  if view.mode == "P" then
    if view.dir == view.owner then
      if view.challenger == "-" then return "Controlled by " .. owner end
      return "Defending - " .. owner
    end
    return "Capturing - " .. FACTION_NAMES[view.dir]
  elseif view.mode == "C" then
    if Frozen(view) and view.capital then
      return "Frozen - " .. FACTION_NAMES[view.challenger] .. " needs " .. CAPITAL_ATTACKERS .. " attackers"
    end
    if Frozen(view) then return "Frozen - " .. FACTION_NAMES[view.challenger] .. " needs a second attacker" end
    return "Contested (" .. view.nH .. " vs " .. view.nA .. ")"
  elseif view.mode == "D" then
    if view.owner == "N" then return "Returning to neutral" end
    return "Returning to " .. owner
  end
  if view.owner == "N" then return "Neutral" end
  return "Controlled by " .. owner
end

-- Why an attempt takes its time, or why a Settlement attempt cannot open for
-- faction side (roadmap WP10): one line for the HUD and the map tooltip.
-- Second value: true when side cannot open the siege at all (the HUD hides).
function Capture:Detail(id, view, side, now)
  local area = self:Outpost(id)
  if not area or not view then return nil end
  if area.type == "CAPITAL" then
    -- The day-long capital siege (decision 0103 § 2).
    local siege = WF.Front and WF.Front:SiegeText(id, now or Now())
    if view.challenger ~= "-" then
      return "Siege: " .. Clock(view.slowed and CAPITAL_DURATION * 2 or CAPITAL_DURATION) .. " for a full bar, "
        .. CAPITAL_ATTACKERS .. " attackers needed to advance"
        .. (view.slowed and ", half speed: enemies on another layer" or "") .. (siege and (". " .. siege) or "")
    end
    if not FACTION_KEYS[side or ""] or side == view.owner then return siege end
    local blocked = self:SiegeBlocked(id, side, now or Now())
    if blocked then
      return (siege and (siege .. ". ") or "") .. "Siege locked: " .. blocked, self:TargetOwner(id, now) ~= side
    end
    local inside = (side == "H" and view.nH or view.nA) or 0
    if inside > CAPITAL_ATTACKERS then inside = CAPITAL_ATTACKERS end
    return (siege and (siege .. ". ") or "") .. inside .. "/" .. CAPITAL_ATTACKERS .. " attackers inside"
  end
  if area.type == "SETTLEMENT" then
    local required = view.owner == "N" and 1 or SIEGE_ATTACKERS
    -- The three-hour countdown of a running siege, for both factions (0079).
    local siege = WF.Front and WF.Front:SiegeText(id, now or Now())
    if view.challenger ~= "-" then
      local attackers = required == 1 and "1 attacker" or required .. " attackers"
      -- A neutral POI holds no garrison: the line names none.
      local garrisonText = ""
      if FACTION_KEYS[view.owner or ""] then
        local used, capacity = self:GarrisonOccupancy(id)
        garrisonText = " (garrison " .. used .. "/" .. capacity .. " Unit Size)"
      end
      return "Siege: " .. Clock(view.dur or SETTLEMENT_DURATION) .. " for a full bar"
        .. garrisonText .. ", " .. attackers .. " needed to advance"
        .. (view.slowed and ", half speed: enemies on another layer" or "")
        .. (siege and (". " .. siege) or "")
    end
    if not FACTION_KEYS[side or ""] or side == view.owner then return siege end
    local blocked = self:SiegeBlocked(id, side, now or Now())
    if blocked then
      return (siege and (siege .. ". ") or "") .. "Siege locked: " .. blocked, self:TargetOwner(id, now) ~= side
    end
    if siege then
      local inside = (side == "H" and view.nH or view.nA) or 0
      if inside > required then inside = required end
      return siege .. ". " .. inside .. "/" .. required .. " attackers inside"
    end
    if required == 1 then return "Siege open: 1 " .. FACTION_NAMES[side] .. " attacker inside starts it" end
    local inside = (side == "H" and view.nH or view.nA) or 0
    if inside > SIEGE_ATTACKERS then inside = SIEGE_ATTACKERS end
    return FACTION_NAMES[side] .. " siege: " .. inside .. "/" .. SIEGE_ATTACKERS .. " attackers inside"
  end
  -- A War Camp (decision 0123 § 3): fixed time, no garrison, no front rule.
  if area.type == "WAR_CAMP" then
    if view.challenger ~= "-" then
      return "Capture time " .. Clock(view.dur or WAR_CAMP_DURATION)
        .. (view.slowed and ", half speed: enemies on another layer" or "")
    end
    return "Capture time " .. Clock(WAR_CAMP_DURATION)
  end
  if view.challenger ~= "-" then
    local garrisonText = ""
    if FACTION_KEYS[view.owner or ""] then
      local used, capacity = self:GarrisonOccupancy(id)
      garrisonText = " (garrison " .. used .. "/" .. capacity .. " Unit Size)"
    end
    return "Capture time " .. Clock(view.dur or CAPTURE_DURATION) .. garrisonText
      .. (view.slowed and ", half speed: enemies on another layer" or "")
  end
  local locked = WF.Front and WF.Front:LockText(id, now or Now())
  if locked then return locked end
  if FACTION_KEYS[side or ""] and side ~= view.owner and WF.Front and not WF.Front:OutpostOpen(id, side) then
    return WF.Front:FrozenText(id, side, now or Now()) or ("Closed: not on the " .. FACTION_NAMES[side] .. " front")
  end
  if not FACTION_KEYS[view.owner] then return "Capture time " .. Clock(CAPTURE_DURATION) end
  local used, capacity = self:GarrisonOccupancy(id)
  local dur = self:AttemptDuration(id)
  if used == 0 then return "Capture time " .. Clock(dur) .. " (empty garrison)" end
  return "Capture time " .. Clock(dur) .. " (garrison " .. used .. "/" .. capacity .. " Unit Size)"
end

-- Capture details for the map tooltip, nil when the area cannot be captured:
-- owner, challenger and percent, status and seconds left, players inside, here.
function Capture:TooltipInfo(id, now)
  if not self:Capturable(id) then return nil end
  local info = { owner = self:GetOwner(id) }
  info.hint = self:BestHint(id, now or Now())
  info.cloud = self:CloudHint(id)
  if info.cloud and info.hint and info.hint.generation >= info.cloud.g then info.cloud = nil end
  if info.cloud and info.cloud.o and info.hint then info.hint = nil end
  if not self:Outpost(id) then return info end
  local _, _, view = self:GetDisplay(id, now or Now())
  if view then
    if view.challenger ~= "-" then
      info.challenger = view.challenger
      info.percent = Floor(view.progress / 10)
    end
    -- An owner alone on its own outpost is plain control, already shown as owner.
    local idle = view.mode == "R" or (view.mode == "P" and view.dir == view.owner
      and view.challenger == "-")
    if not idle then
      info.status = self:ModeText(view)
      info.remaining = self:Remaining(view)
    end
    info.nH, info.nA = view.nH, view.nA
  end
  info.detail = self:Detail(id, view or { owner = info.owner, challenger = "-", progress = 0 },
    self:MyFaction(), now)
  info.here = self.here ~= nil and self.here.id == id
  return info
end

-- Data for the HUD while the player stands in an outpost.
function Capture:GetHud(now)
  local here = self.here
  if not here then return nil end
  now = now or Now()
  local area = self:Outpost(here.id)
  if not area then return nil end
  local st = self:GetState(here.id)
  local view = self:GetView(here.id, now)
  local me = self:Me()
  local detail, locked = self:Detail(here.id, view, self:MyFaction(), now)
  return {
    id = here.id,
    area = area,
    view = view,
    known = st.known,
    authority = st.authority ~= nil and st.authority == me,
    status = here.status,
    reason = here.reason,
    remaining = self:Remaining(view),
    detail = detail,
    locked = locked,
    -- Enemies counted here from another layer (decision 0119 step 2, display only).
    otherLayer = self:OtherLayerRivals(here.id, now),
  }
end

function Capture:PrintStatus()
  local now = Now()
  local here = self.here
  if here then
    Print("capture: in " .. here.id .. " as " .. tostring(here.status)
      .. (here.reason and (" (" .. here.reason .. ")") or ""))
  else
    Print("capture: not in an outpost")
  end
  Print("capture: mount detection=" .. tostring(self.mountSource or "not checked yet")
    .. " stealth detection=" .. tostring(self.stealthSource or "not checked yet"))
  local shown = 0
  for id, st in pairs(self.states) do
    local view = self:GetView(id, now)
    Print(strFormat("capture: %s owner=%s gen=%d challenger=%s %d%% mode=%s epoch=%d authority=%s",
      id, view.owner, view.generation, view.challenger, Floor(view.progress / 10), view.mode,
      st.epoch, tostring(st.authority)))
    shown = shown + 1
  end
  for oid, entry in pairs(self.owners) do
    if not self.states[oid] then
      Print("capture: " .. oid .. " owner=" .. entry.owner .. " gen=" .. entry.generation
        .. " (" .. entry.source .. ")")
      shown = shown + 1
    end
  end
  if shown == 0 then Print("capture: no outpost state known yet") end
  Print("capture: sent=" .. self.sent .. " sendFailures=" .. self.sendFailures
    .. (self.lastSendError and (" lastError=" .. self.lastSendError) or "")
    .. " rejected=" .. self.rejected .. (self.lastReject and (" lastReject=" .. self.lastReject) or "")
    .. " duplicateCaptures=" .. self.duplicates)
  if WF.SendQueue then Print("capture: " .. WF.SendQueue:Summary()) end
  if WF.Catchup then Print("capture: " .. WF.Catchup:Summary()) end
  -- Live receive counters: SavedVariables diagnostics can lag or be stale.
  local p2p = WF.P2PTest or {}
  Print("capture: channelEvents=" .. (p2p.channelEvents or 0) .. " routed=" .. (p2p.capRouted or 0)
    .. " routeErrors=" .. (p2p.capErrors or 0)
    .. (p2p.lastCapError and (" lastRouteError=" .. p2p.lastCapError) or ""))
  Print("capture: received=" .. self.received .. " ignored=" .. self.ignored
    .. (self.lastIgnore and (" lastIgnore=" .. self.lastIgnore) or ""))
  -- AC-2 measurement (decision 0093).
  Print("capture: relayed takeovers, relayers=" .. self.relayTallyCount)
  for via, e in pairs(self.relayTally) do
    Print(strFormat("capture: via %s epochs=%d max60=%d max600=%d owners=%d max60=%d max600=%d",
      via, e.total.epochs, e.max60.epochs, e.max600.epochs, e.total.owners, e.max60.owners, e.max600.owners))
  end
  if WF.lastHandlerError then Print("capture: lastHandlerError=" .. WF.lastHandlerError) end
  local counts = WF.eventCounts or {}
  local total, name, value = 0
  for name, value in pairs(counts) do total = total + value end
  Print("capture: dispatcher CHAT_MSG_CHANNEL=" .. (counts.CHAT_MSG_CHANNEL or 0)
    .. " CHAT_MSG_SYSTEM=" .. (counts.CHAT_MSG_SYSTEM or 0) .. " total=" .. total
    .. " unresolved=" .. (WF.unresolvedEvents or 0) .. " shape=" .. tostring(WF.handlerShape)
    .. " probe=" .. (p2p.probeChannelEvents or 0) .. "/" .. tostring(p2p.probeRegistered))
  local storage = WF.Storage
  local db = storage and type(storage.GetDB) == "function" and storage:GetDB() or nil
  local pois = self:Store()
  local stored = 0
  local key
  if pois then
    for key in pairs(pois) do stored = stored + 1 end
  end
  Print("capture: storage initialized=" .. tostring(storage and storage.initialized)
    .. " readOnly=" .. tostring(storage and storage.readOnly)
    .. " savedTable=" .. tostring(db ~= nil and db == GetGlobal("WarfrontDB"))
    .. " loaded=" .. tostring(self.loaded) .. " realm=" .. Realm() .. " stored=" .. stored)
end

-- Wiring ------------------------------------------------------------------------

if WF.Presence and WF.Presence.OnChange then
  WF.Presence:OnChange(function(area, previous)
    Capture:OnPresenceChange(area, previous)
  end)
end

if WF.RegisterEvent then
  WF.RegisterEvent("CHAT_MSG_SYSTEM", function(eventName, message)
    Capture:OnSystemMessage(message)
  end)
  -- Where the server puts the /pvp answer is not measured yet.
  WF.RegisterEvent("UI_INFO_MESSAGE", function(eventName, errorType, message)
    Capture:OnSystemMessage(message)
  end)
  -- Fires on logout, quit and /reload, before SavedVariables are written.
  WF.RegisterEvent("PLAYER_LOGOUT", function()
    Capture:SaveProgress(Now())
  end)
end

Capture:HookPvpToggle()

local create = GetGlobal("CreateFrame")
if type(create) == "function" then
  local parent = GetGlobal("WorldFrame") or UIParent
  local frameOk, driver = pcall(create, "Frame", "WarfrontCaptureDriver", parent)
  if frameOk and driver and type(driver.SetScript) == "function" then
    driver:SetScript("OnUpdate", function()
      -- Same throttle as Capture:Tick, checked before paying for a pcall
      -- on each of the frames between two ticks.
      local last = Capture.lastTickAt
      if last and Now() - last < TICK_INTERVAL then return end
      local ok, err = pcall(Capture.Tick, Capture)
      if not ok and WF.RecordError then WF.RecordError("capture driver", err) end
    end)
    Capture.driver = driver
  elseif WF.RecordError then
    WF.RecordError("capture driver", "unable to create OnUpdate driver")
  end
end
