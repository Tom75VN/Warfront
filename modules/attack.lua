Warfront = Warfront or {}

local WF = Warfront
local Attack = {
  records = {},
  count = 0,
  out = {},
  addressedOut = {},
  sent = 0,
  received = 0,
  lockAlerts = {},
}

WF.Attack = Attack

-- Virtual attacks and battles (roadmap WP9, docs/attacks.md, decision 0052).
-- An army leaves the reserve at departure and travels like a scout (relative
-- clock, first copy of an order (sender, op) wins, decision 0050). On arrival
-- the first able client (the garrison keeper, then the attacker, then anyone
-- who knows the order) applies the deterministic 0047 formula to its current
-- garrison and announces the full resulting state in AR. Receivers never apply
-- a delta from a message: the state goes through the garrison order (decision
-- 0049), and the battle is marked done once per order key. An order is bound
-- to the target's owner generation: a capture during the march cancels it.
-- Values from the V1 balance sheet (decision 0047, tools/balance_sim.py).
local ASSAULT_MIN = 8
local ASSAULT_MAX = 20
local COUNTER_WFT = 30
local BEATS = { FOOTMAN = "MORTAR", MORTAR = "RIFLEMAN", RIFLEMAN = "FOOTMAN" }
local UNIT_ORDER = { "FOOTMAN", "RIFLEMAN", "MORTAR" }
local FIELDS = { FOOTMAN = "f", RIFLEMAN = "r", MORTAR = "m" }
local LOCK_MAX = 1200
-- A Settlement battle that kills a defender locks unit pledges for a fixed
-- five minutes, refreshed by later damaging battles, never added (0082).
local SIEGE_LOCK = 300
local FINAL_APPROACH = 120
local FACTIONS = { H = true, A = true }
local FACTION_NAMES = { H = "Horde", A = "Alliance" }
local ORIGIN_TYPES = { OUTPOST = true, SETTLEMENT = true, CAPITAL = true }
local MAX_RECORDS = 128
local MAX_PER_OWNER = 4
local MAX_OP = 1000000000
-- The target's capture generation, bounded as in S lines (decision 0089).
local MAX_GENERATION = 999999999
local MAX_NUMBER = 1000000
local MAX_UNITS = 50
local MAX_IDENTITY = 64
local OTHER_CONTINENT = 900
-- Wire bound of an order's War Camp count (decision 0123 § 5); the real bound
-- is the destination continent's catalog total (Scout:OrderTravel).
local MAX_HELD = 999
-- A pending battle lives 24 h after its arrival; a finished one 1 h, so a
-- newcomer's catch-up still learns it is done.
local PENDING_LIFE = 86400
local DONE_LIFE = 3600
-- The owner repeats its order once, and asks for the target's garrison
-- shortly before arrival so every resolver works on a fresh state.
local REPEAT_AFTER = 10
local QUERY_BEFORE = 30
-- Resolver slots after arrival: keeper, attacker, anyone else (plus a random
-- spread), never before catch-up had time to answer after loading.
local SLOT_OWNER = 3
local SLOT_OTHER = 5
local SLOT_SPREAD = 10
local LOAD_WAIT = 20
-- A battle result for an order that has not arrived yet on our clock.
local EARLY_TOLERANCE = 30
-- Catch-up, as scouting (rule R14, rule R13).
local QUERY_DELAY = 14
local QUERY_GAP = 60
-- Our battle on a provisional target (decision 0067): ask again each minute
-- after arrival, 5 times at most per session.
local PENDING_ASK = 60
local PENDING_ASKS = 5
local REPLY_MIN = 0.5
local REPLY_SPREAD = 2.5
local REPLY_MATCHES = 2
local REPLY_ANY = 4
local SEND_GAP = 1
local QUEUE_ROOM = 4
-- Addressed catch-up (decision 0077 § 5f): outside the channel and the group,
-- the same request goes by whisper to ADDRESSED_TARGETS guild peers or
-- contacts (modules/transport.lua), and a whispered request is answered to its
-- asker alone, without the R14 cancellation nobody else could hear: at most
-- ADDRESSED_LINES records per asker, once per minute per asker
-- (Transport:MayAnswer), one line per second through the same queue room.
local ADDRESSED_TARGETS, ADDRESSED_LINES, ADDRESSED_MAX = 2, 16, 48
local PRUNE_INTERVAL = 1
local SAVE_INTERVAL = 5
local SCHEMA = 1
local MAX_LEVELS = 3

Attack.ASSAULT = { min = ASSAULT_MIN, max = ASSAULT_MAX }
Attack.COUNTER_WFT = COUNTER_WFT
Attack.LOCK_MAX = LOCK_MAX
Attack.FINAL_APPROACH = FINAL_APPROACH
Attack.UNIT_ORDER = UNIT_ORDER
Attack.FIELDS = FIELDS

local function Now()
  local now = WF.Now and WF.Now() or 0
  if type(now) ~= "number" then return 0 end
  return now
end

-- Wall clock, only to age the records saved across a restart (never on the wire).
local function Wall()
  local wall = WF.Epoch and WF.Epoch() or 0
  if type(wall) ~= "number" then return 0 end
  return wall
end

local function Floor(value)
  return math.floor(value + 0.0000001)
end

local function Record(kind, fields)
  if WF.Record then WF.Record(kind, fields) end
end

local function Print(text)
  if WF.Print then WF.Print(text) end
end

local function Alert(category, text, options)
  if WF.Alerts and WF.Alerts.Push then WF.Alerts:Push(category, text, options) else Print(text) end
end

local function Int(text, maximum)
  if type(text) ~= "string" or not string.find(text, "^%d+$") or #text > 10 then
    return nil
  end
  local value = tonumber(text)
  if not value or value > maximum then return nil end
  return value
end

local function Me()
  return WF.Capture and WF.Capture:Me()
end

local function MyFaction()
  return WF.Capture and WF.Capture:MyFaction()
end

local function Realm()
  local fn = getglobal and getglobal("GetRealmName") or (_G and _G.GetRealmName)
  local ok, realm = false, nil
  if type(fn) == "function" then ok, realm = pcall(fn) end
  if ok and type(realm) == "string" and realm ~= "" then return realm end
  return "unknown"
end

local function Clock(seconds)
  if WF.Scout and WF.Scout.Clock then return WF.Scout.Clock(seconds) end
  return tostring(Floor(math.max(0, seconds))) .. "s"
end

local function Area(id)
  local map = WF.Map
  local area = map and type(id) == "string" and map.areas[id] or nil
  if area and area.enabled then return area end
  return nil
end

function Attack:Target(id)
  return WF.Scout and WF.Scout:Target(id)
end

function Attack:Label(id)
  if WF.Scout and WF.Scout.Label then return WF.Scout:Label(id) end
  return tostring(id)
end

local function UnitName(key, fac)
  return WF.Army:Name(key, fac)
end

-- "4 Footman, 2 Rifleman" with the names of faction fac; only non-zero counts.
local function Composition(counts, fac)
  local parts = {}
  for index = 1, #UNIT_ORDER do
    local key = UNIT_ORDER[index]
    local n = counts[FIELDS[key]] or 0
    if n > 0 then parts[#parts + 1] = n .. " " .. UnitName(key, fac) end
  end
  if #parts == 0 then return "nothing" end
  return table.concat(parts, ", ")
end

Attack.Composition = Composition

Attack.Composition = Composition

-- Combat (decision 0047) ----------------------------------------------------

local function Mult(attacker, defender)
  if BEATS[attacker] == defender then return 100 + COUNTER_WFT end
  if BEATS[defender] == attacker then return 100 - COUNTER_WFT end
  return 100
end

-- Defender losses of one attack, in whole units; army and garrison carry the
-- counts f, r, m. Integer arithmetic, the same as resolve() in
-- tools/balance_sim.py: each attacking type spreads ATK x count over the
-- defender types in proportion to their DEF power, times the counter
-- multiplier; a type loses floor(damage / DEF); pooled leftovers kill whole
-- units, largest leftover first, then table order.
function Attack.Resolve(army, garrison)
  local units = WF.Army.UNITS
  local kills = { f = 0, r = 0, m = 0 }
  local power, total = {}, 0
  local index = 1
  for index = 1, #UNIT_ORDER do
    local d = UNIT_ORDER[index]
    power[d] = garrison[FIELDS[d]] * units[d].def
    total = total + power[d]
  end
  if total == 0 then return kills end
  local rem, pool = {}, 0
  index = 1
  for index = 1, #UNIT_ORDER do
    local d = UNIT_ORDER[index]
    local acc = 0
    for inner = 1, #UNIT_ORDER do
      local a = UNIT_ORDER[inner]
      acc = acc + army[FIELDS[a]] * units[a].atk * Mult(a, d) * power[d]
    end
    local damage = math.floor(acc / (100 * total))
    local n, def = garrison[FIELDS[d]], units[d].def
    local k = 0
    if n > 0 then k = math.min(n, math.floor(damage / def)) end
    kills[FIELDS[d]] = k
    rem[d] = damage - k * def
    pool = pool + rem[d]
  end
  while true do
    local best
    index = 1
    for index = 1, #UNIT_ORDER do
      local d = UNIT_ORDER[index]
      if garrison[FIELDS[d]] > kills[FIELDS[d]] and units[d].def <= pool
        and (not best or rem[d] > rem[best]) then
        best = d
      end
    end
    if not best then break end
    kills[FIELDS[best]] = kills[FIELDS[best]] + 1
    pool = pool - units[best].def
    rem[best] = -1
  end
  return kills
end

-- Post-combat lock in seconds from the attack's raw ATK (decision 0047):
-- 1200 x min(P, ref) / ref, ref = the best ATK per Unit Size filling the
-- highest Assault Capacity. Applied only when a defender died.
function Attack.LockSeconds(army)
  local units = WF.Army.UNITS
  local best
  local power = 0
  for index = 1, #UNIT_ORDER do
    local key = UNIT_ORDER[index]
    local u = units[key]
    if not best or u.atk * best.size > best.atk * u.size then best = u end
    power = power + army[FIELDS[key]] * u.atk
  end
  local ref = math.floor(ASSAULT_MAX * best.atk / best.size)
  return math.floor(LOCK_MAX * math.min(power, ref) / ref)
end

-- The lock a battle with kills sets: five minutes on a Settlement (decision
-- 0082), the proportional lock on an Outpost; none without a kill.
function Attack.LockFor(r, kills)
  if kills.f + kills.r + kills.m <= 0 then return 0 end
  local area = WF.Map and WF.Map.areas and WF.Map.areas[r.target]
  if area and area.type == "SETTLEMENT" then return SIEGE_LOCK end
  return Attack.LockSeconds(r)
end

local function ISqrt(n)
  local root = math.floor(math.sqrt(n))
  while root * root > n do root = root - 1 end
  while (root + 1) * (root + 1) <= n do root = root + 1 end
  return root
end

-- Assault Capacity of faction fac from its share of the catalog's
-- Settlements (decision 0047): 8 + isqrt(144 x owned / total), 8 to 20.
function Attack:AssaultCapacity(fac)
  local owned, total = 0, 0
  local map = WF.Map
  for id, area in pairs(map and map.areas or {}) do
    if type(area) == "table" and area.enabled and area.type == "SETTLEMENT" then
      total = total + 1
      if WF.Capture:GetOwner(id) == fac then owned = owned + 1 end
    end
  end
  if total == 0 then return ASSAULT_MIN end
  local span = ASSAULT_MAX - ASSAULT_MIN
  return ASSAULT_MIN + ISqrt(math.floor(span * span * owned / total))
end

local function Size(army)
  local units = WF.Army.UNITS
  return army.f * units.FOOTMAN.size + army.r * units.RIFLEMAN.size + army.m * units.MORTAR.size
end

Attack.Size = Size

-- Records -------------------------------------------------------------------

local function Arrival(r)
  return r.depart + r.dur
end

-- The local player's attack still active: marching, or arrived and waiting
-- for its battle, at the target's current generation.
function Attack:Mine(now)
  local me = Me()
  if not me then return nil end
  for key, r in pairs(self.records) do
    if r.owner == me and not r.done then
      local _, generation = WF.Capture:TargetOwner(r.target, now)
      if r.gen >= generation then return r end
    end
  end
  return nil
end

-- Why units cannot be pledged to garrison id right now (decision 0052), or
-- nil: the post-combat lock, an enemy army in its last two minutes of march,
-- or a battle waiting to be resolved. The War Chest ignores this.
function Attack:Freeze(id, now)
  now = now or Now()
  local garrison = WF.Garrison
  local st = garrison and garrison.states[id]
  if st and st.lockEnd and st.lockEnd > now then
    return "reinforcements are locked after a battle (" .. Clock(st.lockEnd - now) .. " left)"
  end
  local owner, generation = WF.Capture:GetOwner(id)
  local soonest
  for key, r in pairs(self.records) do
    if r.target == id and not r.done and r.gen == generation and r.fac ~= owner then
      local left = Arrival(r) - now
      if left <= FINAL_APPROACH and (not soonest or left < soonest) then soonest = left end
    end
  end
  if not soonest then return nil end
  if soonest <= 0 then return "a battle here is waiting to be resolved" end
  return "an enemy army arrives in " .. Clock(soonest)
end

-- Arrived battles of target not yet resolved, at generation, in total order:
-- arrival, then key (the same order everywhere).
function Attack:Due(target, generation, now)
  local list = {}
  for key, r in pairs(self.records) do
    if r.target == target and not r.done and r.gen == generation and Arrival(r) <= now then
      list[#list + 1] = r
    end
  end
  table.sort(list, function(a, b)
    if Arrival(a) ~= Arrival(b) then return Arrival(a) < Arrival(b) end
    return a.key < b.key
  end)
  return list
end

function Attack:Remove(key)
  if self.records[key] then
    self.records[key] = nil
    self.count = self.count - 1
    self.dirty = true
  end
end

-- Drops what can no longer matter: an order whose target changed hands (the
-- attack is cancelled, its units lost), a finished battle 1 h after arrival,
-- a pending one after 24 h.
function Attack:Prune(now)
  local me = Me()
  for key, r in pairs(self.records) do
    local _, generation = WF.Capture:TargetOwner(r.target, now)
    if r.gen < generation then
      if r.owner == me and not r.done then
        Alert("orders", "Your attack on " .. self:Label(r.target)
          .. " is cancelled: the place changed hands during the march; the units are lost",
          { title = "Order cancelled", side = MyFaction(), sound = true })
      end
      Record("ATTACK_CANCELLED", { owner = r.owner, op = r.op, target = r.target, gen = r.gen })
      self:Remove(key)
    elseif r.done and now >= Arrival(r) + DONE_LIFE then
      self:Remove(key)
    elseif not r.done and now >= Arrival(r) + PENDING_LIFE then
      if r.owner == me then
        Alert("orders", "Your attack on " .. self:Label(r.target)
          .. " was never resolved and is dropped; the units are lost",
          { title = "Order expired", side = MyFaction(), sound = true })
      end
      Record("ATTACK_EXPIRED", { owner = r.owner, op = r.op, target = r.target })
      self:Remove(key)
    end
  end
end

-- Room for one more record (rule R9): a cancelled or finished record first,
-- else the oldest departure that is not the local player's own.
function Attack:MakeRoom(now)
  if self.count < MAX_RECORDS then return true end
  self:Prune(now)
  if self.count < MAX_RECORDS then return true end
  local me = Me()
  local victim
  for key, r in pairs(self.records) do
    if r.owner ~= me then
      if not victim or (r.done and not victim.done)
        or (r.done == victim.done and r.depart < victim.depart) then
        victim = r
      end
    end
  end
  if not victim then return false end
  self:Remove(victim.key)
  return true
end

-- Tells the defenders an enemy army is on its way (once per order).
function Attack:Warn(r, now)
  if r.warned then return end
  r.warned = true
  local owner = WF.Capture:GetOwner(r.target)
  local faction = MyFaction()
  if not faction or owner ~= faction or r.fac == faction or Arrival(r) <= now then return end
  Alert("armies", "Enemy army marching on " .. self:Label(r.target) .. ", arrives in "
    .. Clock(Arrival(r) - now), { title = "Enemy army incoming", side = r.fac, sound = true })
end

-- Learns one attack order. The first copy known fixes its local departure;
-- later copies change nothing (rule R8), except that a record learned from a
-- relay or restored after a restart takes a relayed "done" (a client that saw
-- the order itself while online also sees its battle). Returns the record,
-- and whether it was new.
function Attack:Learn(owner, f, direct, now)
  local key = owner .. "#" .. f.op
  local r = self.records[key]
  if r then
    if direct then r.direct = true end
    if f.done and not r.done and not r.direct then
      r.done = true
      self.dirty = true
    elseif f.done and not r.done then
      -- A provisional target has no local garrison to resolve on: a relayed
      -- done is the only way this order ends here (decision 0067).
      local _, _, confirmed = WF.Capture:TargetOwner(r.target, now)
      if not confirmed then self:Done(r, nil, nil, now) end
    end
    return r, false
  end
  local depart = now - f.el
  local arrival = depart + f.dur
  if f.done and now >= arrival + DONE_LIFE then return nil, false end
  if not f.done and now >= arrival + PENDING_LIFE then return nil, false end
  local _, generation = WF.Capture:TargetOwner(f.target, now)
  if f.gen < generation then return nil, false end
  local mine = 0
  for other, rec in pairs(self.records) do
    if rec.owner == owner then mine = mine + 1 end
  end
  if mine >= MAX_PER_OWNER and owner ~= Me() then return nil, false end
  if not self:MakeRoom(now) then return nil, false end
  r = {
    key = key, owner = owner, op = f.op, target = f.target, origin = f.origin, gen = f.gen,
    dur = f.dur, fac = f.fac, held = f.held or 0, f = f.f, r = f.r, m = f.m, depart = depart, direct = direct,
    done = f.done or nil, spread = math.random() * SLOT_SPREAD,
  }
  self.records[key] = r
  self.count = self.count + 1
  self.dirty = true
  Record("ATTACK_SEEN", { owner = owner, op = f.op, target = f.target, fac = f.fac, el = f.el, direct = direct })
  self:Warn(r, now)
  return r, true
end

-- Sending -------------------------------------------------------------------

function Attack:Send(kind, body, key, priority)
  if not WF.Capture then return false end
  local ok = WF.Capture:Send(kind, body, key, priority)
  if ok then self.sent = self.sent + 1 end
  return ok
end

local function Body(r, now)
  return r.target .. "," .. r.origin .. "," .. r.op .. "," .. r.gen .. "," .. r.dur .. ","
    .. Floor(math.max(0, now - r.depart)) .. "," .. r.fac .. "," .. r.f .. "," .. r.r .. "," .. r.m
    .. "," .. (r.held or 0)
end

-- AC <target>,<origin>,<op>,<gen>,<dur>,<elapsed>,<fac>,<f>,<r>,<m>,<held>: the
-- owner's order, an event, never replaced (rule R12). held is the War Camp
-- count of the order's faction on the destination continent at departure
-- (decision 0123 § 5).
function Attack:SendOrder(r, now)
  return self:Send("AC", Body(r, now), nil, true)
end

-- AR <target>,<gen>,<ver>,<epoch>,<f>,<r>,<m>,<gold>,<wood>,<lock>,<kf>,<kr>,<km>,<op>,<owner>:
-- the garrison after a battle, an event (rule R12).
function Attack:SendResult(r, st, now)
  local lock = WF.Garrison:LockLeft(st, now)
  local k = r.kills
  return self:Send("AR", st.id .. "," .. st.gen .. "," .. st.ver .. "," .. st.epoch .. "," .. st.f .. ","
    .. st.r .. "," .. st.m .. "," .. st.gold .. "," .. st.wood .. "," .. lock .. "," .. k.f .. "," .. k.r .. ","
    .. k.m .. "," .. r.op .. "," .. r.owner, nil, true)
end

-- Checks an attack toward targetId with army { f, r, m } from where the
-- player stands. Returns origin, target, duration, generation or nil, reason.
function Attack:Check(targetId, army, now)
  now = now or Now()
  local reserve = WF.Army and WF.Army:Reserve()
  if not reserve then return nil, "no saved data or identity yet" end
  local fac = MyFaction()
  local total = 0
  for index = 1, #UNIT_ORDER do
    local key = UNIT_ORDER[index]
    local n = army[FIELDS[key]]
    if type(n) ~= "number" or n < 0 or math.floor(n) ~= n then return nil, "unit counts must be whole numbers" end
    if n > reserve[key] then return nil, "you have only " .. reserve[key] .. " " .. UnitName(key, fac) end
    total = total + n
  end
  if total < 1 then return nil, "choose at least one combat unit" end
  local talk, lockReason = WF.Capture:CanTalk()
  if not talk then return nil, lockReason or "you cannot take part in the conquest yet" end
  local mine = self:Mine(now)
  if mine then
    if Arrival(mine) > now then return nil, "your army is still marching (" .. Clock(Arrival(mine) - now) .. " left)" end
    return nil, "your last attack is waiting for its battle"
  end
  local origin, why = WF.Army:DeparturePlace()
  if not origin then return nil, why end
  local target = self:Target(targetId)
  if not target then return nil, "only an Outpost or a Settlement can be attacked" end
  local owner, generation = WF.Capture:TargetOwner(target.id, now)
  if not FACTIONS[owner or ""] or owner == fac then
    return nil, "only a place held by the enemy faction can be attacked"
  end
  -- A Settlement only during its three-hour siege (decision 0082); checked
  -- when the order leaves, like the discovery, never on arrival (0098).
  if target.type == "SETTLEMENT" and WF.Front and WF.Front:HasRoutes()
      and not WF.Front:SiegeOpen(target.id, fac, now) then
    return nil, "a Settlement can only be attacked during its siege"
  end
  if not WF.Scout:Discovery(target.id, fac, now) then
    return nil, "scout it first: an attack needs an active discovery of the target"
  end
  local capacity = self:AssaultCapacity(fac)
  local size = Size(army)
  if size > capacity then
    return nil, "army too large: " .. size .. " Unit Size, your Assault Capacity is " .. capacity
  end
  local duration, held = WF.Scout:DepartureTravel(origin, target, fac)
  if not duration then return nil, "no travel data for this map" end
  return origin, target, duration, generation, held
end

-- Sends the player's army: its units leave the reserve at once and for good.
-- op is the reserve's attack number, so a repeated request does nothing (as
-- recruitment). Returns true, record or false, reason.
function Attack:Launch(targetId, army, op)
  local now = Now()
  local origin, target, duration, generation, held = self:Check(targetId, army, now)
  if not origin then return false, target end
  local reserve = WF.Army:Reserve()
  if op ~= reserve.aop then return false, "request already done or out of date" end
  local me = Me()
  local f = {
    target = target.id, origin = origin.id, op = reserve.aop + 1, gen = generation, dur = duration,
    el = 0, fac = MyFaction(), f = army.f, r = army.r, m = army.m, held = held,
  }
  if self.records[me .. "#" .. f.op] then return false, "request already done or out of date" end
  local r = self:Learn(me, f, true, now)
  if not r then return false, "too many attacks known" end
  reserve.FOOTMAN = reserve.FOOTMAN - army.f
  reserve.RIFLEMAN = reserve.RIFLEMAN - army.r
  reserve.MORTAR = reserve.MORTAR - army.m
  reserve.aop = f.op
  -- War effort (decision 0088): units sent in a valid attack, except units a
  -- campaign end gave back after they were counted (decision 0126 § 5).
  if WF.WarRecord then
    local armyApi = WF.Army
    local function Credit(kind, n)
      if n > 0 and type(armyApi.TakeUncredited) == "function" then n = n - armyApi:TakeUncredited(kind, n) end
      if n > 0 then WF.WarRecord:Add("attack", kind, n) end
    end
    Credit("FOOTMAN", army.f)
    Credit("RIFLEMAN", army.r)
    Credit("MORTAR", army.m)
  end
  r.repeatAt = now + REPEAT_AFTER
  r.queryAt = Arrival(r) - QUERY_BEFORE
  self:SendOrder(r, now)
  Record("ATTACK_SENT", { target = f.target, origin = f.origin, op = f.op, gen = f.gen, dur = f.dur,
    f = f.f, r = f.r, m = f.m })
  return true, r
end

-- /wf attack [<POI id> <footmen> [riflemen] [mortars]]
function Attack:Command(text)
  local words = {}
  local position = 1
  while true do
    local first, last, word = string.find(text or "", "(%S+)", position)
    if not first then break end
    words[#words + 1] = word
    position = last + 1
  end
  if #words == 0 then
    self:PrintStatus()
    return false
  end
  local id = string.upper(words[1])
  local army = {
    f = tonumber(words[2] or "0"), r = tonumber(words[3] or "0"), m = tonumber(words[4] or "0"),
  }
  if #words < 2 or #words > 4 or not army.f or not army.r or not army.m then
    Print("usage: /wf attack <POI id> <footmen> [riflemen] [mortars]")
    return false
  end
  local reserve = WF.Army and WF.Army:Reserve()
  local ok, result = self:Launch(id, army, reserve and reserve.aop)
  if not ok then
    Print("attack refused: " .. tostring(result))
    return false
  end
  Alert("orders", "Army of " .. Composition(result, result.fac) .. " sent to " .. self:Label(id)
    .. ", arrives in " .. Clock(result.dur) .. "; the units are gone for good",
    { title = "Order sent", side = result.fac })
  return true
end

-- Battles ---------------------------------------------------------------------

-- Marks a battle done once per order key and tells the players concerned:
-- the attacker's faction and the defenders. The enemy never sees the
-- attacking composition.
function Attack:Done(r, kills, lock, now)
  if r.done then return false end
  r.done = true
  r.kills = kills
  r.lock = lock
  self.dirty = true
  local faction = MyFaction()
  local owner = WF.Capture:TargetOwner(r.target, now)
  if faction and (r.fac == faction or owner == faction) then
    local text = "Battle at " .. self:Label(r.target) .. ": " .. (FACTION_NAMES[r.fac] or "enemy") .. " attack"
    if kills and kills.f + kills.r + kills.m > 0 then
      text = text .. " killed " .. Composition(kills, owner) .. "; reinforcements locked " .. Clock(lock or 0)
    elseif kills then
      text = text .. " killed nobody"
    else
      text = text .. " resolved by another player"
    end
    Alert("battles", text, { title = "Battle resolved", side = r.fac })
  end
  Record("ATTACK_RESOLVED", { owner = r.owner, op = r.op, target = r.target, lock = lock,
    kf = kills and kills.f, kr = kills and kills.r, km = kills and kills.m })
  return true
end

-- Resolves one battle on the current garrison and announces the new state.
function Attack:ResolveOne(r, st, now)
  local kills = Attack.Resolve(r, st)
  local lock = Attack.LockFor(r, kills)
  WF.Garrison:ApplyBattle(st, kills, lock, now)
  self:Done(r, kills, lock, now)
  self:SendResult(r, st, now)
end

-- Resolves the due battles of upto's target in total order, up to upto: each
-- one on the previous result, so the same losses are never applied twice.
function Attack:ResolveTarget(upto, now)
  local st = WF.Garrison:GetState(upto.target)
  if st.gen ~= upto.gen or not FACTIONS[st.owner or ""] then return end
  local list = self:Due(upto.target, st.gen, now)
  local index = 1
  while index <= #list do
    local r = list[index]
    if r.fac ~= st.owner then self:ResolveOne(r, st, now) end
    if r == upto then break end
    index = index + 1
  end
end

-- When this client resolves r (local clock): the keeper at arrival, the
-- attacker 3 s later, anyone else 5 to 15 s later; never before catch-up had
-- time to answer after loading.
function Attack:Slot(r, now)
  local arrival = Arrival(r)
  local me = Me()
  local slot
  local st = WF.Garrison.states[r.target]
  if st and me and st.authority == me and WF.Garrison:KeeperAlive(st, now) then
    slot = arrival
  elseif r.owner == me then
    slot = arrival + SLOT_OWNER
  else
    slot = arrival + SLOT_OTHER + (r.spread or 0)
  end
  local ready = (self.loadedAt or now) + LOAD_WAIT
  if slot < ready then slot = ready end
  return slot
end

function Attack:Resolver(now)
  if not WF.Garrison or not WF.Capture:CanTalk() then return end
  local due = {}
  local key, r
  for key, r in pairs(self.records) do
    if not r.done and Arrival(r) <= now and now >= self:Slot(r, now) then due[#due + 1] = r end
  end
  table.sort(due, function(a, b)
    if Arrival(a) ~= Arrival(b) then return Arrival(a) < Arrival(b) end
    return a.key < b.key
  end)
  for index = 1, #due do
    local r = due[index]
    if not r.done then
      local _, generation = WF.Capture:GetOwner(r.target)
      if r.gen == generation then self:ResolveTarget(r, now) end
    end
  end
end

-- Reception -----------------------------------------------------------------

function Attack:Reject(reason, sender)
  return WF.Capture:Reject(reason, sender)
end

-- Fields shared by AC and AL, strictly checked (rule R2). The duration is
-- recomputed from the order's own held count (decision 0123 § 5).
function Attack:Parse(parts, maxElapsed)
  local f = {
    target = parts[1], origin = parts[2],
    op = Int(parts[3], MAX_OP), gen = Int(parts[4], MAX_GENERATION), dur = Int(parts[5], OTHER_CONTINENT),
    fac = parts[7], f = Int(parts[8], ASSAULT_MAX), r = Int(parts[9], ASSAULT_MAX), m = Int(parts[10], ASSAULT_MAX),
    held = Int(parts[11], MAX_HELD),
  }
  if not f.op or not f.gen or not f.dur or f.op < 1 then return nil, "bad attack number" end
  if not f.held then return nil, "bad attack network" end
  if not f.f or not f.r or not f.m then return nil, "bad attack composition" end
  local size = Size(f)
  if f.f + f.r + f.m < 1 or size > ASSAULT_MAX then return nil, "bad attack composition" end
  f.el = Int(parts[6], f.dur + (maxElapsed or 0))
  if not f.el then return nil, "bad attack elapsed time" end
  if not FACTIONS[f.fac or ""] then return nil, "bad attack faction" end
  local target, origin = self:Target(f.target), Area(f.origin)
  if not target then return nil, "unknown attack target" end
  if not origin or not ORIGIN_TYPES[origin.type] or origin.id == target.id then
    return nil, "bad attack origin"
  end
  local expected = WF.Scout:OrderTravel(origin, target, f.held)
  if not expected then return nil, "bad attack network" end
  if expected ~= f.dur then return nil, "bad attack duration" end
  return f
end

local function ValidOwner(text)
  return type(text) == "string" and #text <= MAX_IDENTITY and WF.Names
    and WF.Names.Valid(text) and WF.Names.Complete(text)
end

-- Saved level-6 records written before decision 0096 still carry @realm. They
-- are local data, so strip that suffix once while loading; current wire data is
-- required to use the realm-free identity.
local function SavedOwner(text)
  local owner = WF.Names and WF.Names.Short(text) or text
  if ValidOwner(owner) then return owner end
end

-- R14: our pending answer is cancelled after two other answers matching
-- what we know, or any four answers.
function Attack:SeeReply(sender, matches)
  if not self.replyAt and #self.out == 0 then return end
  self.replyAny = self.replyAny or {}
  self.replyMatch = self.replyMatch or {}
  self.replyAny[sender] = true
  if matches then self.replyMatch[sender] = true end
  local any, match = 0, 0
  for name in pairs(self.replyAny) do any = any + 1 end
  for name in pairs(self.replyMatch) do match = match + 1 end
  if match >= REPLY_MATCHES or any >= REPLY_ANY then
    self.replyAt, self.replyAny, self.replyMatch = nil, nil, nil
    self.out = {}
  end
end

-- AR: the garrison state goes through the garrison order whatever happens
-- (convergence, rule R6); the battle is marked done only for a known order of
-- that generation that has arrived, and only when the result matches what
-- this client computes from the same garrison version (or when this client
-- is behind and cannot check).
function Attack:ParseResult(parts)
  if #parts ~= 15 then return nil, "bad AR field count" end
  local garrison = WF.Garrison
  local area = self:Target(parts[1])
  if not area or not garrison then return nil, "unknown battle target" end
  local f, err = garrison:ParseState({ parts[1], parts[2], parts[3], parts[4], parts[5], parts[6], parts[7],
    parts[8], parts[9], parts[10], "0", "0000", "-", "1" }, area)
  if not f then return nil, err end
  local kills = { f = Int(parts[11], MAX_UNITS), r = Int(parts[12], MAX_UNITS), m = Int(parts[13], MAX_UNITS) }
  local op = Int(parts[14], MAX_OP)
  if not kills.f or not kills.r or not kills.m or not op or op < 1 then return nil, "bad AR number" end
  if not ValidOwner(parts[15]) then return nil, "bad AR owner" end
  return f, kills, op
end

function Attack:OnResult(parts, sender, now)
  local f, kills, op = self:ParseResult(parts)
  if not f then return self:Reject(kills, sender) end
  local garrison = WF.Garrison
  local r = self.records[parts[15] .. "#" .. op]
  if not r then
    -- An order we never learned: a plain relayed garrison state.
    return garrison:OfferBattle(sender, f, now, false)
  end
  if r.target ~= f.id or r.gen ~= f.gen then return self:Reject("battle result for another target", sender) end
  if Arrival(r) > now + EARLY_TOLERANCE then return self:Reject("early battle result", sender) end
  local owner, generation, confirmed = WF.Capture:TargetOwner(f.id, now)
  if not confirmed then
    -- Provisional target (decision 0067): no local garrison to check or
    -- adopt; the result only ends the known order here, once (rule R8).
    if generation ~= f.gen or owner == r.fac then return self:Reject("battle result for another target", sender) end
    if not r.done then
      self:Done(r, kills, Attack.LockFor(r, kills), now)
    end
    return true
  end
  local st = garrison:GetState(f.id)
  if not r.done and (f.ver == st.ver or f.ver == WF.Serial.NextCount(st.ver)) and st.gen == f.gen then
    local expect = Attack.Resolve(r, st)
    local any = expect.f + expect.r + expect.m > 0
    local ver = st.ver
    if any then ver = WF.Serial.NextCount(ver) end
    if f.ver ~= ver or f.f ~= st.f - expect.f or f.r ~= st.r - expect.r or f.m ~= st.m - expect.m
      or kills.f ~= expect.f or kills.r ~= expect.r or kills.m ~= expect.m then
      -- Built on another garrison version (a concurrent battle) or forged:
      -- not ours to adopt; our own slot resolves it on what we hold.
      return self:Reject("battle result mismatch", sender)
    end
  end
  local accepted = garrison:OfferBattle(sender, f, now, true)
  if accepted and not r.done then
    self:Done(r, kills, Attack.LockFor(r, kills), now)
  end
  return accepted
end

-- Routed by Capture:OnMessage after echo, identity and quota checks.
function Attack:OnMessage(kind, parts, sender, now)
  self.received = self.received + 1
  if kind == "AC" then
    if #parts ~= 11 then return self:Reject("bad AC field count", sender) end
    local f, err = self:Parse(parts, 0)
    if not f then return self:Reject(err, sender) end
    -- Identity: the chat sender, never a field (rule R1).
    self:Learn(sender, f, true, now)
    return true
  elseif kind == "AL" then
    -- A whispered answer ends our addressed rounds (decision 0077 § 5f).
    if WF.Capture and WF.Capture.addressedFrom then self.pullAnswered = true end
    if #parts ~= 13 then return self:Reject("bad AL field count", sender) end
    local f, err = self:Parse(parts, PENDING_LIFE)
    if not f then return self:Reject(err, sender) end
    if parts[12] ~= "0" and parts[12] ~= "1" then return self:Reject("bad AL done flag", sender) end
    if not ValidOwner(parts[13]) then return self:Reject("bad AL owner", sender) end
    f.done = parts[12] == "1"
    -- A relay about a third party (or us): data, never the relayer's identity.
    local r, new = self:Learn(parts[13], f, false, now)
    self:SeeReply(sender, r ~= nil and not new and (r.done or false) == f.done)
    return true
  elseif kind == "AQ" then
    if #parts ~= 1 or parts[1] ~= "*" then return self:Reject("bad AQ", sender) end
    local asker = WF.Capture and WF.Capture.addressedFrom
    if asker then
      local transport = WF.Transport
      if self.count > 0 and transport and type(transport.MayAnswer) == "function"
          and transport:MayAnswer("AQ", asker, now) then
        self:AnswerTo(asker, now)
      end
      return true
    end
    if self.count > 0 and not self.replyAt then
      self.replyAt = now + REPLY_MIN + math.random() * REPLY_SPREAD
      self.replyAny, self.replyMatch = nil, nil
    end
    return true
  elseif kind == "AR" then
    return self:OnResult(parts, sender, now)
  end
  return self:Reject("unknown kind", sender)
end

-- Channel join (modules/p2ptest.lua): one catch-up request a little later.
function Attack:OnJoined(now)
  now = now or Now()
  if self.askedAt and now - self.askedAt < QUERY_GAP then return false end
  self.askedAt = now
  self.queryAt = now + QUERY_DELAY
  return true
end

local function QueueRoom()
  local queue = WF.SendQueue
  if not queue or type(queue.Pending) ~= "function" then return true end
  return queue:Pending() < QUEUE_ROOM
end

local function RelayBody(r, now)
  return Body(r, now) .. "," .. (r.done and "1" or "0") .. "," .. r.owner
end

-- AL <...AC fields>,<done>,<owner>: one known attack, elapsed since its
-- departure; replaceable, dropped first (rule R13).
function Attack:Answer(now)
  self.replyAt = nil
  self.out = {}
  self:Prune(now)
  for key in pairs(self.records) do self.out[#self.out + 1] = key end
  table.sort(self.out)
end

-- A whispered AQ: our records to that asker alone (decision 0077 § 5f).
function Attack:AnswerTo(target, now)
  self:Prune(now)
  local keys = {}
  for key in pairs(self.records) do keys[#keys + 1] = key end
  table.sort(keys)
  for i = 1, math.min(#keys, ADDRESSED_LINES) do
    if #self.addressedOut >= ADDRESSED_MAX then break end
    self.addressedOut[#self.addressedOut + 1] = { key = keys[i], target = target }
  end
end

-- The same request whispered to a few guild peers or contacts (decision 0077
-- § 5f); at most once per QUERY_GAP.
function Attack:PullAddressed(now)
  now = now or Now()
  if self.pulledAt and now - self.pulledAt < QUERY_GAP then return false end
  if self.pullAnswered then return false end
  local transport, capture = WF.Transport, WF.Capture
  if not transport or type(transport.PullTargets) ~= "function" or not capture
      or type(capture.SendTo) ~= "function" then
    return false
  end
  local targets = transport:PullTargets(ADDRESSED_TARGETS, now)
  if #targets == 0 then return false end
  self.pulledAt = now
  local sent = 0
  for i = 1, #targets do
    if capture:SendTo(targets[i], "AQ", "*") then sent = sent + 1 end
  end
  self.pulls = (self.pulls or 0) + sent
  return sent > 0
end

-- Driver --------------------------------------------------------------------

function Attack:Tick(now)
  if not self.loaded then self:Load(now) end
  if not self.loaded then return end
  if self.queryAt and now >= self.queryAt then
    self.queryAt = nil
    self:Send("AQ", "*")
    self:PullAddressed(now)
  end
  if self.replyAt and now >= self.replyAt then self:Answer(now) end
  if #self.out > 0 and now >= (self.nextSendAt or 0) and QueueRoom() then
    local key = table.remove(self.out, 1)
    local r = self.records[key]
    -- Rebuilt at send time so the elapsed time stays current (risk B10).
    if r and self:Send("AL", RelayBody(r, now), "AL," .. key) then
      self.answers = (self.answers or 0) + 1
    end
    self.nextSendAt = now + SEND_GAP
  elseif #self.addressedOut > 0 and now >= (self.nextSendAt or 0) and QueueRoom() then
    local line = table.remove(self.addressedOut, 1)
    local r = self.records[line.key]
    if r and WF.Capture and WF.Capture:SendTo(line.target, "AL", RelayBody(r, now), "AL:" .. line.target .. ":" .. line.key) then
      self.answers = (self.answers or 0) + 1
    end
    self.nextSendAt = now + SEND_GAP
  end
  local mine = self:Mine(now)
  if mine and mine.repeatAt and now >= mine.repeatAt then
    mine.repeatAt = nil
    self:SendOrder(mine, now)
  end
  if mine and mine.queryAt and now >= mine.queryAt then
    mine.queryAt = nil
    if WF.Garrison then WF.Garrison:Send("GQ", mine.target) end
  end
  local faction = MyFaction()
  local states = WF.Garrison and WF.Garrison.states or {}
  for id, st in pairs(states) do
    local owner = WF.Capture and WF.Capture:GetOwner(id)
    if faction and owner == faction and st.lockEnd and st.lockEnd > now then
      self.lockAlerts[id] = st.lockEnd
    elseif self.lockAlerts[id] then
      if faction and owner == faction and self.lockAlerts[id] <= now then
        Alert("battles", "Reinforcements at " .. self:Label(id) .. " are available again.",
          { title = "Reinforcements available", side = faction })
      end
      self.lockAlerts[id] = nil
    end
  end
  if mine and Arrival(mine) <= now and (mine.asks or 0) < PENDING_ASKS
    and now >= Arrival(mine) + PENDING_ASK * ((mine.asks or 0) + 1) then
    local _, _, confirmed = WF.Capture:TargetOwner(mine.target, now)
    if not confirmed then
      -- The result may have been lost: the usual bounded catch-up (AQ).
      mine.asks = (mine.asks or 0) + 1
      self:OnJoined(now)
    end
  end
  if not self.lastPruneAt or now - self.lastPruneAt >= PRUNE_INTERVAL then
    self.lastPruneAt = now
    self:Prune(now)
  end
  self:Resolver(now)
  if self.dirty and (not self.lastSaveAt or now - self.lastSaveAt >= SAVE_INTERVAL) then
    self.lastSaveAt = now
    self:Save()
  end
end

-- Persistence ---------------------------------------------------------------

-- WarfrontDB.scopes[scope].attack = { schema, levels = {
-- [channel level] = { at = wall clock, records = { [key] = { owner, op,
-- target, origin, gen, dur, fac, f, r, m, el, done, kf, kr, km, lock } } } } } } }.
function Attack:Store()
  local storage = WF.Storage
  if not storage or type(storage.GetDB) ~= "function" or storage.readOnly then return nil end
  local db = storage:GetDB()
  if type(db) ~= "table" then return nil end
  -- This ruleset scope's table (decision 0072: the realm never partitions it);
  -- a newer schema belongs to a newer build: leave it untouched.
  local bucket = WF.Ruleset and WF.Ruleset:Module("attack")
  if not bucket then return nil end
  if type(bucket.schema) == "number" and bucket.schema > SCHEMA then return nil end
  bucket.schema = SCHEMA
  if type(bucket.levels) ~= "table" then bucket.levels = {} end
  local level = tonumber(WF.channelLevel) or 0
  if type(bucket.levels[level]) ~= "table" then
    bucket.levels[level] = {}
    -- Older levels stay archived, the oldest beyond MAX_LEVELS dropped.
    while true do
      local count, lowest = 0, nil
      for key in pairs(bucket.levels) do
        count = count + 1
        if not lowest or key < lowest then lowest = key end
      end
      if count <= MAX_LEVELS then break end
      bucket.levels[lowest] = nil
    end
  end
  local entry = bucket.levels[level]
  if type(entry.records) ~= "table" then entry.records = {} end
  return entry
end

-- Campaign end (decision 0102 § 4): attacks not yet resolved are cancelled and
-- this character's own units come back to its reserve, never truncated
-- (Army:Refund). Returns the units given back.
local REFUND_KEYS = { f = "FOOTMAN", r = "RIFLEMAN", m = "MORTAR" }

function Attack:ResetCampaign()
  local me, back = Me(), 0
  local entry = self:Store()
  if not entry then error("campaign refund: attack storage unavailable", 0) end
  -- Reset can run before Load, and Load deliberately ages out old orders.
  -- Read the saved originals here; a resolved result from either source wins.
  local records = {}
  if entry and not self.loaded then
    for _, r in pairs(entry.records) do
      local owner = type(r) == "table" and SavedOwner(r.owner)
      if owner and r.op then
        local key = owner .. "#" .. r.op
        local old = records[key]
        if not old or (r.done and not old.done) or (not old.done and r.owner == owner) then records[key] = r end
      end
    end
  end
  for _, r in pairs(self.records) do
    local key = r.owner .. "#" .. r.op
    if not records[key] or not records[key].done then records[key] = r end
  end
  local plans = {}
  if next(records) and (not me or not WF.Army or not WF.Army.PlanCampaignRefund) then
    error("campaign refund: army unavailable", 0)
  end
  if me and WF.Army then
    for _, r in pairs(records) do
      local owner = SavedOwner(r.owner)
      if owner and not r.done then
        local counts = {}
        for field, key in pairs(REFUND_KEYS) do counts[key] = r[field] or 0 end
        local plan = WF.Army:PlanCampaignRefund(owner, r.op, counts)
        if plan then
          plans[#plans + 1] = plan
          if owner == me then back = back + plan.count end
        end
      end
    end
  end
  -- All potentially failing work finished. Only plain table assignments follow.
  for index = 1, #plans do
    local plan = plans[index]
    for key, value in pairs(plan.values) do plan.reserve[key] = value end
    plan.reserve.overflow = plan.values.overflow
  end
  self.records, self.count = {}, 0
  self.out, self.addressedOut = {}, {}
  self.replyAt = nil
  if entry then entry.records = {} end
  self.dirty = nil
  return back
end

function Attack:Save()
  if not self.loaded then self:Load() end
  if not self.loaded then return end
  local entry = self:Store()
  if not entry then return end
  self.dirty = nil
  local now = Now()
  entry.at = Wall()
  entry.records = {}
  for key, r in pairs(self.records) do
    local saved = {
      owner = r.owner, op = r.op, target = r.target, origin = r.origin, gen = r.gen, dur = r.dur, fac = r.fac,
      held = r.held or 0,
      f = r.f, r = r.r, m = r.m, el = Floor(math.max(0, now - r.depart)), done = r.done and true or nil,
      lock = r.lock,
    }
    if r.kills then saved.kf, saved.kr, saved.km = r.kills.f, r.kills.r, r.kills.m end
    entry.records[key] = saved
  end
end

-- Restores the saved attacks, aged by the wall time spent offline; the same
-- checks as a received record.
function Attack:Load(now)
  now = now or Now()
  local entry = self:Store()
  if not entry then return end
  self.loadedAt = now
  local away = math.max(0, Wall() - (tonumber(entry.at) or Wall()))
  for key, saved in pairs(entry.records) do
    local owner = type(saved) == "table" and SavedOwner(saved.owner) or nil
    if owner then
      local el = (tonumber(saved.el) or 0) + away
      local parts = { tostring(saved.target), tostring(saved.origin), tostring(saved.op), tostring(saved.gen),
        tostring(saved.dur), tostring(Floor(math.min(el, (tonumber(saved.dur) or 0) + PENDING_LIFE))),
        -- Saved before decision 0123: no held count, an unreduced duration.
        tostring(saved.fac), tostring(saved.f), tostring(saved.r), tostring(saved.m), tostring(saved.held or 0) }
      local f = self:Parse(parts, PENDING_LIFE)
      if f then
        f.done = saved.done == true
        local r = self:Learn(owner, f, false, now)
        if r and r.done then
          r.warned = true
          if tonumber(saved.kf) and tonumber(saved.kr) and tonumber(saved.km) then
            r.kills = { f = tonumber(saved.kf), r = tonumber(saved.kr), m = tonumber(saved.km) }
          end
          r.lock = tonumber(saved.lock)
        end
      end
    end
  end
  self.dirty = nil
  self.loaded = true
end

-- Display -------------------------------------------------------------------

-- Armies still marching, for the map routes (modules/map.lua): records with
-- depart, dur, origin, target and fac, as scouts.
function Attack:Marching(now)
  local list = {}
  for key, r in pairs(self.records) do
    if not r.done and Arrival(r) > now then list[#list + 1] = r end
  end
  return list
end

-- Tooltip lines of an Outpost or Settlement: armies on their way (the exact
-- composition for one's own faction only), a battle waiting, the lock.
function Attack:TooltipInfo(id, now)
  if not self:Target(id) or not WF.Capture then return nil end
  now = now or Now()
  local faction = MyFaction()
  local _, generation = WF.Capture:TargetOwner(id, now)
  local info = {}
  for key, r in pairs(self.records) do
    if r.target == id and not r.done and r.gen == generation then
      if Arrival(r) <= now then
        info.pending = true
      elseif r.fac == faction then
        if not info.allied or Arrival(r) < info.allied.arrival then
          info.allied = { arrival = Arrival(r), left = Arrival(r) - now, army = Composition(r, r.fac),
            counts = { FOOTMAN = r.f or 0, RIFLEMAN = r.r or 0, MORTAR = r.m or 0 } }
        end
      elseif not info.enemy or Arrival(r) - now < info.enemy then
        info.enemy = Arrival(r) - now
      end
    end
  end
  local st = WF.Garrison and WF.Garrison.states[id]
  if st and st.lockEnd and st.lockEnd > now then info.locked = st.lockEnd - now end
  if not info.pending and not info.allied and not info.enemy and not info.locked then return nil end
  return info
end

-- Map tooltip of an army on its way: always the route and the time left; the
-- sender and the exact composition only for one's own faction (decision 0052).
function Attack:RouteInfo(r, now)
  if type(r) ~= "table" then return nil end
  now = now or Now()
  local allied = r.fac == MyFaction()
  return {
    allied = allied, owner = allied and r.owner or nil, left = Arrival(r) - now,
    from = WF.Scout:Name(r.origin), to = WF.Scout:Name(r.target),
    army = allied and Composition(r, r.fac) or nil,
  }
end

function Attack:PrintStatus()
  local now = Now()
  local fac = MyFaction()
  local reserve = WF.Army and WF.Army:Reserve()
  if not reserve then
    Print("no saved data or identity yet")
    return
  end
  Print("Assault Capacity " .. self:AssaultCapacity(fac) .. " Unit Size; reserve: "
    .. Composition({ f = reserve.FOOTMAN, r = reserve.RIFLEMAN, m = reserve.MORTAR }, fac))
  local mine = self:Mine(now)
  if mine then
    if Arrival(mine) > now then
      Print("your army (" .. Composition(mine, fac) .. ") arrives at " .. self:Label(mine.target) .. " in "
        .. Clock(Arrival(mine) - now))
    else
      Print("your attack on " .. self:Label(mine.target) .. " is waiting for its battle")
    end
  else
    Print("send an army: /wf attack <POI id> <footmen> [riflemen] [mortars], from an allied place, to a"
      .. " discovered enemy Outpost or Settlement")
  end
  for key, r in pairs(self.records) do
    if r.owner ~= Me() and not r.done then
      local owner = WF.Capture:GetOwner(r.target)
      local where = self:Label(r.target)
      local state = Arrival(r) > now and ("arrives in " .. Clock(Arrival(r) - now)) or "battle pending"
      if r.fac == fac then
        Print("allied army (" .. Composition(r, fac) .. ") toward " .. where .. ": " .. state)
      elseif owner == fac then
        Print("enemy army toward " .. where .. ": " .. state)
      end
    end
  end
end

if WF.RegisterEvent then
  -- Fires on logout, quit and /reload, before SavedVariables are written.
  WF.RegisterEvent("PLAYER_LOGOUT", function()
    if Attack.dirty then Attack:Save() end
  end)
end
