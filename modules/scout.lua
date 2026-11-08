Warfront = Warfront or {}

local WF = Warfront
local Scout = {
  records = {},
  count = 0,
  out = {},
  sent = 0,
  received = 0,
}

WF.Scout = Scout

-- Scouting (roadmap WP8, docs/scouting.md, decision 0050). A scout leaves the
-- reserve and travels from the allied POI the player stands in to an
-- enemy-held Outpost or Settlement; on arrival the target is discovered for
-- the scout's whole faction for one hour. No authority: every client derives
-- arrival and discovery from the order and its own owner registry. No
-- absolute time on the wire (rule R10): an order carries the seconds elapsed
-- since departure, each client anchors it on its own clock, and the first
-- copy known of a scout (sender, op) wins, so repeats and relays never move it.
-- Travel values from the V1 balance sheet (decision 0047, tools/balance_sim.py).
local TRAVEL_SPEED = 7
local SAME_ZONE_MIN = 180
local SAME_ZONE_MAX = 420
local SAME_CONTINENT = 480
local OTHER_CONTINENT = 900
local DISCOVERY = 3600
-- Zone sizes in yards (1.12 world map, not measured on OctoWoW) and continent,
-- by canonical map key (modules/map.lua). The same table as ZONE_YARDS in
-- tools/balance_sim.py; tools/smoke.py checks both stay equal.
local ZONES = {
  elwynn = { 3470.83, 2314.58, "EK" },
  westfall = { 4500.0, 3000.0, "EK" },
  durotar = { 5287.5, 3525.0, "KA" },
  barrens = { 10133.33, 6756.25, "KA" },
}
local TARGET_TYPES = { OUTPOST = "Outpost", SETTLEMENT = "Settlement" }
local ORIGIN_TYPES = { OUTPOST = true, SETTLEMENT = true, BARRACKS = true }
local FACTIONS = { H = true, A = true }
local MAX_RECORDS = 128
local MAX_PER_OWNER = 4
local MAX_OP = 1000000000
local MAX_GENERATION = 1000000
local MAX_IDENTITY = 64
-- The owner repeats its order once, in case the first copy was lost.
local REPEAT_AFTER = 10
-- Catch-up: one request per channel join (at most one per minute), answered
-- late and cancellably (rule R14), one record per second while the send
-- queue has room, so catch-up never delays a capture state (rule R13).
local QUERY_DELAY = 12
local QUERY_GAP = 60
local REPLY_MIN = 0.5
local REPLY_SPREAD = 2.5
local REPLY_MATCHES = 2
local REPLY_ANY = 4
local SEND_GAP = 1
local QUEUE_ROOM = 4
local PRUNE_INTERVAL = 1
local SAVE_INTERVAL = 5
local SCHEMA = 1
local MAX_LEVELS = 3

Scout.DISCOVERY = DISCOVERY
Scout.ZONES = ZONES
Scout.TRAVEL = {
  speed = TRAVEL_SPEED, sameZone = { SAME_ZONE_MIN, SAME_ZONE_MAX },
  sameContinent = SAME_CONTINENT, otherContinent = OTHER_CONTINENT,
}

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
  seconds = Floor(math.max(0, seconds))
  local minutes = Floor(seconds / 60)
  local rest = seconds - minutes * 60
  if rest < 10 then return minutes .. ":0" .. rest end
  return minutes .. ":" .. rest
end

Scout.Clock = Clock

-- Catalogue and travel ------------------------------------------------------

local function Area(id)
  local map = WF.Map
  local area = map and type(id) == "string" and map.areas[id] or nil
  if area and area.enabled then return area end
  return nil
end

function Scout:Target(id)
  local area = Area(id)
  if area and TARGET_TYPES[area.type] then return area end
  return nil
end

-- Travel time in whole seconds between two POIs, the same for scouts and
-- armies (decision 0047): same zone from the straight distance between the
-- map icons, 3 to 7 min; another zone of the continent 8 min; another
-- continent 15 min. Nil when a map has no known size.
function Scout:Travel(origin, target)
  local a = origin and ZONES[origin.mapKey or ""]
  local b = target and ZONES[target.mapKey or ""]
  if not a or not b then return nil end
  if a[3] ~= b[3] then return OTHER_CONTINENT end
  if origin.mapKey ~= target.mapKey then return SAME_CONTINENT end
  local position = WF.Map and WF.Map.IconPosition
  if not position then return nil end
  local ax, ay = position(origin)
  local bx, by = position(target)
  if not ax or not bx then return nil end
  local dx, dy = (ax - bx) * a[1], (ay - by) * a[2]
  local seconds = math.ceil(math.sqrt(dx * dx + dy * dy) / TRAVEL_SPEED - 0.0000001)
  if seconds < SAME_ZONE_MIN then return SAME_ZONE_MIN end
  if seconds > SAME_ZONE_MAX then return SAME_ZONE_MAX end
  return seconds
end

-- Records -------------------------------------------------------------------

local function Arrival(r)
  return r.depart + r.dur
end

-- Arrived scouts of one faction on one target at the target's current
-- generation, in arrival order (ties by key: the same order everywhere).
function Scout:Arrivals(target, fac, generation, now)
  local list = {}
  for key, r in pairs(self.records) do
    if r.target == target and r.fac == fac and r.gen == generation and Arrival(r) <= now then
      list[#list + 1] = r
    end
  end
  table.sort(list, function(a, b)
    if Arrival(a) ~= Arrival(b) then return Arrival(a) < Arrival(b) end
    return a.key < b.key
  end)
  return list
end

-- Discovery windows: the first arrival opens one hour; an arrival inside an
-- open window neither extends nor restarts it. Calls fn(r, start, finish)
-- for each arrived record with the window that holds it.
local function Windows(list, fn)
  local start, finish
  for index = 1, #list do
    local r = list[index]
    if not start or Arrival(r) >= finish then
      start, finish = Arrival(r), Arrival(r) + DISCOVERY
    end
    fn(r, start, finish)
  end
end

-- The open discovery of target for faction fac: start, finish or nil. Only a
-- POI held by the other faction is discovered; the generation binding ends
-- the discovery as soon as the POI changes hands.
function Scout:Discovery(target, fac, now)
  if not WF.Capture or not FACTIONS[fac or ""] then return nil end
  now = now or Now()
  local owner, generation = WF.Capture:TargetOwner(target, now)
  if not FACTIONS[owner or ""] or owner == fac then return nil end
  local start, finish
  Windows(self:Arrivals(target, fac, generation, now), function(r, s, f)
    start, finish = s, f
  end)
  if start and now < finish then return start, finish end
  return nil
end

-- A scout of faction fac still travelling to target (the soonest), or nil.
function Scout:Travelling(target, fac, now)
  local _, generation = WF.Capture:TargetOwner(target, now)
  local best
  for key, r in pairs(self.records) do
    if r.target == target and (not fac or r.fac == fac) and r.gen >= generation and Arrival(r) > now
      and (not best or Arrival(r) < Arrival(best)) then
      best = r
    end
  end
  return best
end

-- The local player's scout still travelling, or nil.
function Scout:Mine(now)
  local me = Me()
  if not me then return nil end
  for key, r in pairs(self.records) do
    if r.owner == me and Arrival(r) > now then return r end
  end
  return nil
end

-- Drops what can no longer matter: a scout bound to an older generation (its
-- target changed hands), the scouts of a window that has ended, then anything
-- older than a full discovery. Windows first: a window's opener and the
-- scouts it absorbed go together, so a later arrival never reopens the hour.
function Scout:Prune(now)
  local groups = {}
  for key, r in pairs(self.records) do
    local _, generation = WF.Capture:TargetOwner(r.target, now)
    if r.gen < generation then
      self:Remove(key)
    elseif r.gen == generation and Arrival(r) <= now then
      groups[r.target .. "#" .. r.fac] = { target = r.target, fac = r.fac, gen = generation }
    end
  end
  for key, g in pairs(groups) do
    Windows(self:Arrivals(g.target, g.fac, g.gen, now), function(rec, start, finish)
      if now >= finish then self:Remove(rec.key) end
    end)
  end
  for key, r in pairs(self.records) do
    if now >= Arrival(r) + DISCOVERY then self:Remove(key) end
  end
end

function Scout:Remove(key)
  if self.records[key] then
    self.records[key] = nil
    self.count = self.count - 1
    self.dirty = true
  end
end

-- Room for one more record: an ended or dead record first, else the oldest
-- departure that is not the local player's own (rule R9).
function Scout:MakeRoom(now)
  if self.count < MAX_RECORDS then return true end
  self:Prune(now)
  if self.count < MAX_RECORDS then return true end
  local me = Me()
  local oldest
  for key, r in pairs(self.records) do
    if r.owner ~= me and (not oldest or r.depart < oldest.depart) then oldest = r end
  end
  if not oldest then return false end
  self:Remove(oldest.key)
  return true
end

-- Learns one scout. The first copy known fixes its local departure; later
-- copies (repeats, relays, duplicates) change nothing (rule R8). Returns the
-- record, and whether it was new.
function Scout:Learn(owner, f, direct, now)
  local key = owner .. "#" .. f.op
  local r = self.records[key]
  if r then
    if direct then r.direct = true end
    return r, false
  end
  local depart = now - f.el
  if depart + f.dur + DISCOVERY <= now then return nil, false end
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
    dur = f.dur, fac = f.fac, depart = depart, direct = direct,
  }
  self.records[key] = r
  self.count = self.count + 1
  self.dirty = true
  Record("SCOUT_SEEN", { owner = owner, op = f.op, target = f.target, fac = f.fac, el = f.el, direct = direct })
  return r, true
end

-- Sending -------------------------------------------------------------------

function Scout:Send(kind, body, key, priority)
  if not WF.Capture then return false end
  local ok = WF.Capture:Send(kind, body, key, priority)
  if ok then self.sent = self.sent + 1 end
  return ok
end

local function Body(r, now)
  return r.target .. "," .. r.origin .. "," .. r.op .. "," .. r.gen .. "," .. r.dur .. ","
    .. Floor(math.max(0, now - r.depart)) .. "," .. r.fac
end

-- SC <target>,<origin>,<op>,<gen>,<dur>,<elapsed>,<fac>: the owner's order, an
-- event, never replaced (rule R12).
function Scout:SendOrder(r, now)
  return self:Send("SC", Body(r, now), nil, true)
end

-- Checks a scouting order toward target from where the player stands.
-- Returns origin, target, duration, generation or nil, reason.
function Scout:Check(targetId, now)
  now = now or Now()
  local army = WF.Army
  local reserve = army and army:Reserve()
  if not reserve then return nil, "no saved data or identity yet" end
  if reserve.SCOUT < 1 then
    return nil, "no " .. army:Name("SCOUT") .. " in your reserve (/wf recruit scout)"
  end
  local talk, lockReason = WF.Capture:CanTalk()
  if not talk then return nil, lockReason or "you cannot take part in the conquest yet" end
  local mine = self:Mine(now)
  if mine then return nil, "your scout is still travelling (" .. Clock(Arrival(mine) - now) .. " left)" end
  local origin, why = army:Place()
  if not origin then return nil, why end
  local target = self:Target(targetId)
  if not target then return nil, "only an Outpost or a Settlement can be scouted" end
  local faction = MyFaction()
  local owner, generation = WF.Capture:TargetOwner(target.id, now)
  if not FACTIONS[owner or ""] or owner == faction then
    return nil, "only a place held by the enemy faction can be scouted"
  end
  local _, finish = self:Discovery(target.id, faction, now)
  if finish then return nil, "already discovered by your faction (" .. Clock(finish - now) .. " left)" end
  local travelling = self:Travelling(target.id, faction, now)
  if travelling then
    return nil, "a scout of your faction is already on its way (" .. Clock(Arrival(travelling) - now) .. " left)"
  end
  local duration = self:Travel(origin, target)
  if not duration then return nil, "no travel data for this map" end
  return origin, target, duration, generation
end

-- Sends the player's scout: it leaves the reserve at once and for good. op is
-- the reserve's scouting number, so a repeated request does nothing (as
-- recruitment). Returns true, record or false, reason.
function Scout:Launch(targetId, op)
  local now = Now()
  local origin, target, duration, generation = self:Check(targetId, now)
  if not origin then return false, target end
  local reserve = WF.Army:Reserve()
  if op ~= reserve.sop then return false, "request already done or out of date" end
  local me = Me()
  local f = {
    target = target.id, origin = origin.id, op = reserve.sop + 1, gen = generation, dur = duration,
    el = 0, fac = MyFaction(),
  }
  if self.records[me .. "#" .. f.op] then return false, "request already done or out of date" end
  local r = self:Learn(me, f, true, now)
  if not r then return false, "too many scouts known" end
  reserve.SCOUT = reserve.SCOUT - 1
  reserve.sop = f.op
  r.repeatAt = now + REPEAT_AFTER
  self:SendOrder(r, now)
  Record("SCOUT_SENT", { target = f.target, origin = f.origin, op = f.op, gen = f.gen, dur = f.dur })
  return true, r
end

function Scout:Command(text)
  local id = string.upper(string.gsub(text or "", "^%s*(.-)%s*$", "%1"))
  if id == "" then
    self:PrintStatus()
    return
  end
  local reserve = WF.Army and WF.Army:Reserve()
  local ok, result = self:Launch(id, reserve and reserve.sop)
  if not ok then
    Print("scout refused: " .. tostring(result))
    return
  end
  Print(WF.Army:Name("SCOUT") .. " sent to " .. self:Label(id) .. ", arrives in " .. Clock(result.dur)
    .. "; it is discovered for your faction for one hour from its arrival")
end

-- Reception -----------------------------------------------------------------

function Scout:Reject(reason, sender)
  return WF.Capture:Reject(reason, sender)
end

-- Fields shared by SC and SL, strictly checked (rule R2); the duration must
-- be the catalog's (same WF level, same catalog).
function Scout:Parse(parts, maxElapsed)
  local f = {
    target = parts[1], origin = parts[2],
    op = Int(parts[3], MAX_OP), gen = Int(parts[4], MAX_GENERATION), dur = Int(parts[5], OTHER_CONTINENT),
    fac = parts[7],
  }
  if not f.op or not f.gen or not f.dur or f.op < 1 then return nil, "bad scout number" end
  f.el = Int(parts[6], f.dur + (maxElapsed or 0))
  if not f.el then return nil, "bad scout elapsed time" end
  if not FACTIONS[f.fac or ""] then return nil, "bad scout faction" end
  local target, origin = self:Target(f.target), Area(f.origin)
  if not target then return nil, "unknown scout target" end
  if not origin or not ORIGIN_TYPES[origin.type] or origin.id == target.id then
    return nil, "bad scout origin"
  end
  if self:Travel(origin, target) ~= f.dur then return nil, "bad scout duration" end
  return f
end

local function ValidOwner(text)
  return type(text) == "string" and #text <= MAX_IDENTITY
    and string.find(text, "^[^,@]+@[^,@]+$") ~= nil
end

-- R14: our pending answer is cancelled after two other answers matching
-- what we know, or any four answers.
function Scout:SeeReply(sender, matches)
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

-- Routed by Capture:OnMessage after echo, identity and quota checks.
function Scout:OnMessage(kind, parts, sender, now)
  self.received = self.received + 1
  if kind == "SC" then
    if #parts ~= 7 then return self:Reject("bad SC field count", sender) end
    local f, err = self:Parse(parts, 0)
    if not f then return self:Reject(err, sender) end
    -- Identity: the chat sender, never a field (rule R1).
    self:Learn(sender, f, true, now)
    return true
  elseif kind == "SL" then
    if #parts ~= 8 then return self:Reject("bad SL field count", sender) end
    local f, err = self:Parse(parts, DISCOVERY)
    if not f then return self:Reject(err, sender) end
    if not ValidOwner(parts[8]) then return self:Reject("bad SL owner", sender) end
    -- Our own scouts are known and saved locally: a relay about them could
    -- only be a forgery blocking our next scout.
    if parts[8] == Me() then
      self:SeeReply(sender, self.records[parts[8] .. "#" .. f.op] ~= nil)
      return true
    end
    -- A relay about a third party: data, never the relayer's identity.
    local _, new = self:Learn(parts[8], f, false, now)
    self:SeeReply(sender, not new)
    return true
  elseif kind == "SQ" then
    if #parts ~= 1 or parts[1] ~= "*" then return self:Reject("bad SQ", sender) end
    if self.count > 0 and not self.replyAt then
      self.replyAt = now + REPLY_MIN + math.random() * REPLY_SPREAD
      self.replyAny, self.replyMatch = nil, nil
    end
    return true
  end
  return self:Reject("unknown kind", sender)
end

-- Channel join (modules/p2ptest.lua): one catch-up request a little later.
function Scout:OnJoined(now)
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

-- SL <target>,<origin>,<op>,<gen>,<dur>,<elapsed>,<fac>,<owner>: one known
-- scout, elapsed since its departure; replaceable, dropped first (rule R13).
function Scout:Answer(now)
  self.replyAt = nil
  self.out = {}
  self:Prune(now)
  for key, r in pairs(self.records) do
    self.out[#self.out + 1] = { key = key, body = Body(r, now) .. "," .. r.owner }
  end
  table.sort(self.out, function(a, b) return a.key < b.key end)
end

-- Driver --------------------------------------------------------------------

function Scout:Tick(now)
  if not self.loaded then self:Load() end
  if self.queryAt and now >= self.queryAt then
    self.queryAt = nil
    self:Send("SQ", "*")
  end
  if self.replyAt and now >= self.replyAt then self:Answer(now) end
  if #self.out > 0 and now >= (self.nextSendAt or 0) and QueueRoom() then
    local line = table.remove(self.out, 1)
    local r = self.records[line.key]
    -- Rebuilt at send time so the elapsed time stays current (risk B10).
    if r and self:Send("SL", Body(r, now) .. "," .. r.owner, "SL," .. line.key) then
      self.answers = (self.answers or 0) + 1
    end
    self.nextSendAt = now + SEND_GAP
  end
  local mine = self:Mine(now)
  if mine and mine.repeatAt and now >= mine.repeatAt then
    mine.repeatAt = nil
    self:SendOrder(mine, now)
  end
  if not self.lastPruneAt or now - self.lastPruneAt >= PRUNE_INTERVAL then
    self.lastPruneAt = now
    self:Prune(now)
  end
  if self.dirty and (not self.lastSaveAt or now - self.lastSaveAt >= SAVE_INTERVAL) then
    self.lastSaveAt = now
    self:Save()
  end
end

-- Persistence ---------------------------------------------------------------

-- WarfrontDB.scopes[scope].scout = { schema, levels = {
-- [channel level] = { at = wall clock, records = { [key] = { owner, op,
-- target, origin, gen, dur, fac, el } } } } } } }: the scouts known, the
-- player's own included, with their elapsed time at the wall-clock save time.
function Scout:Store()
  local storage = WF.Storage
  if not storage or type(storage.GetDB) ~= "function" or storage.readOnly then return nil end
  local db = storage:GetDB()
  if type(db) ~= "table" then return nil end
  -- This ruleset scope's table (decision 0072: the realm never partitions it);
  -- a newer schema belongs to a newer build: leave it untouched.
  local bucket = WF.Ruleset and WF.Ruleset:Module("scout")
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

function Scout:Save()
  local entry = self:Store()
  self.dirty = nil
  if not entry then return end
  local now = Now()
  entry.at = Wall()
  entry.records = {}
  for key, r in pairs(self.records) do
    entry.records[key] = {
      owner = r.owner, op = r.op, target = r.target, origin = r.origin, gen = r.gen, dur = r.dur, fac = r.fac,
      el = Floor(math.max(0, now - r.depart)),
    }
  end
end

-- Restores the saved scouts, aged by the wall time spent offline; the same
-- checks as a received record.
function Scout:Load()
  self.loaded = true
  local entry = self:Store()
  if not entry then return end
  local now = Now()
  local away = math.max(0, Wall() - (tonumber(entry.at) or Wall()))
  for key, saved in pairs(entry.records) do
    if type(saved) == "table" and ValidOwner(saved.owner) then
      local el = (tonumber(saved.el) or 0) + away
      local parts = { tostring(saved.target), tostring(saved.origin), tostring(saved.op), tostring(saved.gen),
        tostring(saved.dur), tostring(Floor(math.min(el, (tonumber(saved.dur) or 0) + DISCOVERY))),
        tostring(saved.fac) }
      local f = self:Parse(parts, DISCOVERY)
      if f then self:Learn(saved.owner, f, false, now) end
    end
  end
  self.dirty = nil
end

-- Display -------------------------------------------------------------------

-- The place's name without its id, for player-facing tooltips.
function Scout:Name(id)
  local area = Area(id)
  if not area then return "Unknown" end
  return area.label or TARGET_TYPES[area.type] or area.type
end

function Scout:Label(id)
  local area = Area(id)
  if not area then return tostring(id) end
  return (area.label or TARGET_TYPES[area.type] or area.type) .. " (" .. id .. ")"
end

-- Map tooltip lines for a POI: discovery and scouts on their way. The enemy
-- sees a scout coming, never who sent it (decision 0050).
function Scout:TooltipInfo(id, now)
  if not self:Target(id) or not WF.Capture then return nil end
  now = now or Now()
  local faction = MyFaction()
  local info = {}
  local _, finish = self:Discovery(id, faction, now)
  if finish then info.discovered = finish - now end
  local mine = self:Travelling(id, faction, now)
  if mine then info.allied = Arrival(mine) - now end
  local enemy = faction == "H" and "A" or "H"
  local theirs = self:Travelling(id, enemy, now)
  if theirs then info.enemy = Arrival(theirs) - now end
  local _, enemyFinish = self:Discovery(id, enemy, now)
  if enemyFinish then info.exposed = enemyFinish - now end
  if not info.discovered and not info.allied and not info.enemy and not info.exposed then return nil end
  if info.discovered and WF.Garrison then
    local view = WF.Garrison:View(id, now)
    local st = WF.Garrison.states[id]
    if view and st and st.seenAt then
      info.garrison = view
      info.seen = now - st.seenAt
    end
  end
  return info
end

-- Map tooltip of a scout on its way: always the route and the time left; the
-- sender only for one's own faction, never for the enemy (decision 0050).
function Scout:RouteInfo(r, now)
  if type(r) ~= "table" then return nil end
  now = now or Now()
  local allied = r.fac == MyFaction()
  return {
    allied = allied, owner = allied and r.owner or nil, left = Arrival(r) - now,
    from = self:Name(r.origin), to = self:Name(r.target),
  }
end

function Scout:PrintStatus()
  local now = Now()
  local faction = MyFaction()
  local reserve = WF.Army and WF.Army:Reserve()
  local name = WF.Army and WF.Army:Name("SCOUT") or "scout"
  Print(name .. " in reserve: " .. (reserve and reserve.SCOUT or 0))
  local mine = self:Mine(now)
  if mine then
    Print("your " .. name .. " travels to " .. self:Label(mine.target) .. ": " .. Clock(Arrival(mine) - now) .. " left")
  end
  local shown = 0
  for id, area in pairs(WF.Map and WF.Map.areas or {}) do
    if self:Target(id) then
      local _, finish = self:Discovery(id, faction, now)
      local travelling = self:Travelling(id, faction, now)
      if finish then
        Print(self:Label(id) .. " discovered: " .. Clock(finish - now) .. " left")
        shown = shown + 1
      elseif travelling and travelling ~= mine then
        Print(self:Label(id) .. ": allied scout arrives in " .. Clock(Arrival(travelling) - now))
        shown = shown + 1
      end
    end
  end
  if shown == 0 and not mine then Print("no scouting under way for your faction") end
  local origin = WF.Army and WF.Army:Place()
  if not origin then
    Print("send a scout from an Outpost or Settlement of your faction: /wf scout <POI id>")
    return
  end
  for id, area in pairs(WF.Map.areas) do
    local owner = self:Target(id) and WF.Capture:TargetOwner(id)
    if FACTIONS[owner or ""] and owner ~= faction then
      local duration = self:Travel(origin, area)
      Print("/wf scout " .. id .. " - " .. (area.label or TARGET_TYPES[area.type]) .. ", "
        .. (duration and Clock(duration) or "no travel data"))
    end
  end
end

if WF.RegisterEvent then
  -- Fires on logout, quit and /reload, before SavedVariables are written.
  WF.RegisterEvent("PLAYER_LOGOUT", function()
    if Scout.loaded then Scout:Save() end
  end)
end
