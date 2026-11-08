local WF = Warfront

-- Cross-faction relay over Battle.net friends (decision 0068).
--
-- One crossing only: a faction channel line -> an elected bridge -> one
-- Battle.net game-data message -> an opposite-faction client, which applies it
-- and rebroadcasts it once on its own channel as an R line. A relayed packet is
-- never bridged again, so loops cannot form.
--
-- Every number below is provisional until measured on Forever (decision 0068).

local Relay = {
  received = 0, delivered = 0, deliverErrors = 0, duplicates = 0, directDuplicates = 0,
  sent = 0, sentBytes = 0, sendErrors = 0, sendRefused = 0,
  queuedTotal = 0, coalesced = 0, dropped = 0, expired = 0, noLink = 0,
  bridged = 0, notElected = 0, oversize = 0, foreign = 0,
  acksSent = 0, acksHeard = 0, retries = 0, unacked = 0,
  rebroadcasts = 0, rebroadcastCancelled = 0, rebroadcastDropped = 0, rebroadcastFailed = 0,
  beaconsSent = 0, beaconsHeard = 0, hellosSent = 0, hellosHeard = 0, scans = 0,
  rejects = {},
}
WF.Relay = Relay

-- Wire --------------------------------------------------------------------------

local PROTOCOL = 1
local PREFIX = "WF"
local LEVEL = WF.channelLevel
-- Larger Battle.net payloads are unverified on Forever: stay at the chat limit.
local WIRE_MAX = 255
local MAX_BODY = 200
local MAX_ENCODED_NAME = 72
local MAX_NAME_BYTES = 48

-- Links and discovery -------------------------------------------------------------

local MAX_LINKS = 6
local LINK_TTL = 300
local KEEPALIVE = 120
local HELLO_RETRY = 120
local REPLY_GAP = 30
local SCAN_INTERVAL = 60
local SCAN_DEBOUNCE = 5
local MIN_SCAN_GAP = 15
local SCAN_SLICE = 20
local MAX_FRIENDS = 200
local MAX_GAME_ACCOUNTS = 4
local MAX_HELLOS_PER_SCAN = 8

-- Bridges and election -------------------------------------------------------------

local BEACON_INTERVAL = 90
local BEACON_JITTER = 30
local BEACON_RETRY = 15
local BEACON_TTL = 240
local MAX_HOLDERS = 64
-- Two bridges carry routine packets, so one bridge that left without a
-- withdrawal beacon (or lies about its links) cannot silence an origin.
local ROUTINE_BRIDGES = 2
local CRITICAL_BRIDGES = 3

-- Outbound budget and queue: one budget for every link and copy ------------------

local BUDGET_RATE = 600
local BUDGET_BURST = 1200
local QUEUE_MAX = 64
local MAX_SENDS_PER_PUMP = 8
local LANE_ORDER = { "control", "critical", "state", "routine" }
local LANE_OF_CLASS = { C = "critical", S = "state", N = "routine" }
local TTL_OF_LANE = { control = 30, critical = 120, state = 30, routine = 60 }
local ACK_TIMEOUT = 5
local MAX_RETRIES = 2
local MAX_ACKS = 64

-- Inbound validation --------------------------------------------------------------

local MAX_AGE = 120
local MAX_SKEW = 30
local DEDUP_TTL = 180
local DEDUP_MAX = 2048
local LIMIT_WINDOW = 10
-- Above the most an honest peer's budget can send in one window.
local LINK_BYTES_PER_WINDOW = 9000
local RELAYER_LINES_PER_WINDOW = 60
local ORIGIN_WINDOW = 60
local MAX_ORIGINS_PER_RELAYER = 100
local MAX_TRACKED = 128

-- Far-channel rebroadcast -----------------------------------------------------------

-- The best-ranked far bridge for an origin speaks first; the others wait one
-- step per rank and stay silent once they hear its R line.
local MAX_REBROADCAST = 32
local REBROADCAST_JITTER = 0.3
local REBROADCAST_RANK_STEP = 0.8
local MAX_REBROADCAST_RANK = 3

-- An opposite-faction P heard on our own channel means the channel already
-- crosses factions: bridging then only duplicates traffic and stands down.
local CROSSING_HOLD = 600

local TICK = 0.1
local SLOW_TICK = 1

local FACTION_OF_TAG = { Alliance = "A", Horde = "H" }
local OPPOSITE = { A = "H", H = "A" }
local BASE36 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
local TWO32 = 4294967296

local strByte, strChar, strFind, strFormat, strMatch, strGsub, strSub =
  string.byte, string.char, string.find, string.format, string.match, string.gsub, string.sub
local mathFloor, mathMin, mathMax, mathRandom = math.floor, math.min, math.max, math.random

-- State ---------------------------------------------------------------------------

local links = {}          -- gameAccountID -> link
local linkCount = 0
local candidates = {}     -- gameAccountID -> character name, from the last scan
local helloAt = {}        -- gameAccountID -> time of our last unanswered hello
local holders = {}        -- elect name -> { links, at, expireAt } from B lines
local holderCount = 0
local lanes = { control = {}, critical = {}, state = {}, routine = {} }
local queued = 0
local coalesceIndex = {}  -- coalescing key -> queued item
local acks = {}           -- dedup key -> pending acknowledgement
local ackCount = 0
local rebroadcast = {}    -- far-channel rebroadcasts, sorted by due time
local rebroadcastIndex = {}
local rebroadcastDue = {} -- origin session -> due time of its last rebroadcast
local bucket = { tokens = BUDGET_BURST, at = nil }
local seen, seenKeys, seenHead, seenTail, seenCount = {}, {}, 1, 0, 0
local hashCache, hashCacheCount = {}, 0
local scan
local nextScanAt, lastScanAt
local nextSlowAt, nextTickAt = 0, 0
local beaconLinks, nextBeaconAt, beaconRetryAt = 0, 0, 0
local channelCrossedAt
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

-- Character name of an identity "Name@Realm". All clients of one realm agree
-- on it, whatever realm spelling the chat event used: the election key.
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
    output = strSub(BASE36, digit + 1, digit + 1) .. output
    value = mathFloor(value / 36)
  end
  return output
end

local function IsPrintableBody(text)
  if type(text) ~= "string" or #text > MAX_BODY then return false end
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
  if type(name) ~= "string" or #name < 2 or #name > MAX_NAME_BYTES then return false end
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
  if type(text) ~= "string" or text == "" or #text > MAX_ENCODED_NAME then return nil end
  local stripped = strGsub(text, "%%%x%x", "")
  if strFind(stripped, "[^A-Za-z]") then return nil end
  local name = strGsub(text, "%%(%x%x)", function(hex) return strChar(tonumber(hex, 16)) end)
  if not ValidName(name) or EncodeName(name) ~= text then return nil end
  return name
end

-- Plain character name of a same-realm identity, or nil.
local function OriginName(identity)
  if type(identity) ~= "string" then return nil end
  local name, realm = strMatch(identity, "^([^@]+)@(.+)$")
  if not name then return nil end
  local realmName, normalized = RealmNames()
  local compact = realmName and strGsub(realmName, "%s", "") or nil
  if realm ~= realmName and realm ~= normalized and realm ~= compact then return nil end
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
  return (((aHi * bLo + aLo * bHi) % 65536) * 65536 + aLo * bLo) % TWO32
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

local function PopSeen()
  local key = seenKeys[seenHead]
  seenKeys[seenHead] = nil
  seenHead = seenHead + 1
  seenCount = seenCount - 1
  if key ~= nil then seen[key] = nil end
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
  seen[key] = now + DEDUP_TTL
  while seenCount > DEDUP_MAX do PopSeen() end
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
    if window.count >= MAX_TRACKED then
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
  local entry = WindowEntry(window, key, now, LIMIT_WINDOW)
  if entry.used + amount > window.limit then return false end
  entry.used = entry.used + amount
  return true
end

local function AllowOrigin(window, via, origin, now)
  local entry = WindowEntry(window, via, now, ORIGIN_WINDOW)
  entry.set = entry.set or {}
  if entry.set[origin] then return true end
  if entry.used >= window.limit then return false end
  entry.set[origin] = true
  entry.used = entry.used + 1
  return true
end

local linkBytes = NewWindow(LINK_BYTES_PER_WINDOW)
local relayerLines = NewWindow(RELAYER_LINES_PER_WINDOW)
local relayerOrigins = NewWindow(MAX_ORIGINS_PER_RELAYER)

-- Links ---------------------------------------------------------------------------

local function LinkAlive(link, now)
  return now - link.lastHeard <= LINK_TTL
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

-- Server facts about a Battle.net game account: a same-realm, opposite-faction
-- WoW character, or nil and a reason. Battle.net authenticates this last hop.
local function Candidate(info, opposite, realmID)
  if type(info) ~= "table" or info.isOnline ~= true then return nil, "offline" end
  if info.clientProgram ~= (BNET_CLIENT_WOW or "WoW") then return nil, "not in WoW" end
  if info.isInCurrentRegion == false then return nil, "other region" end
  if type(info.gameAccountID) ~= "number" or info.realmID ~= realmID then return nil, "other realm" end
  if FACTION_OF_TAG[info.factionName] ~= opposite then return nil, "same faction" end
  local name = info.characterName
  if type(name) ~= "string" or IsSecret(name) then return nil, "no character" end
  -- Same realm (realmID above): only the chat name is kept, "First Surname".
  local names = WF.Names
  if names then
    name = names.Split(name)
  else
    name = strMatch(name, "^([^%-]+)") or name
  end
  if not ValidName(name) then return nil, "character name" end
  return { id = info.gameAccountID, name = name, faction = opposite }
end

local function ResolveAccount(id)
  if type(id) ~= "number" then return nil, "sender id" end
  local opposite, realmID = OPPOSITE[MyFaction() or ""], MyRealmID()
  if not opposite or not realmID then return nil, "local state" end
  local ok, info = pcall(C_BattleNet.GetGameAccountInfoByID, id)
  if not ok then return nil, "account lookup" end
  local account, reason = Candidate(info, opposite, realmID)
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
  if linkCount >= MAX_LINKS then
    local stalestId, stalest
    for id, other in pairs(links) do
      if not stalest or other.lastHeard < stalest.lastHeard then stalestId, stalest = id, other end
    end
    if not stalest or now - stalest.lastHeard <= KEEPALIVE then return nil end
    DropLink(stalestId, "replaced")
  end
  link = {
    id = account.id, name = account.name, faction = account.faction,
    firstAt = now, lastHeard = now, lastSentAt = now, repliedAt = nil,
    sent = 0, received = 0,
  }
  links[account.id] = link
  linkCount = linkCount + 1
  helloAt[account.id] = nil
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

local function Header(kind)
  return "WR" .. PROTOCOL .. ":" .. tostring(LEVEL) .. ":" .. kind .. ":"
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
  routine = { "routine" },
  state = { "routine", "state" },
  critical = { "routine", "state", "critical" },
  control = { "routine", "state", "critical" },
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
  if queued >= QUEUE_MAX and not MakeRoom(item) then
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

local function SendNow(id, payload, now)
  local ok, result = pcall(C_BattleNet.SendGameData, id, PREFIX, payload)
  if not ok then
    Relay.sendErrors = Relay.sendErrors + 1
    Relay.lastSendError = WF.Sanitize and WF.Sanitize(result, 120) or tostring(result)
    return false
  end
  Relay.lastSendResult = result
  local results = type(Enum) == "table" and Enum.SendAddonMessageResult or nil
  local success = type(results) == "table" and results.Success or nil
  if success ~= nil and result ~= nil and result ~= success then
    Relay.sendRefused = Relay.sendRefused + 1
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
  if ackCount >= MAX_ACKS then
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
    tried = tried, retries = 0, due = now + ACK_TIMEOUT,
  }
end

local function Refill(now)
  if not bucket.at then bucket.at = now end
  local elapsed = now - bucket.at
  if elapsed > 0 then
    bucket.tokens = mathMin(BUDGET_BURST, bucket.tokens + elapsed * BUDGET_RATE)
    bucket.at = now
  end
end

-- The first packet still worth sending, by lane priority; expired ones go.
local function Front(now)
  for i = 1, #LANE_ORDER do
    local name = LANE_ORDER[i]
    local lane = lanes[name]
    while #lane > 0 do
      if lane[1].expires > now then return lane[1], name end
      RemoveAt(name, 1)
      Relay.expired = Relay.expired + 1
    end
  end
  return nil
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
  elseif item.critical and item.sentCopies and item.sentCopies > 0 then
    RegisterAck(item, now)
  end
end

local function Pump(now)
  Refill(now)
  local sends = 0
  while sends < MAX_SENDS_PER_PUMP do
    local item, laneName = Front(now)
    if not item then return end
    if not item.targets then
      if item.target then
        item.targets = { item.target }
      else
        item.targets = PickLinks(item.electKey, item.copies, item.exclude, now)
      end
      item.nextTarget = 1
    end
    local target = item.targets[item.nextTarget]
    if not target then
      if (item.sentCopies or 0) == 0 then Relay.noLink = Relay.noLink + 1 end
      FinishItem(item, laneName, now)
    else
      if bucket.tokens < item.bytes then return end
      bucket.tokens = bucket.tokens - item.bytes
      if SendNow(target, item.payload, now) then item.sentCopies = (item.sentCopies or 0) + 1 end
      item.nextTarget = item.nextTarget + 1
      sends = sends + 1
      if item.nextTarget > #item.targets then FinishItem(item, laneName, now) end
    end
  end
end

local function QueueControl(id, payload, now)
  return Enqueue({ lane = "control", target = id, payload = payload, bytes = #payload }, now)
end

local function SendHello(id, flag, now)
  local faction, realmID = MyFaction(), MyRealmID()
  if not faction or not realmID then return false end
  local payload = Header("H") .. flag .. ":" .. faction .. ":" .. realmID .. ":" .. tostring(WF.version)
  if not QueueControl(id, payload, now) then return false end
  Relay.hellosSent = Relay.hellosSent + 1
  local link = links[id]
  if link then link.lastSentAt = now end
  return true
end

local function QueueAck(id, packet, now)
  if QueueControl(id, Header("A") .. packet.session .. ":" .. packet.seqText, now) then
    Relay.acksSent = Relay.acksSent + 1
  end
end

local function CheckAcks(now)
  for key, pending in pairs(acks) do
    if now >= pending.due then
      if pending.retries >= MAX_RETRIES or not status.sendable then
        acks[key] = nil
        ackCount = ackCount - 1
        Relay.unacked = Relay.unacked + 1
      else
        pending.retries = pending.retries + 1
        pending.due = now + ACK_TIMEOUT * (pending.retries + 1)
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
    local interval = BEACON_INTERVAL * BeaconScale()
    nextBeaconAt = now + interval + mathRandom() * BEACON_JITTER
  else
    beaconRetryAt = now + BEACON_RETRY
  end
end

-- Far-channel rebroadcast -----------------------------------------------------------

local function ScheduleRebroadcast(packet, now)
  if #rebroadcast >= MAX_REBROADCAST then
    Relay.rebroadcastDropped = Relay.rebroadcastDropped + 1
    return
  end
  local me = ElectName(MyIdentity())
  local rank = me and mathMin(MAX_REBROADCAST_RANK, Rank(packet.session, me, Bridges(now, me))) or 0
  local due = now + mathRandom() * REBROADCAST_JITTER + rank * REBROADCAST_RANK_STEP
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
local function ParsePacket(text, pattern, now)
  local faction, stampText, session, seqText, encodedName, id, body = strMatch(text, pattern)
  if not faction then return nil, "packet format" end
  local mine = MyFaction()
  if not mine then return nil, "local state" end
  if faction == mine then return nil, "own faction" end
  if #stampText > 10 or #session < 4 or #session > 12 or #seqText > 6 or #id > 4 then
    return nil, "packet field"
  end
  local sequence = tonumber(seqText, 36)
  if not sequence or sequence > 2147483647 or Base36(sequence) ~= seqText then return nil, "packet sequence" end
  if session == MySession() then return nil, "own session" end
  local stamp, clock = tonumber(stampText), ServerTime()
  if not stamp or not clock then return nil, "no clock" end
  if clock - stamp > MAX_AGE then return nil, "stale" end
  if stamp - clock > MAX_SKEW then return nil, "future" end
  if not IsPrintableBody(body) then return nil, "packet body" end
  local name = DecodeName(encodedName)
  if not name then return nil, "origin name" end
  local identity = WF.Capture and WF.Capture.Identity and WF.Capture.Identity(name)
  if not identity or identity == MyIdentity() then return nil, "origin identity" end
  local class, coalesce = RelayClassOf(id, body)
  if not class then return nil, "not relayable" end
  return {
    faction = faction, stamp = stampText, session = session, seqText = seqText, sequence = sequence,
    encodedName = encodedName, name = name, identity = identity, id = id, body = body,
    class = class, coalesce = coalesce and (identity .. "|" .. coalesce) or nil,
    key = DedupKey(identity, session, sequence, id, body),
  }
end

local function Deliver(packet, via)
  local capture = WF.Capture
  if not capture or type(capture.OnMessage) ~= "function" then return end
  local ok, err = pcall(capture.OnMessage, capture, packet.id, packet.body, packet.name, false,
    { via = via, faction = packet.faction })
  if ok then
    Relay.delivered = Relay.delivered + 1
  else
    Relay.deliverErrors = Relay.deliverErrors + 1
    if WF.RecordError then WF.RecordError("relay delivery", err) end
  end
end

-- hop "B": straight from a Battle.net link; hop "C": an R line on our channel.
local function Accept(packet, via, hop, linkId, now)
  local duplicate = Seen(packet.key, now)
  if hop == "B" and packet.class == "C" then QueueAck(linkId, packet, now) end
  if hop == "C" then CancelRebroadcast(packet.key) end
  if duplicate then
    Relay.duplicates = Relay.duplicates + 1
    return false
  end
  if not AllowOrigin(relayerOrigins, via, packet.identity, now) then return Reject("origin flood") end
  MarkSeen(packet.key, now)
  Deliver(packet, via)
  -- Receivers accept R lines only from a live beacon holder: without our own
  -- beacon, a rebroadcast would only spend the send gate.
  if hop == "B" and beaconLinks > 0 then ScheduleRebroadcast(packet, now) end
  return true
end

-- Bridging a line of our own faction ---------------------------------------------

function Relay:Bridge(identity, session, sequence, id, body, now)
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
  local list = Bridges(now, me)
  if Rank(session, me, list) >= (class == "C" and CRITICAL_BRIDGES or ROUTINE_BRIDGES) then
    self.notElected = self.notElected + 1
    return false
  end
  local payload = Header("R") .. faction .. ":" .. stamp .. ":" .. session .. ":" .. Base36(sequence) .. ":"
    .. EncodeName(name) .. ":" .. id .. ":" .. body
  if #payload > WIRE_MAX then
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

-- A capture line heard on our channel (modules/p2ptest.lua). Returns true when
-- the relay already delivered this packet, so the caller skips it.
function Relay:OnLocalLine(id, body, session, sequence, sender, echo)
  if echo or type(session) ~= "string" or type(sequence) ~= "number" then return false end
  local now = Now()
  local capture = WF.Capture
  local identity = capture and capture.Identity and capture.Identity(sender)
  local key = DedupKey(identity, session, sequence, id, body)
  if Seen(key, now) then
    self.directDuplicates = self.directDuplicates + 1
    return true
  end
  MarkSeen(key, now)
  if id == "P" and type(body) == "string" then
    local faction = strMatch(body, "^[^,]*,([AH]),")
    if faction and faction == OPPOSITE[MyFaction() or ""] then
      if not channelCrossedAt then Reject("channel crosses factions") end
      channelCrossedAt = now
      return false
    end
  end
  if identity then self:Bridge(identity, session, sequence, id, body, now) end
  return false
end

-- Our own capture line, once the send gate made or failed the call.
function Relay:OnLocalSend(id, session, sequence, body)
  if type(session) ~= "string" or type(sequence) ~= "number" then return end
  local now = Now()
  local me = MyIdentity()
  local key = DedupKey(me, session, sequence, id, body)
  if Seen(key, now) then return end
  MarkSeen(key, now)
  if me then self:Bridge(me, session, sequence, id, body, now) end
end

-- Channel relay lines: B beacons and R rebroadcasts ------------------------------

function Relay:OnChannelLine(id, body, sender, echo)
  if echo then return end
  local capture = WF.Capture
  local identity = capture and capture.Identity and capture.Identity(sender)
  if not identity or identity == MyIdentity() or type(body) ~= "string" then return end
  local now = Now()
  if id == "B" then
    local count = tonumber(strMatch(body, "^(%d)$") or "")
    if not count or count > MAX_LINKS then return Reject("beacon format") end
    local name = ElectName(identity)
    self.beaconsHeard = self.beaconsHeard + 1
    if count == 0 then
      if holders[name] then
        holders[name] = nil
        holderCount = holderCount - 1
      end
      return
    end
    if not holders[name] then
      if holderCount >= MAX_HOLDERS then
        local oldestName, oldestAt
        for other, holder in pairs(holders) do
          if not oldestAt or holder.at < oldestAt then oldestName, oldestAt = other, holder.at end
        end
        holders[oldestName] = nil
        holderCount = holderCount - 1
      end
      holderCount = holderCount + 1
    end
    holders[name] = { links = count, at = now, expireAt = now + BEACON_TTL * BeaconScale() }
    return
  end
  if id ~= "R" then return end
  self.received = self.received + 1
  if Lockdown() then return Reject("lockdown") end
  -- A relayed origin is a message field: only a live beacon holder may carry one.
  -- A bridge not heard yet costs a missed line, which its next beacon repairs.
  local holder = holders[ElectName(identity)]
  if not holder or holder.links <= 0 or now >= holder.expireAt then return Reject("relayer unknown") end
  if not Allow(relayerLines, identity, now, 1) then return Reject("relayer rate") end
  local packet, reason = ParsePacket(body, LINE_PACKET, now)
  if not packet then return Reject(reason) end
  return Accept(packet, identity, "C", nil, now)
end

-- Battle.net game data -------------------------------------------------------------

local function OnHello(account, rest, now)
  local flag, faction, realm, version = strMatch(rest, "^([ARK]):([AH]):(%d+):([%d%.]+)$")
  if not flag then return Reject("hello format") end
  if faction ~= account.faction or tonumber(realm) ~= MyRealmID() then return Reject("hello mismatch") end
  local versions = WF.Version
  if #version > 16 or (versions and versions.Valid and not versions.Valid(version)) then
    return Reject("hello version")
  end
  local link = UpsertLink(account, now)
  if not link then return Reject("links full") end
  link.version = version
  link.received = link.received + 1
  Relay.hellosHeard = Relay.hellosHeard + 1
  if versions and versions.Note then pcall(versions.Note, versions, version, LEVEL) end
  if flag == "A" and (not link.repliedAt or now - link.repliedAt >= REPLY_GAP) then
    link.repliedAt = now
    SendHello(account.id, "R", now)
  end
  return true
end

local function LinkIdentity(link)
  local capture = WF.Capture
  return capture and capture.Identity and capture.Identity(link.name) or link.name
end

local function OnBridgePacket(account, rest, now)
  local packet, reason = ParsePacket(rest, BN_PACKET, now)
  if not packet then return Reject(reason) end
  if packet.faction ~= account.faction then return Reject("origin faction") end
  local link = UpsertLink(account, now)
  if not link then return Reject("links full") end
  link.received = link.received + 1
  return Accept(packet, LinkIdentity(link), "B", account.id, now)
end

local function OnAck(account, rest, now)
  local session, seqText = strMatch(rest, "^([0-9A-F]+):([0-9A-Z]+)$")
  local sequence = seqText and #seqText <= 6 and tonumber(seqText, 36) or nil
  if not session or not sequence then return Reject("ack format") end
  local link = links[account.id]
  if not link then return Reject("ack unlinked") end
  link.lastHeard = now
  local key = session .. ":" .. sequence
  if acks[key] then
    acks[key] = nil
    ackCount = ackCount - 1
    Relay.acksHeard = Relay.acksHeard + 1
  end
  return true
end

function Relay:OnGameData(prefix, text, channel, senderID)
  if IsSecret(prefix) or IsSecret(text) or IsSecret(senderID) then return Reject("secret") end
  if prefix ~= PREFIX then return end
  self.received = self.received + 1
  if Lockdown() then return Reject("lockdown") end
  if not BattleNetReady() then return Reject("battle.net") end
  if type(text) ~= "string" or #text > WIRE_MAX then return Reject("size") end
  local proto, level, kind, rest = strMatch(text, "^WR(%d+):(%d+):(%u):(.*)$")
  if not proto then return Reject("format") end
  if tonumber(proto) ~= PROTOCOL then return Reject("protocol") end
  if tonumber(level) ~= LEVEL then return Reject("level") end
  local account, reason = ResolveAccount(senderID)
  if not account then
    if links[senderID] then DropLink(senderID, reason) end
    return Reject(reason)
  end
  local now = Now()
  if not Allow(linkBytes, senderID, now, #text) then return Reject("link rate") end
  if kind == "H" then return OnHello(account, rest, now) end
  if kind == "R" then return OnBridgePacket(account, rest, now) end
  if kind == "A" then return OnAck(account, rest, now) end
  return Reject("kind")
end

-- Discovery: an incremental scan of the Battle.net friend list -------------------

local function StartScan(now)
  if type(BNGetNumFriends) ~= "function" or type(C_BattleNet.GetFriendNumGameAccounts) ~= "function"
      or type(C_BattleNet.GetFriendGameAccountInfo) ~= "function" then
    return
  end
  local opposite, realmID = OPPOSITE[MyFaction() or ""], MyRealmID()
  if not opposite or not realmID then return end
  local ok, total = pcall(BNGetNumFriends)
  if not ok or type(total) ~= "number" then return end
  scan = { index = 1, total = mathMin(MAX_FRIENDS, mathFloor(total)), found = {}, opposite = opposite, realmID = realmID }
  lastScanAt = now
  Relay.scans = Relay.scans + 1
end

local function ScanFriend(index)
  local ok, count = pcall(C_BattleNet.GetFriendNumGameAccounts, index)
  if not ok or type(count) ~= "number" or count < 1 then return end
  for j = 1, mathMin(MAX_GAME_ACCOUNTS, count) do
    local okInfo, info = pcall(C_BattleNet.GetFriendGameAccountInfo, index, j)
    if okInfo then
      local account = Candidate(info, scan.opposite, scan.realmID)
      if account then scan.found[account.id] = account.name end
    end
  end
end

local function FinishScan(now)
  local found = scan.found
  scan = nil
  candidates = found
  for id in pairs(links) do
    if not found[id] and not ResolveAccount(id) then DropLink(id, "gone") end
  end
  for id in pairs(helloAt) do
    if not found[id] then helloAt[id] = nil end
  end
  if not status.eligible then return end
  local sent = 0
  for id in pairs(found) do
    if sent >= MAX_HELLOS_PER_SCAN then break end
    if not links[id] and (not helloAt[id] or now - helloAt[id] >= HELLO_RETRY) then
      if SendHello(id, "A", now) then
        helloAt[id] = now
        sent = sent + 1
      end
    end
  end
end

local function ScanStep(now)
  local stop = mathMin(scan.total, scan.index + SCAN_SLICE - 1)
  for i = scan.index, stop do ScanFriend(i) end
  scan.index = stop + 1
  if scan.index > scan.total then FinishScan(now) end
end

function Relay:RequestScan(delay)
  local now = Now()
  local at = now + (delay or SCAN_DEBOUNCE)
  if lastScanAt then at = mathMax(at, lastScanAt + MIN_SCAN_GAP) end
  if not nextScanAt or at < nextScanAt then nextScanAt = at end
end

-- Ticks -------------------------------------------------------------------------------

local function UpdateStatus(now)
  local reason
  if not WF.Capture or not WF.P2PTest then
    reason = "modules"
  elseif not BattleNetReady() then
    reason = "battle.net"
  elseif Lockdown() then
    reason = "chat lockdown"
  elseif not MyFaction() or not MyRealmID() or not ServerTime() or not MySession() then
    reason = "character"
  end
  status.sendable = reason == nil
  if not reason then
    if channelCrossedAt and now - channelCrossedAt < CROSSING_HOLD then
      reason = "channel crosses factions"
    elseif InInstance() then
      reason = "instance"
    elseif type(WF.Capture.CanTalk) == "function" and not WF.Capture:CanTalk() then
      reason = "level"
    end
  end
  status.eligible = status.sendable and reason == nil
  status.bridge = status.eligible and LiveLinkCount(now) > 0
  status.reason = reason or (status.bridge and "bridge" or "no link")
end

local function SlowTick(now)
  UpdateStatus(now)
  for id, link in pairs(links) do
    if not LinkAlive(link, now) then
      DropLink(id, "silent")
    elseif status.sendable and now - link.lastSentAt >= KEEPALIVE then
      SendHello(id, "K", now)
    end
  end
  PruneHolders(now)
  PurgeSeen(now)
  CheckAcks(now)
  if status.sendable then UpdateBeacon(now) end
  if not scan and status.sendable and nextScanAt and now >= nextScanAt then
    nextScanAt = now + SCAN_INTERVAL
    StartScan(now)
  end
end

function Relay:Tick(now)
  if now < nextTickAt then return end
  nextTickAt = now + TICK
  if now >= nextSlowAt then
    nextSlowAt = now + SLOW_TICK
    SlowTick(now)
  end
  if scan then ScanStep(now) end
  ReleaseRebroadcasts(now)
  if status.sendable then Pump(now) end
end

-- Diagnostics -----------------------------------------------------------------------

function Relay:Summary()
  return "relay " .. status.reason .. " links=" .. LiveLinkCount(Now()) .. "/" .. MAX_LINKS
    .. " bridges=" .. holderCount .. " queued=" .. queued .. "/" .. QUEUE_MAX
    .. " sent=" .. self.sent .. " delivered=" .. self.delivered
end

local function CountKeys(map)
  local count = 0
  for _ in pairs(map) do count = count + 1 end
  return count
end

function Relay:PrintStatus()
  local now = Now()
  local print = WF.Print or function() end
  print("relay: role=" .. status.reason .. " faction=" .. tostring(MyFaction()) .. " realmID="
    .. tostring(MyRealmID()) .. " links=" .. LiveLinkCount(now) .. "/" .. MAX_LINKS
    .. " candidates=" .. CountKeys(candidates) .. " other bridges=" .. holderCount)
  for _, link in pairs(links) do
    print("relay: link " .. link.name .. " (" .. link.faction .. ", " .. tostring(link.version or "?")
      .. ") heard " .. mathFloor(now - link.lastHeard) .. "s ago, sent=" .. link.sent .. " received=" .. link.received)
  end
  print("relay: queue control=" .. #lanes.control .. " critical=" .. #lanes.critical .. " state=" .. #lanes.state
    .. " routine=" .. #lanes.routine .. " acks=" .. ackCount .. " rebroadcast=" .. #rebroadcast
    .. " budget=" .. mathFloor(bucket.tokens) .. "/" .. BUDGET_BURST .. " (" .. BUDGET_RATE .. " B/s)")
  print("relay: out bridged=" .. self.bridged .. " notElected=" .. self.notElected .. " sent=" .. self.sent
    .. " bytes=" .. self.sentBytes .. " coalesced=" .. self.coalesced .. " dropped=" .. self.dropped
    .. " expired=" .. self.expired .. " noLink=" .. self.noLink .. " oversize=" .. self.oversize
    .. " retries=" .. self.retries .. " unacked=" .. self.unacked .. " errors=" .. self.sendErrors
    .. " refused=" .. self.sendRefused .. (self.lastSendError and (" lastError=" .. self.lastSendError) or ""))
  print("relay: in received=" .. self.received .. " delivered=" .. self.delivered .. " duplicates=" .. self.duplicates
    .. " directDuplicates=" .. self.directDuplicates .. " acks=" .. self.acksSent .. "/" .. self.acksHeard
    .. " rebroadcasts=" .. self.rebroadcasts .. " cancelled=" .. self.rebroadcastCancelled
    .. " failed=" .. self.rebroadcastFailed .. " deliverErrors=" .. self.deliverErrors)
  print("relay: discovery scans=" .. self.scans .. " hellos=" .. self.hellosSent .. "/" .. self.hellosHeard
    .. " beacons=" .. self.beaconsSent .. "/" .. self.beaconsHeard)
  local parts = {}
  for reason, count in pairs(self.rejects) do parts[#parts + 1] = reason .. "=" .. count end
  table.sort(parts)
  print("relay: rejects " .. (#parts > 0 and table.concat(parts, " ") or "none"))
end

-- Wiring ------------------------------------------------------------------------------

if WF.RegisterEvent then
  WF.RegisterEvent("BN_CHAT_MSG_ADDON", function(_, prefix, text, channel, senderID)
    Relay:OnGameData(prefix, text, channel, senderID)
  end)
  WF.RegisterEvent("PLAYER_ENTERING_WORLD", function() Relay:RequestScan(SCAN_DEBOUNCE) end)
  local function Rescan() Relay:RequestScan(SCAN_DEBOUNCE) end
  WF.RegisterEvent("BN_FRIEND_ACCOUNT_ONLINE", Rescan)
  WF.RegisterEvent("BN_FRIEND_ACCOUNT_OFFLINE", Rescan)
  WF.RegisterEvent("BN_FRIEND_INFO_CHANGED", Rescan)
  WF.RegisterEvent("BN_FRIEND_LIST_SIZE_CHANGED", Rescan)
  WF.RegisterEvent("BN_CONNECTED", Rescan)
  WF.RegisterEvent("BN_DISCONNECTED", function()
    for id in pairs(links) do DropLink(id, "battle.net down") end
  end)
end

if CreateFrame then
  local frame = CreateFrame("Frame", "WarfrontRelayFrame", UIParent)
  frame:SetScript("OnUpdate", function() Relay:Tick(Now()) end)
end
