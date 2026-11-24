Warfront = Warfront or {}

local WF = Warfront

-- Who plays Warfront right now: the members of the hidden Warfront channel,
-- read from the client's channel roster (C_ChatInfo.GetChannelRosterInfo),
-- plus the Warfront players this client already knows elsewhere (decision
-- 0080): guild mates and group mates heard sending Warfront lines, and
-- contacts made through a Battle.net friendship or near us. The roster is
-- loaded by the directory's guarded fetch (modules/directory.lua: another
-- display channel, then ours, never in combat, an instance or with the Channels
-- window open, off after a blocked action); this module never selects a display
-- channel itself. CHANNEL_ROSTER_UPDATE / CHANNEL_COUNT_UPDATE say it changed.
-- Nothing is sent, so it costs nothing (rule R17). Names come from the server
-- roster or the chat event sender, never from a message body. The local
-- character is listed as soon as the channel is joined, under its full Forever
-- name (core/names.lua), as the roster writes it.
local Players = {
  CHANNEL = "Warfront",
  -- A new request while the tab is open; never more than one per MIN_GAP.
  REFRESH = 30,
  MIN_GAP = 5,
  -- A roster read waiting for missing entries retries at most this often.
  READ_GAP = 1,
  -- The other sources are read again this often while the tab is open.
  MERGE_GAP = 5,
  MAX_NAMES = 500,
  names = {},
  -- name -> "near" | "group" | "guild" | "friend" for players known beyond the roster.
  tags = {},
  -- name -> true for the other side's players (decision 0148, Players:ApplyFar).
  far = {},
  -- name -> true for the names read from our channel roster at the last read.
  roster = {},
  -- name -> { faction, region, ruleset } read from the roster GUID; each field
  -- nil when not proven. Names without a roster GUID have no entry.
  info = {},
  -- guid -> the same entry, so GetPlayerInfoByGUID runs once per member; an
  -- entry without a ruleset is read again after RETRY_GAP seconds.
  guidInfo = {},
  guidCount = 0,
  RETRY_GAP = 60,
  -- GUID server -> ruleset parsed from any member named on that realm.
  serverRuleset = {},
  -- Saved realm memory (decision 0138): WarfrontDB.realmRulesets, at most this
  -- many "<region>:<GUID server>" entries.
  MAX_REALMS = 256,
  -- Realm-free name -> ruleset label heard this session from the sender's own
  -- lines (decision 0139 § 6); display only, never saved.
  heard = {},
  heardCount = 0,
  -- Heard realm memory (decision 0147): WarfrontDB.heardRulesets, the scope a
  -- heard marker named for its sender's GUID server; display only, apart from
  -- realmRulesets. heardServers: this session's "<server>" -> scope, or false
  -- once two senders of that server named different scopes.
  heardServers = {},
  -- The first release whose bare campaign field proves record 14: 0.1.1 sent
  -- the bare field on every ruleset.
  MARKER_VERSION = "0.1.2",
  ownRemembered = false,
  me = nil,
  count = 0,
  updatedAt = nil,
  requestedAt = nil,
  readAt = nil,
  dirty = true,
  displayIndex = nil,
  requests = 0,
  answers = 0,
}

WF.Players = Players

local function GetGlobal(name)
  if WF.Compat and WF.Compat.Global then return WF.Compat.Global(name) end
  return _G and _G[name] or nil
end

local function Now()
  return WF.Now and WF.Now() or 0
end

local function IsSecret(value)
  local isSecret = GetGlobal("issecretvalue")
  return type(isSecret) == "function" and isSecret(value) and true or false
end

-- "5. Warfront" or "Warfront".
function Players.IsChannel(value)
  if type(value) ~= "string" or IsSecret(value) then return false end
  local name = string.gsub(value, "^%d+%.%s*", "")
  return string.lower(name) == string.lower(Players.CHANNEL)
end

-- A roster entry as chat shows it ("First Surname", decision 0070), with
-- "-Realm" only for another realm; nil for anything else.
function Players.CleanName(name)
  local names = WF.Names
  if not names or IsSecret(name) then return nil end
  local chatName, realm = names.Split(name)
  if not names.Valid(chatName) then return nil end
  if realm then
    if string.find(realm, "[%c|@]") or #realm > 48 then return nil end
    return chatName .. "-" .. realm
  end
  return chatName
end

local function MyName()
  local name = WF.Names and WF.Names.Mine()
  if name and WF.Names.Valid(name) then return name end
  return nil
end

-- The local channel number, 0 when not joined.
function Players:ChannelNumber()
  local get = GetGlobal("GetChannelName")
  if type(get) ~= "function" then return 0 end
  local ok, id = pcall(get, self.CHANNEL)
  if ok and type(id) == "number" and id > 0 then return id end
  return 0
end

function Players:Joined()
  return self:ChannelNumber() > 0
end

-- The roster API takes the channel's position in the display channel list,
-- not its chat number. Returns that position and the member count it shows.
function Players:FindDisplay()
  local num = GetGlobal("GetNumDisplayChannels")
  local info = GetGlobal("GetChannelDisplayInfo")
  if type(num) ~= "function" or type(info) ~= "function" then return nil end
  local number = self:ChannelNumber()
  if number == 0 then return nil end
  local ok, total = pcall(num)
  if not ok or type(total) ~= "number" then return nil end
  local index = 1
  while index <= total do
    local got, name, header, _, channelNumber, count = pcall(info, index)
    if got and not header and (channelNumber == number or Players.IsChannel(name)) then
      return index, type(count) == "number" and count or 0
    end
    index = index + 1
  end
  return nil
end

-- What a roster GUID proves (knowledge base, Chat channels, 2026-11-21
-- `roster.v1`). Faction only for the classic races: the client's race table
-- is wrong for neutral and newer ones. Region and ruleset only for the realm
-- name tokens seen in game (CAMWOWEU4Realm6PvP, ...Realm9RPPvP); any other
-- token stays unknown.
local GUID_TABLES = {
  FACTION = {
    Human = "Alliance", Dwarf = "Alliance", NightElf = "Alliance", Gnome = "Alliance",
    Orc = "Horde", Scourge = "Horde", Tauren = "Horde", Troll = "Horde",
  },
  -- Races whose token names both factions, told apart by race id
  -- (C_PlayerInfo.GetRace, knowledge base, Chat channels, 2026-11-24): only
  -- the ids measured in game; any other id stays unknown.
  RACE_ID = { [95] = "Alliance", [96] = "Horde" },
  REGION = { EU = "EU" },
  RULESET = { PvP = "PvP", RPPvP = "RP-PvP" },
  -- Our ruleset scope (decisions 0072, 0143: record 14 = PvP, 15 = Normal,
  -- 16 = RP, 18 = RP-PvP) -> label.
  SCOPE = { PVP = "PvP", NORMAL = "PvE", R16 = "RP", R18 = "RP-PvP" },
}

-- The faction of a race shared by both factions (Skyborne), from the race id
-- of the GUID; nil when the id is unknown or unreadable.
local function RaceIdFaction(guid)
  local info, location = GetGlobal("C_PlayerInfo"), GetGlobal("PlayerLocation")
  local read = type(info) == "table" and info.GetRace or nil
  local create = type(location) == "table" and location.CreateFromGUID or nil
  if type(read) ~= "function" or type(create) ~= "function" then return nil end
  local okLocation, where = pcall(create, location, guid)
  if not okLocation or where == nil then return nil end
  local ok, id = pcall(read, where)
  if not ok or IsSecret(id) or type(id) ~= "number" then return nil end
  return GUID_TABLES.RACE_ID[id]
end

-- The GUID server as text ("6940"), or nil (WF.Names.GuidRealm).
local function GuidServer(guid)
  local names = WF.Names
  if type(names) ~= "table" or type(names.GuidRealm) ~= "function" then return nil end
  local realm = names.GuidRealm(guid)
  return realm and tostring(realm) or nil
end

-- Our own GUID server, or nil.
local function OwnServer()
  local unitGuid = GetGlobal("UnitGUID")
  if type(unitGuid) ~= "function" then return nil end
  local ok, mine = pcall(unitGuid, "player")
  return ok and GuidServer(mine) or nil
end

-- The realm name of a roster member: "" means our own realm, kept only when
-- the GUID server is ours and the client names it (build 71037 answers
-- GetRealmName() = "", decision 0137).
local function MemberRealm(realm, server)
  if type(realm) ~= "string" or IsSecret(realm) then return nil end
  if realm ~= "" then return realm end
  if OwnServer() ~= server then return nil end
  local realmName = GetGlobal("GetRealmName")
  local okRealm, name = false, nil
  if type(realmName) == "function" then okRealm, name = pcall(realmName) end
  if okRealm and type(name) == "string" and name ~= "" and not IsSecret(name) then return name end
  return nil
end

-- Our resolved ruleset scope ("PVP", "NORMAL", "R16", "R18"), or nil.
local function OwnScope()
  local ruleset = WF.Ruleset
  if type(ruleset) ~= "table" or type(ruleset.Scope) ~= "function" then return nil end
  local ok, scope = pcall(ruleset.Scope, ruleset, true)
  return ok and scope or nil
end

-- Realm memory (decision 0138) ----------------------------------------------
-- One realm has one game mode and the GUID still names the realm: what was
-- learned about a GUID server labels every member of it, across sessions.
-- Display only; nothing here enters shared state or gameplay.

-- The memory key of a GUID server in our region, or nil.
local function RealmKey(server)
  local region = OwnScope() and WF.Ruleset.region
  if type(region) ~= "number" or region < 1 or region > 1000 or region ~= math.floor(region) then return nil end
  if type(server) ~= "string" or not string.find(server, "^%d+$") or #server > 10 then return nil end
  return region .. ":" .. server
end

-- WarfrontDB.realmRulesets, created only to write; nil when read-only.
local function RealmMemory(write)
  local storage = WF.Storage
  if type(storage) ~= "table" or type(storage.GetDB) ~= "function" then return nil end
  if write and storage.readOnly then return nil end
  local db = storage:GetDB()
  if type(db) ~= "table" then return nil end
  if type(db.realmRulesets) ~= "table" then
    if not write then return nil end
    db.realmRulesets = {}
  end
  return db.realmRulesets
end

-- Remembers a GUID server's scope. An own entry (one of our characters logged
-- in there) is never overwritten by a learned one; a full memory drops its
-- oldest learned entry first. Returns true when the memory holds it.
function Players:RememberRealm(server, scope, own)
  if not GUID_TABLES.SCOPE[scope or ""] then return false end
  local key = RealmKey(server)
  local memory = key and RealmMemory(true)
  if not memory then return false end
  local old = memory[key]
  local now = WF.Epoch and WF.Epoch() or 0
  if type(old) == "table" and GUID_TABLES.SCOPE[old.s or ""] then
    if old.own and not own then return old.s == scope end
    if old.s == scope and (old.own or not own) then
      old.t = now
      return true
    end
  else
    old = nil
    local count, oldest, oldestOwn = 0, nil, nil
    for k, entry in pairs(memory) do
      count = count + 1
      local t = type(entry) == "table" and tonumber(entry.t) or -1
      if type(entry) == "table" and entry.own then
        if not oldestOwn or t < oldestOwn[2] then oldestOwn = { k, t } end
      elseif not oldest or t < oldest[2] then
        oldest = { k, t }
      end
    end
    if count >= self.MAX_REALMS then
      local drop = oldest or oldestOwn
      if drop then memory[drop[1]] = nil end
    end
  end
  memory[key] = { s = scope, own = own and true or nil, t = now }
  return true
end

-- The remembered ruleset label of a GUID server, or nil.
function Players:RealmRuleset(server)
  local key = RealmKey(server)
  local memory = key and RealmMemory(false)
  local entry = memory and memory[key]
  return type(entry) == "table" and GUID_TABLES.SCOPE[entry.s or ""] or nil
end

-- Heard realm memory (decision 0147) ---------------------------------------
-- A heard marker also labels its sender's GUID server, read from the sender's
-- roster GUID. Saved account-wide apart from realmRulesets: a marker is not
-- signed, so it never enters that table and every other source wins. Two
-- senders of one server naming different scopes remove the entry for the
-- session: a forged line can hide a label, never set a rule.

-- WarfrontDB.heardRulesets, created only to write; nil when read-only.
local function HeardMemory(write)
  local storage = WF.Storage
  if type(storage) ~= "table" or type(storage.GetDB) ~= "function" then return nil end
  if write and storage.readOnly then return nil end
  local db = storage:GetDB()
  if type(db) ~= "table" then return nil end
  if type(db.heardRulesets) ~= "table" then
    if not write then return nil end
    db.heardRulesets = {}
  end
  return db.heardRulesets
end

-- Lets every cached roster entry of `server` without a ruleset read again now.
local function Unfreeze(self, server)
  for _, entry in pairs(self.guidInfo) do
    if type(entry) == "table" and entry.server == server and not entry.ruleset then entry.retryAt = 0 end
  end
  self.dirty = true
end

-- Remembers the scope a heard marker named for a GUID server other than ours.
-- Returns true when the memory holds that scope for it.
function Players:RememberHeard(server, scope)
  if not GUID_TABLES.SCOPE[scope or ""] or server == OwnServer() then return false end
  local key = RealmKey(server)
  if not key then return false end
  local session = self.heardServers[server]
  if session == false then return false end
  local memory = HeardMemory(true)
  if session and session ~= scope then
    self.heardServers[server] = false
    if memory then memory[key] = nil end
    return false
  end
  if not session then
    local count = 0
    for _ in pairs(self.heardServers) do count = count + 1 end
    if count >= self.MAX_REALMS then self.heardServers = {} end
    self.heardServers[server] = scope
  end
  if not memory then return false end
  local old = memory[key]
  local now = WF.Epoch and WF.Epoch() or 0
  if type(old) == "table" and old.s == scope then
    old.t = now
    return true
  end
  if type(old) ~= "table" then
    local count, oldest = 0, nil
    for k, entry in pairs(memory) do
      count = count + 1
      local t = type(entry) == "table" and tonumber(entry.t) or -1
      if not oldest or t < oldest[2] then oldest = { k, t } end
    end
    if count >= self.MAX_REALMS and oldest then memory[oldest[1]] = nil end
  end
  memory[key] = { s = scope, t = now }
  Unfreeze(self, server)
  return true
end

-- The heard ruleset label of a GUID server, or nil (conflicting this session:
-- nil).
function Players:HeardRuleset(server)
  if self.heardServers[server or ""] == false then return nil end
  local key = RealmKey(server)
  local memory = key and HeardMemory(false)
  local entry = memory and memory[key]
  return type(entry) == "table" and GUID_TABLES.SCOPE[entry.s or ""] or nil
end

-- Our own GUID server as text, or nil.
function Players:OwnServer()
  return OwnServer()
end

-- The GUID server of a listed name from its roster entry, or nil.
function Players:ServerOf(chatName)
  local info = self.info
  local entry = info[chatName]
  if type(entry) ~= "table" then
    local split = WF.Names and WF.Names.Split
    if type(split) ~= "function" then return nil end
    for name, candidate in pairs(info) do
      if split(name) == chatName then
        entry = candidate
        break
      end
    end
  end
  return type(entry) == "table" and entry.server or nil
end

-- Up to `max` GUID servers of listed roster members that no source labels,
-- sorted; our own server is never listed.
function Players:UnknownServers(max)
  local own, seen, list = OwnServer(), {}, {}
  for _, entry in pairs(self.info) do
    local server = type(entry) == "table" and entry.server or nil
    if server and server ~= own and not entry.ruleset and not seen[server]
        and not self:RealmRuleset(server) and not self:HeardRuleset(server) then
      seen[server] = true
      list[#list + 1] = server
    end
  end
  table.sort(list, function(a, b) return tonumber(a) < tonumber(b) end)
  while #list > max do table.remove(list) end
  return list
end

-- Heard rulesets (decision 0139 § 6) --------------------------------------
-- Every line names its sender's game-mode record in the campaign header field,
-- presence lines included: labelling a sender costs no byte. The field is not
-- signed, so the label is display only: never saved, never in the realm
-- memory, and every other source wins. Any record is read; it is labelled
-- once Ruleset.RECORDS gives it a scope and GUID_TABLES.SCOPE a label (a
-- ruleset where Warfront stays off sends nothing).

-- Notes the ruleset of `sender` (the event sender) from a line it sent with
-- addon `version` and header `field`. A marked field names its record from any
-- version; a bare one proves record 14 only from MARKER_VERSION on. Returns
-- true when a label is held.
function Players:NoteLine(sender, version, field)
  local names, campaign, ruleset = WF.Names, WF.Campaign, WF.Ruleset
  if not names or type(campaign) ~= "table" or type(campaign.FieldRecord) ~= "function"
      or type(ruleset) ~= "table" or type(ruleset.ScopeOf) ~= "function" then return false end
  if type(sender) ~= "string" or IsSecret(sender) or type(field) ~= "string" then return false end
  local chatName = names.Split(sender)
  if not names.Valid(chatName) or chatName == MyName() then return false end
  local record = campaign.FieldRecord(field)
  local label = record ~= nil and GUID_TABLES.SCOPE[ruleset.ScopeOf(record) or ""] or nil
  if not label then return false end
  local _, dots = string.gsub(field, "%.", "")
  if dots < 3 then
    local compare = WF.Version and WF.Version.Compare
    local order = type(compare) == "function" and compare(version, self.MARKER_VERSION) or nil
    if not order or order < 0 then return false end
  end
  -- The sender's realm too (decision 0147), once the roster names its GUID.
  local server = self:ServerOf(chatName)
  if server then self:RememberHeard(server, ruleset.ScopeOf(record)) end
  local heard = self.heard
  if heard[chatName] == label then return true end
  if not heard[chatName] then
    if self.heardCount >= self.MAX_NAMES * 2 then
      heard, self.heardCount = {}, 0
      self.heard = heard
    end
    self.heardCount = self.heardCount + 1
  end
  heard[chatName] = label
  self.dirty = true
  return true
end

-- Our own character's realm, once per session as soon as the ruleset resolves.
function Players:RememberOwn()
  if self.ownRemembered then return end
  local server, scope = OwnServer(), OwnScope()
  if server and scope and self:RememberRealm(server, scope, true) then self.ownRemembered = true end
end

-- Our own region token ("EU"), from the resolved ruleset context, or nil.
local function OwnRegion()
  local context = OwnScope() and WF.Ruleset.context
  local name = type(context) == "table" and context.regionName
  if type(name) ~= "string" or IsSecret(name) then return nil end
  return GUID_TABLES.REGION[name]
end

-- Gives a heard label (Players:NoteLine) to every listed name no other source
-- labels; a channel member or a guild, group or nearby player shares our
-- region, a Battle.net friend may not.
function Players:ApplyHeard(names, info, tags, me)
  local split = WF.Names and WF.Names.Split
  if type(split) ~= "function" or not next(self.heard) then return end
  for i = 1, #names do
    local name = names[i]
    local label = name ~= me and self.heard[split(name) or ""] or nil
    local entry = info[name]
    if label and not (entry and entry.ruleset) then
      local region = entry and entry.region or (tags[name] ~= "friend" and OwnRegion() or nil)
      info[name] = { faction = entry and entry.faction or nil, region = region, ruleset = label,
        guid = entry and entry.guid or nil, server = entry and entry.server or nil }
    end
  end
end

-- The cached entry of a roster GUID, or nil while the client cannot name it yet.
-- Every roster member shares our region: the channel lives on regional servers
-- (decision 0120). The ruleset needs a realm name, blank on build 71037
-- (decision 0137), or another member already named on the same GUID server;
-- a member of our own realm shares our game mode, hence our ruleset scope; a
-- member with a verified ticket or on a verified scoreboard is in our scope,
-- and the realm memory gives the rest (decision 0138).
function Players:GuidInfo(guid, now, name)
  local server = GuidServer(guid)
  if not server then return nil end
  now = now or Now()
  local cached = self.guidInfo[guid]
  if cached and (cached.ruleset or now < cached.retryAt) then return cached end
  local read = GetGlobal("GetPlayerInfoByGUID")
  if type(read) ~= "function" then return cached end
  local ok, _, _, _, race, _, _, realm = pcall(read, guid)
  if not ok or IsSecret(race) then return cached end
  realm = MemberRealm(realm, server)
  local entry = { faction = type(race) == "string" and GUID_TABLES.FACTION[race] or nil, guid = guid,
    server = server }
  if not entry.faction and type(race) == "string" and race ~= "" then entry.faction = RaceIdFaction(guid) end
  if realm then
    local _, _, region, ruleset = string.find(string.gsub(realm, "%s", ""), "^CAMWOW(%u%u)%d+Realm%d+(%a+)$")
    entry.region = region and GUID_TABLES.REGION[region] or nil
    entry.ruleset = ruleset and GUID_TABLES.RULESET[ruleset] or nil
  end
  if entry.ruleset then self.serverRuleset[server] = entry.ruleset end
  entry.ruleset = entry.ruleset or self.serverRuleset[server]
  if not entry.ruleset and server == OwnServer() then
    entry.ruleset = GUID_TABLES.SCOPE[OwnScope() or ""]
  end
  if not entry.ruleset and self:InOurScope(name) then
    self:RememberRealm(server, OwnScope(), false)
    entry.ruleset = GUID_TABLES.SCOPE[OwnScope() or ""]
  end
  entry.ruleset = entry.ruleset or self:RealmRuleset(server) or self:HeardRuleset(server)
  entry.region = entry.region or OwnRegion()
  entry.faction = entry.faction or (cached and cached.faction)
  if not (entry.faction or entry.region or entry.ruleset) then return cached end
  entry.retryAt = now + self.RETRY_GAP
  if not cached then
    if self.guidCount >= self.MAX_NAMES * 2 then
      self.guidInfo, self.guidCount = {}, 0
    end
    self.guidCount = self.guidCount + 1
  end
  self.guidInfo[guid] = entry
  return entry
end

-- The class and level of a listed player, read live from its roster GUID, so a
-- level gained this session shows (knowledge base, Chat channels, 2026-11-23:
-- the level is the 8th value, also for a member far away). Returns the
-- localized class, its file token and the level, each nil when unknown; nil
-- for a name without a roster GUID (group, guild, friend or near only).
function Players:Details(name)
  local entry = type(name) == "string" and self.info[name] or nil
  local guid = type(entry) == "table" and entry.guid or nil
  local read = GetGlobal("GetPlayerInfoByGUID")
  if type(guid) ~= "string" or type(read) ~= "function" then return nil end
  local ok, class, classFile, _, _, _, _, _, level = pcall(read, guid)
  if not ok or IsSecret(class) or IsSecret(classFile) or IsSecret(level) then return nil end
  if type(class) ~= "string" or class == "" then class = nil end
  if type(classFile) ~= "string" or classFile == "" then classFile = nil end
  if type(level) ~= "number" or level < 1 or level ~= math.floor(level) then level = nil end
  if not class and not level then return nil end
  return class, classFile, level
end

-- True when a signed proof puts this roster name in our ruleset scope: a
-- verified ticket, or a verified scoreboard copy ranking it with our region.
function Players:InOurScope(name)
  if type(name) ~= "string" or not OwnScope() then return false end
  local ticket, boards = WF.Ticket, WF.Boards
  if type(ticket) == "table" and type(ticket.Verified) == "function" then
    local ok, verified = pcall(ticket.Verified, ticket, name)
    if ok and verified then return true end
  end
  if type(boards) == "table" and type(boards.HasPlayer) == "function" then
    local ok, listed = pcall(boards.HasPlayer, boards, name, WF.Ruleset.region)
    if ok and listed then return true end
  end
  return false
end

-- Warfront players known beyond the roster, as { name, tag }, the strongest tag
-- kept per name: near us, then group, guild, friend (decision 0080).
local TAG_RANK = { near = 4, group = 3, guild = 2, friend = 1 }

local function KnownElsewhere(now)
  local found = {}
  local function Add(name, tag)
    name = Players.CleanName(name)
    if not name then return end
    if not found[name] or TAG_RANK[tag] > TAG_RANK[found[name]] then found[name] = tag end
  end
  local transport, directory = WF.Transport, WF.Directory
  if transport and type(transport.KnownPlayers) == "function" then
    local ok, list = pcall(transport.KnownPlayers, transport, now)
    if ok and type(list) == "table" then
      for i = 1, #list do Add(list[i].name, list[i].tag) end
    end
  end
  if directory and type(directory.KnownPlayers) == "function" then
    local ok, list = pcall(directory.KnownPlayers, directory, now)
    if ok and type(list) == "table" then
      for i = 1, #list do Add(list[i].name, list[i].tag) end
    end
  end
  return found
end

-- The other side's online players (decision 0148), mixed into the list with
-- their faction and ruleset; same region, since links and the channel stay in
-- one region. Display only: `self.far` marks them so that nothing else (our
-- own summary above all) takes them for players of our side.
function Players:ApplyFar(names, info, seen, me, now)
  local far = {}
  self.far = far
  local source = WF.FarPlayers
  if type(source) ~= "table" or type(source.Entries) ~= "function" then return end
  local ok, list = pcall(source.Entries, source, now)
  if not ok or type(list) ~= "table" then return end
  local region = OwnRegion()
  for i = 1, #list do
    local entry = list[i]
    local name = type(entry) == "table" and entry.name or nil
    if type(name) == "string" and name ~= me and not seen[name] and #names < self.MAX_NAMES then
      seen[name] = true
      names[#names + 1] = name
      far[name] = true
      info[name] = { faction = entry.faction, region = region, ruleset = entry.label }
    end
  end
end

-- Rebuilds names from the roster and the other sources. Returns true when
-- anything was read.
function Players:Read(now)
  now = now or Now()
  self:RememberOwn()
  self.readAt = now
  self.dirty = false
  local names = self.names
  local index = #names
  while index > 0 do
    table.remove(names)
    index = index - 1
  end
  local tags = {}
  self.tags = tags
  local info = {}
  self.info = info
  local seen = {}
  -- name -> true for the names read from our channel roster (decision 0148:
  -- only these go into our summary for the other side).
  local fromRoster = {}
  self.roster = fromRoster
  local me = MyName()
  self.me = me
  local elsewhere = KnownElsewhere(now)
  for name, tag in pairs(elsewhere) do
    if name ~= me and #names < self.MAX_NAMES then
      seen[name] = true
      names[#names + 1] = name
      tags[name] = tag
    end
  end
  if not self:Joined() then
    self.displayIndex = nil
    self:ApplyFar(names, info, seen, me, now)
    if me and #names > 0 then names[#names + 1] = me end
    self:ApplyHeard(names, info, tags, me)
    table.sort(names, function(a, b) return string.lower(a) < string.lower(b) end)
    self.count = #names
    self.updatedAt = #names > 0 and now or self.updatedAt
    return #names > 0
  end
  if me then
    seen[me] = true
    names[#names + 1] = me
  end
  local display, count = self:FindDisplay()
  self.displayIndex = display
  local chat = GetGlobal("C_ChatInfo")
  local roster = type(chat) == "table" and chat.GetChannelRosterInfo or nil
  local missing = false
  if display and type(roster) == "function" then
    local member = 1
    while member <= count and #names < self.MAX_NAMES do
      local ok, name, _, _, guid = pcall(roster, display, member)
      name = ok and Players.CleanName(name) or nil
      if not name then
        missing = true
      else
        if not seen[name] then
          seen[name] = true
          names[#names + 1] = name
        end
        fromRoster[name] = true
        if not info[name] then info[name] = self:GuidInfo(guid, now, name) end
      end
      member = member + 1
    end
    if count > 0 then self.answers = self.answers + 1 end
  end
  -- Entries the server has not sent yet: read again shortly.
  if missing then self.dirty = true end
  self:ApplyFar(names, info, seen, me, now)
  self:ApplyHeard(names, info, tags, me)
  table.sort(names, function(a, b) return string.lower(a) < string.lower(b) end)
  self.count = #names
  self.updatedAt = now
  return true
end

-- Asks for a fresh member list through the directory's guarded fetch. False
-- when too soon or not joined.
function Players:Request(now)
  now = now or Now()
  if self.requestedAt and now - self.requestedAt < self.MIN_GAP then return false end
  if not self:Joined() then
    self:Read(now)
    return false
  end
  self.requestedAt = now
  local directory = WF.Directory
  if directory and type(directory.RequestFetch) == "function" then
    local ok, asked = pcall(directory.RequestFetch, directory, now)
    if ok and asked then self.requests = self.requests + 1 end
  end
  self:Read(now)
  return true
end

-- Called by the Players tab once per second while it is shown.
function Players:Tick(now)
  now = now or Now()
  local last = self.requestedAt
  if not last or now - last >= self.REFRESH then return self:Request(now) end
  if (self.dirty and (not self.readAt or now - self.readAt >= self.READ_GAP))
      or not self.readAt or now - self.readAt >= self.MERGE_GAP then
    self:Read(now)
  end
  return false
end

function Players:Summary()
  return "players=" .. self.count .. " requests=" .. self.requests .. " answers=" .. self.answers
    .. " display=" .. tostring(self.displayIndex)
end

local function OnRosterEvent(_, displayIndex)
  -- Our display position is checked at read time; any roster change marks dirty.
  if Players.displayIndex == nil or displayIndex == nil or displayIndex == Players.displayIndex then
    Players.dirty = true
  end
end

local function OnChannelsChanged()
  Players.displayIndex = nil
  Players.dirty = true
  Players:RememberOwn()
end

if WF.RegisterEvent then
  WF.RegisterEvent("CHANNEL_ROSTER_UPDATE", OnRosterEvent)
  WF.RegisterEvent("CHANNEL_COUNT_UPDATE", OnRosterEvent)
  WF.RegisterEvent("CHANNEL_UI_UPDATE", OnChannelsChanged)
end
