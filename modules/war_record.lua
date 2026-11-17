local WF = Warfront

-- War record (decision 0088 § 3): this character's own raw scoreboard
-- aggregates, local and monotonic, from which the cloud will derive scores.
--   * capture: captures credited to this character, by POI type. Credit only
--     from a live capture event (Capture:HandleEvent, once per POI and
--     generation) when counted inside that POI (status IN) for the winning
--     faction at some moment of its last 60 seconds (decision 0126 § 2); a
--     promoted hint or a catch-up never credits anyone.
--   * chest: gold and wood a keeper accepted into a Settlement War Chest.
--   * attack: combat units sent in a valid attack, and scouts sent (units
--     pledged to a garrison never count here; units given back at a campaign
--     end count no second time when sent again, decision 0126 § 5).
--   * pvp.kills / pvp.assists: honorable kills in the open world, from the
--     difference of the game's own counter; battlegrounds and other instances
--     never count. A kill is an honorable kill matched with our own or our
--     pet's killing blow on a player (PARTY_KILL) within 2 seconds; every other
--     honorable kill is an assist. PARTY_KILL alone never counts.
--   * pvp.deaths: open-world deaths whose Death Recap names another player or
--     a player's pet as the source of the killing blow.
--   * pendingKills: honorable kills waiting for their split; a reload in that
--     short wait turns them into assists. lastPvpDeath: the last recap counted.
--     Both are local guards.
--   * guilds: the same counters per guild at the time of each action, keyed by
--     the guild club id, with the guild's last readable name and faction.
--     Earlier points never move when the character changes guild or the guild
--     is renamed. Without a readable id, the action counts for the character
--     only.
--   * class, race, faction (on the character, not per campaign): the row
--     identity of the scoreboard (decision 0105 § 5), refreshed at each action.
--   * defense: enemy attempts that reached a quarter of the bar and ended
--     without a capture while this character stood inside its faction's POI
--     during their last 60 seconds (decisions 0109 § 3, 0126 § 2), by POI type.
--   * garrison: combat units of a pledge the keeper accepted (decision 0105 § 3).
--   * limits[poi] = { c, d }: server time of the last capture and defense
--     credit there: one capture per hour (decision 0109 § 3), one defense per
--     siege (decision 0126 § 2). A local guard.
--   * victims[guid]: server time of our last counted killing blow on that
--     player; a repeat within the hour counts nothing (decision 0126 § 4).
--     A local guard, never uploaded.
--   * attack.SCOUT: scouts sent (decision 0126 § 5).
--   * limits["*camp"] = { at, n, lock }: the War Camp rapid-credit guard
--     (decision 0123 § 9, 2026-11-15): last War Camp credit, rapid credits in
--     a row, start of the one-hour restriction. Never a POI id.
-- Saved per ruleset scope, per character and campaign; never sent, never read
-- by a gameplay rule. The companion does not read it yet (its roadmap § 7).
local WarRecord = {}
WF.WarRecord = WarRecord

local SCHEMA = 1
-- Counters before campaigns are numbered (decision 0103 § 3) stay under this key.
local CAMPAIGN = "permanent"
local MAX_VALUE = 999999999
local MAX_CAMPAIGNS = 12
local MAX_GUILDS = 32
local MAX_GUILD_ID = 1000000000000000
local MAX_GUILD_NAME = 64
local MAX_TOKEN = 16
local KILL_SETTLE = 15
local MAX_KILL_STEP = 5
local MATCH_WINDOW = 2   -- seconds between our killing blow and the honorable kill it gave
local MATCH_DELAY = 3    -- an honorable kill is split once its killing blow can have arrived
local BLOW_KEEP = 90     -- seconds a killing blow stays a candidate
local MAX_BLOWS = 20
local RECAP_DELAYS = { 2, 1, 2, 5 } -- first read, then retries while the recap is not ready
local DEATH_REPEAT = 3   -- a second PLAYER_DEAD this soon is the same death
local KEYS = {
  -- WAR_CAMP keeps its own counters, never folded into OUTPOST (decision 0123 § 9).
  capture = { OUTPOST = true, SETTLEMENT = true, CAPITAL = true, WAR_CAMP = true },
  defense = { OUTPOST = true, SETTLEMENT = true, CAPITAL = true, WAR_CAMP = true },
  chest = { gold = true, wood = true },
  -- SCOUT: scouts sent (decision 0126 § 5); never a garrison key.
  attack = { FOOTMAN = true, RIFLEMAN = true, MORTAR = true, SCOUT = true },
  garrison = { FOOTMAN = true, RIFLEMAN = true, MORTAR = true },
  pvp = { kills = true, assists = true, deaths = true },
}
-- Anti-farm (decision 0105 § 1, 0109 § 3): one capture credit per POI and
-- hour; one defense credit per siege (decision 0126 § 2): a capital once per
-- 24 hours, a Settlement once per 3 hours (its window), others once per hour.
-- The limits table is a local guard, never uploaded.
local CREDIT_WINDOW = 3600
local DEFENSE_WINDOWS = { CAPITAL = 86400, SETTLEMENT = 10800 }
local LONGEST_WINDOW = 86400
local LIMIT_FIELDS = { capture = "c", defense = "d" }
-- Repeat victims (decision 0126 § 4): an honorable kill matched to our own
-- killing blow on a player struck down by us within the hour counts nothing.
-- victims[guid] = server time of the last counted blow; local, never uploaded.
local VICTIM_WINDOW = 3600
local MAX_VICTIMS = 200
local MAX_LIMIT_ID = 64
-- War Camp abuse guard (decision 0123 § 9, user choice of 2026-11-15): a War
-- Camp credit, capture or defense, less than CAMP_RAPID seconds after this
-- character's previous one is rapid; the CAMP_STREAK-th rapid credit in a row
-- is withheld and starts a CAMP_LOCK restriction without any War Camp credit.
-- Other POI types are never affected. Silent: the capture itself is unchanged.
local CAMP_GUARD = "*camp"
local CAMP_RAPID = 600
local CAMP_STREAK = 3
local CAMP_LOCK = 3600
-- englishRace of GetPlayerInfoByGUID; a race missing here is of unknown faction.
local RACE_FACTION = {
  Human = "Alliance", Dwarf = "Alliance", NightElf = "Alliance", Gnome = "Alliance",
  Draenei = "Alliance", Worgen = "Alliance",
  Orc = "Horde", Scourge = "Horde", Tauren = "Horde", Troll = "Horde",
  BloodElf = "Horde", Goblin = "Horde",
}
WarRecord.KEYS = KEYS

local function Me()
  return WF.Capture and WF.Capture:Me() or nil
end

-- The current campaign's record of this character, or nil when the scope or
-- identity is not known yet, or the saved schema is newer than this build.
function WarRecord:Store()
  local root = WF.Ruleset and WF.Ruleset:Module("warRecord")
  if not root then return nil end
  if type(root.schema) == "number" and root.schema > SCHEMA then return nil end
  root.schema = SCHEMA
  if type(root.chars) ~= "table" then root.chars = {} end
  local me = Me()
  if type(me) ~= "string" or me == "" then return nil end
  local char = root.chars[me]
  if type(char) ~= "table" then
    char = {}
    root.chars[me] = char
  end
  if type(char.campaigns) ~= "table" then char.campaigns = {} end
  -- One record per campaign number (decision 0102 § 4): a new campaign starts
  -- new counters, the earlier ones are kept.
  local key = CAMPAIGN
  local n = WF.Campaign and WF.Campaign:Current()
  if type(n) == "number" and n >= 1 then key = n end
  local record = char.campaigns[key]
  if type(record) ~= "table" then
    record = {}
    char.campaigns[key] = record
    -- Bounded (rule R9): the oldest numbered campaigns beyond MAX_CAMPAIGNS go.
    while true do
      local count, oldest = 0, nil
      for k in pairs(char.campaigns) do
        if type(k) == "number" then
          count = count + 1
          if not oldest or k < oldest then oldest = k end
        end
      end
      if count <= MAX_CAMPAIGNS then break end
      char.campaigns[oldest] = nil
    end
  end
  for category in pairs(KEYS) do
    if type(record[category]) ~= "table" then record[category] = {} end
  end
  if type(record.guilds) ~= "table" then record.guilds = {} end
  return record, char
end

local function Valid(value)
  return type(value) == "number" and value >= 0 and value <= MAX_VALUE and math.floor(value) == value
end

local function Increase(counters, key, amount)
  local value = counters[key]
  if not Valid(value) then value = 0 end
  value = value + amount
  if value > MAX_VALUE then value = MAX_VALUE end
  counters[key] = value
end

-- A value the client hides from addons: never compare or index it.
local function Secret(value)
  return type(issecretvalue) == "function" and issecretvalue(value) and true or false
end

-- This character's faction ("Alliance" or "Horde"), or nil when unreadable.
local function PlayerFaction()
  if type(UnitFactionGroup) ~= "function" then return nil end
  local ok, faction = pcall(UnitFactionGroup, "player")
  if ok and not Secret(faction) and (faction == "Alliance" or faction == "Horde") then return faction end
  return nil
end

-- A client token (class file or English race name) when readable and plain.
local function Token(value, pattern)
  if Secret(value) or type(value) ~= "string" or #value > MAX_TOKEN then return nil end
  return string.find(value, pattern) and value or nil
end

-- Row identity for the scoreboard (decision 0105 § 5): class file name,
-- English race name and faction, saved on the character. A value that cannot
-- be read keeps the last one saved.
local function SaveIdentity(char)
  if type(UnitClass) == "function" then
    local ok, _, classFile = pcall(UnitClass, "player")
    local class = ok and Token(classFile, "^%u+$") or nil
    if class then char.class = class end
  end
  if type(UnitRace) == "function" then
    local ok, _, raceFile = pcall(UnitRace, "player")
    local race = ok and Token(raceFile, "^%a+$") or nil
    if race then char.race = race end
  end
  local faction = PlayerFaction()
  if faction then char.faction = faction end
end

-- This character's guild right now, as its saved key and its display name
-- (nil when unreadable at this instant), or nil without a readable id.
local function CurrentGuild()
  if type(C_Club) ~= "table" or type(C_Club.GetGuildClubId) ~= "function" then return nil end
  local id = C_Club.GetGuildClubId()
  if Secret(id) or type(id) ~= "number" or id < 1 or id > MAX_GUILD_ID or math.floor(id) ~= id then return nil end
  local name
  if type(C_Club.GetClubInfo) == "function" then
    local info = C_Club.GetClubInfo(id)
    if not Secret(info) and type(info) == "table" and not Secret(info.name)
      and type(info.name) == "string" and info.name ~= "" and #info.name <= MAX_GUILD_NAME then
      name = info.name
    end
  end
  return string.format("%.0f", id), name
end

-- A new guild past the bound is not created; existing guilds are never evicted.
local function GuildBucket(record, guildKey)
  local bucket = record.guilds[guildKey]
  if type(bucket) == "table" then return bucket end
  local count = 0
  for _ in pairs(record.guilds) do count = count + 1 end
  if count >= MAX_GUILDS then return nil end
  bucket = {}
  record.guilds[guildKey] = bucket
  return bucket
end

local function CreditGuild(record, category, key, amount)
  local guildKey, guildName = CurrentGuild()
  if not guildKey then return end
  local bucket = GuildBucket(record, guildKey)
  if not bucket then return end
  if guildName then bucket.name = guildName end
  local faction = PlayerFaction()
  if faction then bucket.faction = faction end
  if type(bucket[category]) ~= "table" then bucket[category] = {} end
  Increase(bucket[category], key, amount)
end

-- Adds a whole positive amount; values only grow and stop at MAX_VALUE. A
-- guild that cannot be read never prevents the character's own credit.
function WarRecord:Add(category, key, amount)
  if not KEYS[category] or not KEYS[category][key] or not Valid(amount) or amount < 1 then return false end
  local record, char = self:Store()
  if not record then return false end
  Increase(record[category], key, amount)
  pcall(SaveIdentity, char)
  pcall(CreditGuild, record, category, key, amount)
  if WF.ScoreFloat then pcall(WF.ScoreFloat.Credit, WF.ScoreFloat, category, key, amount) end
  return true
end

function WarRecord:Get(category, key)
  local record = self:Store()
  local value = record and record[category] and record[category][key]
  return Valid(value) and value or 0
end

local function ServerTime()
  if type(GetServerTime) ~= "function" then return nil end
  local ok, now = pcall(GetServerTime)
  if ok and type(now) == "number" and now > 0 then return now end
  return nil
end

-- Capture or defense credit for one POI (decision 0109 § 3): at most one of
-- each kind per POI and hour. Without a server clock nothing is credited.
function WarRecord:CreditPoi(kind, poi, areaType)
  local field = LIMIT_FIELDS[kind]
  if not field or not KEYS[kind][areaType] or type(poi) ~= "string" or poi == "" or #poi > MAX_LIMIT_ID then
    return false
  end
  local now = ServerTime()
  if not now then return false end
  local record = self:Store()
  if not record then return false end
  if type(record.limits) ~= "table" then record.limits = {} end
  -- Pruned on use: only POIs credited within the longest window stay (bounded
  -- by the catalog).
  for id, entry in pairs(record.limits) do
    local keep = false
    if type(entry) == "table" then
      for _, at in pairs(entry) do
        if type(at) == "number" and at <= now and now - at < LONGEST_WINDOW then keep = true end
      end
    end
    if not keep then record.limits[id] = nil end
  end
  if poi == CAMP_GUARD then return false end
  local window = kind == "defense" and DEFENSE_WINDOWS[areaType] or CREDIT_WINDOW
  local entry = record.limits[poi]
  local last = type(entry) == "table" and entry[field]
  if type(last) == "number" and last <= now and now - last < window then return false end
  if areaType == "WAR_CAMP" then
    -- Every field is a past server time (lock its start), so the pruning above
    -- keeps the guard exactly while it still matters.
    local guard = record.limits[CAMP_GUARD]
    if type(guard) ~= "table" then
      guard = {}
      record.limits[CAMP_GUARD] = guard
    end
    local lock = guard.lock
    if type(lock) == "number" and lock <= now and now - lock < CAMP_LOCK then return false end
    guard.lock = nil
    local at = guard.at
    local streak = 0
    if type(at) == "number" and at <= now and now - at < CAMP_RAPID then
      streak = (type(guard.n) == "number" and guard.n or 0) + 1
    end
    if streak >= CAMP_STREAK then
      guard.at, guard.n, guard.lock = nil, nil, now
      return false
    end
    guard.at, guard.n = now, streak
  end
  if not self:Add(kind, areaType, 1) then return false end
  if type(record.limits[poi]) ~= "table" then record.limits[poi] = {} end
  record.limits[poi][field] = now
  return true
end

-- This character's counters of the running campaign (read only for the view),
-- or nil without a scope or identity.
function WarRecord:Current()
  local record, char = self:Store()
  return record, char
end

-- This character's guild key right now (club id string), or nil.
function WarRecord:GuildKey()
  local ok, key = pcall(CurrentGuild)
  if ok then return key end
  return nil
end

local function After(delay, callback)
  if type(C_Timer) ~= "table" or type(C_Timer.After) ~= "function" then return end
  C_Timer.After(delay, function()
    local ok, err = pcall(callback)
    if not ok and WF.RecordError then WF.RecordError("war record", err) end
  end)
end

local function OpenWorld()
  if type(IsInInstance) ~= "function" then return false end
  local ok, inside = pcall(IsInInstance)
  return ok and not Secret(inside) and not inside
end

local function SessionKills()
  if type(GetPVPSessionStats) ~= "function" then return nil end
  local ok, kills = pcall(GetPVPSessionStats)
  if not ok or Secret(kills) or not Valid(kills) then return nil end
  return kills
end

-- Client uptime in seconds, or nil.
local function Clock()
  if type(GetTime) ~= "function" then return nil end
  local ok, value = pcall(GetTime)
  if not ok or Secret(value) or type(value) ~= "number" then return nil end
  return value
end

-- A unit's GUID when readable, otherwise nil.
local function PlainGuid(unit)
  if type(UnitGUID) ~= "function" then return nil end
  local ok, guid = pcall(UnitGUID, unit)
  if not ok or Secret(guid) or type(guid) ~= "string" then return nil end
  return guid
end

-- False only when the player is known to be of our own faction: an unknown
-- faction stays a candidate, since only an enemy gives an honorable kill.
local function MaybeEnemy(guid)
  if type(GetPlayerInfoByGUID) ~= "function" or type(UnitFactionGroup) ~= "function" then return true end
  local ok, _, _, _, race = pcall(GetPlayerInfoByGUID, guid)
  local okMine, mine = pcall(UnitFactionGroup, "player")
  if not ok or not okMine or Secret(race) or Secret(mine) then return true end
  local theirs = type(race) == "string" and RACE_FACTION[race] or nil
  return theirs == nil or type(mine) ~= "string" or theirs ~= mine
end

-- The counter is trusted again only once a loading screen has settled, so a
-- late value after login or a battleground's kills are never credited. Kills
-- during that short wait are lost rather than guessed. Kills still waiting for
-- their split when the interface was reloaded become assists then.
function WarRecord:OnEnteringWorld()
  self.killBaseline = nil
  self.settleToken = (self.settleToken or 0) + 1
  local token = self.settleToken
  After(KILL_SETTLE, function()
    if token ~= self.settleToken then return end
    self.killBaseline = SessionKills()
    self:FlushPendingKills()
  end)
end

-- Our own or our pet's killing blow on a player, kept a short while so the
-- honorable kill it gives can be matched with it. Unreadable payloads (inside
-- a battleground) are ignored.
function WarRecord:OnPartyKill(attacker, target)
  if Secret(attacker) or Secret(target) or type(attacker) ~= "string" or type(target) ~= "string" then return end
  if string.sub(target, 1, 7) ~= "Player-" then return end
  local me, pet = PlainGuid("player"), PlainGuid("pet")
  if attacker ~= me and attacker ~= pet then return end
  if target == me or not MaybeEnemy(target) then return end
  local now = Clock()
  if not now then return end
  local blows = self.blows or {}
  self.blows = blows
  while blows[1] and now - blows[1].at > BLOW_KEEP do table.remove(blows, 1) end
  while #blows >= MAX_BLOWS do table.remove(blows, 1) end
  blows[#blows + 1] = { at = now, guid = target }
end

-- How many distinct players we struck down within the window around an
-- honorable kill, at most wanted; each blow serves one honorable kill only.
-- Also returns the struck players' GUIDs, in match order.
function WarRecord:TakeBlows(at, wanted)
  local blows = self.blows
  if at == nil or type(blows) ~= "table" then return 0, {} end
  local taken, seen, guids = 0, {}, {}
  for index = 1, #blows do
    local blow = blows[index]
    if not blow.used and math.abs(blow.at - at) <= MATCH_WINDOW then
      if not seen[blow.guid] and taken < wanted then
        seen[blow.guid] = true
        taken = taken + 1
        guids[taken] = blow.guid
      end
      if seen[blow.guid] then blow.used = true end
    end
  end
  return taken, guids
end

-- Whether a killing blow on this player is a repeat within the hour; a fresh
-- one is remembered (decision 0126 § 4). Without a server clock nothing is a
-- repeat. Bounded: pruned on use, the oldest out beyond MAX_VICTIMS (R9).
function WarRecord:RepeatVictim(record, guid, now)
  if not now or type(guid) ~= "string" then return false end
  if type(record.victims) ~= "table" then record.victims = {} end
  local victims, count, oldest, oldestAt = record.victims, 0, nil, nil
  for key, at in pairs(victims) do
    if type(at) ~= "number" or at > now or now - at >= VICTIM_WINDOW then
      victims[key] = nil
    else
      count = count + 1
      if not oldestAt or at < oldestAt then oldest, oldestAt = key, at end
    end
  end
  if victims[guid] then return true end
  if count >= MAX_VICTIMS and oldest then victims[oldest] = nil end
  victims[guid] = now
  return false
end

-- Splits honorable kills held by OnKillsChanged into kills and assists; an
-- honorable kill on a repeat victim counts as neither.
function WarRecord:SplitKills(at, count)
  local record = self:Store()
  if not record then return end
  local held = record.pendingKills
  if not Valid(held) or held < 1 then return end
  if count > held then count = held end
  record.pendingKills = held - count
  local matched, guids = self:TakeBlows(at, count)
  local now, kills = ServerTime(), 0
  for index = 1, matched do
    if not self:RepeatVictim(record, guids[index], now) then kills = kills + 1 end
  end
  if kills > 0 then self:Add("pvp", "kills", kills) end
  if count - matched > 0 then self:Add("pvp", "assists", count - matched) end
end

-- Honorable kills whose split a reload cut short: their killing blows are
-- gone, so they count as assists.
function WarRecord:FlushPendingKills()
  local record = self:Store()
  if not record then return end
  local held = record.pendingKills
  record.pendingKills = nil
  if Valid(held) and held > 0 then self:Add("pvp", "assists", held) end
end

-- The event repeats for many units per kill: only the counter's difference is
-- credited. A drop (daily reset) or an implausible jump moves the reference only.
function WarRecord:OnKillsChanged()
  local previous = self.killBaseline
  if previous == nil then return end
  local current = SessionKills()
  if current == nil then return end
  self.killBaseline = current
  local delta = current - previous
  if delta <= 0 or delta > MAX_KILL_STEP or not OpenWorld() then return end
  local record = self:Store()
  if not record then return end
  Increase(record, "pendingKills", delta)
  local at = Clock()
  After(MATCH_DELAY, function() self:SplitKills(at, delta) end)
end

-- The timestamp of the killing blow when the latest Death Recap names another
-- player or a player's pet as its source, otherwise nil.
local function DeathByPlayer()
  if type(C_DeathRecap) ~= "table" or type(C_DeathRecap.GetRecapEvents) ~= "function" then return nil end
  local ok, events = pcall(C_DeathRecap.GetRecapEvents)
  if not ok or Secret(events) or type(events) ~= "table" then return nil end
  local blow = events[1]
  if Secret(blow) or type(blow) ~= "table" then return nil end
  local source, stamp = blow.sourceGUID, blow.timestamp
  if Secret(source) or Secret(stamp) or type(source) ~= "string" or type(stamp) ~= "number" then return nil end
  if string.sub(source, 1, 7) ~= "Player-" and string.sub(source, 1, 4) ~= "Pet-" then return nil end
  if source == PlainGuid("player") or source == PlainGuid("pet") then return nil end
  return stamp
end

-- Whether the client has built a recap to read (assumed when it cannot say).
local function RecapReady()
  if type(C_DeathRecap) ~= "table" or type(C_DeathRecap.HasRecapEvents) ~= "function" then return true end
  local ok, ready = pcall(C_DeathRecap.HasRecapEvents)
  return ok and not Secret(ready) and ready == true
end

-- A recap already counted is never counted again, even after a reload. A
-- recap not ready yet is read again a few times.
function WarRecord:CreditDeath(attempt)
  attempt = attempt or 1
  if not RecapReady() then
    local nextAttempt = attempt + 1
    if RECAP_DELAYS[nextAttempt] then
      After(RECAP_DELAYS[nextAttempt], function() self:CreditDeath(nextAttempt) end)
    end
    return
  end
  local stamp = DeathByPlayer()
  if not stamp then return end
  local record = self:Store()
  if not record then return end
  if type(record.lastPvpDeath) == "number" and stamp <= record.lastPvpDeath then return end
  if self:Add("pvp", "deaths", 1) then record.lastPvpDeath = stamp end
end

-- The client may fire PLAYER_DEAD twice for one death.
function WarRecord:OnPlayerDead()
  if not OpenWorld() then return end
  local now = Clock()
  if now and self.lastDeadAt and now - self.lastDeadAt >= 0 and now - self.lastDeadAt < DEATH_REPEAT then return end
  self.lastDeadAt = now
  After(RECAP_DELAYS[1], function() self:CreditDeath(1) end)
end

if type(WF.RegisterEvent) == "function" then
  WF.RegisterEvent("PLAYER_ENTERING_WORLD", function() WarRecord:OnEnteringWorld() end)
  WF.RegisterEvent("PLAYER_PVP_KILLS_CHANGED", function() WarRecord:OnKillsChanged() end)
  WF.RegisterEvent("PARTY_KILL", function(_, attacker, target) WarRecord:OnPartyKill(attacker, target) end)
  WF.RegisterEvent("PLAYER_DEAD", function() WarRecord:OnPlayerDead() end)
end
