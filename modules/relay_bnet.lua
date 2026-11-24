local WF = Warfront
local Relay = WF.Relay

-- Cross-faction relay, Battle.net side (decision 0068): game-data receive,
-- owner catch-up and board copies over links, friend scan, status and tick.
-- modules/relay.lua loads first and shares its constants, state and helpers
-- through Relay.Kit. Keep each relay file far below Lua 5.1's limit of 200
-- active locals (.claude/forever-compatibility.md, Top-level local limit).
local Kit = Relay.Kit
local Accept = Kit.Accept
local Allow = Kit.Allow
local BN_PACKET = Kit.BN_PACKET
local BULK = Kit.BULK
local BattleNetReady = Kit.BattleNetReady
local Candidate = Kit.Candidate
local CanTakePresence = Kit.CanTakePresence
local CheckAcks = Kit.CheckAcks
local DropLink = Kit.DropLink
local Enqueue = Kit.Enqueue
local HELLO = Kit.HELLO
local Header = Kit.Header
local InInstance = Kit.InInstance
local IsPrintableBody = Kit.IsPrintableBody
local IsSecret = Kit.IsSecret
local K = Kit.K
local LinkAlive = Kit.LinkAlive
local LiveLinkCount = Kit.LiveLinkCount
local Lockdown = Kit.Lockdown
local MyFaction = Kit.MyFaction
local MyRealmID = Kit.MyRealmID
local MyRecord = Kit.MyRecord
local MySession = Kit.MySession
local Now = Kit.Now
local OnAck = Kit.OnAck
local OPPOSITE = Kit.OPPOSITE
local ParsePacket = Kit.ParsePacket
local PruneHolders = Kit.PruneHolders
local Pump = Kit.Pump
local PurgeDirect = Kit.PurgeDirect
local PurgeSeen = Kit.PurgeSeen
local QueueControl = Kit.QueueControl
local Refill = Kit.Refill
local Reject = Kit.Reject
local ReleaseRebroadcasts = Kit.ReleaseRebroadcasts
local ResolveAccount = Kit.ResolveAccount
local SCAN = Kit.SCAN
local SendHello = Kit.SendHello
local ServerTime = Kit.ServerTime
local UpdateBeacon = Kit.UpdateBeacon
local UpsertLink = Kit.UpsertLink
local bucket = Kit.bucket
local hello = Kit.hello
local lanes = Kit.lanes
local linkBytes = Kit.linkBytes
local links = Kit.links
local rebroadcast = Kit.rebroadcast
local status = Kit.status
local Queued = Kit.Queued
local AckCount = Kit.AckCount
local HolderCount = Kit.HolderCount
local ChannelCrossedAt = Kit.ChannelCrossedAt
local strMatch = string.match
local mathFloor, mathMin, mathMax = math.floor, math.min, math.max

-- State ---------------------------------------------------------------------------

local candidates = {}     -- gameAccountID -> character name, from the last scan
local scan
local nextScanAt, lastScanAt
local nextSlowAt, nextTickAt = 0, 0
-- gameAccountID -> { at, record }: a bare ask of another ruleset we answered
-- (decision 0148 § 1); its reply or summary then proves the far client.
local presenceAsked = {}

-- Battle.net game data -------------------------------------------------------------

-- A bare ask of another ruleset without a link: answered, never linked. An old
-- client only ever sends such asks to another ruleset, so it never holds a
-- presence slot; an updated one proves itself by its reply or keepalive, or by
-- a summary after our answer (decision 0148 § 1).
local function AnswerPresenceAsk(account, record, now)
  local asked = presenceAsked[account.id]
  if asked and now - asked.at < K.REPLY_GAP then return true end
  if not CanTakePresence() then return Reject("presence full") end
  presenceAsked[account.id] = { at = now, record = record }
  SendHello(account.id, "R", now)
  Relay.presenceAsks = (Relay.presenceAsks or 0) + 1
  return true
end

local function OnHello(account, rest, now)
  local flag, faction, record, version = strMatch(rest, "^([ARK]):([AH]):(%d+):([%d%.]+)$")
  if not flag then return Reject("hello format") end
  if faction ~= account.faction then return Reject("hello mismatch") end
  local theirs, mine = tonumber(record), MyRecord()
  if #record > 10 or not theirs or not mine then
    if links[account.id] then DropLink(account.id, "ruleset") end
    return Reject("hello ruleset")
  end
  local versions = WF.Version
  if #version > 16 or (versions and versions.Valid and not versions.Valid(version)) then
    return Reject("hello version")
  end
  -- Another ruleset links for the online players list only (decision 0148
  -- § 1, amending 0112 § 3); a ruleset change mid-session switches the mode.
  local presence = theirs ~= mine
  if presence and not links[account.id] and flag == "A" then return AnswerPresenceAsk(account, theirs, now) end
  local link = UpsertLink(account, now, presence)
  if not link then return Reject("links full") end
  presenceAsked[account.id] = nil
  link.version = version
  -- An ask on a live link: the far client started again and holds nothing of
  -- ours, so our summary goes again soon (modules/far_players.lua).
  if flag == "A" then link.askedAt = now end
  link.received = link.received + 1
  Relay.hellosHeard = Relay.hellosHeard + 1
  if versions and versions.Note then pcall(versions.Note, versions, version, K.LEVEL, link.name) end
  if flag == "A" and (not link.repliedAt or now - link.repliedAt >= K.REPLY_GAP) then
    link.repliedAt = now
    SendHello(account.id, "R", now)
  end
  return true
end

local function LinkIdentity(link)
  local capture = WF.Capture
  return capture and capture.Identity and capture.Identity(link.name) or link.name
end

-- The WR campaign field: <N>.<S>.<set> and decision 0139's optional ruleset
-- marker .<record> of one to three base-36 characters (as P2P.CampaignFieldOk).
local function CampaignFieldOk(text)
  if #text > 20 then return false end
  if strMatch(text, "^[0-9A-Z]+%.[0-9A-Z]+%.[A-Z0-9%-]+$") then return true end
  local marker = strMatch(text, "^[0-9A-Z]+%.[0-9A-Z]+%.[A-Z0-9%-]+%.([0-9A-Z]+)$")
  return marker ~= nil and #marker <= 3
end

-- A packet of another campaign is never delivered (decision 0103 § 4b); a CE
-- carries its own campaign and passes (modules/campaign.lua).
local function CampaignOk(id, campaign)
  local p2p = WF.P2PTest
  if p2p and type(p2p.AdmitCampaign) == "function" then return p2p.AdmitCampaign(id, campaign) end
  return true
end

local function OnBridgePacket(account, rest, now, campaign)
  local packet, reason = ParsePacket(rest, BN_PACKET, now)
  if not packet then return Reject(reason) end
  if not CampaignOk(packet.id, campaign) then return Reject("campaign skew") end
  if packet.faction ~= account.faction then return Reject("origin faction") end
  -- Only a link whose hello stated our ruleset (decision 0112): the realm no
  -- longer tells, so a packet never creates a link by itself.
  local link = links[account.id]
  if not link then return Reject("bridge unlinked") end
  link.name, link.lastHeard = account.name, now
  link.received = link.received + 1
  return Accept(packet, LinkIdentity(link), "B", account.id, now)
end

-- The online players summary of a link (decision 0148 § 2): any link, game or
-- presence. modules/far_players.lua parses it; nothing here reaches gameplay.
local function OnPresence(account, rest, now)
  local link = links[account.id]
  if not link then
    -- A summary right after our answer to its ask proves the far client.
    local asked, mine = presenceAsked[account.id], MyRecord()
    if not asked or now - asked.at > K.LINK_TTL or not mine or asked.record == mine then
      return Reject("presence unlinked")
    end
    link = UpsertLink(account, now, true)
    if not link then return Reject("links full") end
    presenceAsked[account.id] = nil
  end
  link.name, link.lastHeard = account.name, now
  link.received = link.received + 1
  local far = WF.FarPlayers
  if not far or type(far.OnSummary) ~= "function" then return Reject("far players") end
  local ok, result = pcall(far.OnSummary, far, account.id, account.faction, rest, now)
  if not ok then
    if WF.RecordError then WF.RecordError("relay presence", result) end
    return false
  end
  if not result then return Reject("presence format") end
  return true
end

-- Live links of either mode for the summary: { id, faction, askedAt }, by id.
function Relay:PresenceTargets(now)
  now = now or Now()
  local list = {}
  if not status.sendable then return list end
  for id, link in pairs(links) do
    if LinkAlive(link, now) then list[#list + 1] = { id = id, faction = link.faction, askedAt = link.askedAt } end
  end
  table.sort(list, function(a, b) return a.id < b.id end)
  return list
end

-- True while link `id` lives, in either mode.
function Relay:LinkLive(id, now)
  local link = links[id]
  return link ~= nil and LinkAlive(link, now or Now())
end

-- One summary part for link `id`, in the presence lane: a newer part of the
-- same index replaces a queued one; the shared budget paces it.
function Relay:SendPresence(id, part, body, now)
  now = now or Now()
  if not status.sendable or type(body) ~= "string" or not IsPrintableBody(body) then return false end
  local link = links[id]
  if not link or not LinkAlive(link, now) then return false end
  local payload = Header("P") .. body
  if #payload > K.WIRE_MAX then
    self.oversize = self.oversize + 1
    return false
  end
  return Enqueue({ lane = "presence", target = id, payload = payload, bytes = #payload, anyLink = true,
    coalesce = "presence:" .. id .. ":" .. tostring(part) }, now)
end

-- Owner catch-up with our links (decision 0081 § 1) ------------------------------
-- Battle.net names the link's character (Candidate), so its D digest and O
-- owner lines need no relayed origin: modules/catchup.lua counts each answer
-- as one hint of that character, never a quorum alone.

-- Live links: { id, identity, firstAt }, by id.
function Relay:CatchupLinks(now)
  now = now or Now()
  local list = {}
  if not status.sendable then return list end
  for id, link in pairs(links) do
    if LinkAlive(link, now) and not link.presence then
      list[#list + 1] = { id = id, identity = LinkIdentity(link), firstAt = link.firstAt }
    end
  end
  table.sort(list, function(a, b) return a.id < b.id end)
  return list
end

-- One D (our digest) or O (an owner line) for link `id`, in the last lane:
-- it never delays a relayed packet, and the shared budget paces it.
function Relay:SendCatchup(id, kind, body, key, now)
  now = now or Now()
  if (kind ~= "D" and kind ~= "O") or not status.sendable or not IsPrintableBody(body) then return false end
  local link = links[id]
  if not link or not LinkAlive(link, now) then return false end
  local payload = Header(kind) .. body
  if #payload > K.WIRE_MAX then
    self.oversize = self.oversize + 1
    return false
  end
  return Enqueue({ lane = "catchup", target = id, payload = payload, bytes = #payload,
    coalesce = key and ("catchup:" .. id .. ":" .. key) or nil }, now)
end

-- Board copies over Battle.net (decision 0110 § 4): one line to one live link,
-- kind W, body "<BD|BQ|BP>,<board body>". Only when no packet of any lane
-- waits, the shared budget is full and nothing slows the relay; it takes no
-- budget, and a refusal stops the board lane for 10 minutes without slowing
-- the relay. Never queued, never relayed further.
-- SR: the link partner's own scoreboard row (decision 0146), same lane.
local BOARD_IDS = { BD = true, BQ = true, BP = true, AM = true, SR = true }
Relay.boardSent, Relay.boardRefused, Relay.boardIn, Relay.boardBackoffUntil = 0, 0, 0, 0

function Relay:BoardLinks(now)
  now = now or Now()
  local out = {}
  if not status.sendable then return out end
  for id, link in pairs(links) do
    if LinkAlive(link, now) and not link.presence then out[#out + 1] = id end
  end
  return out
end

function Relay:SendBoard(id, boardId, body, now)
  now = now or Now()
  if not BOARD_IDS[boardId] or type(body) ~= "string" or not status.sendable or Lockdown() then return false end
  if now < self.boardBackoffUntil or Queued() > 0 then return false end
  local link = links[id]
  -- A presence link carries only hellos and summaries (decision 0148 § 1).
  if not link or link.presence or not LinkAlive(link, now) then return false end
  Refill(now)
  if bucket.slowUntil or bucket.tokens < K.BUDGET_BURST then return false end
  local payload = Header("W") .. boardId .. "," .. body
  if #payload > K.WIRE_MAX or not IsPrintableBody(boardId .. "," .. body) then return false end
  if boardId == "AM" then
    local gate = WF.SendQueue
    if not gate then return false end
    local function SendMatch(target, line, at)
      bucket.tokens = bucket.tokens - #line
      if not Kit.SendNow(target, line, at) then error("match send refused") end
    end
    local ok = gate:SendIdle({ fn = SendMatch, n = 3, a1 = id, a2 = payload, a3 = now, accounted = true }, 3)
    return ok == true
  end
  local ok, result = pcall(C_BattleNet.SendGameData, id, K.PREFIX, payload)
  local results = type(Enum) == "table" and Enum.SendAddonMessageResult or nil
  local success = type(results) == "table" and results.Success or nil
  if not ok or (success ~= nil and result ~= nil and result ~= success) then
    self.boardRefused = self.boardRefused + 1
    self.boardBackoffUntil = now + 600
    return false
  end
  self.boardSent = self.boardSent + 1
  -- Read by the activity meter only (modules/traffic.lua).
  self.boardBytes = (self.boardBytes or 0) + #payload
  return true
end

function Relay:OnGameData(prefix, text, channel, senderID)
  if IsSecret(prefix) or IsSecret(text) or IsSecret(senderID) then return Reject("secret") end
  if prefix ~= K.PREFIX then return end
  self.received = self.received + 1
  if Lockdown() then return Reject("lockdown") end
  if not BattleNetReady() then return Reject("battle.net") end
  if type(text) ~= "string" or #text > BULK.IN_MAX then return Reject("size") end
  local proto, level, kind, campaign, rest = strMatch(text, "^WR(%d+):(%d+):(%u):([0-9A-Z%.%-]+):(.*)$")
  if not proto or not CampaignFieldOk(campaign) then return Reject("format") end
  if #text > K.WIRE_MAX and kind ~= "Z" and kind ~= "M" then return Reject("size") end
  if tonumber(proto) ~= K.PROTOCOL then return Reject("protocol") end
  if tonumber(level) ~= K.LEVEL then return Reject("level") end
  local account, reason = ResolveAccount(senderID)
  if not account then
    if links[senderID] then DropLink(senderID, reason) end
    return Reject(reason)
  end
  local now = Now()
  if not Allow(linkBytes, senderID, now, #text) then return Reject("link rate") end
  local held = links[senderID]
  if held and held.presence and kind ~= "H" and kind ~= "P" then return Reject("presence link") end
  if kind == "H" then return OnHello(account, rest, now) end
  if kind == "P" then return OnPresence(account, rest, now) end
  if kind == "R" then return OnBridgePacket(account, rest, now, campaign) end
  if kind == "A" then return OnAck(account, rest, now) end
  if kind == "Z" then
    -- A link measuring us: answer with the bytes that arrived.
    local nonce = strMatch(rest, "^([0-9A-Z]+):")
    if not nonce or #nonce > 8 or not links[senderID] then return Reject("probe") end
    QueueControl(senderID, Header("Y") .. nonce .. ":" .. #text, now)
    return true
  end
  if kind == "Y" then
    local nonce, bytes = strMatch(rest, "^([0-9A-Z]+):(%d+)$")
    local link = links[senderID]
    if not nonce or not link or link.probeNonce ~= nonce then return Reject("probe answer") end
    link.probeNonce = nil
    link.bulk = tonumber(bytes) == BULK.PROBE_BYTES
    if link.bulk then Relay.probesAnswered = Relay.probesAnswered + 1 end
    return true
  end
  if kind == "M" then
    -- Several relayed packets in one message: each takes the R path alone.
    local count = 0
    for part in string.gmatch(rest, "[^|]+") do
      count = count + 1
      if count > BULK.PARTS then return Reject("bulk parts") end
      OnBridgePacket(account, part, now, campaign)
    end
    self.bulkIn = self.bulkIn + 1
    return count > 0
  end
  if kind == "W" then
    local link = links[senderID]
    if not link then return Reject("board unlinked") end
    local boardId, data = strMatch(rest, "^(%u%u),(.*)$")
    if not boardId or not BOARD_IDS[boardId] then return Reject("board format") end
    link.lastHeard = now
    link.received = link.received + 1
    self.boardIn = self.boardIn + 1
    if (boardId == "AM" or boardId == "SR") and not CampaignOk(boardId, campaign) then return false end
    if boardId == "SR" then
      local rows = WF.ScoreRows
      if not rows or type(rows.OnLine) ~= "function" then return Reject("score rows") end
      local okRows, taken = pcall(rows.OnLine, rows, data, LinkIdentity(link))
      if not okRows then
        if WF.RecordError then WF.RecordError("relay score row", taken) end
        return false
      end
      return taken
    end
    local boards = boardId == "AM" and WF.AlliesMesh or WF.Boards
    if not boards or type(boards.OnLine) ~= "function" then return Reject("boards") end
    local ok, result = pcall(boards.OnLine, boards, boardId, data, LinkIdentity(link), "L:" .. tostring(senderID), now)
    if not ok then
      if WF.RecordError then WF.RecordError("relay board", result) end
      return false
    end
    return result
  end
  if kind == "D" or kind == "O" then
    local link = links[senderID]
    if not link then return Reject("catch-up unlinked") end
    if not CampaignOk(kind == "D" and "OD" or "OL", campaign) then return Reject("campaign skew") end
    link.lastHeard = now
    link.received = link.received + 1
    local catchup = WF.Catchup
    local method = catchup and catchup[kind == "D" and "OnLinkDigest" or "OnLinkAnswer"]
    if type(method) ~= "function" then return Reject("catch-up unavailable") end
    local ok, result = pcall(method, catchup, senderID, LinkIdentity(link), rest, now)
    if not ok then
      if WF.RecordError then WF.RecordError("relay catch-up", result) end
      return false
    end
    return result
  end
  return Reject("kind")
end

-- Discovery: an incremental scan of the Battle.net friend list -------------------

local function StartScan(now)
  if type(BNGetNumFriends) ~= "function" or type(C_BattleNet.GetFriendNumGameAccounts) ~= "function"
      or type(C_BattleNet.GetFriendGameAccountInfo) ~= "function" then
    return
  end
  local opposite = OPPOSITE[MyFaction() or ""]
  if not opposite or not MyRecord() then return end
  -- realmID only for same-faction friends: a whisper stays on our realm. Nil
  -- is fine: Relay.SameRealm asks the client first (build 71037).
  local realmID = MyRealmID()
  local ok, total = pcall(BNGetNumFriends)
  if not ok or type(total) ~= "number" then return end
  scan = { index = 1, total = mathMin(SCAN.MAX_FRIENDS, mathFloor(total)), found = {}, allies = {},
    opposite = opposite, mine = MyFaction(), realmID = realmID }
  lastScanAt = now
  Relay.scans = Relay.scans + 1
end

local function ScanFriend(index)
  local ok, count = pcall(C_BattleNet.GetFriendNumGameAccounts, index)
  if not ok or type(count) ~= "number" or count < 1 then return end
  for j = 1, mathMin(SCAN.MAX_GAME_ACCOUNTS, count) do
    local okInfo, info = pcall(C_BattleNet.GetFriendGameAccountInfo, index, j)
    if okInfo then
      local account = Candidate(info, scan.opposite)
      if account then scan.found[account.id] = account.name end
      local ally = Relay.Ally(info, scan.mine, scan.realmID)
      if ally then scan.allies[#scan.allies + 1] = ally end
    end
  end
end

local function FinishScan(now)
  local found, allies = scan.found, scan.allies
  scan = nil
  candidates = found
  -- Same-faction friends become directory names (decision 0077 § 5f).
  local directory = WF.Directory
  if directory and type(directory.TakeFriends) == "function" then
    local ok, err = pcall(directory.TakeFriends, directory, allies, now)
    if not ok and WF.RecordError then WF.RecordError("directory friends", err) end
  end
  for id in pairs(links) do
    if not found[id] and not ResolveAccount(id) then DropLink(id, "gone") end
  end
  -- A friend who left WoW starts again from the shortest wait when back.
  for id in pairs(hello.at) do
    if not found[id] then hello.at[id] = nil end
  end
  for id in pairs(hello.wait) do
    if not found[id] then hello.wait[id] = nil end
  end
  if not status.eligible then return end
  local due = {}
  for id in pairs(found) do
    if not links[id] and (not hello.at[id] or now - hello.at[id] >= (hello.wait[id] or HELLO.first)) then
      due[#due + 1] = id
    end
  end
  -- Never greeted first, then the least recently greeted: past
  -- SCAN.MAX_HELLOS candidates, no one waits forever.
  table.sort(due, function(a, b)
    local ta, tb = hello.at[a] or -1, hello.at[b] or -1
    if ta ~= tb then return ta < tb end
    return a < b
  end)
  local sent = 0
  for i = 1, #due do
    if sent >= SCAN.MAX_HELLOS then break end
    local id = due[i]
    if SendHello(id, "A", now) then
      if hello.at[id] then
        hello.wait[id] = mathMin(HELLO.max, (hello.wait[id] or HELLO.first) * 2)
      else
        hello.wait[id] = HELLO.first
      end
      hello.at[id] = now
      sent = sent + 1
    end
  end
end

local function ScanStep(now)
  local stop = mathMin(scan.total, scan.index + SCAN.SLICE - 1)
  for i = scan.index, stop do ScanFriend(i) end
  scan.index = stop + 1
  if scan.index > scan.total then FinishScan(now) end
end

function Relay:RequestScan(delay)
  local now = Now()
  local at = now + (delay or SCAN.DEBOUNCE)
  if lastScanAt then at = mathMax(at, lastScanAt + SCAN.MIN_GAP) end
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
  elseif not MyFaction() or not MyRecord() or not ServerTime() or not MySession() then
    reason = "character"
  end
  status.sendable = reason == nil
  if not reason then
    if ChannelCrossedAt() and now - ChannelCrossedAt() < K.CROSSING_HOLD then
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
    else
      if status.sendable and now - link.lastSentAt >= K.KEEPALIVE then SendHello(id, "K", now) end
      if status.sendable and not link.presence then BULK.Probe(id, link, now) end
    end
  end
  for id, asked in pairs(presenceAsked) do
    if now - asked.at > K.LINK_TTL then presenceAsked[id] = nil end
  end
  PruneHolders(now)
  PurgeSeen(now)
  PurgeDirect(now)
  CheckAcks(now)
  if status.sendable then UpdateBeacon(now) end
  if not scan and status.sendable and nextScanAt and now >= nextScanAt then
    nextScanAt = now + SCAN.INTERVAL
    StartScan(now)
  end
end

function Relay:Tick(now)
  if now < nextTickAt then return end
  nextTickAt = now + K.TICK
  if now >= nextSlowAt then
    nextSlowAt = now + K.SLOW_TICK
    SlowTick(now)
  end
  if scan then ScanStep(now) end
  ReleaseRebroadcasts(now)
  if status.sendable then Pump(now) end
end

-- Diagnostics -----------------------------------------------------------------------

function Relay:Summary()
  return "relay " .. status.reason .. " links=" .. LiveLinkCount(Now()) .. "/" .. K.MAX_LINKS
    .. " bridges=" .. HolderCount() .. " queued=" .. Queued() .. "/" .. K.QUEUE_MAX
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
  print("relay: role=" .. status.reason .. " faction=" .. tostring(MyFaction()) .. " record="
    .. tostring(MyRecord()) .. " realmID=" .. tostring(MyRealmID()) .. " links=" .. LiveLinkCount(now) .. "/" .. K.MAX_LINKS
    .. " candidates=" .. CountKeys(candidates) .. " other bridges=" .. HolderCount())
  for _, link in pairs(links) do
    print("relay: link " .. link.name .. " (" .. link.faction .. ", " .. tostring(link.version or "?")
      .. (link.presence and ", presence" or "")
      .. ") heard " .. mathFloor(now - link.lastHeard) .. "s ago, sent=" .. link.sent .. " received=" .. link.received
      .. " bulk=" .. (link.bulk == true and "yes" or (link.bulk == false and "no" or "?")))
  end
  print("relay: bulk probes=" .. self.probesSent .. "/" .. self.probesAnswered .. " sent=" .. self.bulkSent
    .. " parts=" .. self.bulkParts .. " in=" .. self.bulkIn)
  print("relay: queue control=" .. #lanes.control .. " critical=" .. #lanes.critical .. " state=" .. #lanes.state
    .. " routine=" .. #lanes.routine .. " catchup=" .. #lanes.catchup .. " presence=" .. #lanes.presence
    .. " held=" .. (Relay.presenceHeld or 0) .. " aged=" .. (Relay.agedServed or 0)
    .. " acks=" .. AckCount() .. " rebroadcast=" .. #rebroadcast
    .. " budget=" .. mathFloor(bucket.tokens) .. "/" .. K.BUDGET_BURST .. " (" .. K.BUDGET_RATE .. " B/s)"
    .. ((bucket.slowUntil and now < bucket.slowUntil)
      and (" halved " .. mathFloor(bucket.slowUntil - now) .. "s after a refusal") or ""))
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
  WF.RegisterEvent("PLAYER_ENTERING_WORLD", function() Relay:RequestScan(SCAN.DEBOUNCE) end)
  local function Rescan() Relay:RequestScan(SCAN.DEBOUNCE) end
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
