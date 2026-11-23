local WF = Warfront

-- Same-faction addon-message transports (decisions 0077 and 0134).
--
-- A capture line keeps its channel wire WF<level>:<version>:<id>:<session>:<seq>:<body>
-- and travels as an addon message with the prefix WF:
--   * GROUP (RAID in a raid, PARTY otherwise): every capture line, like the
--     channel did, for the players of our group;
--   * GUILD: only critical events (the relay's class C: K, AC, AR, SC, GD and S
--     carrying START or CAPTURED) and a slow network presence NP, rare on
--     purpose: one line per 15 s per client, a whole-guild ceiling counted on what
--     is heard, nothing while no other Warfront client was heard in the guild,
--     never a request or an answer.
--   * GROUP also carries the cross-faction relay's B beacons and R far
--     rebroadcasts (decision 0077 step 5), received like the channel's.
--   * WHISPER (decision 0077 steps 3 and 4a): the NP presence to and from the
--     channel member list (modules/directory.lua); the owner catch-up digest OD
--     and its answers OL between guild peers and contacts, whose NP carries a
--     digest of their confirmed registry (modules/catchup.lua); and our own
--     critical lines, first-hand, to a few contacts; and F lines, a fact of our
--     faction passed hand to hand (modules/chain.lua, step 4b), only between
--     guild peers and contacts.
--     A whisper to a player who just left would print "No player named ..." in
--     chat: that one line is hidden for Warfront's recent whisper targets only.
--     Since decision 0077 § 5f the attack and scout catch-up (AQ/AL, SQ/SL)
--     also travels addressed between guild peers and contacts.
--   * GROUP also carries the version announce V (§ 5f), as the channel did.
--   * CHANNEL is supplementary and peer-gated: V is a bounded canary; after a
--     valid remote Warfront line is heard, safe push lines also use the hidden
--     addon channel. Requests and catch-up answers never use that audience.
-- Received lines go through the channel's reception chain: the relay's
-- duplicate check (and bridge), then Capture:OnMessage with the event sender.
-- Nothing is sent or read inside an instance or during chat lockdown. Every
-- send passes WF.SendQueue (rule R12). Numbers are provisional (decision 0077).

local Transport = {
  sent = 0, refused = 0, errors = 0, superseded = 0, skipped = 0,
  received = 0, delivered = 0, duplicates = 0, echoes = 0, ignored = 0,
  noRoute = 0, guildQueued = 0, guildDropped = 0, guildExpired = 0, guildCapped = 0,
  addressed = 0, addressedIn = 0, fanned = 0, fanSkipped = 0, presencesWhispered = 0, hiddenOffline = 0,
  guildNoPeer = 0, presences = 0, oversize = 0, overBudget = 0, throttled = 0,
  boardSent = 0, boardRefused = 0, boardIn = 0, boardBackoffUntil = 0,
  rejects = {},
}
WF.Transport = Transport

local PREFIX = "WF"
-- Prefix, separator and message stay within the 255-byte addon message.
local MAX_BYTES = 255 - #PREFIX - 1
local NETWORK_PRESENCE = "NP"
local GROUP_TYPES = { PARTY = true, RAID = true }
local CHANNEL_NAME = "Warfront"
-- Broadcast pushes only. Realm-wide requests or catch-up answers would bring
-- back the answer storm of risk B8, so they stay on group/addressed transports.
local CHANNEL_CAPTURE_LINES = {
  P = true, S = true, X = true, G = true, GD = true, SC = true, AC = true, AR = true,
  T = true, FW = true, CE = true,
}
-- What an addressed whisper may carry (decision 0077 step 3).
local ADDRESSED = { OD = true, OL = true, AQ = true, AL = true, SQ = true, SL = true, FQ = true, FW = true,
  CQ = true, CL = true, LJ = true, LN = true }
-- A request to join a layer and its refusal (decision 0119 step 4): accepted by
-- whisper from any player of our faction, not only a contact, and never routed
-- to capture.
local LAYER_LINES = { LJ = true, LN = true }
local FORWARD_ID = "F"
local RELAY_LINES = { B = true, R = true }
-- Lines about the POI we stand in (decision 0080): also whispered to the
-- contacts near us there (modules/nearby.lua), and accepted by whisper from a
-- guild peer or contact.
local LOCAL_LINES = { P = true, S = true, Q = true, X = true, G = true, GQ = true, GD = true, H = true, HQ = true,
  K = true }
-- Presence and state lines, built with age 0: first in the send gate (risk B10,
-- decision 0095).
local LIVE_LINES = { P = true, S = true, X = true }
-- What may go to our group only, outside the capture lines: the relay's lines
-- and the version announce (decision 0077 § 5f).
local GROUP_LINES = { B = true, R = true, V = true }
-- Group mates heard sending Warfront lines: the hearers of a group line.
local GROUP_PEER_TTL, MAX_GROUP_PEERS = 600, 40
-- An addressed catch-up request (AQ, SQ) answered once per ANSWER_GAP s per
-- asker, ANSWERS_PER_WINDOW askers per ANSWER_WINDOW s for each kind.
local ANSWER_GAP, ANSWERS_PER_WINDOW, ANSWER_WINDOW, MAX_ANSWERED = 60, 6, 600, 32
-- The addressed attack and scout catch-up starts PULL_AFTER s after loading
-- once PULL_PEERS guild peers or contacts are known, or with one after
-- PULL_LATE s: a first contact alone may know nothing. It is asked again
-- PULL_ROUNDS s after that start, until an addressed answer came (a contact
-- may not hold us as one yet and refuse the first request).
local PULL_AFTER, PULL_LATE, PULL_PEERS = 60, 180, 2
local PULL_ROUNDS = { 0, 300, 900 }
-- A bridge's links heard in a NP presence live this long (decision 0077 step 5):
-- presences are rarer than B lines.
local NP_BEACON_TTL = 1500
local WHISPER_INTAKE_PER_MIN, MAX_WHISPER_INTAKE = 24, 128
local MAX_TARGET_BYTES = 64
-- Our own critical lines to contacts (decision 0077 step 4a): FAN contacts per
-- line, a kill at most once per KILL_GAP s, CHAIN_RATE whispers a second
-- (CHAIN_BURST at once) for all of them. Provisional.
local FAN, KILL_GAP, CHAIN_RATE, CHAIN_BURST = 4, 30, 0.5, 10
-- Whisper targets of the last TARGET_TTL s, for the offline-line filter.
local TARGET_TTL, MAX_TARGETS = 120, 64

-- Two token buckets per client: a capture start or end spends `terminal`
-- (RATE, BURST); every other line spends `tokens`, refilled at this client's
-- fair share of SOFT_PER_MIN among the guild's Warfront clients (itself
-- included), never faster than RATE. So the guild's ordinary traffic stays
-- near SOFT_PER_MIN whatever its size.
local GUILD = {
  RATE = 1 / 15, BURST = 2,
  SOFT_PER_MIN = 3, HARD_PER_MIN = 8,
  OUTBOX_MAX = 8, OUTBOX_TTL = 60, STATE_TTL = 15,
  -- A line waits WAIT_MIN..WAIT_MAX s. Each time the ceiling holds it, it draws
  -- a new wait widened by WAIT_PER_PEER s per guild peer: clients held on the
  -- same minute spread out far beyond the ~1 s a copy takes to be heard.
  WAIT_MIN = 1, WAIT_MAX = 6, WAIT_PER_PEER = 1.5, TERMINAL_SPREAD = 2,
  PEER_TTL = 1800, MAX_PEERS = 256,
  INTAKE_PER_MIN = 12, MAX_INTAKE = 256,
  -- One sender counts for at most CEILING_SHARE lines a minute toward the
  -- ceiling, so a single flooder cannot silence the guild lane alone.
  CEILING_SHARE = 2, HEARD_KEEP = 32,
  ECHO_WAIT = 10, SILENT_AFTER = 3, SILENT_GAP = 300,
  PRESENCE_FIRST = 45, PRESENCE_FIRST_JITTER = 30,
  PRESENCE_MIN = 300, PRESENCE_PER_PEER = 60, PRESENCE_ALONE = 600, PRESENCE_JITTER = 30,
}
local REFUSED_PAUSE, REFUSED_MAX = 30, 300
-- The client also limits addon messages (Enum.SendAddonMessageResult
-- AddonMessageThrottle = 3, Forever FrameXML ChatConstantsDocumentation.lua:154);
-- its numbers are unmeasured. Warfront assumes ADDON_BURST at once and
-- ADDON_RATE a second for every group and guild copy (provisional), and a
-- throttle refusal pauses that chat type THROTTLE_PAUSE s, doubling up to
-- THROTTLE_MAX, instead of the longer pause of any other refusal.
-- TargetOffline (12, same file :163) is about one whisper target: that player
-- stops being a contact or a pull target, as for the offline chat line below,
-- and other whispers go on (decision 0077 § 5g). The measured client returned
-- 0 for an offline target (2026-11-09); 12 is handled in case a build returns it.
local ADDON_BURST, ADDON_RATE = 10, 1
-- Board copies (decision 0110): the lowest lane. A board line leaves only with
-- a full addon budget, an empty gate silent for BOARD_QUIET seconds, an empty
-- guild outbox, out of combat; it takes no token and pauses nothing when refused.
local BOARD_LINES = { BD = true, BQ = true, BP = true, AM = true }
local BOARD_QUIET = 3
local BOARD_BACKOFF = 600
-- Whisper targets of board audiences "W:<identity>", contacts and guild peers only.
local boardTargets = {}
local THROTTLE_RESULT, CHANNEL_THROTTLE_RESULT, THROTTLE_PAUSE, THROTTLE_MAX, OFFLINE_RESULT = 3, 8, 2, 30, 12
local DEDUP_TTL, DEDUP_MAX = 120, 1024
local TICK = 0.5

local strSub, strFind, mathFloor, mathMin, mathMax, mathRandom =
  string.sub, string.find, math.floor, math.min, math.max, math.random

-- State --------------------------------------------------------------------------

local guild = {
  tokens = GUILD.BURST, terminal = GUILD.BURST, at = nil, outbox = {}, heard = {}, peers = {}, peerCount = 0,
  targets = {},
  intake = {}, intakeCount = 0, pendingEcho = {}, echoMissed = 0, silent = false,
  nextPresenceAt = nil,
}
local paused = {}          -- chat type -> { untilAt, count }
local whisperIntake, whisperIntakeCount = {}, 0
local lastGroupType
local recentTargets, recentTargetCount = {}, 0
local chain = { tokens = CHAIN_BURST, at = nil, killAt = nil }
local addon = { tokens = ADDON_BURST, at = nil }
local seen, seenKeys, seenHead, seenTail = {}, {}, 1, 0
-- Exact admitted facts and their routing metadata share the seen FIFO bounds.
-- A later channel/fallback copy grants no permission to a changed body.
local seenFacts = {}
local nextTickAt = 0
local groupPeers, groupPeerCount = {}, 0
local answered = {}        -- kind -> { last = { target -> at }, times = { at, ... }, count }
local startAt, pullFirstAt, pullRound = nil, nil, 0

Transport.channelConfirmed = false
Transport.channelSent = 0
Transport.channelRemote = 0
Transport.channelAcks = 0
Transport.channelCanaries = 0
Transport.channelAckCancelled = 0

-- Small helpers ---------------------------------------------------------------------

local function Now()
  local now = WF.Now and WF.Now() or 0
  if type(now) ~= "number" then return 0 end
  return now
end

local function Global(name)
  if WF.Compat and WF.Compat.Global then return WF.Compat.Global(name) end
  return _G and _G[name] or nil
end

local function Call(name, ...)
  local fn = Global(name)
  if type(fn) ~= "function" then return false end
  return pcall(fn, ...)
end

local function IsSecret(value)
  local fn = Global("issecretvalue")
  if type(fn) ~= "function" then return false end
  local ok, secret = pcall(fn, value)
  return ok and secret and true or false
end

local function Reject(reason)
  Transport.rejects[reason] = (Transport.rejects[reason] or 0) + 1
  return false
end

local function Lockdown()
  local chat = Global("C_ChatInfo")
  if type(chat) ~= "table" or type(chat.InChatMessagingLockdown) ~= "function" then return false end
  local ok, locked = pcall(chat.InChatMessagingLockdown)
  return ok and locked == true
end

local function InInstance()
  local ok, inside = Call("IsInInstance")
  return ok and inside == true
end

local function Usable()
  return not InInstance() and not Lockdown()
end

local function MySession()
  local storage = WF.Storage
  local db = storage and type(storage.GetDB) == "function" and storage:GetDB() or nil
  local session = db and db.session and db.session.id
  if type(session) ~= "string" then return nil end
  return session
end

local function GroupType()
  -- The two-player group of a layer jump carries no group line (decision 0119 § 7).
  local jump = WF.LayerJump
  if jump and type(jump.IsHopGroup) == "function" then
    local okHop, hop = pcall(jump.IsHopGroup, jump)
    if okHop and hop then return nil end
  end
  local okRaid, raid = Call("IsInRaid")
  if okRaid and raid then
    local okUnit, index = Call("UnitInRaid", "player")
    if okUnit and index ~= nil then return "RAID" end
  end
  local okGroup, grouped = Call("IsInGroup")
  if okGroup and grouped then return "PARTY" end
  return nil
end

local function InGuild()
  local ok, member = Call("IsInGuild")
  return ok and member == true
end

local function Accepted(result)
  if result == nil or result == true or result == 0 then return true end
  local enum = Global("Enum")
  local results = type(enum) == "table" and enum.SendAddonMessageResult or nil
  return type(results) == "table" and results.Success ~= nil and result == results.Success
end

local function Paused(chatType, now)
  local entry = paused[chatType]
  return entry ~= nil and now < entry.untilAt
end

local function NotePause(chatType, now, throttled)
  local entry = paused[chatType] or { count = 0 }
  entry.count = entry.count + 1
  if throttled then
    entry.untilAt = now + mathMin(THROTTLE_MAX, THROTTLE_PAUSE * 2 ^ (entry.count - 1))
  else
    entry.untilAt = now + mathMin(REFUSED_MAX, REFUSED_PAUSE * 2 ^ (entry.count - 1))
  end
  paused[chatType] = entry
end

-- One token per group or guild copy; false when none is left.
local function TakeAddonToken(now)
  if not addon.at then addon.at = now end
  addon.tokens = mathMin(ADDON_BURST, addon.tokens + mathMax(0, now - addon.at) * ADDON_RATE)
  addon.at = now
  if addon.tokens < 1 then return false end
  addon.tokens = addon.tokens - 1
  return true
end

local function NoteSuccess(chatType)
  paused[chatType] = nil
end

-- Lines heard here and from which transport: one per identity, session and
-- sequence, whatever transports it came by.
local function SeenKey(identity, session, sequence, id)
  return identity .. "|" .. session .. ":" .. tostring(sequence) .. ":" .. id
end

-- A FIFO ring: the oldest key leaves first, past DEDUP_TTL or DEDUP_MAX keys.
local function PurgeSeen(now)
  while seenHead <= seenTail do
    local key = seenKeys[seenHead]
    if seenTail - seenHead + 1 <= DEDUP_MAX and now - seen[key] <= DEDUP_TTL then break end
    seen[key] = nil
    seenFacts[key] = nil
    seenKeys[seenHead] = nil
    seenHead = seenHead + 1
  end
end

local function MarkSeen(key, now)
  if seen[key] then return false end
  seen[key] = now
  seenTail = seenTail + 1
  seenKeys[seenTail] = key
  return true
end

-- Sending -----------------------------------------------------------------------------

local canary = {
  RETRY_FIRST = 60, RETRY_MAX = 1800, RETRIES = 6, ACK_DELAY = 1, ACK_SPREAD = 4, ACK_GAP = 30,
  retryAt = nil, wait = nil, retries = 0, ackAt = nil, lastAckAt = nil,
  target = nil, generation = 0, hearers = {}, hearerCount = 0,
}

local function ChannelTarget()
  local p2p = WF.P2PTest
  local target, name
  if p2p and type(p2p.ChannelTarget) == "function" then
    local ok, value, label = pcall(p2p.ChannelTarget)
    if ok and type(value) == "string" and value ~= "" then target, name = value, label end
  end
  if target ~= canary.target then
    canary.target, canary.generation = target, canary.generation + 1
    canary.ackAt, canary.retryAt, canary.wait = nil, nil, nil
    canary.hearers, canary.hearerCount = {}, 0
    Transport.channelConfirmed = false
    -- Retry count and acknowledgement gap remain session-wide, even on rejoin.
  end
  return target, name
end

-- The client call, made by WF.SendQueue. A refusal raises, so the send gate
-- reports a failure (its result is otherwise not passed on).
local function AddonCall(prefix, line, chatType, target)
  local send = Global("SendAddonMessage")
  if type(send) ~= "function" then error("SendAddonMessage is unavailable") end
  local result = send(prefix, line, chatType, target)
  if not Accepted(result) then error("refused " .. tostring(result)) end
end

-- A replaceable line (key) is dropped without an addon token, a newer copy
-- follows; an event still goes and only risks a throttle refusal.
local function NoteTarget(target, now)
  local lowered = string.lower(target)
  if not recentTargets[lowered] then
    if recentTargetCount >= MAX_TARGETS then
      for other, at in pairs(recentTargets) do
        if now - at > TARGET_TTL then
          recentTargets[other] = nil
          recentTargetCount = recentTargetCount - 1
        end
      end
      if recentTargetCount >= MAX_TARGETS then return end
    end
    recentTargetCount = recentTargetCount + 1
  end
  recentTargets[lowered] = now
end

local function Submit(chatType, line, key, priority, onDone, target, live)
  local queue = WF.SendQueue
  if not queue or type(queue.Submit) ~= "function" then return false, "send gate missing" end
  local now = Now()
  if not TakeAddonToken(now) then
    Transport.overBudget = Transport.overBudget + 1
    if key then return false, "addon message budget" end
  end
  if chatType == "WHISPER" and target then NoteTarget(target, now) end
  local channelGeneration = chatType == "CHANNEL" and canary.generation or nil
  local ok, err, delayed = queue:Submit({
    fn = AddonCall, n = target and 4 or 3, a1 = PREFIX, a2 = line, a3 = chatType, a4 = target,
    key = key and (chatType .. "|" .. key) or nil, priority = priority, live = live or nil,
    guard = function()
      if not Usable() or Paused(chatType, Now()) then return false end
      if chatType == "CHANNEL" then
        return ChannelTarget() == target and canary.generation == channelGeneration
      end
      if GROUP_TYPES[chatType] then return GroupType() == chatType end
      if chatType == "GUILD" then return InGuild() end
      return true
    end,
    done = function(ok, err, skipped)
      local at = Now()
      if ok then
        Transport.sent = Transport.sent + 1
        NoteSuccess(chatType)
      elseif skipped then
        if err == "route unavailable" then
          Transport.routeCancelled = (Transport.routeCancelled or 0) + 1
        else
          Transport.superseded = Transport.superseded + 1
        end
      elseif type(err) == "string" and strFind(err, "refused", 1, true) then
        Transport.refused = Transport.refused + 1
        local result = tonumber(string.match(err, "refused (%d+)"))
        local throttled = result == THROTTLE_RESULT or (chatType == "CHANNEL" and result == CHANNEL_THROTTLE_RESULT)
        if result == OFFLINE_RESULT and chatType == "WHISPER" and target then
          Transport.offline = (Transport.offline or 0) + 1
          local directory, catchup = WF.Directory, WF.Catchup
          if directory and directory.NoteUnreachable then pcall(directory.NoteUnreachable, directory, target, at) end
          if catchup and catchup.NoteUnreachable then pcall(catchup.NoteUnreachable, catchup, target, at) end
          if onDone then onDone(ok, err, skipped, at) end
          return
        end
        if throttled then
          Transport.throttled = Transport.throttled + 1
          addon.tokens = 0
        end
        NotePause(chatType, at, throttled)
        if chatType == "GUILD" then guild.tokens, guild.terminal = 0, 0 end
      else
        Transport.errors = Transport.errors + 1
        Transport.lastError = WF.Sanitize and WF.Sanitize(err, 120) or tostring(err)
      end
      if onDone then onDone(ok, err, skipped, at) end
    end,
  })
  -- Forever returned ChannelThrottle (8) for a line that still echoed 2.77 s
  -- later. Back off, but count that submission as taken so no caller retries the
  -- same event immediately and creates a duplicate (decision 0134).
  if not ok and chatType == "CHANNEL" and type(err) == "string"
      and strFind(err, "refused " .. tostring(CHANNEL_THROTTLE_RESULT), 1, true) then
    return true, err, delayed
  end
  return ok, err, delayed
end

local function SubmitChannel(line, key, priority, live, canary)
  local target = ChannelTarget()
  if not target then return false end
  if not canary and not Transport.channelConfirmed then return false end
  local now = Now()
  if Paused("CHANNEL", now) then return false end
  local ok = Submit("CHANNEL", line, key and ("channel:" .. key) or nil, priority, nil, target, live)
  if ok then Transport.channelSent = Transport.channelSent + 1 end
  return ok and true or false
end

local function ChannelEventMatches(target, localID, name)
  if type(name) ~= "string" or IsSecret(name) or string.lower(name) ~= string.lower(CHANNEL_NAME) then return false end
  if IsSecret(localID) or (type(localID) ~= "number" and type(localID) ~= "string") then return false end
  local expected = ChannelTarget()
  if not expected or tostring(localID) ~= expected then return false end
  if target ~= nil and (type(target) ~= "string" or IsSecret(target)) then return false end
  return true
end

local Wire

-- Hidden-channel canary (decision 0134 § 2, amended 2026-11-17): while no peer
-- confirmed the lane, V,A is retried 60 s after the join, then at doubling
-- waits up to 1,800 s, 6 retries a session. A remote V,A draws one V,R 1-5 s
-- later, cancelled by any other V,R heard meanwhile, at most one per 30 s.
local function SendCanary(flag)
  local storage = WF.Storage
  local db = storage and type(storage.GetDB) == "function" and storage:GetDB() or nil
  local sequence = storage and type(storage.NextSequence) == "function" and storage:NextSequence() or nil
  local session = db and db.session and db.session.id or nil
  if type(session) ~= "string" or type(sequence) ~= "number" then return false end
  local line = Wire("V", session, sequence, flag)
  if not line or #line > MAX_BYTES then return false end
  return SubmitChannel(line, nil, nil, nil, true)
end

-- A remote V heard on the hidden channel.
local function NoteChannelVersion(flag, now)
  if flag == "R" then
    if canary.ackAt then
      canary.ackAt = nil
      Transport.channelAckCancelled = Transport.channelAckCancelled + 1
    end
    return
  end
  if flag ~= "A" or canary.ackAt then return end
  if canary.lastAckAt and now - canary.lastAckAt < canary.ACK_GAP then return end
  canary.ackAt = now + canary.ACK_DELAY + mathRandom() * canary.ACK_SPREAD
end

local function ChannelCanaryTick(now)
  local target = ChannelTarget()
  if canary.ackAt and now >= canary.ackAt then
    canary.ackAt, canary.lastAckAt = nil, now
    if SendCanary("R") then Transport.channelAcks = Transport.channelAcks + 1 end
  end
  if Transport.channelConfirmed or not target then
    canary.retryAt = nil
    return
  end
  if not canary.retryAt then
    canary.wait = canary.wait or canary.RETRY_FIRST
    canary.retryAt = now + canary.wait
    return
  end
  if now < canary.retryAt or canary.retries >= canary.RETRIES then return end
  canary.retries = canary.retries + 1
  canary.wait = mathMin(canary.wait * 2, canary.RETRY_MAX)
  canary.retryAt = now + canary.wait
  if SendCanary("A") then Transport.channelCanaries = Transport.channelCanaries + 1 end
end

Wire = function(id, session, sequence, body)
  local p2p = WF.P2PTest
  if not p2p or type(p2p.ChannelWire) ~= "function" then return nil end
  return p2p.ChannelWire(id, session, sequence, body)
end

local function RelayClass(id, body)
  local capture = WF.Capture
  if not capture or type(capture.RelayClass) ~= "function" then return nil end
  local ok, class = pcall(capture.RelayClass, capture, id, body)
  return ok and class or nil
end

-- Guild: rank 3 a capture start or end, 2 orders and battles, 1 a kill, 0 our presence.
local function GuildRank(id)
  if id == NETWORK_PRESENCE then return 0 end
  if id == "S" then return 3 end
  if id == "K" then return 1 end
  return 2
end

local function GuildPeers(now)
  local count = 0
  for identity, at in pairs(guild.peers) do
    if now - at > GUILD.PEER_TTL then
      guild.peers[identity] = nil
      guild.targets[identity] = nil
      guild.peerCount = guild.peerCount - 1
    else
      count = count + 1
    end
  end
  return count
end

local function QueueGuild(id, line, now)
  local outbox = guild.outbox
  if #outbox >= GUILD.OUTBOX_MAX then
    -- The lowest rank goes, oldest first; the new line when nothing is lower.
    local victim, rank = nil, GuildRank(id)
    for i = 1, #outbox do
      if outbox[i].rank < rank then victim, rank = i, outbox[i].rank end
    end
    if not victim then
      Transport.guildDropped = Transport.guildDropped + 1
      return false
    end
    table.remove(outbox, victim)
    Transport.guildDropped = Transport.guildDropped + 1
  end
  outbox[#outbox + 1] = {
    id = id, line = line, rank = GuildRank(id), at = now,
    readyAt = now + GUILD.WAIT_MIN + mathRandom() * (GUILD.WAIT_MAX - GUILD.WAIT_MIN),
    expires = now + (id == "S" and GUILD.STATE_TTL or GUILD.OUTBOX_TTL),
  }
  Transport.guildQueued = Transport.guildQueued + 1
  return true
end

-- Drops the guild lines `stale(line)` names (a campaign change, decision 0103
-- § 4b). Returns the count dropped.
function Transport:Purge(stale)
  local outbox, dropped, index = guild.outbox, 0, 1
  while index <= #outbox do
    if stale(outbox[index].line) then
      table.remove(outbox, index)
      dropped = dropped + 1
    else
      index = index + 1
    end
  end
  return dropped
end

-- Our own capture line (the single send path, rule R12, through
-- modules/p2ptest.lua). Returns whether any transport took it.
function Transport:Send(id, body, session, sequence, key, priority)
  if type(id) ~= "string" or type(body) ~= "string" or type(session) ~= "string" or type(sequence) ~= "number" then
    return false, "invalid line"
  end
  if not Usable() then
    self.skipped = self.skipped + 1
    return false, "instance or lockdown"
  end
  local line = Wire(id, session, sequence, body)
  if not line then return false, "wire unavailable" end
  if #line > MAX_BYTES then
    self.oversize = self.oversize + 1
    return false, "line exceeds the addon message size"
  end
  local now = Now()
  local taken = false
  if CHANNEL_CAPTURE_LINES[id]
      and SubmitChannel(line, key, priority, LIVE_LINES[id], false) then taken = true end
  local groupType = GroupType()
  if groupType and not Paused(groupType, now) then
    local ok = Submit(groupType, line, key, priority, nil, nil, LIVE_LINES[id])
    if ok then taken = true end
  end
  -- Our local lines to the contacts near us in our POI (decision 0080), never
  -- to a group mate the group copy reached.
  local nearbyTargets = {}
  local nearby = WF.Nearby
  if LOCAL_LINES[id] and nearby and type(nearby.Targets) == "function" and not Paused("WHISPER", now) then
    local okTargets, list = pcall(nearby.Targets, nearby, now, nearby.LOCAL_FAN,
      function(identity) return groupType ~= nil and self:IsGroupMate(identity, now) end)
    if okTargets and type(list) == "table" then
      for i = 1, #list do
        local target = list[i]
        if Submit("WHISPER", line, key and ("L:" .. target .. ":" .. key) or nil, priority, nil, target, LIVE_LINES[id]) then
          nearbyTargets[string.lower(target)] = true
          taken = true
          self.localSent = (self.localSent or 0) + 1
        end
      end
    end
  end
  local critical = RelayClass(id, body) == "C"
  local guildCopy = false
  if InGuild() and critical then
    if GuildPeers(now) == 0 then
      self.guildNoPeer = self.guildNoPeer + 1
    elseif QueueGuild(id, line, now) then
      taken, guildCopy = true, true
    end
  end
  if critical and self:FanOut(id, line, now, guildCopy, nearbyTargets) then taken = true end
  if not taken then
    self.noRoute = self.noRoute + 1
    return false, "no transport reaches another player"
  end
  return true
end

-- One addressed line to one player (Capture:SendTo, decision 0077 step 3):
-- only OD and OL, by whisper, through the send gate and the addon budget.
function Transport:SendTo(target, id, body, key)
  if not ADDRESSED[id] or type(body) ~= "string" then return false, "not an addressed line" end
  if type(target) ~= "string" or target == "" or #target > MAX_TARGET_BYTES or IsSecret(target)
      or strFind(target, "[%c|]") then
    return false, "invalid target"
  end
  if not Usable() then
    self.skipped = self.skipped + 1
    return false, "instance or lockdown"
  end
  local storage = WF.Storage
  local session = MySession()
  local sequence = storage and type(storage.NextSequence) == "function" and storage:NextSequence() or nil
  if not session or not sequence then return false, "storage is unavailable" end
  local line = Wire(id, session, sequence, body)
  if not line then return false, "wire unavailable" end
  if #line > MAX_BYTES then
    self.oversize = self.oversize + 1
    return false, "line exceeds the addon message size"
  end
  local now = Now()
  if Paused("WHISPER", now) then return false, "whispers paused" end
  local ok, err = Submit("WHISPER", line, key, nil, nil, target)
  if not ok then return false, err end
  self.addressed = self.addressed + 1
  return true
end

-- Our NP line: "1,<registry digest>,<confirmed owners>" (decision 0077 step 3), or "1".
local function PresenceLine()
  local storage = WF.Storage
  local session = MySession()
  if not storage or type(storage.NextSequence) ~= "function" or not session then return nil end
  local sequence = storage:NextSequence()
  if not sequence then return nil end
  local body = "1"
  local catchup = WF.Catchup
  if catchup and type(catchup.RegistryDigest) == "function" then
    local ok, digest, owned = pcall(catchup.RegistryDigest, catchup)
    if ok and type(digest) == "string" and type(owned) == "number" then
      body = "1," .. digest .. "," .. tostring(mathMin(999, mathFloor(owned)))
      -- Our Battle.net links while we are a bridge (decision 0077 step 5).
      local relay = WF.Relay
      if relay and type(relay.LinkCount) == "function" then
        local okLinks, links = pcall(relay.LinkCount, relay, Now())
        if okLinks and type(links) == "number" and links > 0 then
          body = body .. "," .. tostring(mathMin(9, mathFloor(links)))
        end
      end
    end
  end
  return Wire(NETWORK_PRESENCE, session, sequence, body)
end

local function SendPresence(now)
  local line = PresenceLine()
  if not line then return false end
  return QueueGuild(NETWORK_PRESENCE, line, now)
end

-- A relay B or R line (modules/relay.lua through modules/p2ptest.lua), or the
-- version announce V (core/version.lua). V is also the hidden-channel canary;
-- B/R use that channel only after a remote Warfront client confirmed it.
function Transport:SendRelayLine(id, body, session, sequence, key, priority)
  if not GROUP_LINES[id] or type(body) ~= "string" or type(session) ~= "string" or type(sequence) ~= "number" then
    return false
  end
  if not Usable() then return false end
  local line = Wire(id, session, sequence, body)
  if not line or #line > MAX_BYTES then
    self.oversize = self.oversize + 1
    return false
  end
  local taken = SubmitChannel(line, key and ("relay:" .. key) or nil, priority, nil, id == "V")
  local groupType = GroupType()
  if not groupType then return taken end
  local now = Now()
  if Paused(groupType, now) then return taken end
  local ok = Submit(groupType, line, key and ("relay:" .. key) or nil, priority)
  if ok then self.relayLines = (self.relayLines or 0) + 1; taken = true end
  return taken
end

-- Our presence whispered to one player of the member list (modules/directory.lua).
function Transport:SendPresenceTo(target)
  if type(target) ~= "string" or target == "" or #target > MAX_TARGET_BYTES or IsSecret(target)
      or strFind(target, "[%c|]") then
    return false
  end
  if not Usable() then return false end
  local now = Now()
  if Paused("WHISPER", now) then return false end
  local line = PresenceLine()
  if not line then return false end
  local ok = Submit("WHISPER", line, "NP:" .. target, nil, nil, target)
  if ok then
    self.presencesWhispered = self.presencesWhispered + 1
    -- Contacts answer only a client they heard (Catchup:MaybePull waits for it).
    self.presenceAt = self.presenceAt or now
  end
  return ok and true or false
end

-- `reserve`: tokens this send must leave (forwards keep some for our own facts).
local function TakeChainToken(now, reserve)
  if not chain.at then chain.at = now end
  chain.tokens = mathMin(CHAIN_BURST, chain.tokens + mathMax(0, now - chain.at) * CHAIN_RATE)
  chain.at = now
  if chain.tokens - 1 < (reserve or 0) then return false end
  chain.tokens = chain.tokens - 1
  return true
end

-- One F line (modules/chain.lua, decision 0077 step 4b) to one contact.
function Transport:SendChain(target, body, reserve)
  if type(target) ~= "string" or target == "" or #target > MAX_TARGET_BYTES or IsSecret(target)
      or strFind(target, "[%c|]") or type(body) ~= "string" then
    return false
  end
  if not Usable() then return false end
  local now = Now()
  if Paused("WHISPER", now) then return false end
  local storage = WF.Storage
  local session = MySession()
  local sequence = storage and type(storage.NextSequence) == "function" and storage:NextSequence() or nil
  if not session or not sequence then return false end
  local line = Wire(FORWARD_ID, session, sequence, body)
  if not line then return false end
  if #line > MAX_BYTES then
    self.oversize = self.oversize + 1
    return false
  end
  if not TakeChainToken(now, reserve) then
    self.fanSkipped = self.fanSkipped + 1
    return false
  end
  return Submit("WHISPER", line, nil, true, nil, target) and true or false
end

local function SchedulePresence(now)
  local peers = GuildPeers(now)
  local interval = peers == 0 and GUILD.PRESENCE_ALONE
    or mathMax(GUILD.PRESENCE_MIN, GUILD.PRESENCE_PER_PEER * peers)
  guild.nextPresenceAt = now + interval + mathRandom() * GUILD.PRESENCE_JITTER
end

local function HeardPerMinute(now)
  local heard = guild.heard
  while heard[1] and now - heard[1] > 60 do table.remove(heard, 1) end
  return #heard
end

-- Only what can reach a ceiling is kept: a flood costs no memory.
local function NoteHeard(now)
  local heard = guild.heard
  if #heard >= GUILD.HEARD_KEEP then table.remove(heard, 1) end
  heard[#heard + 1] = now
end

local function GuildTick(now)
  -- Tokens (see GUILD); both fall to one per 5 minutes while our copies stop
  -- coming back.
  if not guild.at then guild.at = now end
  local elapsed = mathMax(0, now - guild.at)
  guild.at = now
  local terminalRate = GUILD.RATE
  local fairRate = mathMin(GUILD.RATE, GUILD.SOFT_PER_MIN / 60 / (GuildPeers(now) + 1))
  if guild.silent then terminalRate, fairRate = 1 / GUILD.SILENT_GAP, 1 / GUILD.SILENT_GAP end
  guild.terminal = mathMin(GUILD.BURST, guild.terminal + elapsed * terminalRate)
  guild.tokens = mathMin(GUILD.BURST, guild.tokens + elapsed * fairRate)

  for i = #guild.pendingEcho, 1, -1 do
    if now - guild.pendingEcho[i].at > GUILD.ECHO_WAIT then
      table.remove(guild.pendingEcho, i)
      guild.echoMissed = guild.echoMissed + 1
      if guild.echoMissed >= GUILD.SILENT_AFTER and not guild.silent then
        guild.silent = true
        guild.tokens, guild.terminal = mathMin(guild.tokens, 0), mathMin(guild.terminal, 0)
      end
    end
  end

  local outbox = guild.outbox
  for i = #outbox, 1, -1 do
    if outbox[i].expires <= now then
      table.remove(outbox, i)
      Transport.guildExpired = Transport.guildExpired + 1
    end
  end

  if not InGuild() then
    for i = #outbox, 1, -1 do outbox[i] = nil end
    guild.nextPresenceAt = nil
    return
  end
  if not guild.nextPresenceAt then
    guild.nextPresenceAt = now + GUILD.PRESENCE_FIRST + mathRandom() * GUILD.PRESENCE_FIRST_JITTER
  elseif now >= guild.nextPresenceAt then
    if SendPresence(now) then
      Transport.presences = Transport.presences + 1
      Transport.presenceAt = Transport.presenceAt or now
    end
    SchedulePresence(now)
  end

  if #outbox == 0 or Paused("GUILD", now) then return end
  -- Best rank first, oldest first among equals, among lines whose wait is
  -- over and whose bucket holds a token; above the soft ceiling only a capture
  -- start or end goes, above the hard one nothing. A held line draws a new wait.
  local perMinute = HeardPerMinute(now)
  local spread = GUILD.WAIT_MAX - GUILD.WAIT_MIN + GUILD.WAIT_PER_PEER * GuildPeers(now)
  local best
  for i = 1, #outbox do
    local item = outbox[i]
    local terminal = item.rank >= 3
    if item.readyAt <= now and (terminal and guild.terminal or guild.tokens) >= 1 then
      local allowed = perMinute < GUILD.SOFT_PER_MIN or (terminal and perMinute < GUILD.HARD_PER_MIN)
      if not allowed then
        -- A capture start or end is rare and short-lived (STATE_TTL): it retries soon.
        item.readyAt = now + GUILD.WAIT_MIN + mathRandom() * (item.rank >= 3 and GUILD.TERMINAL_SPREAD or spread)
        Transport.guildCapped = Transport.guildCapped + 1
      elseif not best or item.rank > outbox[best].rank then
        best = i
      end
    end
  end
  if not best then return end
  local item = table.remove(outbox, best)
  -- The token is spent even if the send gate drops the line: never faster.
  if item.rank >= 3 then guild.terminal = guild.terminal - 1 else guild.tokens = guild.tokens - 1 end
  Submit("GUILD", item.line, nil, item.rank >= 2 or nil, function(sent, _, _, at)
    if sent then guild.pendingEcho[#guild.pendingEcho + 1] = { line = item.line, at = at } end
  end)
end

-- Receiving ---------------------------------------------------------------------------

local function NoteGuildPeer(identity, now, target)
  if not guild.peers[identity] then
    if guild.peerCount >= GUILD.MAX_PEERS then
      local oldest, oldestAt
      for other, at in pairs(guild.peers) do
        if not oldestAt or at < oldestAt then oldest, oldestAt = other, at end
      end
      if oldest then
        guild.peers[oldest] = nil
        guild.targets[oldest] = nil
        guild.peerCount = guild.peerCount - 1
      end
    end
    guild.peerCount = guild.peerCount + 1
  end
  guild.peers[identity] = now
  if target then guild.targets[identity] = target end
end

-- A group mate heard sending a Warfront line.
local function NoteGroupPeer(identity, now)
  if not groupPeers[identity] then
    if groupPeerCount >= MAX_GROUP_PEERS then
      local oldest, oldestAt
      for other, at in pairs(groupPeers) do
        if not oldestAt or at < oldestAt then oldest, oldestAt = other, at end
      end
      if oldest then
        groupPeers[oldest] = nil
        groupPeerCount = groupPeerCount - 1
      end
    end
    groupPeerCount = groupPeerCount + 1
  end
  groupPeers[identity] = now
end

local function GuildIntake(identity, now)
  local entry = guild.intake[identity]
  if not entry or now - entry.at > 60 then
    if not entry then
      if guild.intakeCount >= GUILD.MAX_INTAKE then
        for other, row in pairs(guild.intake) do
          if now - row.at > 60 then
            guild.intake[other] = nil
            guild.intakeCount = guild.intakeCount - 1
          end
        end
        if guild.intakeCount >= GUILD.MAX_INTAKE then return false end
      end
      guild.intakeCount = guild.intakeCount + 1
    end
    entry = { at = now, count = 0 }
    guild.intake[identity] = entry
  end
  entry.count = entry.count + 1
  return entry.count <= GUILD.INTAKE_PER_MIN, entry.count
end

local function WhisperIntake(identity, now)
  local entry = whisperIntake[identity]
  if not entry or now - entry.at > 60 then
    if not entry then
      if whisperIntakeCount >= MAX_WHISPER_INTAKE then
        for other, row in pairs(whisperIntake) do
          if now - row.at > 60 then
            whisperIntake[other] = nil
            whisperIntakeCount = whisperIntakeCount - 1
          end
        end
        if whisperIntakeCount >= MAX_WHISPER_INTAKE then return false end
      end
      whisperIntakeCount = whisperIntakeCount + 1
    end
    entry = { at = now, count = 0 }
    whisperIntake[identity] = entry
  end
  entry.count = entry.count + 1
  return entry.count <= WHISPER_INTAKE_PER_MIN
end

local function IsGuildPeer(identity, now)
  local at = guild.peers[identity]
  return at ~= nil and now - at <= GUILD.PEER_TTL
end

-- A whisper target from an event sender: the character name alone, "First
-- Surname". Forever names are unique per region and a whisper to that name
-- crosses realms (decision 0077 § 5c); a first name alone is "No player named", and a
-- "-Realm" suffix is read as a surname (both measured on Forever, one client,
-- 2026-11-09).
local function WhisperTarget(sender)
  local names = WF.Names
  if names and type(names.Split) == "function" then
    local ok, name = pcall(names.Split, sender)
    if ok and type(name) == "string" and name ~= "" then return name end
  end
  return sender
end

function Transport:IsGuildPeer(identity, now)
  return IsGuildPeer(identity, now or Now())
end

-- A whispered presence from a member of our guild roster (the server's
-- C_GuildInfo.MemberExistsByName, decision 0081 § 4) makes its sender a guild
-- peer before we heard it in the guild: a newcomer can pull a senior that
-- welcomed it. Unmeasured on Forever: false whenever the call fails.
function Transport:RosterPeer(identity, sender, now)
  if not identity or not InGuild() then return false end
  local api = Global("C_GuildInfo")
  if type(api) ~= "table" or type(api.MemberExistsByName) ~= "function" then return false end
  local target = WhisperTarget(sender)
  local ok, exists = pcall(api.MemberExistsByName, target)
  if not ok or IsSecret(exists) or exists ~= true then return false end
  NoteGuildPeer(identity, now, target)
  self.rosterPeers = (self.rosterPeers or 0) + 1
  return true
end

-- Guild and group mates heard sending Warfront lines, for the Players tab:
-- { name, tag }.
function Transport:KnownPlayers(now)
  now = now or Now()
  local list = {}
  local names = WF.Names
  for identity, at in pairs(groupPeers) do
    if now - at <= GROUP_PEER_TTL and names then list[#list + 1] = { name = names.Short(identity), tag = "group" } end
  end
  for identity, at in pairs(guild.peers) do
    local name = guild.targets[identity] or (names and names.Short(identity))
    if now - at <= GUILD.PEER_TTL and name then list[#list + 1] = { name = name, tag = "guild" } end
  end
  return list
end

-- A group mate heard sending a Warfront line lately.
function Transport:IsGroupMate(identity, now)
  local at = type(identity) == "string" and groupPeers[identity] or nil
  return at ~= nil and (now or Now()) - at <= GROUP_PEER_TTL
end

local function IsContact(identity, now)
  local directory = WF.Directory
  return directory ~= nil and type(directory.IsContact) == "function" and directory:IsContact(identity, now) or false
end

-- A player we chose to hear: a guild peer, a contact or a listed name.
local function Known(identity, now)
  if IsGuildPeer(identity, now) or IsContact(identity, now) then return true end
  local directory = WF.Directory
  return directory ~= nil and type(directory.Lists) == "function" and directory:Lists(identity) or false
end

-- The Warfront clients known to hear a guild or group line, us excluded
-- (modules/chain.lua elects its speakers among them, decision 0077 § 5f).
function Transport:Hearers(chatType, now)
  now = now or Now()
  local list = {}
  if chatType == "CHANNEL" then
    ChannelTarget()
    for identity, at in pairs(canary.hearers) do
      if now - at <= GROUP_PEER_TTL then
        list[#list + 1] = identity
      else
        canary.hearers[identity] = nil
        canary.hearerCount = canary.hearerCount - 1
      end
    end
  elseif chatType == "GUILD" then
    for identity, at in pairs(guild.peers) do
      if now - at <= GUILD.PEER_TTL then list[#list + 1] = identity end
    end
  elseif GROUP_TYPES[chatType] then
    for identity, at in pairs(groupPeers) do
      if now - at <= GROUP_PEER_TTL then list[#list + 1] = identity end
    end
  end
  return list
end

-- True while someone can hear our capture lines (decision 0141): the channel
-- is joined, or a Warfront group mate or guild peer was heard within its TTL.
-- Capture:CanTalk locks an isolated client, whose actions nobody would see.
function Transport:Reached(now)
  now = now or Now()
  local p2p = WF.P2PTest
  if p2p and type(p2p.ChannelJoined) == "function" then
    local ok, joined = pcall(p2p.ChannelJoined)
    if ok and joined then return true end
  end
  if GroupType() then
    for _, at in pairs(groupPeers) do
      if now - at <= GROUP_PEER_TTL then return true end
    end
  end
  if InGuild() then
    for _, at in pairs(guild.peers) do
      if now - at <= GUILD.PEER_TTL then return true end
    end
  end
  return false
end

-- Whisper names of up to `limit` guild peers and contacts, the most recently
-- heard first: where an addressed catch-up request goes (decision 0077 § 5f).
function Transport:PullTargets(limit, now)
  now = now or Now()
  local list, added = {}, {}
  local directory = WF.Directory
  if directory and type(directory.ContactTargets) == "function" then
    local ok, contacts = pcall(directory.ContactTargets, directory, now)
    if ok and type(contacts) == "table" then
      for i = 1, #contacts do
        local entry = contacts[i]
        if type(entry) == "table" and entry.identity and not added[entry.identity] then
          added[entry.identity] = true
          list[#list + 1] = entry
        end
      end
    end
  end
  for identity, at in pairs(guild.peers) do
    local target = guild.targets[identity]
    if target and now - at <= GUILD.PEER_TTL and not added[identity] then
      added[identity] = true
      list[#list + 1] = { identity = identity, target = target, at = at }
    end
  end
  table.sort(list, function(a, b)
    if a.at ~= b.at then return a.at > b.at end
    return a.identity < b.identity
  end)
  local targets = {}
  for i = 1, mathMin(limit or 0, #list) do targets[i] = list[i].target end
  return targets
end

-- Whether an addressed request of `kind` from `target` gets an answer now:
-- once per ANSWER_GAP s per asker, ANSWERS_PER_WINDOW askers per window.
function Transport:MayAnswer(kind, target, now)
  if type(kind) ~= "string" or not ADDRESSED[kind] or type(target) ~= "string" then return false end
  now = now or Now()
  local entry = answered[kind]
  if not entry then
    entry = { last = {}, times = {}, count = 0 }
    answered[kind] = entry
  end
  local key = string.lower(target)
  local last = entry.last[key]
  if last and now - last < ANSWER_GAP then return false end
  local times = entry.times
  while times[1] and now - times[1] >= ANSWER_WINDOW do table.remove(times, 1) end
  if #times >= ANSWERS_PER_WINDOW then return false end
  times[#times + 1] = now
  if not last then entry.count = entry.count + 1 end
  entry.last[key] = now
  if entry.count > MAX_ANSWERED then
    for other, at in pairs(entry.last) do
      if now - at >= ANSWER_GAP then
        entry.last[other] = nil
        entry.count = entry.count - 1
      end
    end
  end
  return true
end

-- Our own critical line, first-hand, to up to FAN contacts (never a guild
-- peer already reached by the guild copy); a kill at most once per KILL_GAP.
function Transport:FanOut(id, line, now, guildCopy, already)
  local directory = WF.Directory
  if not directory or type(directory.Contacts) ~= "function" then return false end
  if id == "K" and chain.killAt and now - chain.killAt < KILL_GAP then
    self.fanSkipped = self.fanSkipped + 1
    return false
  end
  if Paused("WHISPER", now) then return false end
  -- The author's fan-out grows with the directory (decision 0077 § 5f).
  local fan = FAN
  if type(directory.Fans) == "function" then
    local ok, _, author = pcall(directory.Fans, directory, now)
    if ok and type(author) == "number" then fan = author end
  end
  local targets = directory:Contacts(now, fan, function(identity)
    if guildCopy and IsGuildPeer(identity, now) then return true end
    -- Already whispered as a local line (decision 0080).
    local name = already and WF.Names and WF.Names.Short(identity)
    return name ~= nil and already[string.lower(name)] == true
  end)
  local sent = 0
  for i = 1, #targets do
    if not TakeChainToken(now) then
      self.fanSkipped = self.fanSkipped + 1
      break
    end
    if Submit("WHISPER", line, nil, true, nil, targets[i], LIVE_LINES[id]) then sent = sent + 1 end
  end
  if sent == 0 then return false end
  if id == "K" then chain.killAt = now end
  self.fanned = self.fanned + sent
  return true
end

-- A guild peer's or contact's NP presence: its registry digest goes to the catch-up.
local function OnPresence(identity, sender, body, now)
  local digest, owned, links = string.match(body or "",
    "^1,([0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z]),(%d%d?%d?),?(%d?)$")
  if not digest then return end
  -- A bridge's links (step 5): a presence without them withdraws it.
  local relay = WF.Relay
  if relay and type(relay.NoteBeacon) == "function" then
    local okBeacon, beaconError = pcall(relay.NoteBeacon, relay, identity, tonumber(links) or 0, now, NP_BEACON_TTL)
    if not okBeacon and WF.RecordError then WF.RecordError("relay beacon", beaconError) end
  end
  local catchup = WF.Catchup
  if catchup and type(catchup.OnPeerDigest) == "function" then
    local ok, err = pcall(catchup.OnPeerDigest, catchup, identity, WhisperTarget(sender), digest, tonumber(owned), now)
    if not ok and WF.RecordError then WF.RecordError("catch-up peer digest", err) end
  end
end

-- Only a copy of a line we really sent says the guild still carries ours.
local function OnOwnGuildCopy(text)
  local pending = guild.pendingEcho
  for i = 1, #pending do
    if pending[i].line == text then
      table.remove(pending, i)
      guild.echoMissed = 0
      guild.silent = false
      return true
    end
  end
  return false
end

local function DiscoverChannelPeer(sender, identity, now)
  local ticket, directory = WF.Ticket, WF.Directory
  if ticket and ticket.Admit and not ticket:Admit(identity, "V", now, true) then return false end
  Transport.channelConfirmed = true
  if not canary.hearers[identity] then
    if canary.hearerCount >= GUILD.MAX_PEERS then Transport:Hearers("CHANNEL", now) end
    if canary.hearerCount < GUILD.MAX_PEERS then
      canary.hearerCount = canary.hearerCount + 1
      canary.hearers[identity] = now
    end
  else
    canary.hearers[identity] = now
  end
  if directory and type(directory.OnChannelPeer) == "function" then
    local ok, err = pcall(directory.OnChannelPeer, directory, sender, now)
    if not ok and WF.RecordError then WF.RecordError("channel peer", err) end
  end
  return true
end

local function PassDirect(identity, parsed, chatType, now)
  local chainModule = WF.Chain
  if chatType == "CHANNEL" or not chainModule or type(chainModule.OnDirect) ~= "function"
      or RelayClass(parsed.id, parsed.data) ~= "C" then return end
  local hearers = Transport:Hearers(chatType, now)
  local ok, err = pcall(chainModule.OnDirect, chainModule, identity, parsed, chatType, hearers, now)
  if not ok and WF.RecordError then WF.RecordError("chain direct", err) end
end

function Transport:OnAddonMessage(prefix, text, chatType, sender, target, zoneChannelID, localID, channelName, instanceID)
  if IsSecret(prefix) or IsSecret(text) or IsSecret(chatType) or IsSecret(sender) then return end
  if prefix ~= PREFIX or type(text) ~= "string" or strSub(text, 1, 2) ~= "WF" then return end
  if chatType == "CHANNEL" then
    if not ChannelEventMatches(target, localID, channelName) then return Reject("channel name/id") end
  elseif not GROUP_TYPES[chatType] and chatType ~= "GUILD" and chatType ~= "WHISPER" then
    return
  end
  self.received = self.received + 1
  if not Usable() then return Reject("instance or lockdown") end
  local p2p = WF.P2PTest
  if not p2p or type(p2p.ParseChannel) ~= "function" then return Reject("parser") end
  local capture = WF.Capture
  local identity = capture and capture.Identity and capture.Identity(sender) or nil
  local now = Now()
  local parsed, parseError, meta = p2p.ParseChannel(text)
  -- The sender's version is a warning only; by whisper only from a player we
  -- chose to hear, so a stranger cannot raise a false notice (decision 0077 § 5f).
  if meta and WF.Version and WF.Version.Note and (chatType ~= "WHISPER" or (identity and Known(identity, now))) then
    local noted, noteError = pcall(WF.Version.Note, WF.Version, meta.version, meta.level, sender)
    if not noted and WF.RecordError then WF.RecordError("version note", noteError) end
  end
  if not parsed then return Reject(parseError or "format") end
  if not identity then return Reject("sender") end
  local me = capture.Me and capture:Me() or nil
  if parsed.session == MySession() then
    -- Sessions travel in clear: our own copy only when it also comes from us.
    if identity ~= me then return Reject("forged echo") end
    self.echoes = self.echoes + 1
    if chatType == "GUILD" then
      NoteHeard(now)
      OnOwnGuildCopy(text)
    end
    return
  end
  if identity == me then return Reject("own identity") end
  -- The sender's ruleset for the Players tab, from any line it sent (decision
  -- 0139 § 6): display only; by whisper only from a player we chose to hear.
  local players = WF.Players
  if players and type(players.NoteLine) == "function" and (chatType ~= "WHISPER" or Known(identity, now)) then
    local noted, noteError = pcall(players.NoteLine, players, identity, parsed.version, parsed.campaign)
    if not noted and WF.RecordError then WF.RecordError("players ruleset", noteError) end
  end
  if chatType == "CHANNEL" then
    if not CHANNEL_CAPTURE_LINES[parsed.id] and not GROUP_LINES[parsed.id] then return Reject("channel kind") end
    self.channelRemote = self.channelRemote + 1
  end
  -- A line of another campaign is never applied (decision 0103 § 4b).
  if type(p2p.AdmitCampaign) == "function" and not p2p.AdmitCampaign(parsed.id, parsed.campaign) then
    self.campaignSkew = (self.campaignSkew or 0) + 1
    return false
  end
  -- The partner of a layer jump earns no group trust (decision 0119 § 7).
  if GROUP_TYPES[chatType] and WF.LayerJump and type(WF.LayerJump.IsPartner) == "function" then
    local okPartner, isPartner = pcall(WF.LayerJump.IsPartner, WF.LayerJump, identity, now)
    if okPartner and isPartner then return Reject("jump partner") end
  end
  -- Board copies (decision 0110): group and guild only, outside the guild
  -- intake and its ceiling, never relayed, never passed to capture.
  if BOARD_LINES[parsed.id] then
    local audience = GROUP_TYPES[chatType] and "GROUP" or chatType
    if chatType == "WHISPER" then
      -- One to one, only from a player we chose to hear (decision 0110 § 4).
      if not WhisperIntake(identity, now) then return Reject("whisper intake") end
      if not IsGuildPeer(identity, now) and not IsContact(identity, now) then return Reject("whisper stranger") end
      audience = "W:" .. identity
      boardTargets[identity] = WhisperTarget(sender)
    elseif not GROUP_TYPES[chatType] and chatType ~= "GUILD" then
      return Reject("board line kind")
    end
    PurgeSeen(now)
    if not MarkSeen(SeenKey(identity, parsed.session, parsed.sequence, parsed.id), now) then
      self.duplicates = self.duplicates + 1
      return false
    end
    if capture.AllowSender and not capture:AllowSender(identity, parsed.id, now) then return Reject("quota " .. parsed.id) end
    local ticket = WF.Ticket
    if ticket and type(ticket.Admit) == "function" and not ticket:Admit(identity, parsed.id, now, true) then return false end
    local boards = parsed.id == "AM" and WF.AlliesMesh or WF.Boards
    if not boards or type(boards.OnLine) ~= "function" then return Reject("boards") end
    self.boardIn = self.boardIn + 1
    local ok, err = pcall(boards.OnLine, boards, parsed.id, parsed.data, identity, audience, now)
    if not ok and WF.RecordError then WF.RecordError("boards line", err) end
    return ok and err ~= false
  end
  if GROUP_TYPES[chatType] then NoteGroupPeer(identity, now) end
  if chatType == "GUILD" then
    local allowed, count = GuildIntake(identity, now)
    if count and count <= GUILD.CEILING_SHARE then NoteHeard(now) end
    if not allowed then return Reject("guild intake") end
    NoteGuildPeer(identity, now, WhisperTarget(sender))
    if parsed.id ~= NETWORK_PRESENCE and RelayClass(parsed.id, parsed.data) ~= "C" then
      return Reject("guild kind")
    end
  elseif chatType == "WHISPER" then
    if not WhisperIntake(identity, now) then return Reject("whisper intake") end
    if LAYER_LINES[parsed.id] then
      local jump = WF.LayerJump
      if not jump or type(jump.OnWhisper) ~= "function" then return Reject("layer jump") end
      PurgeSeen(now)
      if not MarkSeen(SeenKey(identity, parsed.session, parsed.sequence, parsed.id), now) then
        self.duplicates = self.duplicates + 1
        return false
      end
      if capture.AllowSender and not capture:AllowSender(identity, parsed.id, now) then return Reject("quota " .. parsed.id) end
      local okJump, result = pcall(jump.OnWhisper, jump, parsed.id, parsed.data, identity, WhisperTarget(sender), now)
      if not okJump and WF.RecordError then WF.RecordError("layer jump", result) end
      return okJump and result
    end
    if parsed.id == NETWORK_PRESENCE then
      -- A greeting or the answer to ours: the directory decides who is a contact.
      local directory = WF.Directory
      local contact = false
      if directory and type(directory.OnWhisperPresence) == "function" then
        local ok, result = pcall(directory.OnWhisperPresence, directory, identity, WhisperTarget(sender), now)
        if ok then contact = result and true or false
        elseif WF.RecordError then WF.RecordError("directory presence", result) end
      end
      if contact or IsGuildPeer(identity, now) or self:RosterPeer(identity, sender, now) then
        OnPresence(identity, sender, parsed.data, now)
      end
      return true
    end
    -- The catch-up exchange and our peers' own critical lines, only from a
    -- guild peer or a contact.
    if not ADDRESSED[parsed.id] and parsed.id ~= FORWARD_ID and not LOCAL_LINES[parsed.id]
        and RelayClass(parsed.id, parsed.data) ~= "C" then
      return Reject("whisper kind")
    end
    if not IsGuildPeer(identity, now) and not IsContact(identity, now) then return Reject("whisper stranger") end
    self.addressedIn = self.addressedIn + 1
    if parsed.id == FORWARD_ID then
      -- A fact passed on to us: the chain applies the relay's acceptance.
      PurgeSeen(now)
      if not MarkSeen(SeenKey(identity, parsed.session, parsed.sequence, parsed.id), now) then
        self.duplicates = self.duplicates + 1
        return false
      end
      local chainModule = WF.Chain
      if not chainModule or type(chainModule.OnForward) ~= "function" then return Reject("chain") end
      local ok, result = pcall(chainModule.OnForward, chainModule, identity, parsed.data, now)
      if not ok then
        if WF.RecordError then WF.RecordError("chain forward", result) end
        return false
      end
      return result
    end
  end
  if parsed.id == NETWORK_PRESENCE then
    if chatType == "GUILD" then OnPresence(identity, sender, parsed.data, now) end
    return true
  end
  -- The version announce from our group or confirmed hidden channel.
  if parsed.id == "V" then
    if not GROUP_TYPES[chatType] and chatType ~= "CHANNEL" then return Reject("version line kind") end
    if chatType == "CHANNEL" then
      if parsed.data ~= "A" and parsed.data ~= "R" then return Reject("channel version flag") end
      PurgeSeen(now)
      if not MarkSeen(SeenKey(identity, parsed.session, parsed.sequence, parsed.id), now) then
        self.duplicates = self.duplicates + 1
        return false
      end
      if not DiscoverChannelPeer(sender, identity, now) then return false end
      NoteChannelVersion(parsed.data, now)
    end
    local version = WF.Version
    if version and type(version.OnAnnounce) == "function" then
      local okV, versionError = pcall(version.OnAnnounce, version, parsed.version, parsed.data, now)
      if not okV and WF.RecordError then WF.RecordError("version announce", versionError) end
    end
    return true
  end
  -- The relay's beacons and far rebroadcasts from our group or hidden channel.
  if RELAY_LINES[parsed.id] then
    if not GROUP_TYPES[chatType] and chatType ~= "CHANNEL" then return Reject("relay line kind") end
    local relay = WF.Relay
    if relay and type(relay.OnChannelLine) == "function" then
      local okLine, lineError = pcall(relay.OnChannelLine, relay, parsed.id, parsed.data, sender, false)
      if not okLine and WF.RecordError then WF.RecordError("relay group line", lineError) end
      if okLine and lineError == true and chatType == "CHANNEL" then DiscoverChannelPeer(sender, identity, now) end
    end
    return true
  end
  if type(p2p.IsCaptureId) ~= "function" or not p2p.IsCaptureId(parsed.id) then
    self.ignored = self.ignored + 1
    return false
  end
  PurgeSeen(now)
  local seenKey = SeenKey(identity, parsed.session, parsed.sequence, parsed.id)
  if not MarkSeen(seenKey, now) then
    self.duplicates = self.duplicates + 1
    -- A faster channel copy must not swallow the group/guild/whisper's
    -- existing onward route. Never apply twice or start a chain from CHANNEL.
    local fact = seenFacts[seenKey]
    if fact and fact.text == text then
      local ticket = WF.Ticket
      if not ticket or not ticket.Admit or ticket:Admit(identity, parsed.id, now, true) then
        if chatType == "CHANNEL" and not fact.channelHeard then
          fact.channelHeard = true
          DiscoverChannelPeer(sender, identity, now)
        elseif chatType ~= "CHANNEL" and fact.pending then
          fact.pending = nil
          PassDirect(identity, parsed, chatType, now)
        end
      end
    end
    return false
  end
  -- The channel's chain: the relay's duplicate check and bridge, then capture.
  local relay = WF.Relay
  if relay and relay.OnLocalLine then
    local handled, duplicate = pcall(relay.OnLocalLine, relay, parsed.id, parsed.data, parsed.session,
      parsed.sequence, sender, false, chatType)
    if not handled then
      if WF.RecordError then WF.RecordError("relay local line", duplicate) end
    elseif duplicate then
      self.duplicates = self.duplicates + 1
      return false
    end
  end
  if not capture or not capture.OnMessage then return Reject("capture") end
  -- The catch-up answers an addressed digest to its sender alone.
  if chatType == "WHISPER" and ADDRESSED[parsed.id] then capture.addressedFrom = WhisperTarget(sender) end
  local ok, err = pcall(capture.OnMessage, capture, parsed.id, parsed.data, sender, false)
  capture.addressedFrom = nil
  if not ok then
    if WF.RecordError then WF.RecordError("capture message", err) end
    return false
  end
  -- Invalid/admission-rejected lines stop; a parsed but locally old fact may
  -- still help another client without counting as local delivery.
  if err == false and not capture.forwardable then return false end
  if err ~= false then self.delivered = self.delivered + 1 end
  if capture.forwardable ~= false then
    seenFacts[seenKey] = { text = text, channelHeard = chatType == "CHANNEL",
      pending = chatType == "CHANNEL" and RelayClass(parsed.id, parsed.data) == "C" }
  end
  if chatType == "CHANNEL" then
    DiscoverChannelPeer(sender, identity, now)
  elseif capture.forwardable ~= false then
    PassDirect(identity, parsed, chatType, now)
  end
  return true
end

-- Ticks and diagnostics ---------------------------------------------------------------

local function Run(scope, module, method, ...)
  if not module or type(module[method]) ~= "function" then return end
  local ok, err = pcall(module[method], module, ...)
  if not ok and WF.RecordError then WF.RecordError(scope, err) end
end

function Transport:Tick(now)
  if now < nextTickAt then return end
  nextTickAt = now + TICK
  startAt = startAt or now
  if not Usable() then return end
  ChannelCanaryTick(now)
  local groupType = GroupType()
  if groupType and not lastGroupType then
    -- Entering a group starts an owner catch-up series there (decision 0077
    -- step 3), and the attack and scout catch-up and our version announce, as
    -- a channel join did (§ 5f): the group is a broadcast medium.
    Run("catch-up series", WF.Catchup, "RequestSeries", now)
    Run("attack catch-up", WF.Attack, "OnJoined", now)
    Run("scout catch-up", WF.Scout, "OnJoined", now)
    Run("version announce", WF.Version, "Announce", now)
    Run("boards join", WF.Boards, "OnJoined", now, "GROUP")
  elseif not groupType and lastGroupType then
    groupPeers, groupPeerCount = {}, 0
  end
  lastGroupType = groupType
  -- The attack and scout catch-up by whisper, once someone we may whisper is
  -- known (decision 0077 § 5f).
  if not pullFirstAt and now - startAt >= PULL_AFTER then
    local known = #self:PullTargets(PULL_PEERS, now)
    if known >= PULL_PEERS or (known > 0 and now - startAt >= PULL_LATE) then pullFirstAt = now end
  end
  local due = pullFirstAt and PULL_ROUNDS[pullRound + 1]
  if due and now >= pullFirstAt + due then
    pullRound = pullRound + 1
    Run("attack pull", WF.Attack, "PullAddressed", now)
    Run("scout pull", WF.Scout, "PullAddressed", now)
    Run("front pull", WF.Front, "PullAddressed", now)
  end
  GuildTick(now)
  Run("boards", WF.Boards, "Tick", now)
end

local function InCombat()
  local api = Global("C_RestrictedActions")
  if type(api) ~= "table" or type(api.InCombatLockdown) ~= "function" then return false end
  local ok, combat = pcall(api.InCombatLockdown)
  return ok and combat == true
end

-- Where a board copy may go now: "GROUP" (party or raid), "GUILD", and
-- "W:<identity>" for each contact outside them (decision 0110 § 4), plus a
-- guild peer or contact that whispered us a board line.
function Transport:BoardAudiences()
  local out = {}
  local now = Now()
  if GroupType() then out.GROUP = true end
  if InGuild() then out.GUILD = true end
  local directory = WF.Directory
  if directory and type(directory.ContactTargets) == "function" then
    local ok, contacts = pcall(directory.ContactTargets, directory, now)
    if ok and type(contacts) == "table" then
      for i = 1, #contacts do
        local entry = contacts[i]
        if type(entry) == "table" and entry.identity and entry.target and not IsGuildPeer(entry.identity, now)
            and not groupPeers[entry.identity] then
          boardTargets[entry.identity] = entry.target
          out["W:" .. entry.identity] = true
        end
      end
    end
  end
  for identity in pairs(boardTargets) do
    if IsGuildPeer(identity, now) or IsContact(identity, now) then
      out["W:" .. identity] = true
    else
      boardTargets[identity] = nil
    end
  end
  -- Battle.net links (other-faction friends), through the relay's own path.
  local relay = WF.Relay
  if relay and type(relay.BoardLinks) == "function" then
    local ok, ids = pcall(relay.BoardLinks, relay, now)
    if ok and type(ids) == "table" then
      for i = 1, #ids do out["L:" .. tostring(ids[i])] = true end
    end
  end
  return out
end

-- One board line (BD, BQ, BP) to the group or the guild, only when no gameplay
-- line waits anywhere (decision 0110 § 3). False when it did not leave now;
-- the caller tries again later. A refusal backs the board lane off alone.
function Transport:SendBoard(audience, id, body)
  if not BOARD_LINES[id] or type(body) ~= "string" then return false end
  local now = Now()
  if type(audience) == "string" and strSub(audience, 1, 2) == "L:" then
    -- A Battle.net link: only when the gate and the guild are idle too.
    local relay, queue = WF.Relay, WF.SendQueue
    local linkId = tonumber(strSub(audience, 3))
    if not linkId or not relay or type(relay.SendBoard) ~= "function" or InCombat() or not Usable() then return false end
    if not queue or queue:Pending() > 0 or #guild.outbox > 0 then return false end
    return relay:SendBoard(linkId, id, body, now) == true
  end
  if now < self.boardBackoffUntil or not Usable() or InCombat() then return false end
  local chatType = audience == "GROUP" and GroupType() or (audience == "GUILD" and InGuild() and "GUILD") or nil
  local target
  if not chatType and type(audience) == "string" and strSub(audience, 1, 2) == "W:" then
    target = boardTargets[strSub(audience, 3)]
    if target then chatType = "WHISPER" end
  end
  if not chatType or Paused(chatType, now) or #guild.outbox > 0 then return false end
  if not addon.at then addon.at = now end
  if mathMin(ADDON_BURST, addon.tokens + mathMax(0, now - addon.at) * ADDON_RATE) < ADDON_BURST then return false end
  local queue = WF.SendQueue
  if not queue or type(queue.SendIdle) ~= "function" then return false end
  local storage = WF.Storage
  local session = MySession()
  local sequence = storage and type(storage.NextSequence) == "function" and storage:NextSequence() or nil
  if not session or not sequence then return false end
  local line = Wire(id, session, sequence, body)
  if not line or #line > MAX_BYTES then
    self.oversize = self.oversize + 1
    return false
  end
  local ok, _, attempted = queue:SendIdle({ fn = AddonCall, n = target and 4 or 3, a1 = PREFIX, a2 = line, a3 = chatType, a4 = target, accounted = id == "AM" }, BOARD_QUIET)
  if attempted and id == "AM" then TakeAddonToken(now) end
  if ok then
    self.boardSent = self.boardSent + 1
  elseif attempted then
    self.boardRefused = self.boardRefused + 1
    self.boardBackoffUntil = now + BOARD_BACKOFF
  end
  return ok == true
end

local function CountKeys(map)
  local count = 0
  for _ in pairs(map) do count = count + 1 end
  return count
end

function Transport:Summary()
  local now = Now()
  return "transport group=" .. tostring(GroupType() or "none") .. " guild=" .. (InGuild() and "yes" or "no")
    .. " guildPeers=" .. GuildPeers(now) .. " sent=" .. self.sent .. " delivered=" .. self.delivered
    .. " channel=" .. (self.channelConfirmed and "peer" or "canary")
end

function Transport:PrintStatus()
  local now = Now()
  local print = WF.Print or function() end
  print(self:Summary())
  print("transport: guild outbox=" .. #guild.outbox .. "/" .. GUILD.OUTBOX_MAX .. " tokens="
    .. string.format("%.2f", guild.tokens) .. " terminal=" .. string.format("%.2f", guild.terminal)
    .. " heard/min=" .. HeardPerMinute(now)
    .. (guild.silent and " silent (own copies missing)" or "") .. " presences=" .. self.presences
    .. " queued=" .. self.guildQueued .. " dropped=" .. self.guildDropped .. " expired=" .. self.guildExpired
    .. " capped=" .. self.guildCapped .. " noPeer=" .. self.guildNoPeer)
  local pauses = {}
  for chatType, entry in pairs(paused) do
    if now < entry.untilAt then pauses[#pauses + 1] = chatType .. " " .. mathFloor(entry.untilAt - now) .. "s" end
  end
  print("transport: out sent=" .. self.sent .. " refused=" .. self.refused .. " throttled=" .. self.throttled
    .. " overBudget=" .. self.overBudget .. " addonTokens=" .. string.format("%.1f", addon.tokens)
    .. " errors=" .. self.errors
    .. " superseded=" .. self.superseded .. " noRoute=" .. self.noRoute .. " skipped=" .. self.skipped
    .. " oversize=" .. self.oversize .. (#pauses > 0 and (" paused " .. table.concat(pauses, ", ")) or "")
    .. (self.lastError and (" lastError=" .. self.lastError) or ""))
  print("transport: channel confirmed=" .. (self.channelConfirmed and "yes" or "no")
    .. " sent=" .. self.channelSent .. " remote=" .. self.channelRemote .. " acks=" .. self.channelAcks
    .. " retries=" .. self.channelCanaries .. " ackCancelled=" .. self.channelAckCancelled)
  print("transport: channel hearers=" .. #self:Hearers("CHANNEL", now)
    .. " routeCancelled=" .. (self.routeCancelled or 0))
  print("transport: addressed out=" .. self.addressed .. " in=" .. self.addressedIn .. " presences=" .. self.presencesWhispered
    .. " fanned=" .. self.fanned .. " fanSkipped=" .. self.fanSkipped .. " hiddenOffline=" .. self.hiddenOffline
    .. " offline=" .. (self.offline or 0)
    .. " chainTokens=" .. string.format("%.1f", chain.tokens))
  if WF.Directory and WF.Directory.Summary then print("transport: " .. WF.Directory:Summary()) end
  if WF.Chain and WF.Chain.Summary then print("transport: " .. WF.Chain:Summary()) end
  if WF.Chain and WF.Chain.SpreadSummary then print("transport: " .. WF.Chain:SpreadSummary()) end
  if WF.Nearby and WF.Nearby.Summary then print("transport: " .. WF.Nearby:Summary() .. " local=" .. (self.localSent or 0)) end
  print("transport: in received=" .. self.received .. " delivered=" .. self.delivered .. " duplicates="
    .. self.duplicates .. " echoes=" .. self.echoes .. " ignored=" .. self.ignored
    .. " seen=" .. CountKeys(seen))
  local parts = {}
  for reason, count in pairs(self.rejects) do parts[#parts + 1] = reason .. "=" .. count end
  table.sort(parts)
  print("transport: rejects " .. (#parts > 0 and table.concat(parts, " ") or "none"))
end

-- The offline line ----------------------------------------------------------------------

-- CHAT_MSG_SYSTEM "No player named X is currently playing" (ERR_CHAT_PLAYER_NOT_FOUND_S,
-- the client's own wording in any locale) for a player Warfront whispered within
-- TARGET_TTL s: hidden, and that player stops being a contact or a pull target.
-- Every other system line is left alone.
function Transport:IsOfflineLine(text, now)
  if type(text) ~= "string" or IsSecret(text) or recentTargetCount == 0 then return nil end
  local format = Global("ERR_CHAT_PLAYER_NOT_FOUND_S")
  if type(format) ~= "string" or format == "" then return nil end
  local lowered = string.lower(text)
  for target, at in pairs(recentTargets) do
    if now - at <= TARGET_TTL then
      local ok, expected = pcall(string.format, format, target)
      if ok and string.lower(expected) == lowered then return target end
      local base = string.match(target, "^([^%-]+)%-")
      if base then
        ok, expected = pcall(string.format, format, base)
        if ok and string.lower(expected) == lowered then return target end
      end
    end
  end
  return nil
end

-- The filter runs once per chat frame for the same line: the line found is
-- remembered a moment, so every frame hides it and the effects run once.
local lastHidden = { text = nil, at = -1000 }

local function OfflineFilter(_, _, text)
  local now = Now()
  if type(text) == "string" and not IsSecret(text) and lastHidden.text == text and now - lastHidden.at <= 2 then
    return true
  end
  local ok, target = pcall(Transport.IsOfflineLine, Transport, text, now)
  if not ok or not target then return false end
  lastHidden.text, lastHidden.at = text, now
  Transport.hiddenOffline = Transport.hiddenOffline + 1
  local directory, catchup = WF.Directory, WF.Catchup
  if directory and directory.NoteUnreachable then pcall(directory.NoteUnreachable, directory, target, now) end
  if catchup and catchup.NoteUnreachable then pcall(catchup.NoteUnreachable, catchup, target, now) end
  return true
end

local function InstallOfflineFilter()
  local util = Global("ChatFrameUtil")
  if type(util) ~= "table" or type(util.AddMessageEventFilter) ~= "function" then return false end
  return pcall(util.AddMessageEventFilter, "CHAT_MSG_SYSTEM", OfflineFilter)
end

-- Wiring ------------------------------------------------------------------------------

InstallOfflineFilter()

if WF.RegisterEvent then
  WF.RegisterEvent("CHAT_MSG_ADDON", function(_, prefix, text, chatType, sender, target, zoneChannelID, localID, name, instanceID)
    Transport:OnAddonMessage(prefix, text, chatType, sender, target, zoneChannelID, localID, name, instanceID)
  end)
end

if CreateFrame then
  local frame = CreateFrame("Frame", "WarfrontTransportFrame", UIParent)
  frame:SetScript("OnUpdate", function() Transport:Tick(Now()) end)
end
