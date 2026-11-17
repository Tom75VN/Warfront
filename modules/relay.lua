local WF = Warfront

-- Cross-faction relay over Battle.net friends (decision 0068).
--
-- One crossing only: a faction channel line -> an elected bridge -> one
-- Battle.net game-data message -> an opposite-faction client, which applies it
-- and rebroadcasts it once on its own channel as an R line. A relayed packet is
-- never bridged again, so loops cannot form.
--
-- Every number below is provisional until measured on Forever (decision 0068).
-- Keep each relay file far below Lua 5.1's limit of 200 active locals
-- (.claude/forever-compatibility.md, Top-level local limit): scalar tunables
-- are fields of K, and modules/relay_bnet.lua (Battle.net side) loads next
-- and reads the helpers it needs through Relay.Kit.

local Relay = {
  received = 0, delivered = 0, deliverErrors = 0, duplicates = 0, directDuplicates = 0,
  sent = 0, sentBytes = 0, sendErrors = 0, sendRefused = 0,
  queuedTotal = 0, coalesced = 0, dropped = 0, expired = 0, noLink = 0,
  bridged = 0, notElected = 0, oversize = 0, foreign = 0,
  probesSent = 0, probesAnswered = 0, bulkSent = 0, bulkParts = 0, bulkIn = 0,
  acksSent = 0, acksHeard = 0, retries = 0, unacked = 0,
  rebroadcasts = 0, rebroadcastCancelled = 0, rebroadcastDropped = 0, rebroadcastFailed = 0,
  beaconsSent = 0, beaconsHeard = 0, hellosSent = 0, hellosHeard = 0, scans = 0,
  rejects = {},
}
WF.Relay = Relay

-- Wire --------------------------------------------------------------------------

-- Scalar tunables share one table: each would otherwise be a chunk local.
local K = {}
K.PROTOCOL = 1
K.PREFIX = "WF"
K.LEVEL = WF.channelLevel
-- Larger Battle.net payloads are unverified on Forever: stay at the chat limit,
-- except toward a link that proved larger ones (BULK, decision 0080, risk B68).
K.WIRE_MAX = 255
-- Each link measures itself: one size probe Z of PROBE_BYTES after its hello,
-- answered by Y with the bytes received. A link that answered with the full
-- size gets several relayed packets per message (M, parts joined by "|", which
-- no body holds), up to MAX bytes and PARTS packets; a link that never answered
-- within WAIT s, or refused one, stays at one packet per message and is probed
-- again RETRY s later. A refused bulk send turns the link back to single lines.
-- A received Z or M may be up to IN_MAX bytes; every other kind stays at WIRE_MAX.
-- Under a backlog the first packet for a proven link waits at most HOLD s for
-- the budget to cover the packets queued behind it for that link.
local BULK = { PROBE_BYTES = 600, MAX = 900, PARTS = 6, WAIT = 30, RETRY = 3600, IN_MAX = 1000, HOLD = 1 }
-- A state, routine or catch-up packet that waited AGED.WAIT s goes before the
-- lanes above it, at most one every AGED.GAP s (decision 0081 § 3): a steady
-- critical flow cannot starve them. Control packets still go first.
BULK.AGED = { WAIT = 20, GAP = 1, at = nil }
K.MAX_BODY = 200
K.MAX_ENCODED_NAME = 72
K.MAX_NAME_BYTES = 48

-- Links and discovery -------------------------------------------------------------

K.MAX_LINKS = 6
K.LINK_TTL = 300
K.KEEPALIVE = 120
-- An unanswered hello waits HELLO.first, then twice as long each time, up to
-- HELLO.max (decision 0077 § 3): a friend without Warfront costs almost nothing.
local HELLO = { first = 120, max = 1800 }
K.REPLY_GAP = 30
local SCAN = { INTERVAL = 60, DEBOUNCE = 5, MIN_GAP = 15, SLICE = 20, MAX_FRIENDS = 200, MAX_GAME_ACCOUNTS = 4, MAX_HELLOS = 8 }

-- Bridges and election -------------------------------------------------------------

local BEACON = { INTERVAL = 90, JITTER = 30, RETRY = 15, TTL = 240 }
K.MAX_HOLDERS = 64
-- Two bridges carry routine packets, so one bridge that left without a
-- withdrawal beacon (or lies about its links) cannot silence an origin.
K.ROUTINE_BRIDGES = 2
K.CRITICAL_BRIDGES = 3

-- Outbound budget and queue: one budget for every link and copy ------------------

K.BUDGET_RATE = 600
K.BUDGET_BURST = 1200
-- A send Battle.net refuses empties the budget and halves its rate for
-- bucket.slowFor seconds (decision 0077 § 3); a new refusal extends it.
K.QUEUE_MAX = 64
K.MAX_SENDS_PER_PUMP = 8
-- "catchup": owner catch-up with links (decision 0081 § 1), always last.
local LANE_ORDER = { "control", "critical", "state", "routine", "catchup" }
local LANE_OF_CLASS = { C = "critical", S = "state", N = "routine" }
local TTL_OF_LANE = { control = 30, critical = 120, state = 30, routine = 60, catchup = 120 }
K.ACK_TIMEOUT = 5
K.MAX_RETRIES = 2
K.MAX_ACKS = 64

-- Inbound validation --------------------------------------------------------------

K.MAX_AGE = 120
K.MAX_SKEW = 30
K.DEDUP_TTL = 180
K.DEDUP_MAX = 2048
-- Players heard directly on our channel (AC-3, provisional): a relayed origin
-- never speaks for one of them.
K.DIRECT_TTL = 1800
K.DIRECT_MAX = 512
K.LIMIT_WINDOW = 10
-- Above the most an honest peer's budget can send in one window.
K.LINK_BYTES_PER_WINDOW = 9000
K.RELAYER_LINES_PER_WINDOW = 60
K.ORIGIN_WINDOW = 60
K.MAX_ORIGINS_PER_RELAYER = 100
K.MAX_TRACKED = 128

-- Far-channel rebroadcast -----------------------------------------------------------

-- The best-ranked far bridge for an origin speaks first; the others wait one
-- step per rank and stay silent once they hear its R line.
K.MAX_REBROADCAST = 32
K.REBROADCAST_JITTER = 0.3
K.REBROADCAST_RANK_STEP = 0.8
K.MAX_REBROADCAST_RANK = 3

-- An opposite-faction P heard on our own channel means the channel already
-- crosses factions: bridging then only duplicates traffic and stands down.
K.CROSSING_HOLD = 600

K.TICK = 0.1
K.SLOW_TICK = 1

local FACTION_OF_TAG = { Alliance = "A", Horde = "H" }
local OPPOSITE = { A = "H", H = "A" }
K.BASE36 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
K.TWO32 = 4294967296

local strByte, strChar, strFind, strFormat, strMatch, strGsub, strSub =
  string.byte, string.char, string.find, string.format, string.match, string.gsub, string.sub
local mathFloor, mathMin, mathMax, mathRandom = math.floor, math.min, math.max, math.random

-- State ---------------------------------------------------------------------------

local links = {}          -- gameAccountID -> link
local linkCount = 0
-- gameAccountID -> time of our last unanswered hello (at), wait before the next (wait)
local hello = { at = {}, wait = {} }
local holders = {}        -- elect name -> { links, at, expireAt } from B lines
local holderCount = 0
local lanes = { control = {}, critical = {}, state = {}, routine = {}, catchup = {} }
local queued = 0
local coalesceIndex = {}  -- coalescing key -> queued item
local acks = {}           -- dedup key -> pending acknowledgement
local ackCount = 0
local rebroadcast = {}    -- far-channel rebroadcasts, sorted by due time
local rebroadcastIndex = {}
local rebroadcastDue = {} -- origin session -> due time of its last rebroadcast
local bucket = { tokens = K.BUDGET_BURST, at = nil, slowUntil = nil, slowFor = 60 }
local seen, seenKeys, seenHead, seenTail, seenCount = {}, {}, 1, 0, 0
local hashCache, hashCacheCount = {}, 0
local beaconLinks, nextBeaconAt, beaconRetryAt = 0, 0, 0
local channelCrossedAt
-- Standing down needs two distinct senders within window seconds, never one
-- alone (AC-5, provisional): the declared faction is unverified. claimer and at:
-- last sender declaring the other faction; ours: identities heard declaring ours.
local crossing = { window = 60, ours = {} }
-- sendable: Battle.net usable; eligible: may also discover and bridge; bridge:
-- eligible with at least one live link.
local status = { sendable = false, eligible = false, bridge = false, reason = "starting" }

-- Small helpers -------------------------------------------------------------------

local function Now()
  local now = WF.Now and WF.Now() or 0
  if type(now) ~= "number" then return 0 end
  return now
end

local function IsSecret(value)
  if type(issecretvalue) ~= "function" then return false end
  local ok, secret = pcall(issecretvalue, value)
  return ok and secret and true or false
end

local function ServerTime()
  if type(GetServerTime) ~= "function" then return nil end
  local ok, value = pcall(GetServerTime)
  if not ok or type(value) ~= "number" or value <= 0 then return nil end
  return mathFloor(value)
end

local function MyRealmID()
  if type(GetRealmID) ~= "function" then return nil end
  local ok, value = pcall(GetRealmID)
  if not ok or type(value) ~= "number" then return nil end
  return value
end

-- Our game-mode record (decision 0072: 14 = PvP, 15 = Normal), or nil while the
-- ruleset is unresolved, unsupported or in conflict. Links are admitted by this
-- record, never by realm (decision 0112).
local function MyRecord()
  local ruleset = WF.Ruleset
  if type(ruleset) ~= "table" or type(ruleset.Scope) ~= "function" then return nil end
  local ok, scope = pcall(ruleset.Scope, ruleset)
  if not ok or not scope then return nil end
  local record = ruleset.record
  if type(record) ~= "number" or record ~= mathFloor(record) or record < 0 then return nil end
  return record
end

local function RealmNames()
  local name, normalized
  if type(GetRealmName) == "function" then
    local ok, value = pcall(GetRealmName)
    if ok and type(value) == "string" and value ~= "" then name = value end
  end
  if type(GetNormalizedRealmName) == "function" then
    local ok, value = pcall(GetNormalizedRealmName)
    if ok and type(value) == "string" and value ~= "" then normalized = value end
  end
  return name, normalized
end

local function Lockdown()
  if type(C_ChatInfo) ~= "table" or type(C_ChatInfo.InChatMessagingLockdown) ~= "function" then return false end
  local ok, locked = pcall(C_ChatInfo.InChatMessagingLockdown)
  return ok and locked == true
end

local function InInstance()
  if type(IsInInstance) ~= "function" then return false end
  local ok, inside = pcall(IsInInstance)
  return ok and inside == true
end

local function BattleNetReady()
  if type(C_BattleNet) ~= "table" or type(C_BattleNet.SendGameData) ~= "function"
      or type(C_BattleNet.GetGameAccountInfoByID) ~= "function" then
    return false
  end
  if type(BNConnected) == "function" then
    local ok, connected = pcall(BNConnected)
    if ok and not connected then return false end
  end
  return true
end

local function MyFaction()
  local capture = WF.Capture
  if not capture or type(capture.MyFaction) ~= "function" then return nil end
  return capture:MyFaction()
end

local function MyIdentity()
  local capture = WF.Capture
  if not capture or type(capture.Me) ~= "function" then return nil end
  return capture:Me()
end

local function MySession()
  local storage = WF.Storage
  local db = storage and type(storage.GetDB) == "function" and storage:GetDB() or nil
  local session = db and db.session and db.session.id
  if type(session) ~= "string" then return nil end
  return session
end

-- Realm-free character identity (decision 0096). ElectName still strips a
-- legacy suffix from in-memory data built before the change.
local function ElectName(identity)
  if type(identity) ~= "string" then return nil end
  return strMatch(identity, "^([^@]+)@") or identity
end

local function Base36(value)
  value = mathFloor(tonumber(value) or 0)
  if value <= 0 then return "0" end
  local output = ""
  while value > 0 do
    local digit = value % 36
    output = strSub(K.BASE36, digit + 1, digit + 1) .. output
    value = mathFloor(value / 36)
  end
  return output
end

local function IsPrintableBody(text)
  if type(text) ~= "string" or #text > K.MAX_BODY then return false end
  if strFind(text, "|", 1, true) then return false end
  return not strFind(text, "[^\32-\126]")
end

local function Reject(reason)
  local rejects = Relay.rejects
  rejects[reason] = (rejects[reason] or 0) + 1
  Relay.lastReject = reason
  return false
end

-- Origin names ------------------------------------------------------------------
-- Letters travel as they are; every other byte as %XX, so UTF-8 names stay
-- printable ASCII. Decoding accepts only the canonical form.

local function EncodeName(name)
  return (strGsub(name, "[^A-Za-z]", function(c) return strFormat("%%%02X", strByte(c)) end))
end

-- Letters (ASCII or UTF-8) with single spaces between the first name and the
-- surname: the Forever chat name "First Surname" (decision 0070).
local function ValidName(name)
  if type(name) ~= "string" or #name < 2 or #name > K.MAX_NAME_BYTES then return false end
  local i, n = 1, #name
  while i <= n do
    local b = strByte(name, i)
    if b == 32 then
      if i == 1 or i == n or strByte(name, i - 1) == 32 then return false end
      i = i + 1
    elseif b < 128 then
      if not ((b >= 65 and b <= 90) or (b >= 97 and b <= 122)) then return false end
      i = i + 1
    else
      local extra
      if b >= 194 and b <= 223 then extra = 1
      elseif b >= 224 and b <= 239 then extra = 2
      elseif b >= 240 and b <= 244 then extra = 3
      else return false end
      if i + extra > n then return false end
      for k = 1, extra do
        local c = strByte(name, i + k)
        if c < 128 or c > 191 then return false end
      end
      i = i + extra + 1
    end
  end
  return true
end

local function DecodeName(text)
  if type(text) ~= "string" or text == "" or #text > K.MAX_ENCODED_NAME then return nil end
  local stripped = strGsub(text, "%%%x%x", "")
  if strFind(stripped, "[^A-Za-z]") then return nil end
  local name = strGsub(text, "%%(%x%x)", function(hex) return strChar(tonumber(hex, 16)) end)
  if not ValidName(name) or EncodeName(name) ~= text then return nil end
  return name
end

-- Plain character name of an identity, or nil. Pre-0096 identities may still
-- carry @realm in memory while a SavedVariables migration is being adopted.
local function OriginName(identity)
  if type(identity) ~= "string" then return nil end
  local names = WF.Names
  local name = names and names.Short and names.Short(identity) or (strMatch(identity, "^([^@]+)@") or identity)
  if not ValidName(name) then return nil end
  return name
end

-- Rendezvous hashing --------------------------------------------------------------
-- Exact unsigned 32-bit arithmetic in Lua 5.1 doubles, without any bit library,
-- so every client computes the same scores.

local XOR4 = {}
for a = 0, 15 do
  for b = 0, 15 do
    local result, place, x, y = 0, 1, a, b
    for _ = 1, 4 do
      if x % 2 ~= y % 2 then result = result + place end
      x, y, place = mathFloor(x / 2), mathFloor(y / 2), place * 2
    end
    XOR4[a * 16 + b] = result
  end
end

local function Xor32(a, b)
  local result, place = 0, 1
  for _ = 1, 8 do
    result = result + XOR4[(a % 16) * 16 + b % 16] * place
    a, b, place = mathFloor(a / 16), mathFloor(b / 16), place * 16
  end
  return result
end

local function Mul32(a, b)
  local aHi, aLo = mathFloor(a / 65536), a % 65536
  local bHi, bLo = mathFloor(b / 65536), b % 65536
  return (((aHi * bLo + aLo * bHi) % 65536) * 65536 + aLo * bLo) % K.TWO32
end

-- 32-bit finalizer: xor-shift and multiply rounds with full avalanche.
local function Mix(x)
  x = Xor32(x, mathFloor(x / 65536))
  x = Mul32(x, 2246822507)
  x = Xor32(x, mathFloor(x / 8192))
  x = Mul32(x, 3266489909)
  return Xor32(x, mathFloor(x / 65536))
end

-- FNV-1a over the bytes, then the finalizer.
local function Hash(text)
  local cached = hashCache[text]
  if cached then return cached end
  local h = 2166136261
  for i = 1, #text do
    h = Mul32(Xor32(h, strByte(text, i)), 16777619)
  end
  h = Mix(h)
  if hashCacheCount >= 512 then hashCache, hashCacheCount = {}, 0 end
  hashCache[text] = h
  hashCacheCount = hashCacheCount + 1
  return h
end

-- The "#" prefix keeps names and keys in separate hash domains; both are cached.
local function Score(key, name)
  return Mix(Xor32(Hash(key), Hash("#" .. name)))
end

local function Ahead(scoreA, nameA, scoreB, nameB)
  if scoreA ~= scoreB then return scoreA > scoreB end
  return nameA < nameB
end

-- Deduplication -------------------------------------------------------------------

-- Relay.relayedOnly[key]: a key seen only as a relayed copy so far (a chain
-- line, decision 0077 step 4b). Its direct copy, stronger evidence, is then
-- still applied once (handlers are idempotent, rule R8).
Relay.relayedOnly = {}
Relay.rejectedKeys = {}

local function PopSeen()
  local key = seenKeys[seenHead]
  seenKeys[seenHead] = nil
  seenHead = seenHead + 1
  seenCount = seenCount - 1
  if key ~= nil then
    seen[key] = nil
    Relay.relayedOnly[key] = nil
    Relay.rejectedKeys[key] = nil
  end
end

-- Sessions travel in clear and sequences grow by one, so session:sequence alone
-- let a forged copy hide a genuine line. The key also holds the origin, id and
-- body: honest copies (direct, relayed, rebroadcast) are identical and still
-- meet; a copy that differs is a different line. Acks keep session:sequence.
local function DedupKey(identity, session, sequence, id, body)
  return tostring(identity) .. "|" .. session .. ":" .. sequence .. ":" .. tostring(id) .. ":" .. tostring(body)
end

local function Seen(key, now)
  local expiry = seen[key]
  return expiry ~= nil and expiry > now
end

local function MarkSeen(key, now)
  if seen[key] ~= nil then return end
  seenTail = seenTail + 1
  seenKeys[seenTail] = key
  seenCount = seenCount + 1
  seen[key] = now + K.DEDUP_TTL
  while seenCount > K.DEDUP_MAX do PopSeen() end
end

local direct, directCount = {}, 0   -- identity -> last time heard on our channel

local function NoteDirect(identity, now)
  if not identity then return end
  if not direct[identity] then
    if directCount >= K.DIRECT_MAX then
      local oldestName, oldestAt
      for name, at in pairs(direct) do
        if not oldestAt or at < oldestAt then oldestName, oldestAt = name, at end
      end
      direct[oldestName] = nil
      crossing.ours[oldestName] = nil
      directCount = directCount - 1
    end
    directCount = directCount + 1
  end
  direct[identity] = now
end

local function HeardDirectly(identity, now)
  local at = direct[identity]
  return at ~= nil and now - at < K.DIRECT_TTL
end

local function PurgeDirect(now)
  for name, at in pairs(direct) do
    if now - at >= K.DIRECT_TTL then
      direct[name] = nil
      crossing.ours[name] = nil
      directCount = directCount - 1
    end
  end
end

local function PurgeSeen(now)
  while seenHead <= seenTail do
    local expiry = seen[seenKeys[seenHead]]
    if expiry and expiry > now then return end
    PopSeen()
  end
end

-- Bounded windows: bytes per link, lines and origins per relayer ------------------

local function NewWindow(limit)
  return { limit = limit, keys = {}, count = 0 }
end

local function WindowEntry(window, key, now, period)
  local entry = window.keys[key]
  if not entry then
    if window.count >= K.MAX_TRACKED then
      local oldestKey, oldestStart
      for k, e in pairs(window.keys) do
        if not oldestStart or e.start < oldestStart then oldestKey, oldestStart = k, e.start end
      end
      if oldestKey ~= nil then
        window.keys[oldestKey] = nil
        window.count = window.count - 1
      end
    end
    entry = { start = now, used = 0 }
    window.keys[key] = entry
    window.count = window.count + 1
  end
  if now - entry.start >= period then
    entry.start, entry.used, entry.set = now, 0, nil
  end
  return entry
end

local function Allow(window, key, now, amount)
  local entry = WindowEntry(window, key, now, K.LIMIT_WINDOW)
  if entry.used + amount > window.limit then return false end
  entry.used = entry.used + amount
  return true
end

local function AllowOrigin(window, via, origin, now)
  local entry = WindowEntry(window, via, now, K.ORIGIN_WINDOW)
  entry.set = entry.set or {}
  if entry.set[origin] then return true end
  if entry.used >= window.limit then return false end
  entry.set[origin] = true
  entry.used = entry.used + 1
  return true
end

local linkBytes = NewWindow(K.LINK_BYTES_PER_WINDOW)
local relayerLines = NewWindow(K.RELAYER_LINES_PER_WINDOW)
local relayerOrigins = NewWindow(K.MAX_ORIGINS_PER_RELAYER)

-- Links ---------------------------------------------------------------------------

local function LinkAlive(link, now)
  return now - link.lastHeard <= K.LINK_TTL
end

local function LiveLinkCount(now)
  local count = 0
  for _, link in pairs(links) do
    if LinkAlive(link, now) then count = count + 1 end
  end
  return count
end

local function DropLink(id, reason)
  if not links[id] then return end
  links[id] = nil
  linkCount = linkCount - 1
  if reason then Reject("link " .. reason) end
end

-- Server facts about a Battle.net game account: an opposite-faction WoW
-- character of our region, on any technical realm, or nil and a reason.
-- Battle.net authenticates this last hop. Its ruleset is not a server fact: the
-- hello declares it and OnHello admits only our own record (decision 0112).
local function Candidate(info, opposite)
  if type(info) ~= "table" or info.isOnline ~= true then return nil, "offline" end
  if info.clientProgram ~= (BNET_CLIENT_WOW or "WoW") then return nil, "not in WoW" end
  if info.isInCurrentRegion ~= true then return nil, "other region" end
  if type(info.gameAccountID) ~= "number" then return nil, "account id" end
  if FACTION_OF_TAG[info.factionName] ~= opposite then return nil, "same faction" end
  local name = info.characterName
  if type(name) ~= "string" or IsSecret(name) then return nil, "no character" end
  -- Names are unique per region (decision 0096): only the chat name is kept,
  -- "First Surname", whatever technical realm the character is on.
  local names = WF.Names
  if names then
    name = names.Split(name)
  else
    name = strMatch(name, "^([^%-]+)") or name
  end
  if not ValidName(name) then return nil, "character name" end
  return { id = info.gameAccountID, name = name, faction = opposite }
end

-- A same-realm, same-faction WoW character of a Battle.net friend: its chat
-- name, "First Surname", for the directory of contacts (decision 0077 § 5f).
-- An addon whisper never crosses factions, so only our own faction is kept.
function Relay.Ally(info, mine, realmID)
  if type(info) ~= "table" or info.isOnline ~= true then return nil end
  if info.clientProgram ~= (BNET_CLIENT_WOW or "WoW") or info.isInCurrentRegion == false then return nil end
  if info.realmID ~= realmID or FACTION_OF_TAG[info.factionName] ~= mine then return nil end
  local name = info.characterName
  if type(name) ~= "string" or IsSecret(name) then return nil end
  local names = WF.Names
  if names then
    name = names.Split(name)
  else
    name = strMatch(name, "^([^%-]+)") or name
  end
  if not ValidName(name) then return nil end
  -- A whisper to a first name alone never arrives, and that name may be shared.
  if names and names.Complete and not names.Complete(name) then return nil end
  return name
end

local function ResolveAccount(id)
  if type(id) ~= "number" then return nil, "sender id" end
  local opposite = OPPOSITE[MyFaction() or ""]
  if not opposite or not MyRecord() then return nil, "local state" end
  local ok, info = pcall(C_BattleNet.GetGameAccountInfoByID, id)
  if not ok then return nil, "account lookup" end
  local account, reason = Candidate(info, opposite)
  if not account then return nil, reason end
  if account.id ~= id then return nil, "account id" end
  return account
end

local function UpsertLink(account, now)
  local link = links[account.id]
  if link then
    link.name, link.faction, link.lastHeard = account.name, account.faction, now
    return link
  end
  if linkCount >= K.MAX_LINKS then
    local stalestId, stalest
    for id, other in pairs(links) do
      if not stalest or other.lastHeard < stalest.lastHeard then stalestId, stalest = id, other end
    end
    if not stalest or now - stalest.lastHeard <= K.KEEPALIVE then return nil end
    DropLink(stalestId, "replaced")
  end
  link = {
    id = account.id, name = account.name, faction = account.faction,
    firstAt = now, lastHeard = now, lastSentAt = now, repliedAt = nil,
    sent = 0, received = 0,
  }
  links[account.id] = link
  linkCount = linkCount + 1
  hello.at[account.id], hello.wait[account.id] = nil, nil
  return link
end

-- Live links ordered for one origin, best first, skipping `exclude`.
local function PickLinks(electKey, count, exclude, now)
  local list = {}
  for id, link in pairs(links) do
    if LinkAlive(link, now) and not (exclude and exclude[id]) then
      list[#list + 1] = { id = id, name = link.name, score = Score(electKey, link.name) }
    end
  end
  table.sort(list, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    if a.name ~= b.name then return a.name < b.name end
    return a.id < b.id
  end)
  local targets = {}
  for i = 1, mathMin(count, #list) do targets[i] = list[i].id end
  return targets
end

-- Outbound queue ------------------------------------------------------------------

-- WR<protocol>:<level>:<kind>:<campaign>: the sender's campaign header field
-- (decision 0103 § 4b), as on every WF line (modules/p2ptest.lua).
local function CampaignTag()
  local campaign = WF.Campaign
  if not campaign or type(campaign.Tag) ~= "function" then return "0.0.-" end
  local ok, tag = pcall(campaign.Tag, campaign)
  if ok and type(tag) == "string" then return tag end
  return "0.0.-"
end

local function Header(kind)
  return "WR" .. K.PROTOCOL .. ":" .. tostring(K.LEVEL) .. ":" .. kind .. ":" .. CampaignTag() .. ":"
end

local function RemoveAt(lane, index)
  local item = table.remove(lanes[lane], index)
  queued = queued - 1
  if item.coalesce and coalesceIndex[item.coalesce] == item then coalesceIndex[item.coalesce] = nil end
  return item
end

-- What a new packet may push out of a full queue, oldest first: never a lane
-- worth more than its own; control packets (hellos, acks) are never pushed out.
local EVICTABLE = {
  catchup = { "catchup" },
  routine = { "catchup", "routine" },
  state = { "catchup", "routine", "state" },
  critical = { "catchup", "routine", "state", "critical" },
  control = { "catchup", "routine", "state", "critical" },
}

local function MakeRoom(item)
  local order = EVICTABLE[item.lane]
  for i = 1, #order do
    if #lanes[order[i]] > 0 then
      RemoveAt(order[i], 1)
      Relay.dropped = Relay.dropped + 1
      return true
    end
  end
  return false
end

local function Enqueue(item, now)
  item.expires = item.expires or (now + TTL_OF_LANE[item.lane])
  item.queuedAt = item.queuedAt or now
  if item.coalesce then
    local old = coalesceIndex[item.coalesce]
    if old then
      -- The newest state replaces the queued one in place, keeping its turn.
      old.payload, old.bytes, old.dedupKey, old.expires = item.payload, item.bytes, item.dedupKey, item.expires
      old.copies, old.targets, old.nextTarget, old.sentCopies = item.copies, nil, nil, nil
      Relay.coalesced = Relay.coalesced + 1
      return true
    end
  end
  if queued >= K.QUEUE_MAX and not MakeRoom(item) then
    Relay.dropped = Relay.dropped + 1
    return false
  end
  local lane = lanes[item.lane]
  lane[#lane + 1] = item
  queued = queued + 1
  Relay.queuedTotal = Relay.queuedTotal + 1
  if item.coalesce then coalesceIndex[item.coalesce] = item end
  return true
end

-- `sizeTest`: a size probe or a bulk send; its refusal only marks the link as
-- single-line, it does not slow the whole relay down.
local function SendNow(id, payload, now, sizeTest)
  local ok, result = pcall(C_BattleNet.SendGameData, id, K.PREFIX, payload)
  if not ok then
    Relay.sendErrors = Relay.sendErrors + 1
    Relay.lastSendError = WF.Sanitize and WF.Sanitize(result, 120) or tostring(result)
    if sizeTest and links[id] then links[id].bulk = false end
    return false
  end
  Relay.lastSendResult = result
  local results = type(Enum) == "table" and Enum.SendAddonMessageResult or nil
  local success = type(results) == "table" and results.Success or nil
  if success ~= nil and result ~= nil and result ~= success then
    if sizeTest then
      Relay.sizeRefused = (Relay.sizeRefused or 0) + 1
      if links[id] then links[id].bulk = false end
      return false
    end
    Relay.sendRefused = Relay.sendRefused + 1
    -- Battle.net said no (throttle or other): stop at once and slow down.
    bucket.tokens = 0
    bucket.slowUntil = now + bucket.slowFor
    return false
  end
  Relay.sent = Relay.sent + 1
  Relay.sentBytes = Relay.sentBytes + #payload
  local link = links[id]
  if link then
    link.sent = link.sent + 1
    link.lastSentAt = now
  end
  return true
end

local function RegisterAck(item, now)
  if ackCount >= K.MAX_ACKS then
    local oldestKey, oldestDue
    for key, pending in pairs(acks) do
      if not oldestDue or pending.due < oldestDue then oldestKey, oldestDue = key, pending.due end
    end
    if oldestKey then
      acks[oldestKey] = nil
      ackCount = ackCount - 1
      Relay.unacked = Relay.unacked + 1
    end
  end
  local tried = {}
  for i = 1, #item.targets do tried[item.targets[i]] = true end
  if not acks[item.dedupKey] then ackCount = ackCount + 1 end
  acks[item.dedupKey] = {
    payload = item.payload, bytes = item.bytes, electKey = item.electKey,
    tried = tried, retries = 0, due = now + K.ACK_TIMEOUT,
  }
end

local function Refill(now)
  if not bucket.at then bucket.at = now end
  local elapsed = now - bucket.at
  if elapsed > 0 then
    local rate = K.BUDGET_RATE
    if bucket.slowUntil then
      if now < bucket.slowUntil then rate = K.BUDGET_RATE / 2 else bucket.slowUntil = nil end
    end
    bucket.tokens = mathMin(K.BUDGET_BURST, bucket.tokens + elapsed * rate)
    bucket.at = now
  end
end

-- The first packet still worth sending, by lane priority, unless a lower
-- lane's oldest packet has waited BULK.AGED.WAIT s; expired ones go.
local function Front(now)
  local first, firstName, aged, agedName
  for i = 1, #LANE_ORDER do
    local name = LANE_ORDER[i]
    local lane = lanes[name]
    while #lane > 0 and lane[1].expires <= now do
      RemoveAt(name, 1)
      Relay.expired = Relay.expired + 1
    end
    local head = lane[1]
    if head then
      if not first then
        first, firstName = head, name
      elseif i > 2 and now - (head.queuedAt or now) >= BULK.AGED.WAIT
          and (not aged or head.queuedAt < aged.queuedAt) then
        aged, agedName = head, name
      end
    end
  end
  if aged and firstName ~= "control" and now - (BULK.AGED.at or -BULK.AGED.GAP) >= BULK.AGED.GAP then
    BULK.AGED.at = now
    Relay.agedServed = (Relay.agedServed or 0) + 1
    return aged, agedName
  end
  return first, firstName
end

local function FinishItem(item, laneName, now)
  local lane = lanes[laneName]
  for i = 1, #lane do
    if lane[i] == item then RemoveAt(laneName, i) break end
  end
  if item.retryOf then
    local pending = acks[item.retryOf]
    if pending then
      for i = 1, #item.targets do pending.tried[item.targets[i]] = true end
    end
  elseif item.critical and item.attempted then
    -- Also when every copy was refused: the acknowledgement timeout then
    -- retries it like a lost copy (decision 0077 § 3), still bounded.
    RegisterAck(item, now)
  end
end

function BULK.Targets(item, now)
  if not item.targets then
    if item.target then
      item.targets = { item.target }
    else
      item.targets = PickLinks(item.electKey, item.copies, item.exclude, now)
    end
    item.nextTarget = 1
  end
  return item.targets[item.nextTarget]
end

-- The R header follows the campaign: its length is read at each use.
local function RHeader()
  local head = Header("R")
  return head, #head
end

-- Queued packets whose next copy also goes to `target`, for one bulk message
-- after `first` (BULK): relayed packets only, in lane order, within the
-- message size and the budget. Returns { item, lane } pairs, their bytes, and
-- whether a packet was left out only for want of budget.
function BULK.Companions(first, target, now)
  local rHead, rLength = RHeader()
  local picked, bytes, short = {}, #Header("M") + #first.payload - rLength, false
  for l = 1, #LANE_ORDER do
    local name = LANE_ORDER[l]
    if name ~= "control" then
      local lane = lanes[name]
      for i = 1, #lane do
        local item = lane[i]
        if #picked + 1 >= BULK.PARTS then return picked, bytes, short end
        if item ~= first and item.expires > now and strSub(item.payload, 1, rLength) == rHead
            and BULK.Targets(item, now) == target then
          local add = #item.payload - rLength + 1
          if bytes + add <= BULK.MAX then
            if bucket.tokens >= bytes + add then
              picked[#picked + 1] = { item = item, lane = name }
              bytes = bytes + add
            else
              short = true
            end
          end
        end
      end
    end
  end
  return picked, bytes, short
end

local function Pump(now)
  Refill(now)
  local sends = 0
  while sends < K.MAX_SENDS_PER_PUMP do
    local item, laneName = Front(now)
    if not item then return end
    local target = BULK.Targets(item, now)
    if not target then
      if (item.sentCopies or 0) == 0 then Relay.noLink = Relay.noLink + 1 end
      FinishItem(item, laneName, now)
    else
      if bucket.tokens < item.bytes then return end
      local link = links[target]
      local companions, ignored, short
      local rHead, rLength = RHeader()
      if link and link.bulk == true and strSub(item.payload, 1, rLength) == rHead then
        companions, ignored, short = BULK.Companions(item, target, now)
        -- Wait a moment for the budget to carry the whole batch.
        if short and now - (item.queuedAt or now) < BULK.HOLD then return end
      end
      if companions and #companions > 0 then
        -- Several relayed packets in one message to a link that proved it.
        local parts = { strSub(item.payload, rLength + 1) }
        for i = 1, #companions do parts[#parts + 1] = strSub(companions[i].item.payload, rLength + 1) end
        local payload = Header("M") .. table.concat(parts, "|")
        bucket.tokens = bucket.tokens - #payload
        local sent = SendNow(target, payload, now, true)
        if sent then
          Relay.bulkSent = Relay.bulkSent + 1
          Relay.bulkParts = Relay.bulkParts + #parts
        end
        local all = { { item = item, lane = laneName } }
        for i = 1, #companions do all[#all + 1] = companions[i] end
        for i = 1, #all do
          local entry = all[i].item
          entry.attempted = true
          if sent then entry.sentCopies = (entry.sentCopies or 0) + 1 end
          entry.nextTarget = entry.nextTarget + 1
          if entry.nextTarget > #entry.targets then FinishItem(entry, all[i].lane, now) end
        end
      else
        bucket.tokens = bucket.tokens - item.bytes
        item.attempted = true
        if SendNow(target, item.payload, now, item.sizeTest) then item.sentCopies = (item.sentCopies or 0) + 1 end
        item.nextTarget = item.nextTarget + 1
        if item.nextTarget > #item.targets then FinishItem(item, laneName, now) end
      end
      sends = sends + 1
    end
  end
end

local function QueueControl(id, payload, now)
  return Enqueue({ lane = "control", target = id, payload = payload, bytes = #payload }, now)
end

local function SendHello(id, flag, now)
  local faction, record = MyFaction(), MyRecord()
  if not faction or not record then return false end
  local payload = Header("H") .. flag .. ":" .. faction .. ":" .. record .. ":" .. tostring(WF.version)
  if not QueueControl(id, payload, now) then return false end
  Relay.hellosSent = Relay.hellosSent + 1
  local link = links[id]
  if link then link.lastSentAt = now end
  return true
end

-- The size probe of a link (BULK): once after its hello, then every RETRY s
-- while it never answered.
function BULK.Probe(id, link, now)
  if link.bulk == true or not link.version then return end
  if link.probeNonce then
    if now - link.probeAt >= BULK.WAIT then
      link.probeNonce, link.bulk = nil, false
    end
    return
  end
  if link.probeAt and now - link.probeAt < BULK.RETRY then return end
  local nonce = Base36(mathRandom(1, 2147483646))
  local head = Header("Z") .. nonce .. ":"
  local payload = head .. string.rep("x", BULK.PROBE_BYTES - #head)
  if Enqueue({ lane = "control", target = id, payload = payload, bytes = #payload, sizeTest = true }, now) then
    link.probeNonce, link.probeAt = nonce, now
    Relay.probesSent = Relay.probesSent + 1
  end
end

local function QueueAck(id, packet, now)
  if QueueControl(id, Header("A") .. packet.session .. ":" .. packet.seqText, now) then
    Relay.acksSent = Relay.acksSent + 1
  end
end

local function CheckAcks(now)
  for key, pending in pairs(acks) do
    if now >= pending.due then
      if pending.retries >= K.MAX_RETRIES or not status.sendable then
        acks[key] = nil
        ackCount = ackCount - 1
        Relay.unacked = Relay.unacked + 1
      else
        pending.retries = pending.retries + 1
        pending.due = now + K.ACK_TIMEOUT * (pending.retries + 1)
        local exclude = pending.tried
        if #PickLinks(pending.electKey, 1, exclude, now) == 0 then exclude = nil end
        Enqueue({
          lane = "critical", payload = pending.payload, bytes = pending.bytes, electKey = pending.electKey,
          copies = 1, exclude = exclude, retryOf = key, critical = true,
        }, now)
        Relay.retries = Relay.retries + 1
      end
    end
  end
end

-- Bridges -------------------------------------------------------------------------

-- Beacons repeat more slowly above four known bridges (UpdateBeacon), so a
-- beacon lives longer by the same factor: a live bridge never expires between
-- two of its beacons. No extra beacon is ever sent.
local function BeaconScale()
  return mathMax(1, holderCount / 4)
end

local function Bridges(now, me)
  local list = {}
  for name, holder in pairs(holders) do
    if holder.links > 0 and now < holder.expireAt and name ~= me then list[#list + 1] = name end
  end
  list[#list + 1] = me
  return list
end

local function Rank(electKey, me, list)
  local mine = Score(electKey, me)
  local rank = 0
  for i = 1, #list do
    local other = list[i]
    if other ~= me and Ahead(Score(electKey, other), other, mine, me) then rank = rank + 1 end
  end
  return rank
end

local function PruneHolders(now)
  for name, holder in pairs(holders) do
    if holder.links <= 0 or now >= holder.expireAt then
      holders[name] = nil
      holderCount = holderCount - 1
    end
  end
end

local function SendLine(id, body, key, priority)
  local p2p = WF.P2PTest
  if not p2p or type(p2p.SendRelayLine) ~= "function" then return false end
  local ok, accepted = pcall(p2p.SendRelayLine, id, body, key, priority)
  return ok and accepted and true or false
end

local function UpdateBeacon(now)
  if now < beaconRetryAt then return end
  local count = status.bridge and LiveLinkCount(now) or 0
  if count > 0 and beaconLinks > 0 and now < nextBeaconAt then return end
  if count == 0 and beaconLinks == 0 then return end
  if SendLine("B", tostring(count), "B") then
    beaconLinks = count
    Relay.beaconsSent = Relay.beaconsSent + 1
    local interval = BEACON.INTERVAL * BeaconScale()
    nextBeaconAt = now + interval + mathRandom() * BEACON.JITTER
  else
    beaconRetryAt = now + BEACON.RETRY
  end
end

-- Far-channel rebroadcast -----------------------------------------------------------

local function ScheduleRebroadcast(packet, now)
  if #rebroadcast >= K.MAX_REBROADCAST then
    Relay.rebroadcastDropped = Relay.rebroadcastDropped + 1
    return
  end
  local me = ElectName(MyIdentity())
  local rank = me and mathMin(K.MAX_REBROADCAST_RANK, Rank(packet.session, me, Bridges(now, me))) or 0
  local due = now + mathRandom() * K.REBROADCAST_JITTER + rank * K.REBROADCAST_RANK_STEP
  -- One origin keeps its arrival order: an event never follows the newer
  -- state after it. Other origins are not held back.
  local previous = rebroadcastDue[packet.session]
  if previous and previous > due then due = previous end
  rebroadcastDue[packet.session] = due
  local item = {
    key = packet.key, session = packet.session, due = due, class = packet.class, coalesce = packet.coalesce,
    body = packet.faction .. "," .. packet.stamp .. "," .. packet.session .. "," .. packet.seqText .. ","
      .. packet.encodedName .. "," .. packet.id .. "," .. packet.body,
  }
  local index = #rebroadcast + 1
  while index > 1 and rebroadcast[index - 1].due > due do index = index - 1 end
  table.insert(rebroadcast, index, item)
  rebroadcastIndex[packet.key] = item
end

local function CancelRebroadcast(key)
  local item = rebroadcastIndex[key]
  if not item or item.cancelled then return end
  item.cancelled = true
  rebroadcastIndex[key] = nil
  Relay.rebroadcastCancelled = Relay.rebroadcastCancelled + 1
end

local function ReleaseRebroadcasts(now)
  while rebroadcast[1] and (rebroadcast[1].cancelled or rebroadcast[1].due <= now) do
    local item = table.remove(rebroadcast, 1)
    local last = rebroadcastDue[item.session]
    if last and last <= now then rebroadcastDue[item.session] = nil end
    if not item.cancelled then
      rebroadcastIndex[item.key] = nil
      local key = item.class == "S" and item.coalesce and ("R," .. item.coalesce) or nil
      local priority = item.class == "C" or nil
      if SendLine("R", item.body, key, priority) then
        Relay.rebroadcasts = Relay.rebroadcasts + 1
      else
        Relay.rebroadcastFailed = Relay.rebroadcastFailed + 1
      end
    end
  end
end

-- Packets ---------------------------------------------------------------------------

local BN_PACKET = "^([AH]):(%d+):([0-9A-F]+):([0-9A-Z]+):([%w%%]+):([A-Z][A-Z0-9]*):(.*)$"
local LINE_PACKET = "^([AH]),(%d+),([0-9A-F]+),([0-9A-Z]+),([%w%%]+),([A-Z][A-Z0-9]*),(.*)$"

local function RelayClassOf(id, body)
  local capture = WF.Capture
  if not capture or type(capture.RelayClass) ~= "function" then return nil end
  local ok, class, key = pcall(capture.RelayClass, capture, id, body)
  if not ok or not LANE_OF_CLASS[class] then return nil end
  return class, key
end

-- Fields of a relayed packet, checked for shape, origin, age and class.
-- `wanted`: the origin faction a same-faction chain line must state
-- (decision 0077 step 4b); nil for the cross-faction relay, whose origin is
-- the other faction.
local function ParsePacket(text, pattern, now, wanted)
  local faction, stampText, session, seqText, encodedName, id, body = strMatch(text, pattern)
  if not faction then return nil, "packet format" end
  local mine = MyFaction()
  if not mine then return nil, "local state" end
  if wanted then
    if faction ~= wanted then return nil, "chain faction" end
  elseif faction == mine then
    return nil, "own faction"
  end
  if #stampText > 10 or #session < 4 or #session > 12 or #seqText > 6 or #id > 4 then
    return nil, "packet field"
  end
  local sequence = tonumber(seqText, 36)
  if not sequence or sequence > 2147483647 or Base36(sequence) ~= seqText then return nil, "packet sequence" end
  if session == MySession() then return nil, "own session" end
  local stamp, clock = tonumber(stampText), ServerTime()
  if not stamp or not clock then return nil, "no clock" end
  if clock - stamp > K.MAX_AGE then return nil, "stale" end
  if stamp - clock > K.MAX_SKEW then return nil, "future" end
  if not IsPrintableBody(body) then return nil, "packet body" end
  local name = DecodeName(encodedName)
  if not name then return nil, "origin name" end
  local identity = WF.Capture and WF.Capture.Identity and WF.Capture.Identity(name)
  if not identity or identity == MyIdentity() then return nil, "origin identity" end
  local class, coalesce = RelayClassOf(id, body)
  if not class then return nil, "not relayable" end
  local capture = WF.Capture
  if capture and capture.ValidateForward and not capture:ValidateForward(id, body) then
    return nil, "invalid relay body"
  end
  return {
    faction = faction, stamp = stampText, session = session, seqText = seqText, sequence = sequence,
    encodedName = encodedName, name = name, identity = identity, id = id, body = body,
    class = class, coalesce = coalesce and (identity .. "|" .. coalesce) or nil,
    key = DedupKey(identity, session, sequence, id, body),
  }
end

local function Deliver(packet, via, hop)
  local capture = WF.Capture
  if not capture or type(capture.OnMessage) ~= "function" then return false end
  local ok, err = pcall(capture.OnMessage, capture, packet.id, packet.body, packet.name, false,
    { via = via, faction = packet.faction, hop = hop })
  if ok then
    if err ~= false then Relay.delivered = Relay.delivered + 1 end
    return err ~= false or capture.forwardable == true
  else
    Relay.deliverErrors = Relay.deliverErrors + 1
    if WF.RecordError then WF.RecordError("relay delivery", err) end
  end
  return false
end

-- hop "B": straight from a Battle.net link; hop "C": an R line on our channel.
local function Accept(packet, via, hop, linkId, now)
  local duplicate = Seen(packet.key, now)
  if duplicate and Relay.rejectedKeys[packet.key] then return false end
  if hop == "B" and packet.class == "C" then QueueAck(linkId, packet, now) end
  if hop == "C" then CancelRebroadcast(packet.key) end
  -- A player heard on our own channel is never spoken for by a relay: honest
  -- copies of such a player's lines are only duplicates of what we heard.
  if HeardDirectly(packet.identity, now) then return Reject("origin heard") end
  if duplicate then
    Relay.duplicates = Relay.duplicates + 1
    return false
  end
  if not AllowOrigin(relayerOrigins, via, packet.identity, now) then return Reject("origin flood") end
  MarkSeen(packet.key, now)
  if not Deliver(packet, via, hop) then
    Relay.rejectedKeys[packet.key] = true
    return false
  end
  -- Receivers accept R lines only from a live beacon holder: without our own
  -- beacon, a rebroadcast would only spend the send gate.
  if hop == "B" and beaconLinks > 0 then ScheduleRebroadcast(packet, now) end
  -- Without the channel, the bridge also starts a critical fact down our
  -- chain of contacts (decision 0077 step 5, modules/chain.lua).
  if hop == "B" and WF.Chain and type(WF.Chain.OnBridged) == "function" then
    local started, startError = pcall(WF.Chain.OnBridged, WF.Chain, packet, now, via)
    if not started and WF.RecordError then WF.RecordError("chain bridged", startError) end
  end
  return true
end

-- Bridging a line of our own faction ---------------------------------------------

-- The bridges of `list` that heard the same line, us included (decision 0077
-- § 5g): only they can carry it in our place. `audience` is where the line was
-- heard: "GUILD" keeps our guild peers, "PARTY" or "RAID" our group mates,
-- "own" (our own line) our group mates, whose group copy is the one sure to
-- reach them; a whispered line keeps nobody else. Without an audience (a
-- channel line, which every bridge hears) the list is unchanged.
function Relay.HeardBy(list, me, audience, now)
  if audience == nil then return list end
  local chatType = audience == "own" and "PARTY" or audience
  local heard = {}
  local transport = WF.Transport
  if (chatType == "GUILD" or chatType == "PARTY" or chatType == "RAID")
      and transport and type(transport.Hearers) == "function" then
    local ok, names = pcall(transport.Hearers, transport, chatType, now)
    if ok and type(names) == "table" then
      for i = 1, #names do
        local name = ElectName(names[i])
        if name then heard[name] = true end
      end
    end
  end
  local kept = {}
  for i = 1, #list do
    if list[i] == me or heard[list[i]] then kept[#kept + 1] = list[i] end
  end
  return kept
end

function Relay:Bridge(identity, session, sequence, id, body, now, audience)
  if not status.bridge then return false end
  local class, coalesce = RelayClassOf(id, body)
  if not class then return false end
  local name = OriginName(identity)
  if not name or not IsPrintableBody(body) then
    self.foreign = self.foreign + 1
    return false
  end
  local me = ElectName(MyIdentity())
  local faction, stamp = MyFaction(), ServerTime()
  if not me or not faction or not stamp then return false end
  local list = self.HeardBy(Bridges(now, me), me, audience, now)
  if Rank(session, me, list) >= (class == "C" and K.CRITICAL_BRIDGES or K.ROUTINE_BRIDGES) then
    self.notElected = self.notElected + 1
    return false
  end
  local payload = Header("R") .. faction .. ":" .. stamp .. ":" .. session .. ":" .. Base36(sequence) .. ":"
    .. EncodeName(name) .. ":" .. id .. ":" .. body
  if #payload > K.WIRE_MAX then
    self.oversize = self.oversize + 1
    return false
  end
  local accepted = Enqueue({
    lane = LANE_OF_CLASS[class], payload = payload, bytes = #payload, electKey = session,
    copies = (class == "C" and #list < 2) and 2 or 1, critical = class == "C",
    dedupKey = session .. ":" .. sequence, coalesce = coalesce and (identity .. "|" .. coalesce) or nil,
  }, now)
  if accepted then self.bridged = self.bridged + 1 end
  return accepted
end

-- The line OnLocalLine just let through, until Capture:OnMessage has run its
-- quota and admission steps on it (BridgeLocal). Both run in the same call.
local pendingLocal

-- A capture line heard on our channel (modules/p2ptest.lua), or in our group or
-- guild (modules/transport.lua, `transport` = its chat type). Returns true when
-- the relay already delivered this packet, so the caller skips it.
function Relay:OnLocalLine(id, body, session, sequence, sender, echo, transport)
  pendingLocal = nil
  if echo or type(session) ~= "string" or type(sequence) ~= "number" then return false end
  local now = Now()
  local capture = WF.Capture
  local identity = capture and capture.Identity and capture.Identity(sender)
  NoteDirect(identity, now)
  local key = DedupKey(identity, session, sequence, id, body)
  if Seen(key, now) then
    if not self.relayedOnly[key] and not self.rejectedKeys[key] then
      self.directDuplicates = self.directDuplicates + 1
      return true
    end
    -- Had only as passed on by a chain hand: the direct copy goes through once.
    self.relayedOnly[key] = nil
    self.upgraded = (self.upgraded or 0) + 1
  end
  MarkSeen(key, now)
  -- Only Capture's post-admission parser may authorize a direct duplicate to
  -- travel further. An envelope alone is not evidence of a valid fact.
  self.rejectedKeys[key] = true
  if id == "P" and type(body) == "string" then
    local faction = strMatch(body, "^[^,]*,([AH]),")
    if identity and faction and faction == MyFaction() then crossing.ours[identity] = true end
    if faction and faction == OPPOSITE[MyFaction() or ""] then
      -- A sender heard in our faction is not counted; the claim stays unbridged.
      -- Only the channel can cross factions: a group or guild line never counts.
      if transport == nil and identity and not crossing.ours[identity] then
        if crossing.claimer and crossing.claimer ~= identity and now - crossing.at < crossing.window then
          if not channelCrossedAt then Reject("channel crosses factions") end
          channelCrossedAt = now
        end
        crossing.claimer, crossing.at = identity, now
      end
      return false
    end
  end
  if identity then
    pendingLocal = { identity = identity, session = session, sequence = sequence, id = id, body = body,
      audience = transport }
  end
  return false
end

-- Called by Capture:OnMessage once the line passed the sender's quota and
-- admission (AC-7): a spammer or revoked character spends no Battle.net budget.
-- The single AllowSender result is reused; nothing is counted twice.
function Relay:BridgeLocal(identity, kind, now)
  local line = pendingLocal
  pendingLocal = nil
  if not line or line.identity ~= identity or line.id ~= kind then return false end
  self.rejectedKeys[DedupKey(identity, line.session, line.sequence, line.id, line.body)] = nil
  return self:Bridge(identity, line.session, line.sequence, line.id, line.body, now or Now(), line.audience)
end

-- Our own capture line, once the send gate made or failed the call. `audience`:
-- "own" when it left by our group and guild instead of the channel (decision
-- 0077 § 5g), nil when it went to the channel.
function Relay:OnLocalSend(id, session, sequence, body, audience)
  if type(session) ~= "string" or type(sequence) ~= "number" then return end
  local now = Now()
  local me = MyIdentity()
  local key = DedupKey(me, session, sequence, id, body)
  if Seen(key, now) then return end
  MarkSeen(key, now)
  if me then self:Bridge(me, session, sequence, id, body, now, audience) end
end

-- Channel relay lines: B beacons and R rebroadcasts ------------------------------

-- The reception chain's revocation step (Ticket:Admit, decision 0061) for a
-- relayer: these lines bypass Capture:OnMessage. No quota is charged, since an
-- honest far bridge rebroadcasts above the normal per-sender rate.
local function Admitted(identity, now)
  local ticket = WF.Ticket
  return not ticket or not ticket.Admit or ticket:Admit(identity, "R", now)
end

function Relay:OnChannelLine(id, body, sender, echo)
  if echo then return end
  local capture = WF.Capture
  local identity = capture and capture.Identity and capture.Identity(sender)
  if not identity or identity == MyIdentity() or type(body) ~= "string" then return end
  local now = Now()
  NoteDirect(identity, now)
  if id == "B" then
    local count = tonumber(strMatch(body, "^(%d)$") or "")
    if not count or count > K.MAX_LINKS then return Reject("beacon format") end
    self.beaconsHeard = self.beaconsHeard + 1
    return self:NoteBeacon(identity, count, now)
  end
  if id ~= "R" then return end
  self.received = self.received + 1
  if Lockdown() then return Reject("lockdown") end
  -- A relayed origin is a message field: only a live beacon holder may carry one.
  -- A bridge not heard yet costs a missed line, which its next beacon repairs.
  local holder = holders[ElectName(identity)]
  if not holder or holder.links <= 0 or now >= holder.expireAt or not Admitted(identity, now) then
    return Reject("relayer unknown")
  end
  if not Allow(relayerLines, identity, now, 1) then return Reject("relayer rate") end
  local packet, reason = ParsePacket(body, LINE_PACKET, now)
  if not packet then return Reject(reason) end
  return Accept(packet, identity, "C", nil, now)
end

-- A bridge's link count, from a B line or a NP presence (decision 0077 step 5).
-- `ttl`: how long it lives without news; a B line uses the scaled BEACON.TTL, a
-- presence, rarer, a longer one (modules/transport.lua). 0 links withdraws it.
function Relay:NoteBeacon(identity, count, now, ttl)
  if type(identity) ~= "string" or type(count) ~= "number" or identity == MyIdentity() then return end
  now = now or Now()
  local name = ElectName(identity)
  if not name then return end
  if count <= 0 or not Admitted(identity, now) then
    if holders[name] then
      holders[name] = nil
      holderCount = holderCount - 1
    end
    return
  end
  if not holders[name] then
    if holderCount >= K.MAX_HOLDERS then
      local oldestName, oldestAt
      for other, holder in pairs(holders) do
        if not oldestAt or holder.at < oldestAt then oldestName, oldestAt = other, holder.at end
      end
      holders[oldestName] = nil
      holderCount = holderCount - 1
    end
    holderCount = holderCount + 1
  end
  local expireAt = now + mathMax(ttl or 0, BEACON.TTL * BeaconScale())
  local previous = holders[name]
  -- A presence never shortens what a fresher B line promised.
  if previous and previous.expireAt > expireAt then expireAt = previous.expireAt end
  holders[name] = { links = mathMin(count, K.MAX_LINKS), at = now, expireAt = expireAt }
end

-- Our live link count while we are a bridge, else 0: the NP presence carries it.
function Relay:LinkCount(now)
  return status.bridge and LiveLinkCount(now or Now()) or 0
end

-- Same-faction chain (decision 0077 step 4b, modules/chain.lua) -------------------
-- A fact of our own faction passed hand to hand by whisper. Its origin is a
-- message field, written by the forwarder like a bridge's (decision 0068), so
-- it takes the relay's whole acceptance: shape, class, age, our faction only,
-- duplicates, an origin we hear directly refused, per-forwarder line, origin
-- and revocation limits, then Capture:OnRelayedMessage (hints once per
-- forwarder, never a ticket, never a witness, never bridged again).

-- The relayed-line body of one of our faction's lines, as heard first-hand.
function Relay.ChainLine(identity, session, sequence, id, body)
  if type(session) ~= "string" or type(sequence) ~= "number" or type(id) ~= "string" then return nil end
  local name, faction, stamp = OriginName(identity), MyFaction(), ServerTime()
  if not name or not faction or not stamp or not IsPrintableBody(body) or #body > K.MAX_BODY then return nil end
  return faction .. "," .. stamp .. "," .. session .. "," .. Base36(sequence) .. "," .. EncodeName(name) .. ","
    .. id .. "," .. body
end

-- The same body again, from a packet accepted from a chain line.
function Relay.PacketLine(packet)
  return packet.faction .. "," .. packet.stamp .. "," .. packet.session .. "," .. packet.seqText .. ","
    .. packet.encodedName .. "," .. packet.id .. "," .. packet.body
end

-- Our faction's facts (step 4b), or the other faction's that a bridge received
-- over Battle.net and started down our chain (step 5).
function Relay.ParseChainLine(text, now)
  if type(text) ~= "string" then return nil, "packet format" end
  local mine = MyFaction()
  if not mine then return nil, "local state" end
  now = now or Now()
  local packet, reason = ParsePacket(text, LINE_PACKET, now, mine)
  if not packet and reason == "chain faction" then packet, reason = ParsePacket(text, LINE_PACKET, now) end
  return packet, reason
end

-- `via`: the forwarder's identity (the whisper sender, rule R1). True when the
-- packet was new and delivered; false and true when it was a valid duplicate
-- (already had by another path: the chain may still pass it on once).
-- For an origin we hear directly (decision 0077 § 5f) a copy is never applied:
-- identical to the line we heard first-hand (same relay key, body included),
-- it is that genuine line and counts as a duplicate; otherwise the third result
-- is true and the chain holds it until that line comes first-hand.
function Relay:AcceptChain(packet, via, now)
  now = now or Now()
  if type(packet) ~= "table" or type(via) ~= "string" then return false end
  if not Admitted(via, now) then return Reject("chain forwarder") end
  if not Allow(relayerLines, via, now, 1) then return Reject("chain rate") end
  self.chained = (self.chained or 0) + 1
  if HeardDirectly(packet.identity, now) then
    if Seen(packet.key, now) and not self.rejectedKeys[packet.key] and not self.relayedOnly[packet.key] then
      self.duplicates = self.duplicates + 1
      return false, true
    end
    Reject("origin heard")
    return false, false, true
  end
  local duplicatesBefore = self.duplicates
  local accepted = Accept(packet, via, "W", nil, now)
  if accepted then
    self.relayedOnly[packet.key] = true
    return true
  end
  return false, self.duplicates > duplicatesBefore
end

local function OnAck(account, rest, now)
  local session, seqText = strMatch(rest, "^([0-9A-F]+):([0-9A-Z]+)$")
  local sequence = seqText and #seqText <= 6 and tonumber(seqText, 36) or nil
  if not session or not sequence then return Reject("ack format") end
  local link = links[account.id]
  if not link then return Reject("ack unlinked") end
  link.lastHeard = now
  local key = session .. ":" .. sequence
  -- Only a link this packet was sent to may stop its retries (AC-13).
  local pending = acks[key]
  if pending and pending.tried[account.id] then
    acks[key] = nil
    ackCount = ackCount - 1
    Relay.acksHeard = Relay.acksHeard + 1
  end
  return true
end

-- Shared with modules/relay_bnet.lua, which loads next (Battle.net side).
Relay.Kit = {
  Accept = Accept,
  Allow = Allow,
  BN_PACKET = BN_PACKET,
  BULK = BULK,
  BattleNetReady = BattleNetReady,
  Candidate = Candidate,
  CheckAcks = CheckAcks,
  DropLink = DropLink,
  Enqueue = Enqueue,
  HELLO = HELLO,
  Header = Header,
  InInstance = InInstance,
  IsPrintableBody = IsPrintableBody,
  IsSecret = IsSecret,
  K = K,
  LinkAlive = LinkAlive,
  LiveLinkCount = LiveLinkCount,
  Lockdown = Lockdown,
  MyFaction = MyFaction,
  MyRealmID = MyRealmID,
  MyRecord = MyRecord,
  MySession = MySession,
  Now = Now,
  OnAck = OnAck,
  OPPOSITE = OPPOSITE,
  ParsePacket = ParsePacket,
  PruneHolders = PruneHolders,
  Pump = Pump,
  PurgeDirect = PurgeDirect,
  PurgeSeen = PurgeSeen,
  QueueControl = QueueControl,
  Refill = Refill,
  Reject = Reject,
  ReleaseRebroadcasts = ReleaseRebroadcasts,
  ResolveAccount = ResolveAccount,
  SCAN = SCAN,
  SendHello = SendHello,
  SendNow = SendNow,
  ServerTime = ServerTime,
  UpdateBeacon = UpdateBeacon,
  UpsertLink = UpsertLink,
  bucket = bucket,
  hello = hello,
  lanes = lanes,
  linkBytes = linkBytes,
  links = links,
  rebroadcast = rebroadcast,
  status = status,
  Queued = function() return queued end,
  AckCount = function() return ackCount end,
  HolderCount = function() return holderCount end,
  ChannelCrossedAt = function() return channelCrossedAt end,
}

