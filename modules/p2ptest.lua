local WF = Warfront
local Storage = WF.Storage

-- 1.12-shaped chat functions from core/compat.lua (never global on Forever).
local SendAddonMessage = WF.Compat.Global("SendAddonMessage")
local RegisterAddonMessagePrefix = WF.Compat.Global("RegisterAddonMessagePrefix")
local SendChatMessage = WF.Compat.Global("SendChatMessage")
local JoinChannelByName = WF.Compat.Global("JoinChannelByName")

WF.P2PTest = WF.P2PTest or {}
local P2P = WF.P2PTest

local PREFIX = "WF"
-- Keep the conservative 255-byte wire ceiling used by the shared protocol.
local ADDON_MESSAGE_MAX_BYTES = 255
local MAX_MESSAGE_BYTES = ADDON_MESSAGE_MAX_BYTES - #PREFIX - 1
local MAX_DATA_BYTES = MAX_MESSAGE_BYTES
local MAX_BURST_COUNT = 50
local MAX_BURST_SECONDS = 10
local MAX_CAPTURED_ARGS = 9
local ALLOWED_TYPES = { HELLO = true, PING = true, PONG = true, DATA = true, BURST = true }
local TRANSPORTS = { PARTY = true, RAID = true, GUILD = true, INSTANCE_CHAT = true }
local EVENT_TRANSPORTS = {
  PARTY = true,
  RAID = true,
  GUILD = true,
  OFFICER = true,
  INSTANCE_CHAT = true,
  CHANNEL = true,
  WHISPER = true,
  SAY = true,
  YELL = true,
  EMOTE = true,
}
local SAFE_AUTO_REPLY = { PARTY = true, RAID = true, GUILD = true }
local DEFAULT_CUSTOM_CHANNEL = "Warfront"
-- Visible channel line (decisions 0027, 0029):
-- WF<level>:<addon version>:<id>:<session>:<seq base 36>:<body>. The addon
-- version always follows "WF<n>:", so a build reads it even on another level.
local CHANNEL_LEVEL = WF.channelLevel
local CHANNEL_WIRE_PREFIX = "WF" .. tostring(CHANNEL_LEVEL) .. ":" .. tostring(WF.version) .. ":"
-- One short id per event. HI and D are diagnostics, V the version announce
-- (core/version.lua), B and R the cross-faction relay beacon and relayed packet
-- (modules/relay.lua, decision 0068), NP the guild network presence
-- (modules/transport.lua, decision 0077), F a fact passed hand to hand by
-- whisper (modules/chain.lua, decision 0077 step 4b), BD/BQ/BP the board copies
-- (modules/boards.lua, decision 0110, group and guild only); the capture ids are routed to
-- WF.Capture:OnMessage (docs/p2p-protocol.md).
local CHANNEL_ID_BY_TYPE = { HELLO = "HI", DATA = "D" }
-- LJ/LN: a request to join a layer and its refusal (modules/layer_jump.lua,
-- decision 0119 step 4), whisper only. GF: the group finder (modules/group_finder.lua,
-- decision 0145), listings on the channel and the guild, answers by whisper. SR: a
-- player's own scoreboard row (modules/score_rows.lua, decision 0146). RQ/RA:
-- the ruleset question for unknown realms and its answer (modules/realm_ask.lua,
-- decision 0147), channel only. PW: the other side's online players
-- (modules/far_players.lua, decision 0148), channel only.
local CHANNEL_TYPE_BY_ID = { HI = "HELLO", D = "DATA", V = "VERSION", B = "BEACON", R = "RELAY", NP = "NETWORK",
  F = "FORWARD", BD = "BOARD", BQ = "BOARD", BP = "BOARD", AM = "ALLIES", LJ = "LAYER", LN = "LAYER",
  GF = "GROUPS", SR = "SCORES", RQ = "REALMS", RA = "REALMS", PW = "PLAYERS" }
local CAPTURE_IDS = {
  P = true, S = true, Q = true, K = true, H = true, HQ = true, OD = true, OL = true, X = true,
  G = true, GD = true, GQ = true, SC = true, SQ = true, SL = true, AC = true, AQ = true, AL = true, AR = true,
  T = true, TQ = true, FW = true, FQ = true, CE = true, CQ = true, CL = true,
}
-- modules/transport.lua routes the same capture ids (decision 0077).
function P2P.IsCaptureId(id)
  return CAPTURE_IDS[id] == true
end
local CUSTOM_CHANNEL_MAX_BYTES = 255
local CUSTOM_CHANNEL_TRANSPORT = "CHANNEL_CHAT"
-- Visible custom-channel sends stay off (decision 0075). Decision 0134 adds a
-- hidden addon-message lane through modules/transport.lua; this guard still
-- protects the old visible CHAT_MSG_CHANNEL path and its diagnostics.
local CHANNEL_SEND_OFF = true
local CHANNEL_SEND_OFF_ERROR = "custom channel sending is off on Forever"
-- Octo's own UI whispers addon data through the server: a GUILD addon message
-- whose prefix is TW_CHAT_MSG_WHISPER<Name> reaches only Name, which receives
-- the first payload is TW_CHAT_MSG_WHISPER and the fourth is the sender.
local TW_WHISPER_PREFIX = "TW_CHAT_MSG_WHISPER"
local TW_WHISPER_TRANSPORT = "TW_WHISPER"
local CHANNEL_MONITOR_SECONDS = 5
local PREPARED_CHAT_DELAY_SECONDS = 0.05
local SIZE_SWEEP_BASELINE_BYTES = { 32, 64, 96, 128, 160, 192, 224, 240, MAX_MESSAGE_BYTES, 32 }
local SIZE_SWEEP_BOUNDARY_BYTES = {
  MAX_MESSAGE_BYTES - 8, MAX_MESSAGE_BYTES - 4, MAX_MESSAGE_BYTES - 2, MAX_MESSAGE_BYTES - 1, MAX_MESSAGE_BYTES, 32,
}

local pendingPings = {}
local pendingPingOrder = {}
local seen = {}
local seenOrder = {}
-- Last sequence per session seen, for the diagnostic counters only; at most
-- 256 sessions, the oldest seen dropped first (risk B15).
local lastSequence = { bySession = {}, order = {} }
local burstState
local sizeSweepState
local preparedChatState
local configuredChannelTab
local channelMonitorState
local joinAttemptAt
local burstFrame = CreateFrame("Frame", "WarfrontP2PBurstFrame", UIParent)
local sizeSweepFrame = CreateFrame("Frame", "WarfrontP2PSizeSweepFrame", UIParent)
local channelMonitorFrame = CreateFrame("Frame", "WarfrontP2PChannelMonitorFrame", UIParent)
local preparedChatFrame = CreateFrame("Frame", "WarfrontP2PPreparedChatFrame", UIParent)

local function Upper(value)
  return string.upper(tostring(value or ""))
end

local function IsPrintableASCII(value)
  if type(value) ~= "string" then return false end
  for i = 1, #value do
    local byte = string.byte(value, i)
    if byte < 32 or byte > 126 then return false end
  end
  return true
end

local function TakeWord(text)
  local source = tostring(text or "")
  local _, _, word, rest = string.find(source, "^%s*(%S+)%s*(.*)$")
  return word, rest or ""
end

-- A player named in a command: every word, since a Forever name is "First
-- Surname" (decision 0070), minus a trailing keyword from options. "First-Surname"
-- is read as Warfront reads a sender (WF.Names.Split). Returns target, keyword.
local function TakeTarget(text, options)
  local words = {}
  for word in string.gmatch(tostring(text or ""), "%S+") do words[#words + 1] = word end
  local option
  if options and #words > 1 and options[string.lower(words[#words])] then
    option = string.lower(table.remove(words))
  end
  local target = table.concat(words, " ")
  if target == "" then return nil, option end
  local names = WF.Names
  if names and type(names.Split) == "function" then
    local ok, name, realm = pcall(names.Split, target)
    if ok and type(name) == "string" and name ~= "" then
      target = realm and (name .. "-" .. realm) or name
    end
  end
  return target, option
end

local function AddSeen(key)
  if seen[key] then return false end
  seen[key] = true
  seenOrder[#seenOrder + 1] = key
  while #seenOrder > 200 do
    local old = table.remove(seenOrder, 1)
    seen[old] = nil
  end
  return true
end

local function MakeFill(length)
  local output = ""
  local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
  for i = 1, length do
    local index = ((i - 1) % (#alphabet)) + 1
    output = output .. string.sub(alphabet, index, index)
  end
  return output
end

local function ValidateTransport(transport)
  local normalized = Upper(transport)
  if not TRANSPORTS[normalized] then
    return nil, "transport must be PARTY, RAID, GUILD, or INSTANCE_CHAT"
  end
  return normalized
end

local function IsExactSizeProbe(messageType, data, payloadBytes)
  if messageType ~= "DATA" or type(data) ~= "string" then return false end
  local _, _, requested = string.find(data, "^SIZE=(%d+);BODY=")
  if requested then return tonumber(requested) == payloadBytes end
  return false
end

-- OctoWoW rejects | in any chat-system message ("Invalid escape code in chat
-- message", comms.chat_message_rejects_pipe_escape): fields are separated by :.
local function Wire(messageType, session, sequence, data)
  return "V1:" .. messageType .. ":" .. session .. ":" .. tostring(sequence) .. ":" .. (data or "")
end

local function IsWire(value)
  local head = string.sub(value, 1, 3)
  return head == "V1:" or head == "V1|"
end

function P2P.Parse(message)
  if type(message) ~= "string" then return nil, "payload is not a string" end
  if #message > MAX_MESSAGE_BYTES then return nil, "payload exceeds diagnostic safety limit" end

  local _, _, messageType, session, sequenceText, data = string.find(message, "^V1[:|]([A-Z]+)[:|]([0-9A-F]+)[:|](%d+)[:|](.*)$")
  if not messageType then return nil, "envelope does not match V1" end
  if not ALLOWED_TYPES[messageType] then return nil, "unknown message type" end
  if #session < 4 or #session > 12 then return nil, "invalid session id" end
  if #data > MAX_DATA_BYTES and not IsExactSizeProbe(messageType, data, #message) then
    return nil, "data exceeds diagnostic safety limit"
  end
  if not IsPrintableASCII(data) then return nil, "data is not printable ASCII" end

  local sequence = tonumber(sequenceText)
  if not sequence or sequence < 0 or sequence > 2147483647 then return nil, "invalid sequence" end

  return {
    version = "V1",
    messageType = messageType,
    session = session,
    sequence = sequence,
    data = data,
  }
end

local BASE36 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"

-- Channel sequences travel in base 36: 2147483647 still fits in 6 characters.
local function Base36(value)
  value = math.floor(tonumber(value) or 0)
  if value <= 0 then return "0" end
  local output = ""
  while value > 0 do
    local digit = value - math.floor(value / 36) * 36
    output = string.sub(BASE36, digit + 1, digit + 1) .. output
    value = math.floor(value / 36)
  end
  return output
end

-- The campaign header field <N>.<S>.<set> (decision 0103 § 4b, 0102 § 5):
-- every line carries the sender's campaign; modules/campaign.lua decides.
local NO_CAMPAIGN = "0.0.-"

local function CampaignTag()
  local campaign = WF.Campaign
  if not campaign or type(campaign.Tag) ~= "function" then return NO_CAMPAIGN end
  local ok, tag = pcall(campaign.Tag, campaign)
  if ok and type(tag) == "string" then return tag end
  return NO_CAMPAIGN
end

local function ChannelWire(id, session, sequence, body)
  return CHANNEL_WIRE_PREFIX .. id .. ":" .. session .. ":" .. Base36(sequence) .. ":" .. CampaignTag() .. ":"
    .. (body or "")
end
P2P.ChannelWire = ChannelWire

-- The campaign header field <N>.<S>.<set>, with decision 0139's optional
-- ruleset marker .<record>: one to three base-36 characters (modules/campaign.lua
-- decides whether the ruleset is ours).
function P2P.CampaignFieldOk(text)
  if string.find(text, "^[0-9A-Z]+%.[0-9A-Z]+%.[A-Z0-9%-]+$") then return true end
  local marker = string.match(text, "^[0-9A-Z]+%.[0-9A-Z]+%.[A-Z0-9%-]+%.([0-9A-Z]+)$")
  return marker ~= nil and #marker <= 3
end

-- Whether a received line of the given id and campaign header may be applied
-- (modules/campaign.lua): a line of another campaign is counted, not applied.
function P2P.AdmitCampaign(id, campaign)
  local module = WF.Campaign
  if not module or type(module.Admit) ~= "function" then return campaign == CampaignTag() end
  local ok, admitted = pcall(module.Admit, module, id, campaign, WF.Now())
  if not ok then
    WF.RecordError("campaign admit", admitted)
    return false
  end
  return admitted
end

local function ChannelMessageType(id)
  return CHANNEL_TYPE_BY_ID[id] or id
end

-- Returns parsed, error, meta; nil without error: not Warfront traffic.
-- meta = { level, version } whenever the sender's addon version is readable,
-- even on a line of another level that is not applied.
function P2P.ParseChannel(text)
  if type(text) ~= "string" then return nil end
  local _, _, levelText, rest = string.find(text, "^WF(%d+):(.*)$")
  if not levelText then return nil end
  local level = #levelText <= 3 and tonumber(levelText) or nil
  local _, _, build, tail = string.find(rest, "^([^:]*):(.*)$")
  local meta
  if level and build and WF.Version and WF.Version.Valid(build) then
    meta = { level = level, version = build }
  end
  if level ~= CHANNEL_LEVEL then return nil, "unsupported channel protocol WF" .. levelText, meta end
  if #text > CUSTOM_CHANNEL_MAX_BYTES then return nil, "channel message exceeds 255 bytes", meta end
  if not meta then return nil, "invalid addon version" end

  local _, _, id, session, sequenceText, campaign, body = string.find(tail,
    "^([A-Z][A-Z0-9]*):([0-9A-F]+):([0-9A-Z]+):([0-9A-Z%.%-]+):(.*)$")
  if not id then return nil, "envelope does not match WF" .. tostring(CHANNEL_LEVEL), meta end
  if #campaign > 20 or not P2P.CampaignFieldOk(campaign) then return nil, "invalid campaign", meta end
  if not CHANNEL_TYPE_BY_ID[id] and not CAPTURE_IDS[id] then return nil, "unknown channel event id", meta end
  if #session < 4 or #session > 12 then return nil, "invalid session id", meta end
  local sequence = #sequenceText <= 6 and tonumber(sequenceText, 36)
  if not sequence or sequence > 2147483647 then return nil, "invalid sequence", meta end
  if not IsPrintableASCII(body) then return nil, "data is not printable ASCII", meta end

  return {
    version = build,
    level = level,
    id = id,
    messageType = ChannelMessageType(id),
    session = session,
    sequence = sequence,
    campaign = campaign,
    data = body,
  }, nil, meta
end

local function CallStatus(accepted, skipped)
  if accepted then return "CALL_ACCEPTED" end
  if skipped then return "SKIPPED" end
  return "CALL_FAILED"
end

local function RecordSendResult(transport, messageType, sequence, payload, accepted, errorText, skipped)
  Storage:AddResult({
    kind = "SEND",
    status = CallStatus(accepted, skipped),
    transport = transport,
    messageType = messageType,
    sequence = sequence,
    bytes = #payload,
    error = errorText and WF.Sanitize(errorText, 200) or nil,
  })
  WF.Record("SEND", {
    status = CallStatus(accepted, skipped),
    transport = transport,
    messageType = messageType,
    sequence = sequence,
    bytes = #payload,
  })
end

-- Every client send goes through WF.SendQueue (decision 0023); the counters
-- and results are written when the call is really made or skipped.
local gateMissingReported

-- A file newly added to the TOC is only loaded by a client restart, not /reload.
-- priority: an event message, dropped last when the queue is full (risk B9).
local function Gate(fn, n, a1, a2, a3, a4, done, key, priority)
  if not WF.SendQueue then
    if not gateMissingReported then
      gateMissingReported = true
      WF.Print("send gate missing (core/send_queue.lua not loaded): restart the WoW client; /reload is not enough.")
    end
    return false, "send gate not loaded: restart the client"
  end
  return WF.SendQueue:Submit({ fn = fn, n = n, a1 = a1, a2 = a2, a3 = a3, a4 = a4, done = done, key = key,
    priority = priority })
end

local function SendRecorder(transport, messageType, sequence, payload, errorScope, extra)
  return function(ok, result, skipped)
    if ok then
      Storage:IncrementSend(transport, "acceptedCalls")
    elseif skipped then
      Storage:IncrementSend(transport, "skippedCalls")
    else
      Storage:IncrementSend(transport, "failedCalls")
      WF.RecordError(errorScope, result)
    end
    RecordSendResult(transport, messageType, sequence, payload, ok, result, skipped)
    if extra then extra(ok, result, skipped) end
  end
end

function P2P.SendEnvelope(messageType, transport, data, reservedSequence)
  local normalized, transportError = ValidateTransport(transport)
  if not normalized then return false, transportError end
  if not ALLOWED_TYPES[messageType] then return false, "invalid message type" end
  if not IsPrintableASCII(data or "") then return false, "data must contain printable ASCII only" end
  if string.find(data or "", "|", 1, true) then return false, "data cannot contain | (rejected by the client)" end

  local db = Storage:GetDB()
  if not db then return false, "SavedVariables are unavailable" end
  local sequence = reservedSequence or Storage:NextSequence()
  if not sequence then return false, "sequence is unavailable" end

  local payload = Wire(messageType, db.session.id, sequence, data)
  if #payload > MAX_MESSAGE_BYTES then return false, "complete message is too large" end
  if #(data or "") > MAX_DATA_BYTES and not IsExactSizeProbe(messageType, data, #payload) then
    return false, "data is too large"
  end

  Storage:IncrementSend(normalized, "attempted")
  if type(SendAddonMessage) ~= "function" then
    Storage:IncrementSend(normalized, "failedCalls")
    RecordSendResult(normalized, messageType, sequence, payload, false, "SendAddonMessage is unavailable")
    return false, "SendAddonMessage is unavailable"
  end

  local ok, err = Gate(SendAddonMessage, 3, PREFIX, payload, normalized, nil,
    SendRecorder(normalized, messageType, sequence, payload, "SendAddonMessage"))
  if not ok then return false, tostring(err) end
  return true, nil, sequence, payload
end

-- Experimental hidden whisper to one player; see TW_WHISPER_PREFIX.
local function SendTwWhisper(target, messageType, data, reservedSequence)
  if type(target) ~= "string" or target == "" or #target > 48 or string.find(target, "[%c<>|]") then
    return false, "target must be a player name"
  end
  if not ALLOWED_TYPES[messageType] then return false, "invalid message type" end
  if not IsPrintableASCII(data or "") then return false, "data must contain printable ASCII only" end
  if string.find(data or "", "|", 1, true) then return false, "data cannot contain | on the TW whisper transport" end
  if type(SendAddonMessage) ~= "function" then return false, "SendAddonMessage is unavailable" end

  local db = Storage:GetDB()
  if not db then return false, "SavedVariables are unavailable" end
  local sequence = reservedSequence or Storage:NextSequence()
  if not sequence then return false, "sequence is unavailable" end

  local prefix = TW_WHISPER_PREFIX .. "<" .. target .. ">"
  local payload = Wire(messageType, db.session.id, sequence, data)
  if #prefix + 1 + #payload > ADDON_MESSAGE_MAX_BYTES then
    return false, "message exceeds the 255-byte addon message limit"
  end

  Storage:IncrementSend(TW_WHISPER_TRANSPORT, "attempted")
  local ok, err = Gate(SendAddonMessage, 3, prefix, payload, "GUILD", nil,
    SendRecorder(TW_WHISPER_TRANSPORT, messageType, sequence, payload, "TW whisper"))
  if not ok then return false, tostring(err) end
  return true, nil, sequence, payload
end

local function PackArguments(a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16)
  local values = {}
  values[1], values[2], values[3], values[4], values[5] = a1, a2, a3, a4, a5
  values[6], values[7], values[8], values[9], values[10] = a6, a7, a8, a9, a10
  values[11], values[12], values[13] = a11, a12, a13
  values[14], values[15], values[16] = a14, a15, a16

  local count = 0
  for i = 1, MAX_CAPTURED_ARGS do
    if values[i] ~= nil then count = i end
  end

  local descriptors = {}
  for i = 1, count do
    local value = values[i]
    local valueType = type(value)
    local representation, truncated, originalLength = WF.Sanitize(value, 160)
    descriptors[i] = {
      index = i,
      valueType = valueType,
      value = representation,
      truncated = truncated or nil,
      stringBytes = valueType == "string" and originalLength or nil,
    }
  end
  return values, descriptors, count
end

local function FindTransport(values, count)
  for i = 1, count do
    if type(values[i]) == "string" then
      local candidate = Upper(values[i])
      if EVENT_TRANSPORTS[candidate] then return candidate, i end
    end
  end
  return nil
end

local function FindCandidateSender(values, count, prefixIndex, payloadIndex, transportIndex)
  for i = 1, count do
    if i ~= prefixIndex and i ~= payloadIndex and i ~= transportIndex and type(values[i]) == "string" and values[i] ~= "" then
      return WF.Sanitize(values[i], 100), i
    end
  end
  return nil
end

local function RecordMalformed(rawEntry, reason, oversized)
  if oversized then
    Storage:IncrementReceive("oversized")
  else
    Storage:IncrementReceive("malformed")
  end
  rawEntry.parseStatus = oversized and "OVERSIZED" or "MALFORMED"
  rawEntry.parseError = WF.Sanitize(reason, 160)
  Storage:AddMessage(rawEntry)
  WF.Record("RECEIVE_REJECTED", { reason = rawEntry.parseError, argCount = rawEntry.argCount })
end

local function ValidateMeasuredSize(parsed, rawPayload)
  local _, _, requested = string.find(parsed.data, "^SIZE=(%d+);BODY=")
  if not requested then return nil end
  local expected = tonumber(requested)
  local actual = #rawPayload
  return expected, actual, expected == actual
end

local function HandleParsed(parsed, rawPayload, transport, rawEntry)
  local db = Storage:GetDB()
  local key = parsed.session .. ":" .. tostring(parsed.sequence) .. ":" .. parsed.messageType
  local fresh = AddSeen(key)
  if not fresh then Storage:IncrementReceive("duplicates") end

  local sequences = lastSequence.bySession
  local previous = sequences[parsed.session]
  if previous and parsed.sequence < previous then Storage:IncrementReceive("outOfOrder") end
  if previous and parsed.sequence > previous + 1 then
    Storage:AddReceiveAmount("missingSequences", parsed.sequence - previous - 1)
  end
  if not previous then
    local order = lastSequence.order
    order[#order + 1] = parsed.session
    while #order > 256 do sequences[table.remove(order, 1)] = nil end
  end
  if not previous or parsed.sequence > previous then sequences[parsed.session] = parsed.sequence end

  if db and parsed.session == db.session.id then Storage:IncrementReceive("echoes") end

  local expectedSize, actualSize, exactSize = ValidateMeasuredSize(parsed, rawPayload)
  rawEntry.parseStatus = "VALID"
  rawEntry.messageType = parsed.messageType
  rawEntry.session = parsed.session
  rawEntry.sequence = parsed.sequence
  rawEntry.transportCandidate = transport
  rawEntry.duplicate = not fresh
  rawEntry.expectedBytes = expectedSize
  rawEntry.actualBytes = actualSize or #rawPayload
  rawEntry.exactSize = exactSize
  Storage:AddMessage(rawEntry)
  Storage:IncrementReceive("validMessages", transport)

  if expectedSize then
    Storage:AddResult({
      kind = "SIZE_RECEIVE",
      status = exactSize and "EXACT" or "MISMATCH",
      messageType = parsed.messageType,
      transport = transport,
      session = parsed.session,
      sequence = parsed.sequence,
      requestedBytes = expectedSize,
      receivedBytes = actualSize,
    })
  end

  local whisperBack = transport == TW_WHISPER_TRANSPORT and rawEntry.senderCandidate
  if parsed.messageType == "PING" and (SAFE_AUTO_REPLY[transport] or whisperBack)
      and db and parsed.session ~= db.session.id then
    local ok, err
    if whisperBack then
      ok, err = SendTwWhisper(rawEntry.senderCandidate, "PONG", parsed.data)
    else
      ok, err = P2P.SendEnvelope("PONG", transport, parsed.data)
    end
    Storage:AddResult({
      kind = "AUTO_PONG",
      status = ok and "CALL_ACCEPTED" or "CALL_FAILED",
      transport = transport,
      requestSession = parsed.session,
      requestSequence = parsed.sequence,
      error = err,
    })
  elseif parsed.messageType == "PONG" then
    local pending = pendingPings[parsed.data]
    if pending then
      local rtt = math.floor(((WF.Now() - pending.sentAt) * 1000) + 0.5)
      pendingPings[parsed.data] = nil
      Storage:IncrementReceive("pongs")
      Storage:RecordRTT(rtt)
      Storage:AddResult({
        kind = "PING_RTT",
        status = "ROUND_TRIP_OBSERVED",
        transport = transport,
        token = parsed.data,
        rttMs = rtt,
        responderSession = parsed.session,
      })
      WF.Print("PONG received on " .. tostring(transport or "unknown") .. ": " .. rtt .. " ms")
    end
  end
end

local function OnAddonMessage(eventName, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16)
  Storage:IncrementReceive("events")
  -- CHAT_MSG_ADDON passes the prefix first: skip other addons' traffic and legacy
  -- TW_ whispers, before building any capture.
  local twWhisper = a1 == TW_WHISPER_PREFIX and type(a2) == "string" and IsWire(a2)
  if a1 ~= PREFIX and not twWhisper then return end
  -- A WF<level> capture line is modules/transport.lua's (decision 0077), not a diagnostic.
  if a1 == PREFIX and type(a2) == "string" and string.find(a2, "^WF%d") then return end
  local values, descriptors, count = PackArguments(a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16)
  local rawEntry = {
    at = WF.Epoch(),
    elapsed = WF.Now(),
    event = eventName,
    handlerShape = WF.handlerShape,
    argCount = count,
    args = descriptors,
  }

  local prefixIndex
  local payloadIndex
  local payload
  for i = 1, count do
    if values[i] == PREFIX or values[i] == TW_WHISPER_PREFIX then prefixIndex = i end
    if type(values[i]) == "string" and IsWire(values[i]) then
      payloadIndex = i
      payload = values[i]
    end
  end

  local transport, transportIndex = FindTransport(values, count)
  local senderCandidate, senderIndex = FindCandidateSender(values, count, prefixIndex, payloadIndex, transportIndex)
  if twWhisper then
    transport = TW_WHISPER_TRANSPORT
    if type(a4) == "string" and a4 ~= "" then senderCandidate, senderIndex = WF.Sanitize(a4, 100), 4 end
  end
  rawEntry.prefixArgIndex = prefixIndex
  rawEntry.payloadArgIndex = payloadIndex
  rawEntry.transportArgIndex = transportIndex
  rawEntry.senderCandidate = senderCandidate
  rawEntry.senderCandidateArgIndex = senderIndex

  if not prefixIndex then
    rawEntry.parseStatus = "OTHER_PREFIX_OR_UNKNOWN_SIGNATURE"
    Storage:AddMessage(rawEntry)
    WF.Record("CHAT_MSG_ADDON", { argCount = count, prefixMatch = false })
    return
  end

  Storage:IncrementReceive("prefixMatches")
  if not payload then
    RecordMalformed(rawEntry, "WF prefix found but no V1 payload argument was identified", false)
    return
  end

  local parsed, parseError = P2P.Parse(payload)
  if not parsed then
    RecordMalformed(rawEntry, parseError, #payload > MAX_MESSAGE_BYTES)
    return
  end

  HandleParsed(parsed, payload, transport, rawEntry)
  WF.Record("CHAT_MSG_ADDON", {
    argCount = count,
    prefixMatch = true,
    messageType = parsed.messageType,
    transportCandidate = transport,
    senderCandidate = senderCandidate,
  })
end

local prefixRegistered = false
local prefixError
if type(RegisterAddonMessagePrefix) == "function" then
  local ok, result = pcall(RegisterAddonMessagePrefix, PREFIX)
  prefixRegistered = ok and true or false
  if C_ChatInfo and C_ChatInfo.IsAddonMessagePrefixRegistered then
    prefixRegistered = ok and C_ChatInfo.IsAddonMessagePrefixRegistered(PREFIX) and true or false
  end
  if not prefixRegistered then prefixError = ok and tostring(result) or tostring(result) end
else
  prefixError = "RegisterAddonMessagePrefix is unavailable"
end
if not prefixRegistered and WF.RecordError then
  WF.RecordError("addon prefix registration", prefixError)
end

local registered, registrationError = WF.RegisterEvent("CHAT_MSG_ADDON", OnAddonMessage)
P2P.registration = {
  attempted = true,
  accepted = registered and prefixRegistered and true or false,
  error = (registrationError or prefixError) and WF.Sanitize(registrationError or prefixError, 200) or nil,
}
Storage:AddResult({
  kind = "EVENT_REGISTRATION",
  event = "CHAT_MSG_ADDON",
  status = registered and prefixRegistered and "REGISTER_ACCEPTED" or "REGISTER_FAILED",
  error = P2P.registration.error,
})

local function SendHello(transport)
  return P2P.SendEnvelope("HELLO", transport, WF.version)
end

local function GetJoinedChannels()
  if type(GetChannelList) ~= "function" then return nil, "GetChannelList is unavailable" end
  local values = { pcall(GetChannelList) }
  if not values[1] then return nil, tostring(values[2]) end

  local channels = {}
  local i
  -- Forever returns channel ID, name, disabled triples.
  for i = 2, #values, 3 do
    local channelId = values[i]
    local channelName = values[i + 1]
    if type(channelId) == "number" and channelId > 0 and type(channelName) == "string" then
      channels[#channels + 1] = { id = channelId, name = channelName }
    end
  end
  return channels
end

local function PrintJoinedChannels()
  local channels, err = GetJoinedChannels()
  if not channels then
    WF.Print("channel list unavailable: " .. tostring(err))
    return false
  end
  if #channels == 0 then
    WF.Print("joined channels: none")
    return true
  end

  local parts = {}
  for i = 1, #channels do
    parts[#parts + 1] = tostring(channels[i].id) .. "=" .. WF.Sanitize(channels[i].name, 40)
  end
  WF.Print("joined channels: " .. table.concat(parts, ", "))
  return true
end

local function JoinDiagnosticChannel(requestedName, quiet, hidden)
  local name = requestedName
  if not name or name == "" then name = DEFAULT_CUSTOM_CHANNEL end
  if #name > 40 or not IsPrintableASCII(name) then
    if not quiet then WF.Print("channel join failed: name must be 1-40 printable ASCII characters") end
    return false, "name must be 1-40 printable ASCII characters"
  end
  if type(JoinChannelByName) ~= "function" then
    if not quiet then WF.Print("channel join failed: JoinChannelByName is unavailable") end
    return false, "JoinChannelByName is unavailable"
  end

  local ok
  local result
  if hidden then
    ok, result = pcall(JoinChannelByName, name, "", 0)
  else
    ok, result = pcall(JoinChannelByName, name)
  end
  local channelId = ok and tonumber(result) or nil
  if ok and (not channelId or channelId <= 0) and type(GetChannelName) == "function" then
    local lookupOk, lookupResult = pcall(GetChannelName, name)
    if lookupOk then channelId = tonumber(lookupResult) end
  end
  Storage:AddResult({
    kind = "CHANNEL_JOIN",
    status = ok and "CALL_ACCEPTED" or "CALL_FAILED",
    channelName = name,
    channelId = channelId,
    hidden = hidden and true or false,
    error = ok and nil or tostring(result),
  })
  if not ok then
    if not quiet then WF.Print("channel join failed: " .. tostring(result)) end
    return false, tostring(result)
  end

  if not quiet then
    WF.Print("channel join call accepted: " .. name .. " id=" .. tostring(channelId or "pending"))
    PrintJoinedChannels()
  end
  return true, nil, channelId, name
end

local function FindJoinedChannel(requestedName)
  local name = requestedName
  if not name or name == "" then name = DEFAULT_CUSTOM_CHANNEL end
  local channels, err = GetJoinedChannels()
  if not channels then return nil, err end

  local expected = string.lower(name)
  for i = 1, #channels do
    if string.lower(channels[i].name) == expected then return channels[i] end
  end
  return nil, "channel is not joined or the join is still pending"
end

-- Only a chat tab named exactly like the channel shows its lines; every other
-- tab hides them. The default channel matches by its configured spelling, so
-- the server's casing of the joined name does not matter.
local function ChannelTabName(channelName)
  if type(channelName) ~= "string" then return nil end
  if string.lower(channelName) == string.lower(DEFAULT_CUSTOM_CHANNEL) then return DEFAULT_CUSTOM_CHANNEL end
  return channelName
end

local function TabShowsChannel(frameIndex, channelName)
  if type(GetChatWindowInfo) ~= "function" then return false end
  local ok, tabName = pcall(GetChatWindowInfo, frameIndex)
  return ok and type(tabName) == "string" and tabName == ChannelTabName(channelName)
end

local function FrameListsChannel(chatFrame, channelName)
  if not chatFrame or type(chatFrame.channelList) ~= "table" then return false end
  local expected = string.lower(channelName)
  for index, value in pairs(chatFrame.channelList) do
    if type(value) == "string" and string.lower(value) == expected then return true end
  end
  return false
end

local function MaxChatWindows()
  if Constants and Constants.ChatFrameConstants
      and type(Constants.ChatFrameConstants.MaxChatWindows) == "number" then
    return Constants.ChatFrameConstants.MaxChatWindows
  end
  return 10
end

-- A closed tab keeps its saved name while hidden and undocked; only a shown or
-- docked window counts, so a closed one is reopened by FCF_OpenNewWindow.
local function ChatWindowActive(frameIndex)
  if type(FCF_IsChatWindowIndexActive) == "function" then
    local ok, active = pcall(FCF_IsChatWindowIndexActive, frameIndex)
    if ok then return active and true or false end
  end
  if type(GetChatWindowInfo) ~= "function" then return true end
  local ok, _, _, _, _, _, _, shown, _, docked = pcall(GetChatWindowInfo, frameIndex)
  return ok and (shown and true or (docked and docked ~= 0)) or false
end

local function FindChannelTab(channelName)
  local frameIndex = 1
  local maximum = MaxChatWindows()
  while frameIndex <= maximum do
    local chatFrame = _G["ChatFrame" .. frameIndex]
    if chatFrame and TabShowsChannel(frameIndex, channelName)
        and ChatWindowActive(frameIndex) then return chatFrame end
    frameIndex = frameIndex + 1
  end
  return nil
end

-- Player choice, saved in WarfrontDB.settings.chatTabDeclined: closing the
-- Warfront tab stops its automatic creation; /wf tab brings it back.
local function ChatSettings()
  if not Storage or type(Storage.GetDB) ~= "function" or Storage.readOnly then return nil end
  local db = Storage:GetDB()
  if type(db) ~= "table" or type(db.settings) ~= "table" then return nil end
  return db.settings
end

local function ChannelTabDeclined()
  local settings = ChatSettings()
  return settings and settings.chatTabDeclined and true or false
end

local function SetChannelTabDeclined(declined)
  local settings = ChatSettings()
  if not settings then return false end
  settings.chatTabDeclined = declined and true or nil
  return true
end

-- Without force, a declined tab is not created: no tab and no error.
local function EnsureChannelTab(channelName, force)
  local chatFrame = FindChannelTab(channelName)
  if chatFrame then return chatFrame, false end
  if not force and ChannelTabDeclined() then return nil, false, nil end
  if type(FCF_OpenNewWindow) ~= "function" then
    return nil, false, "FCF_OpenNewWindow is unavailable"
  end
  local ok, created = pcall(FCF_OpenNewWindow, ChannelTabName(channelName), true)
  if not ok then return nil, false, tostring(created) end
  if not created then return nil, false, "no chat window slot is available" end
  return created, true
end

local function ConfigureChannelTab(chatFrame)
  if configuredChannelTab == chatFrame then return true end
  if type(chatFrame.RemoveAllMessageGroups) ~= "function"
      or type(chatFrame.RemoveAllChannels) ~= "function" then
    return false, "chat filter controls are unavailable"
  end
  local groupsOk, groupsError = pcall(chatFrame.RemoveAllMessageGroups, chatFrame)
  if not groupsOk then return false, tostring(groupsError) end
  local channelsOk, channelsError = pcall(chatFrame.RemoveAllChannels, chatFrame)
  if not channelsOk then return false, tostring(channelsError) end
  configuredChannelTab = chatFrame
  return true
end

-- The tab menu's Close and a middle-click both go through FCF_PopInWindow;
-- FCF_Close alone also runs while the client restores saved windows, so only
-- FCF_PopInWindow is a player choice.
local function OnChatWindowPoppedIn(frame, fallback)
  local chatFrame = fallback or frame
  if type(chatFrame) ~= "table" or type(chatFrame.GetID) ~= "function" then return end
  if chatFrame == DEFAULT_CHAT_FRAME then return end
  local ok, frameIndex = pcall(chatFrame.GetID, chatFrame)
  if not ok or not TabShowsChannel(frameIndex, DEFAULT_CUSTOM_CHANNEL) then return end
  if configuredChannelTab == chatFrame then configuredChannelTab = nil end
  if SetChannelTabDeclined(true) then
    WF.Print("Warfront chat tab closed; it will not be recreated. /wf tab restores it.")
  end
end

if type(hooksecurefunc) == "function" and type(FCF_PopInWindow) == "function" then
  hooksecurefunc("FCF_PopInWindow", OnChatWindowPoppedIn)
end

-- Forever chat payloads can be secret during chat messaging lockdown; a secret
-- value cannot be compared, so it never matches our channel.
local function IsSecret(value)
  return type(issecretvalue) == "function" and issecretvalue(value) and true or false
end

-- Chat frames drop the lines of a channel missing from their channelList
-- (ChatFrameMixin), while CHAT_MSG_CHANNEL still reaches every frame that
-- registered it. The list is rebuilt from the saved window settings on
-- UPDATE_CHAT_WINDOWS, so it is set here for every tab: added to the tabs named
-- like the channel, removed from all others. A declined tab leaves the channel
-- hidden in every tab.
local function ApplyChannelDisplay(channel, forceTab)
  if not channel then return false, "channel is unavailable" end
  local channelTab, createdTab, tabError = EnsureChannelTab(channel.name, forceTab)
  if tabError then return false, tabError end
  if channelTab then
    local configured, configureError = ConfigureChannelTab(channelTab)
    if not configured then return false, configureError end
  end
  local removed, added, kept = 0, 0, 0
  local frameIndex = 1
  local maximum = MaxChatWindows()
  while frameIndex <= maximum do
    local chatFrame = _G["ChatFrame" .. frameIndex]
    if chatFrame and type(chatFrame.channelList) == "table"
        and type(chatFrame.AddChannel) == "function" and type(chatFrame.RemoveChannel) == "function" then
      local listed = FrameListsChannel(chatFrame, channel.name)
      if TabShowsChannel(frameIndex, channel.name) then
        if listed then
          kept = kept + 1
        elseif pcall(chatFrame.AddChannel, chatFrame, channel.name) then
          added = added + 1
        end
      elseif listed and pcall(chatFrame.RemoveChannel, chatFrame, channel.name) then
        removed = removed + 1
      end
    end
    frameIndex = frameIndex + 1
  end
  Storage:AddResult({
    kind = "CHANNEL_CHAT_DISPLAY",
    status = "COMPLETED",
    channelId = channel.id,
    channelName = channel.name,
    removedFrames = removed,
    addedFrames = added,
    keptFrames = kept,
    createdTab = createdTab,
    tabDeclined = not channelTab or nil,
  })
  return true
end

-- Display guard: a chat frame drops the default channel's lines unless its tab
-- is named exactly like the channel, whatever its channelList holds (a client
-- rebuild or another addon may put the channel back). A matching tab gets the
-- channel listed so the line shows. Display only: reception has its own frame.
-- Forever runs chat message filters before the channelList check
-- (ChatFrameUtil.AddMessageEventFilter); returning true drops the line.
local CHANNEL_DISPLAY_EVENTS = {
  "CHAT_MSG_CHANNEL", "CHAT_MSG_CHANNEL_JOIN", "CHAT_MSG_CHANNEL_LEAVE",
  "CHAT_MSG_CHANNEL_NOTICE", "CHAT_MSG_CHANNEL_NOTICE_USER",
}

local function ChannelDisplayFilter(frame, event, a1, a2, a3, a4, a5, a6, a7, a8, channelBaseName)
  if type(channelBaseName) ~= "string" or IsSecret(channelBaseName) then return false end
  if string.lower(channelBaseName) ~= string.lower(DEFAULT_CUSTOM_CHANNEL) then return false end
  if not frame or type(frame.GetID) ~= "function" then return false end
  if not TabShowsChannel(frame:GetID(), channelBaseName) then return true end
  if not FrameListsChannel(frame, channelBaseName) and type(frame.AddChannel) == "function" then
    pcall(frame.AddChannel, frame, channelBaseName)
  end
  return false
end

local function InstallChannelDisplayGuard()
  if type(ChatFrameUtil) ~= "table" or type(ChatFrameUtil.AddMessageEventFilter) ~= "function" then return end
  for index = 1, #CHANNEL_DISPLAY_EVENTS do
    ChatFrameUtil.AddMessageEventFilter(CHANNEL_DISPLAY_EVENTS[index], ChannelDisplayFilter)
  end
end
InstallChannelDisplayGuard()

-- The client, rather than the addon, owns permanent-channel membership. Once it
-- has joined the channel, synchronization starts automatically without calling
-- the protected JoinPermanentChannel API.
local function OnChannelJoined(channel)
  local applied, applyError = ApplyChannelDisplay(channel)
  if not applied then
    WF.Print("Warfront chat tab could not be set up; /wf tab retries it.")
    WF.RecordError("chat display", applyError)
  end
  -- Tell the channel which build we run; older peers get warned, and newer
  -- ones answer so that we get warned (core/version.lua).
  if WF.Version then
    local announced, announceError = pcall(WF.Version.Announce, WF.Version)
    if not announced then WF.RecordError("version announce", announceError) end
  end
  -- Membership ticket, once per join (modules/ticket.lua, decision 0061).
  if WF.Ticket then
    local joined, joinError = pcall(WF.Ticket.OnJoined, WF.Ticket)
    if not joined then WF.RecordError("ticket join", joinError) end
  end
  -- Owner catch-up digest, 10 s later (modules/catchup.lua, decision 0038).
  if WF.Catchup then
    local joined, joinError = pcall(WF.Catchup.OnJoined, WF.Catchup)
    if not joined then WF.RecordError("catch-up join", joinError) end
  end
  -- Scouts under way and discoveries (modules/scout.lua, decision 0050).
  if WF.Scout then
    local asked, askError = pcall(WF.Scout.OnJoined, WF.Scout)
    if not asked then WF.RecordError("scout join", askError) end
  end
  -- Armies under way and pending battles (modules/attack.lua, decision 0052).
  if WF.Attack then
    local asked, askError = pcall(WF.Attack.OnJoined, WF.Attack)
    if not asked then WF.RecordError("attack join", askError) end
  end
  -- Siege windows under way (modules/front.lua, decision 0098).
  if WF.Front then
    local asked, askError = pcall(WF.Front.OnJoined, WF.Front)
    if not asked then WF.RecordError("front join", askError) end
  end
  return applied, applyError
end

local function ChannelMonitorTick()
  if not channelMonitorState or WF.Now() < channelMonitorState.nextAt then return end
  channelMonitorState.nextAt = WF.Now() + CHANNEL_MONITOR_SECONDS

  local channel = FindJoinedChannel(DEFAULT_CUSTOM_CHANNEL)
  if channelMonitorState.autoJoinPending then
    -- SavedVariables initialize on ADDON_LOADED, after this file is loaded.
    -- Wait until that event has classified the profile before consuming the
    -- one-shot decision.
    if not (Storage and Storage.initialized) then return end
    channelMonitorState.autoJoinPending = false
    if Storage.newProfile == true and not channel then
      joinAttemptAt = WF.Now()
      local joined, joinError = JoinDiagnosticChannel(DEFAULT_CUSTOM_CHANNEL, true, true)
      if not joined then
        joinAttemptAt = nil
        WF.RecordError("new profile channel join", joinError)
      end
      channel = FindJoinedChannel(DEFAULT_CUSTOM_CHANNEL)
    end
  end
  if not channel then
    channelMonitorState.channelId = nil
    return
  end
  if channelMonitorState.channelId == channel.id then return end

  channelMonitorState.channelId = channel.id
  local synchronized, syncError = OnChannelJoined(channel)
  Storage:AddResult({
    kind = "CHANNEL_SYNC_START",
    status = synchronized and "STARTED" or "DISPLAY_FAILED",
    channelId = channel.id,
    channelName = channel.name,
    error = syncError,
  })
end

local function StartChannelMonitor()
  if channelMonitorState then return end
  channelMonitorState = {
    nextAt = WF.Now() + 1,
    autoJoinPending = true,
  }
  channelMonitorFrame:SetScript("OnUpdate", ChannelMonitorTick)
end
StartChannelMonitor()

local function OpenPreparedChatNow(text)
  if type(ChatFrameUtil) == "table" and type(ChatFrameUtil.OpenChat) == "function" then
    local ok, err = pcall(ChatFrameUtil.OpenChat, text)
    if ok then return true end
    return false, tostring(err)
  end
  return false, "the native chat composer is unavailable"
end

-- Main window "Connect" button (decision 0118). A new saved profile also makes
-- one hidden join attempt at startup (0135); established profiles only join
-- from this button. A blocked attempt is remembered for the client build in
-- WarfrontDB.channelJoinBlocked, and later clicks open the chat box with the
-- join command, which the player sends with Enter.
local JOIN_BLOCK_WINDOW = 0.5

local function ClientBuild()
  local info = WF.Compat.Global("GetBuildInfo")
  if type(info) ~= "function" then return nil end
  local ok, _, build = pcall(info)
  if ok and build ~= nil then return tostring(build) end
  return nil
end

local function JoinDB()
  if not Storage or Storage.readOnly then return nil end
  local db = Storage:GetDB()
  if type(db) == "table" then return db end
  return nil
end

local function OpenJoinCommand()
  return OpenPreparedChatNow("/join " .. DEFAULT_CUSTOM_CHANNEL)
end

function P2P.ChannelJoined()
  return FindJoinedChannel(DEFAULT_CUSTOM_CHANNEL) ~= nil
end

-- Hidden addon-message channel target (decision 0134). Forever's measured
-- CHANNEL path accepts the joined channel id string, not its name.
function P2P.ChannelTarget()
  local channel = FindJoinedChannel(DEFAULT_CUSTOM_CHANNEL)
  if not channel then return nil end
  return tostring(channel.id), channel.name
end

-- "joined", "joining" (direct call made), "chat" (chat box waits for Enter),
-- or nil and an error.
function P2P.JoinChannelFromUI()
  if P2P.ChannelJoined() then return "joined" end
  local db, build = JoinDB(), ClientBuild()
  if not (db and build and db.channelJoinBlocked == build) then
    joinAttemptAt = WF.Now()
    local joined, joinError = JoinDiagnosticChannel(DEFAULT_CUSTOM_CHANNEL, true)
    -- A blocked action reported during the call already opened the chat box.
    if joined and joinAttemptAt then return "joining" end
    if joined then return "chat" end
    joinAttemptAt = nil
    WF.RecordError("channel join", joinError)
  end
  local opened, openError = OpenJoinCommand()
  if opened then return "chat" end
  return nil, openError
end

-- Click-driven automatic join (decision 0140, modules/channel_autojoin.lua):
-- the same direct call as Connect, without joinAttemptAt, so a blocked result
-- is left to the caller and never opens the chat box or marks Connect.
function P2P.JoinChannelAuto()
  if P2P.ChannelJoined() then return "joined" end
  local joined, joinError = JoinDiagnosticChannel(DEFAULT_CUSTOM_CHANNEL, true)
  if joined then return "joining" end
  WF.RecordError("channel auto join", joinError)
  return nil, joinError
end

local function OnJoinBlocked(_, source)
  if not joinAttemptAt then return end
  local secret = WF.Compat.Global("issecretvalue")
  if type(secret) == "function" then
    local ok, isSecret = pcall(secret, source)
    if not ok or isSecret then return end
  end
  if source ~= "Warfront" then return end
  local attemptAt = joinAttemptAt
  joinAttemptAt = nil
  if WF.Now() - attemptAt > JOIN_BLOCK_WINDOW then return end
  local db, build = JoinDB(), ClientBuild()
  if db and build then db.channelJoinBlocked = build end
  Storage:AddResult({ kind = "CHANNEL_JOIN", status = "BLOCKED", channelName = DEFAULT_CUSTOM_CHANNEL })
  if OpenJoinCommand() and WF.MainWindow and WF.MainWindow.SetStatus then
    WF.MainWindow:SetStatus("Press Enter in chat to connect.", "GOOD")
  end
end
WF.RegisterEvent("ADDON_ACTION_BLOCKED", OnJoinBlocked)
WF.RegisterEvent("ADDON_ACTION_FORBIDDEN", OnJoinBlocked)

local function PreparedChatTick()
  if not preparedChatState then return end
  if WF.Now() < preparedChatState.openAt then return end

  local state = preparedChatState
  preparedChatState = nil
  preparedChatFrame:SetScript("OnUpdate", nil)
  local opened, openError = OpenPreparedChatNow(state.commandText)
  Storage:AddResult({
    kind = "CHANNEL_CHAT_PREPARE",
    status = opened and "AWAITING_USER_SEND" or "PREPARE_FAILED",
    transport = CUSTOM_CHANNEL_TRANSPORT,
    channelId = state.channelId,
    channelName = state.channelName,
    sequence = state.sequence,
    bytes = state.bytes,
    messageType = state.messageType,
    error = openError,
  })
  if opened then
    WF.Print(state.messageType .. " ready for " .. state.channelName .. "; press Enter once to send it.")
  else
    WF.Print("channel HELLO not prepared: " .. tostring(openError) .. "; manually send: " .. state.commandText)
  end
end

local function QueuePreparedChat(commandText, channel, sequence, bytes, messageType)
  if preparedChatState then return false, "another channel message is already being prepared" end
  preparedChatState = {
    commandText = commandText,
    channelId = channel.id,
    channelName = channel.name,
    sequence = sequence,
    bytes = bytes,
    messageType = messageType,
    openAt = WF.Now() + PREPARED_CHAT_DELAY_SECONDS,
  }
  preparedChatFrame:SetScript("OnUpdate", PreparedChatTick)
  return true
end

local function PrepareChannelMessage(messageType, data, requestedName)
  local channel, channelError = FindJoinedChannel(requestedName)
  if not channel then return false, channelError end

  local id = CHANNEL_ID_BY_TYPE[messageType]
  if not id then return false, "invalid message type" end
  if not IsPrintableASCII(data or "") then return false, "data must contain printable ASCII only" end

  local attached, attachError = ApplyChannelDisplay(channel)
  if not attached then return false, attachError end

  local db = Storage:GetDB()
  local sequence = Storage:NextSequence()
  if not db or not sequence then return false, "storage is unavailable" end

  local visiblePayload = ChannelWire(id, db.session.id, sequence, data)
  if #visiblePayload > CUSTOM_CHANNEL_MAX_BYTES then
    return false, "prepared channel message exceeds 255 bytes"
  end

  local commandText = "/" .. tostring(channel.id) .. " " .. visiblePayload
  local queued, queueError = QueuePreparedChat(commandText, channel, sequence, #visiblePayload, messageType)
  Storage:AddResult({
    kind = "CHANNEL_CHAT_PREPARE",
    status = queued and "QUEUED" or "PREPARE_FAILED",
    transport = CUSTOM_CHANNEL_TRANSPORT,
    channelId = channel.id,
    channelName = channel.name,
    sequence = sequence,
    bytes = #visiblePayload,
    messageType = messageType,
    error = queueError,
  })
  if not queued then return false, queueError .. "; manually send: " .. commandText end

  WF.Print(messageType .. " queued for " .. channel.name .. "; the populated chat input will open next.")
  return true
end

local function PrepareChannelHello(requestedName)
  return PrepareChannelMessage("HELLO", WF.version, requestedName)
end

local function PrepareChannelData(data)
  if not data or data == "" then return false, "text is required" end
  return PrepareChannelMessage("DATA", data, DEFAULT_CUSTOM_CHANNEL)
end

-- retryCall: only the channel retry (decision 0076) passes it; it goes past
-- CHANNEL_SEND_OFF and runs right before the client call.
local function SendChannelDataInternal(id, data, reservedSequence, maximumBytes, resultKind, key, priority, retryCall)
  if not data or data == "" then return false, "text is required" end
  if not IsPrintableASCII(data) then return false, "data must contain printable ASCII only" end
  if string.find(data, "|", 1, true) then return false, "data cannot contain | on the visible channel transport" end

  if CHANNEL_SEND_OFF and not retryCall then
    -- A capture line still crosses to the other faction (decision 0068) and
    -- reaches the supplementary hidden channel, group, guild and contacts as
    -- addon messages (decisions 0077 and 0134).
    if CAPTURE_IDS[id] then
      local db = Storage:GetDB()
      local sequence = reservedSequence or Storage:NextSequence()
      if db and db.session and sequence then
        if WF.Relay and WF.Relay.OnLocalSend then
          local hooked, hookError = pcall(WF.Relay.OnLocalSend, WF.Relay, id, db.session.id, sequence, data, "own")
          if not hooked then WF.RecordError("relay local send", hookError) end
        end
        if WF.Transport and WF.Transport.Send then
          local called, taken, reason = pcall(WF.Transport.Send, WF.Transport, id, data, db.session.id, sequence,
            key, priority)
          if not called then
            WF.RecordError("transport send", taken)
          elseif taken then
            return true, nil, sequence
          else
            return false, tostring(reason or CHANNEL_SEND_OFF_ERROR)
          end
        end
      end
    end
    -- The relay's beacons and far rebroadcasts, and the version announce, go
    -- to our group instead (decision 0077 step 5 and § 5f); a group is a
    -- broadcast medium like the channel.
    if (id == "B" or id == "R" or id == "V") and WF.Transport and WF.Transport.SendRelayLine then
      local db = Storage:GetDB()
      local sequence = reservedSequence or Storage:NextSequence()
      if db and db.session and sequence then
        local called, taken = pcall(WF.Transport.SendRelayLine, WF.Transport, id, data, db.session.id, sequence,
          key, priority)
        if not called then
          WF.RecordError("transport relay line", taken)
        elseif taken then
          return true, nil, sequence
        end
      end
    end
    return false, CHANNEL_SEND_OFF_ERROR
  end

  local channel, channelError = FindJoinedChannel(DEFAULT_CUSTOM_CHANNEL)
  if not channel then return false, channelError end
  if type(SendChatMessage) ~= "function" then return false, "SendChatMessage is unavailable" end

  local db = Storage:GetDB()
  local sequence = reservedSequence or Storage:NextSequence()
  if not db or not sequence then return false, "storage is unavailable" end

  local visiblePayload = ChannelWire(id, db.session.id, sequence, data)
  local messageType = ChannelMessageType(id)
  local allowedBytes = maximumBytes or CUSTOM_CHANNEL_MAX_BYTES
  if #visiblePayload > allowedBytes then
    return false, "complete visible channel message exceeds " .. tostring(allowedBytes) .. " bytes"
  end

  Storage:IncrementSend(CUSTOM_CHANNEL_TRANSPORT, "attempted")
  -- 1.12 targets a channel by its number: FrameXML resolves it with
  -- GetChannelName before SendChatMessage; a name is not delivered on OctoWoW.
  local channelId, channelName = channel.id, channel.name
  local sendFn = SendChatMessage
  if retryCall then
    sendFn = function(a1, a2, a3, a4)
      pcall(retryCall, WF.Now())
      return SendChatMessage(a1, a2, a3, a4)
    end
  end
  local ok, result = Gate(sendFn, 4, visiblePayload, "CHANNEL", nil, channelId,
    SendRecorder(CUSTOM_CHANNEL_TRANSPORT, messageType, sequence, visiblePayload, "SendChatMessage CHANNEL",
      function(sent, errorText, skipped)
        Storage:AddResult({
          kind = resultKind or "CHANNEL_VISIBLE_SEND",
          status = CallStatus(sent, skipped),
          apiVariant = "DIRECT_DEFAULT_NUMBER",
          transport = CUSTOM_CHANNEL_TRANSPORT,
          channelId = channelId,
          channelName = channelName,
          sequence = sequence,
          bytes = #visiblePayload,
          messageType = messageType,
          error = errorText,
        })
        -- A capture line also crosses to the other faction (decision 0068),
        -- unless the send gate superseded or dropped it.
        if not skipped and CAPTURE_IDS[id] and WF.Relay and WF.Relay.OnLocalSend then
          local hooked, hookError = pcall(WF.Relay.OnLocalSend, WF.Relay, id, db.session.id, sequence, data)
          if not hooked then WF.RecordError("relay local send", hookError) end
        end
      end), key, priority)
  if not ok then return false, tostring(result) end
  return true, nil, sequence, visiblePayload
end

-- key: a queued message with the same key is superseded (WF.SendQueue).
function P2P.SendChannelData(data, reservedSequence, key)
  return SendChannelDataInternal("D", data, reservedSequence, CUSTOM_CHANNEL_MAX_BYTES, "CHANNEL_VISIBLE_SEND", key)
end

-- Capture traffic: id is one of CAPTURE_IDS, body its comma-separated fields.
-- priority marks an event (START/CAPTURED state, kill), which is never
-- replaceable (rule R12) and is dropped last when the send queue is full.
function P2P.SendChannelEvent(id, body, key, priority)
  if not CAPTURE_IDS[id] then return false, "unknown channel event id" end
  if key and priority then return false, "an event message cannot be replaceable" end
  return SendChannelDataInternal(id, body, nil, CUSTOM_CHANNEL_MAX_BYTES, "CHANNEL_VISIBLE_SEND", key,
    priority and true or nil)
end

-- Version announce (core/version.lua): flag A at channel join, R in reply.
function P2P.SendVersion(flag)
  if flag ~= "A" and flag ~= "R" then return false, "invalid version flag" end
  return SendChannelDataInternal("V", flag, nil, CUSTOM_CHANNEL_MAX_BYTES, "CHANNEL_VISIBLE_SEND")
end

-- Channel retry, visible test (decision 0076): one version announce past
-- CHANNEL_SEND_OFF. onCall(now) runs right before the client call.
-- Returns ok, error, sequence, payload.
function P2P.TestChannelSend(onCall)
  if type(onCall) ~= "function" then return false, "onCall is required" end
  return SendChannelDataInternal("V", "A", nil, CUSTOM_CHANNEL_MAX_BYTES, "CHANNEL_RETRY_SEND", nil, nil, onCall)
end

-- Relay lines (modules/relay.lua, decision 0068): B bridge beacon, R packet
-- relayed from the other faction. Never bridged again.
function P2P.SendRelayLine(id, body, key, priority)
  if id ~= "B" and id ~= "R" then return false, "unknown relay line id" end
  if key and priority then return false, "an event message cannot be replaceable" end
  return SendChannelDataInternal(id, body, nil, CUSTOM_CHANNEL_MAX_BYTES, "CHANNEL_VISIBLE_SEND", key,
    priority and true or nil)
end

-- CHAT_MSG_CHANNEL at its measured fixed arguments (decision 0092, ForeverRuntimeProbe
-- chanargs 2026-11-10): 1 text, 2 author, 9 channel base name. A line from another
-- channel or without an author is refused like a lost line; the language is never read.
local CHANNEL_KEY = string.lower(DEFAULT_CUSTOM_CHANNEL)

local function ChannelLine(text, author, baseName)
  if type(text) ~= "string" or IsSecret(text) then return nil, nil, "no text" end
  if type(baseName) ~= "string" or IsSecret(baseName) or string.lower(baseName) ~= CHANNEL_KEY then
    return nil, nil, "other channel"
  end
  if type(author) ~= "string" or IsSecret(author) or author == "" then return nil, nil, "no author" end
  return text, WF.Sanitize(author, 100)
end

P2P.ChannelLine = ChannelLine

local function OnChannelMessage(eventName, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16)
  P2P.channelEvents = (P2P.channelEvents or 0) + 1
  local values, descriptors, count = PackArguments(a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16)
  local payloadIndex
  local visiblePayload
  local parsed
  local parseError
  local meta
  local text, senderCandidate, refusal = ChannelLine(a1, a2, a9)
  if text then
    parsed, parseError, meta = P2P.ParseChannel(text)
    if parsed or parseError then
      payloadIndex = 1
      visiblePayload = text
    end
  end

  Storage:IncrementReceive("events")
  local channelCandidate = refusal ~= "other channel" and DEFAULT_CUSTOM_CHANNEL or nil
  local channelIndex = 9
  local senderIndex = senderCandidate and 2 or nil
  local rawEntry = {
    at = WF.Epoch(),
    elapsed = WF.Now(),
    event = eventName,
    handlerShape = WF.handlerShape,
    argCount = count,
    args = descriptors,
    payloadArgIndex = payloadIndex,
    transportArgIndex = channelIndex,
    transportCandidate = CUSTOM_CHANNEL_TRANSPORT,
    channelCandidate = channelCandidate,
    senderCandidate = senderCandidate,
    senderCandidateArgIndex = senderIndex,
  }

  if not visiblePayload then
    rawEntry.parseStatus = "OTHER_PREFIX_OR_UNKNOWN_SIGNATURE"
    rawEntry.refusal = refusal
    Storage:AddMessage(rawEntry)
    WF.Record("CHAT_MSG_CHANNEL", {
      argCount = count,
      prefixMatch = false,
      channelCandidate = channelCandidate,
      senderCandidate = senderCandidate,
    })
    return
  end

  Storage:IncrementReceive("prefixMatches")
  rawEntry.visibleBytes = #visiblePayload

  -- Any readable addon version counts, even on a line that is not applied:
  -- this is how a player learns that the addon is outdated (decision 0029).
  if meta and WF.Version then
    local noted, noteError = pcall(WF.Version.Note, WF.Version, meta.version, meta.level, senderCandidate)
    if not noted then WF.RecordError("version note", noteError) end
  end

  if not parsed then
    RecordMalformed(rawEntry, parseError, #visiblePayload > CUSTOM_CHANNEL_MAX_BYTES)
    return
  end

  HandleParsed(parsed, visiblePayload, CUSTOM_CHANNEL_TRANSPORT, rawEntry)
  Storage:AddResult({
    kind = "CHANNEL_CHAT_RECEIVE",
    status = "VALID",
    transport = CUSTOM_CHANNEL_TRANSPORT,
    channelName = channelCandidate,
    sender = senderCandidate,
    messageType = parsed.messageType,
    session = parsed.session,
    sequence = parsed.sequence,
  })
  WF.Record("CHAT_MSG_CHANNEL", {
    argCount = count,
    prefixMatch = true,
    messageType = parsed.messageType,
    channelCandidate = channelCandidate,
    senderCandidate = senderCandidate,
  })
  local db = Storage:GetDB()
  local echo = db and db.session and parsed.session == db.session.id or false
  if parsed.id == "V" then
    if not echo and WF.Version then
      local handled, versionError = pcall(WF.Version.OnAnnounce, WF.Version, parsed.version, parsed.data)
      if not handled then WF.RecordError("version announce", versionError) end
    end
    return
  end
  -- The guild network presence and chain lines never travel on the channel (decision 0077).
  if parsed.id == "NP" or parsed.id == "F" then return end
  -- A line of another campaign is never applied (decision 0103 § 4b).
  if not echo and not P2P.AdmitCampaign(parsed.id, parsed.campaign) then return end
  if parsed.id == "B" or parsed.id == "R" then
    if WF.Relay and WF.Relay.OnChannelLine then
      local handled, relayError = pcall(WF.Relay.OnChannelLine, WF.Relay, parsed.id, parsed.data, senderCandidate, echo)
      if not handled then WF.RecordError("relay line", relayError) end
    end
    return
  end
  if CAPTURE_IDS[parsed.id] then
    -- The relay may bridge this line to the other faction, and reports a packet
    -- it already delivered from there (decision 0068).
    if WF.Relay and WF.Relay.OnLocalLine then
      local handled, duplicate = pcall(WF.Relay.OnLocalLine, WF.Relay, parsed.id, parsed.data, parsed.session,
        parsed.sequence, senderCandidate, echo)
      if not handled then
        WF.RecordError("relay local line", duplicate)
      elseif duplicate then
        return
      end
    end
    if WF.Capture and WF.Capture.OnMessage then
      P2P.capRouted = (P2P.capRouted or 0) + 1
      local ok, err = pcall(WF.Capture.OnMessage, WF.Capture, parsed.id, parsed.data, senderCandidate, echo)
      if not ok then
        P2P.capErrors = (P2P.capErrors or 0) + 1
        P2P.lastCapError = WF.Sanitize(err, 160)
        WF.RecordError("capture message", err)
      end
    end
    return
  end
  WF.Print("custom-channel " .. parsed.messageType .. " received from " .. tostring(senderCandidate or "unknown") .. " on " .. tostring(channelCandidate or "unknown"))
end

local channelRegistered, channelRegistrationError = WF.RegisterEvent("CHAT_MSG_CHANNEL", OnChannelMessage)
P2P.channelRegistration = {
  attempted = true,
  accepted = channelRegistered and true or false,
  error = channelRegistrationError and WF.Sanitize(channelRegistrationError, 200) or nil,
}
Storage:AddResult({
  kind = "EVENT_REGISTRATION",
  event = "CHAT_MSG_CHANNEL",
  status = channelRegistered and "REGISTER_ACCEPTED" or "REGISTER_FAILED",
  error = P2P.channelRegistration.error,
})

-- Independent probe: a bare frame counting CHAT_MSG_CHANNEL outside the shared
-- dispatcher, to tell a client that stops delivering from a dispatcher fault.
P2P.probeChannelEvents = 0
local probeOk, probe = pcall(CreateFrame, "Frame", "WarfrontChannelProbe", UIParent)
if probeOk and probe then
  P2P.probeRegistered = pcall(probe.RegisterEvent, probe, "CHAT_MSG_CHANNEL") and true or false
  probe:SetScript("OnEvent", function()
    P2P.probeChannelEvents = P2P.probeChannelEvents + 1
  end)
end

local function SendAutomaticChannelProbe(channel, apiVariant, sender)
  local db = Storage:GetDB()
  local sequence = Storage:NextSequence()
  if not db or not sequence then return false, "storage is unavailable" end

  local tag = "AUTO_" .. apiVariant
  local payload = Wire("DATA", db.session.id, sequence, tag)
  if #payload > MAX_MESSAGE_BYTES then return false, "probe payload exceeds the 1.12 addon message limit" end

  Storage:IncrementSend("CHANNEL", "attempted")
  local ok, result = Gate(sender, 1, payload, nil, nil, nil,
    SendRecorder("CHANNEL", "DATA", sequence, payload, "automatic CHANNEL probe " .. apiVariant,
      function(sent, errorText, skipped)
        Storage:AddResult({
          kind = "CHANNEL_AUTOMATIC_PROBE",
          status = CallStatus(sent, skipped),
          apiVariant = apiVariant,
          channelId = channel.id,
          channelName = channel.name,
          sequence = sequence,
          tag = tag,
          error = errorText,
        })
      end))
  return ok, ok and nil or tostring(result), payload
end

local function SendAutomaticChannelProbes()
  if CHANNEL_SEND_OFF then return false, CHANNEL_SEND_OFF_ERROR end
  local channel, channelError = FindJoinedChannel(DEFAULT_CUSTOM_CHANNEL)
  if not channel then return false, channelError end

  local attempted = 0
  local accepted = 0
  local function Probe(apiVariant, sender)
    attempted = attempted + 1
    local ok = SendAutomaticChannelProbe(channel, apiVariant, sender)
    if ok then accepted = accepted + 1 end
  end

  if type(SendAddonMessage) == "function" then
    Probe("GLOBAL_THREE", function(payload)
      return SendAddonMessage(PREFIX, payload, "CHANNEL")
    end)
    Probe("GLOBAL_FOUR_ID", function(payload)
      return SendAddonMessage(PREFIX, payload, "CHANNEL", channel.id)
    end)
    Probe("GLOBAL_FOUR_NAME", function(payload)
      return SendAddonMessage(PREFIX, payload, "CHANNEL", channel.name)
    end)
  end

  if type(SendChatMessage) == "function" then
    Probe("CHAT_ADDON_DIRECT", function(payload)
      return SendChatMessage(PREFIX .. "\t" .. payload, "CHANNEL", "ADDON", channel.id)
    end)
  end

  Storage:AddResult({
    kind = "CHANNEL_AUTOMATIC_PROBE_SET",
    status = attempted > 0 and "COMPLETED" or "NO_API",
    channelId = channel.id,
    channelName = channel.name,
    attempted = attempted,
    submitted = accepted,
  })
  if attempted == 0 then return false, "no automatic channel API is available" end
  return true, nil, attempted, accepted
end

-- Channel retry, hidden test (decision 0076): one addon message on the
-- channel past CHANNEL_SEND_OFF. onCall(now) runs right before the client
-- call, onResult(result) gets the client's return value.
-- Returns ok, error, payload.
function P2P.TestChannelAddon(onCall, onResult)
  if type(onCall) ~= "function" or type(onResult) ~= "function" then
    return false, "onCall and onResult are required"
  end
  local channel, channelError = FindJoinedChannel(DEFAULT_CUSTOM_CHANNEL)
  if not channel then return false, channelError end
  if type(SendAddonMessage) ~= "function" then return false, "SendAddonMessage is unavailable" end
  return SendAutomaticChannelProbe(channel, "RETRY", function(payload)
    pcall(onCall, WF.Now())
    local result = SendAddonMessage(PREFIX, payload, "CHANNEL", channel.id)
    pcall(onResult, result)
    return result
  end)
end

local function BuildVisibleAutomaticProbe(channel, apiVariant)
  local db = Storage:GetDB()
  local sequence = Storage:NextSequence()
  if not db or not sequence then return nil, nil, nil, "storage is unavailable" end
  local tag = "AUTO_VISIBLE_" .. apiVariant
  local visiblePayload = ChannelWire("D", db.session.id, sequence, tag)
  if #visiblePayload > CUSTOM_CHANNEL_MAX_BYTES then
    return nil, nil, nil, "visible probe exceeds 255 bytes"
  end
  return visiblePayload, sequence, tag
end

local function RecordVisibleAutomaticProbe(channel, apiVariant, sequence, tag, visiblePayload, ok, errorText, skipped)
  Storage:AddResult({
    kind = "CHANNEL_VISIBLE_AUTOMATIC_PROBE",
    status = CallStatus(ok, skipped),
    apiVariant = apiVariant,
    transport = CUSTOM_CHANNEL_TRANSPORT,
    channelId = channel.id,
    channelName = channel.name,
    sequence = sequence,
    bytes = visiblePayload and #visiblePayload or nil,
    messageType = "DATA",
    tag = tag,
    error = errorText,
  })
end

local function SendVisibleAutomaticChannelProbes()
  if CHANNEL_SEND_OFF then return false, CHANNEL_SEND_OFF_ERROR end
  local channel, channelError = FindJoinedChannel(DEFAULT_CUSTOM_CHANNEL)
  if not channel then return false, channelError end
  if type(SendChatMessage) ~= "function" then return false, "SendChatMessage is unavailable" end

  local attempted = 0
  local accepted = 0
  local function Probe(apiVariant, sender)
    local visiblePayload, sequence, tag, buildError = BuildVisibleAutomaticProbe(channel, apiVariant)
    if not visiblePayload then return false, buildError end
    attempted = attempted + 1
    local ok = Gate(sender, 1, visiblePayload, nil, nil, nil, function(sent, errorText, skipped)
      RecordVisibleAutomaticProbe(channel, apiVariant, sequence, tag, visiblePayload, sent, errorText, skipped)
    end)
    if ok then accepted = accepted + 1 end
    return ok
  end

  Probe("DIRECT_DEFAULT_NAME", function(payload)
    return SendChatMessage(payload, "CHANNEL", nil, channel.name)
  end)

  local defaultLanguage
  if type(GetDefaultLanguage) == "function" then
    local languageOk, language = pcall(GetDefaultLanguage)
    if languageOk and type(language) == "string" and language ~= "" then defaultLanguage = language end
  end
  if defaultLanguage then
    Probe("DIRECT_LANGUAGE_NAME", function(payload)
      return SendChatMessage(payload, "CHANNEL", defaultLanguage, channel.name)
    end)
  end

  Probe("DIRECT_DEFAULT_ID", function(payload)
    return SendChatMessage(payload, "CHANNEL", nil, tostring(channel.id))
  end)

  if type(RunScript) == "function" then
    Probe("RUNSCRIPT_NAME", function(payload)
      local code = string.format("C_ChatInfo.SendChatMessage(%q, %q, nil, %q)", payload, "CHANNEL", channel.name)
      return RunScript(code)
    end)
  end

  Storage:AddResult({
    kind = "CHANNEL_VISIBLE_AUTOMATIC_PROBE_SET",
    status = "COMPLETED",
    channelId = channel.id,
    channelName = channel.name,
    attempted = attempted,
    submitted = accepted,
  })
  return true, nil, attempted, accepted
end

local function SendInvisibleTransportProbe(apiVariant, transport, target, sender)
  local db = Storage:GetDB()
  local sequence = Storage:NextSequence()
  if not db or not sequence then return false, "storage is unavailable" end

  local tag = "AUTO_" .. apiVariant
  local payload = Wire("DATA", db.session.id, sequence, tag)
  if #payload > MAX_MESSAGE_BYTES then return false, "probe payload exceeds the 1.12 addon message limit" end

  Storage:IncrementSend(transport, "attempted")
  local ok, result = Gate(sender, 1, payload, nil, nil, nil,
    SendRecorder(transport, "DATA", sequence, payload, "invisible probe " .. apiVariant,
      function(sent, errorText, skipped)
        Storage:AddResult({
          kind = "INVISIBLE_AUTOMATIC_PROBE",
          status = CallStatus(sent, skipped),
          apiVariant = apiVariant,
          transport = transport,
          target = target,
          sequence = sequence,
          tag = tag,
          error = errorText,
        })
      end))
  return ok, ok and nil or tostring(result)
end

local function SendInvisibleTransportProbes(requestedTarget)
  if type(SendAddonMessage) ~= "function" then
    return false, "SendAddonMessage is unavailable"
  end

  local target = requestedTarget
  if target == "" then target = nil end
  -- Accented names (UTF-8) are valid player names too.
  local validName = WF.Names and WF.Names.Valid(target)
  if target and (#target > 48 or not (validName or IsPrintableASCII(target))) then
    return false, "target must be a player name of at most 48 bytes"
  end

  local attempted = 0
  local accepted = 0
  local function Probe(apiVariant, transport, probeTarget, sender)
    attempted = attempted + 1
    local ok = SendInvisibleTransportProbe(apiVariant, transport, probeTarget, sender)
    if ok then accepted = accepted + 1 end
  end

  local untargeted = { "SAY", "YELL", "EMOTE", "GUILD", "OFFICER", "INSTANCE_CHAT" }
  for i = 1, #untargeted do
    local chatType = untargeted[i]
    Probe("GLOBAL_" .. chatType, chatType, nil, function(payload)
      return SendAddonMessage(PREFIX, payload, chatType)
    end)
  end

  Probe("GLOBAL_WHISPER_THREE", "WHISPER", target, function(payload)
    return SendAddonMessage(PREFIX, payload, "WHISPER")
  end)
  if target then
    Probe("GLOBAL_WHISPER_FOUR_TARGET", "WHISPER", target, function(payload)
      return SendAddonMessage(PREFIX, payload, "WHISPER", target)
    end)
  end

  Storage:AddResult({
    kind = "INVISIBLE_AUTOMATIC_PROBE_SET",
    status = "COMPLETED",
    target = target,
    attempted = attempted,
    submitted = accepted,
  })
  return true, nil, attempted, accepted
end

local function SendPing(transport, whisperTarget)
  local db = Storage:GetDB()
  local sequence = Storage:NextSequence()
  if not db or not sequence then return false, "storage is unavailable" end
  local token = db.session.id .. "-" .. tostring(sequence) .. "-" .. tostring(math.floor(WF.Now() * 1000))
  pendingPings[token] = {
    sentAt = WF.Now(), sequence = sequence,
    transport = whisperTarget and TW_WHISPER_TRANSPORT or Upper(transport),
  }
  pendingPingOrder[#pendingPingOrder + 1] = token
  while #pendingPingOrder > 50 do
    local old = table.remove(pendingPingOrder, 1)
    pendingPings[old] = nil
  end
  local ok, err
  if whisperTarget then
    ok, err = SendTwWhisper(whisperTarget, "PING", token, sequence)
  else
    ok, err = P2P.SendEnvelope("PING", transport, token, sequence)
  end
  if not ok then pendingPings[token] = nil end
  return ok, err
end

local function SendExactSize(transport, requestedSize)
  local db = Storage:GetDB()
  local sequence = Storage:NextSequence()
  if not db or not sequence then return false, "storage is unavailable" end
  local header = Wire("DATA", db.session.id, sequence, "")
  local marker = "SIZE=" .. tostring(requestedSize) .. ";BODY="
  local fillLength = requestedSize - #header - #marker
  if fillLength < 0 then return false, "requested size is too small for the envelope" end
  if requestedSize > MAX_MESSAGE_BYTES then return false, "requested size exceeds the safety limit" end
  return P2P.SendEnvelope("DATA", transport, marker .. MakeFill(fillLength), sequence)
end

local function StopSizeSweep(reason)
  if not sizeSweepState then return end
  local completed = sizeSweepState.index
  local total = #sizeSweepState.sizes
  local profile = sizeSweepState.profile
  sizeSweepState = nil
  sizeSweepFrame:SetScript("OnUpdate", nil)
  Storage:AddResult({ kind = "SIZE_SWEEP_END", status = reason, profile = profile, completed = completed, requested = total })
  WF.Print("size sweep " .. profile .. " stopped: " .. tostring(reason) .. " (" .. completed .. "/" .. total .. ")")
end

local function SizeSweepTick()
  if not sizeSweepState then return end
  local now = WF.Now()
  if now < sizeSweepState.nextAt then return end

  local nextIndex = sizeSweepState.index + 1
  local requestedSize = sizeSweepState.sizes[nextIndex]
  local total = #sizeSweepState.sizes
  WF.Print("SIZE TRY bytes=" .. requestedSize .. " profile=" .. sizeSweepState.profile .. " step=" .. nextIndex .. "/" .. total)
  local ok, err = SendExactSize(sizeSweepState.transport, requestedSize)
  sizeSweepState.index = nextIndex
  sizeSweepState.nextAt = now + sizeSweepState.intervalSeconds
  Storage:AddResult({
    kind = "SIZE_SWEEP_STEP",
    status = ok and "CALL_ACCEPTED" or "CALL_FAILED",
    transport = sizeSweepState.transport,
    index = nextIndex,
    requestedBytes = requestedSize,
    error = err,
  })
  if ok then
    WF.Print("SIZE ACCEPTED bytes=" .. requestedSize)
  else
    WF.Print("SIZE FAILED bytes=" .. requestedSize .. " error=" .. tostring(err))
  end

  if nextIndex >= #sizeSweepState.sizes then
    StopSizeSweep("COMPLETED")
  end
end

sizeSweepFrame:SetScript("OnUpdate", nil)

local function StartSizeSweep(transport, requestedProfile)
  if sizeSweepState then return false, "a size sweep is already active" end
  if burstState then return false, "a burst is already active" end
  local normalized, transportError = ValidateTransport(transport)
  if not normalized then return false, transportError end

  local profile = string.lower(requestedProfile or "")
  local sizes
  local intervalSeconds = 1
  if profile == "" or profile == "baseline" then
    profile = "baseline"
    sizes = SIZE_SWEEP_BASELINE_BYTES
  elseif profile == "boundary" or profile == "extended" then
    profile = "boundary"
    sizes = SIZE_SWEEP_BOUNDARY_BYTES
  else
    return false, "profile must be baseline or boundary"
  end

  sizeSweepState = {
    transport = normalized,
    profile = profile,
    sizes = sizes,
    intervalSeconds = intervalSeconds,
    index = 0,
    startedAt = WF.Now(),
    nextAt = WF.Now(),
  }
  Storage:AddResult({
    kind = "SIZE_SWEEP_START",
    status = "STARTED",
    transport = normalized,
    profile = profile,
    messages = #sizes,
    intervalSeconds = intervalSeconds,
  })
  sizeSweepFrame:SetScript("OnUpdate", SizeSweepTick)
  return true, nil, profile, #sizes, intervalSeconds
end

local function BuildBurstData(index, count, dataBytes)
  local marker = "B=" .. tostring(index) .. "/" .. tostring(count) .. ";"
  if #marker > dataBytes then return nil end
  return marker .. MakeFill(dataBytes - #marker)
end

local function StopBurst(reason)
  if not burstState then return end
  local completed = burstState.sent
  local total = burstState.count
  burstState = nil
  burstFrame:SetScript("OnUpdate", nil)
  Storage:AddResult({ kind = "BURST_END", status = reason, sent = completed, requested = total })
  WF.Print("burst stopped: " .. tostring(reason) .. " (" .. completed .. "/" .. total .. ")")
end

local function BurstTick()
  if not burstState then return end
  local now = WF.Now()
  if now < burstState.nextAt then return end
  if now - burstState.startedAt > MAX_BURST_SECONDS + 1 then
    StopBurst("TIME_LIMIT")
    return
  end

  local nextIndex = burstState.sent + 1
  local data = BuildBurstData(nextIndex, burstState.count, burstState.dataBytes)
  if not data then
    StopBurst("INVALID_SIZE")
    return
  end

  local ok, err = P2P.SendEnvelope("BURST", burstState.transport, data)
  if not ok then
    Storage:AddResult({ kind = "BURST_ERROR", status = "CALL_FAILED", error = err, index = nextIndex })
    StopBurst("SEND_FAILED")
    return
  end

  burstState.sent = nextIndex
  burstState.nextAt = now + (1 / burstState.rate)
  if burstState.sent >= burstState.count then StopBurst("COMPLETED") end
end

burstFrame:SetScript("OnUpdate", nil)

local function StartBurst(transport, count, dataBytes, rate)
  if burstState then return false, "a burst is already active" end
  if sizeSweepState then return false, "a size sweep is already active" end
  local normalized, transportError = ValidateTransport(transport)
  if not normalized then return false, transportError end
  if count < 1 or count > MAX_BURST_COUNT then return false, "count must be between 1 and 50" end
  if dataBytes < 12 or dataBytes > MAX_DATA_BYTES then return false, "data bytes must be between 12 and " .. MAX_DATA_BYTES end
  if rate ~= 1 and rate ~= 2 and rate ~= 4 then return false, "rate must be 1, 2, or 4 messages/second (send gate: 0.25 s apart, a 1.1 s pause after 6 close sends)" end
  if ((count - 1) / rate) > MAX_BURST_SECONDS then return false, "burst duration would exceed 10 seconds" end

  burstState = {
    transport = normalized,
    count = count,
    dataBytes = dataBytes,
    rate = rate,
    sent = 0,
    startedAt = WF.Now(),
    nextAt = WF.Now(),
  }
  Storage:AddResult({
    kind = "BURST_START",
    status = "STARTED",
    transport = normalized,
    count = count,
    dataBytes = dataBytes,
    rate = rate,
  })
  burstFrame:SetScript("OnUpdate", BurstTick)
  return true
end

local function PrintStatus()
  local db = Storage:GetDB()
  local receive = db and db.receiveStats or {}
  local send = db and db.sendStats or {}
  local registration = P2P.registration or {}
  local channelRegistration = P2P.channelRegistration or {}
  WF.Print("version=" .. WF.version .. " channel=WF" .. tostring(CHANNEL_LEVEL) .. " addon=V1 prefix=" .. PREFIX .. " session=" .. tostring(db and db.session.id or "none"))
  if WF.Version then WF.Print(WF.Version:Summary()) end
  WF.Print("CHAT_MSG_ADDON registration=" .. (registration.accepted and "accepted" or "failed") .. " handler=" .. WF.handlerShape)
  WF.Print("CHAT_MSG_CHANNEL registration=" .. (channelRegistration.accepted and "accepted" or "failed") .. " assisted transport=" .. CUSTOM_CHANNEL_TRANSPORT)
  local joinedChannel = FindJoinedChannel(DEFAULT_CUSTOM_CHANNEL)
  if joinedChannel then
    WF.Print("custom channel=" .. joinedChannel.name .. " id=" .. tostring(joinedChannel.id) .. " joined=yes chat=tab "
      .. DEFAULT_CUSTOM_CHANNEL .. " only")
  else
    WF.Print("custom channel=" .. DEFAULT_CUSTOM_CHANNEL .. " joined=no")
  end
  WF.Print("send calls attempted=" .. tostring(send.attempted or 0) .. " accepted=" .. tostring(send.acceptedCalls or 0) .. " failed=" .. tostring(send.failedCalls or 0) .. " skipped=" .. tostring(send.skippedCalls or 0))
  WF.Print(WF.SendQueue:Summary())
  WF.Print("receive events=" .. tostring(receive.events or 0) .. " prefix=" .. tostring(receive.prefixMatches or 0) .. " valid=" .. tostring(receive.validMessages or 0) .. " malformed=" .. tostring(receive.malformed or 0))
  WF.Print("missing=" .. tostring(receive.missingSequences or 0) .. " duplicates=" .. tostring(receive.duplicates or 0) .. " out-of-order=" .. tostring(receive.outOfOrder or 0) .. " echoes=" .. tostring(receive.echoes or 0))
  if (receive.rttCount or 0) > 0 then
    local average = math.floor(((receive.rttTotalMs or 0) / receive.rttCount) + 0.5)
    WF.Print("RTT ms min/avg/max=" .. tostring(receive.rttMinMs) .. "/" .. tostring(average) .. "/" .. tostring(receive.rttMaxMs) .. " samples=" .. tostring(receive.rttCount))
  else
    WF.Print("PONG round trips observed=0")
  end
  if registration.error then WF.Print("registration error: " .. registration.error) end
  if channelRegistration.error then WF.Print("channel registration error: " .. channelRegistration.error) end
  if burstState then WF.Print("burst active: " .. burstState.sent .. "/" .. burstState.count .. " at " .. burstState.rate .. "/s") end
  if sizeSweepState then WF.Print("size sweep " .. sizeSweepState.profile .. " active: " .. sizeSweepState.index .. "/" .. #sizeSweepState.sizes) end
end

local function PrintLog(requested)
  local db = Storage:GetDB()
  local messages = db and db.lastMessages or {}
  local count = tonumber(requested) or 10
  if count < 1 then count = 1 end
  if count > 20 then count = 20 end
  local first = #messages - count + 1
  if first < 1 then first = 1 end
  if #messages == 0 then
    WF.Print("no P2P receive events captured")
    return
  end

  for i = first, #messages do
    local item = messages[i]
    local sizeSummary = ""
    if item.expectedBytes then
      sizeSummary = " size=" .. tostring(item.actualBytes) .. "/" .. tostring(item.expectedBytes) .. " exact=" .. tostring(item.exactSize)
    end
    WF.Print("#" .. i .. " " .. tostring(item.parseStatus) .. " args=" .. tostring(item.argCount) .. " type=" .. tostring(item.messageType or "-") .. " transport=" .. tostring(item.transportCandidate or "-") .. " sender?=" .. tostring(item.senderCandidate or "-") .. sizeSummary)
    local parts = {}
    for j = 1, #(item.args or {}) do
      local argument = item.args[j]
      parts[#parts + 1] = tostring(argument.index) .. ":" .. tostring(argument.valueType) .. "=" .. WF.Sanitize(argument.value, 60)
    end
    if #parts > 0 then
      WF.Print("  " .. WF.Sanitize(table.concat(parts, "; "), 300))
    end
  end
end

-- /wf help lists gameplay commands only. Diagnostics live in the separate
-- WarfrontDev addon (/wfd, decision 0115), never in Warfront's own commands.
local function PrintHelp()
  WF.Print("/wf or /wf ui (open or close the Warfront window); /wf help (this list)")
  WF.Print("/wf welcome (show the welcome window again)")
  WF.Print("/wf tab (reopen the Warfront chat tab after closing it)")
  WF.Print("/wf where (your position and the place you stand in)")
  WF.Print("/wf layerhelp on|off (invite players who ask to join your layer's fight)")
  WF.Print("/wf groups (open the Group Finder)")
  WF.Print("/wf match [on|off] (meet a Warfront player from the other faction to improve data sharing between factions)")
  WF.Print("/wf army (reserve, unit costs and whether you can recruit here)")
  WF.Print("/wf recruit <unit> [count] (in your capital, or a Settlement or War Camp held by your faction; footman, rifleman, mortar, scout)")
  WF.Print("/wf res (your resources, and the stock of the Gold Mine, Forest or Farm you stand in)")
  WF.Print("/wf garrison (garrison, Settlement level and War Chest of the place you stand in)")
  WF.Print("/wf pledge <unit|gold|wood> [count] confirm (irreversible gift to the garrison or Settlement War Chest)")
  WF.Print("/wf scout [POI id] (scouting status and targets, or send your scout to an enemy Outpost or Settlement)")
  WF.Print("/wf attack [POI id footmen riflemen mortars] (armies and battles, or send an army to a discovered enemy place)")
end

-- /wfd p2p help (WarfrontDev, decision 0115); kept here for the size limits.
function P2P.PrintDevHelp()
  WF.Print("/wfd p2p status")
  WF.Print("/wfd p2p join [channel-name] | channels")
  WF.Print("/wfd p2p channelauto (hidden CHANNEL SendAddonMessage experiments; no Enter)")
  WF.Print("/wfd p2p channelvisibleauto (automatic visible API probes; no Enter)")
  WF.Print("/wfd p2p channelsend <printable ASCII text> (automatic visible P2P)")
  WF.Print("/wfd p2p invisible [target-player] (all non-group hidden probes)")
  WF.Print("/wfd p2p channelhello [channel-name] (then press Enter)")
  WF.Print("/wfd p2p channeldata <printable ASCII text> (then press Enter)")
  WF.Print("/wfd p2p hello PARTY|RAID|GUILD|INSTANCE_CHAT")
  WF.Print("/wfd p2p ping PARTY|RAID|GUILD")
  WF.Print("/wfd p2p twhisper <player> [ping|hello] (experimental hidden whisper through the server)")
  WF.Print("/wfd p2p send <transport> <printable ASCII text>")
  WF.Print("/wfd p2p size <transport> <complete message bytes>")
  WF.Print("/wfd p2p sizes <transport> [baseline|boundary]")
  WF.Print("  maximum=" .. MAX_MESSAGE_BYTES .. " message bytes (" .. ADDON_MESSAGE_MAX_BYTES .. " with prefix)")
  WF.Print("/wfd p2p burst <transport> <count> <data bytes> [1|2|4 per second]")
  WF.Print("/wfd p2p report | stop | log [1-20] | clear")
  WF.Print("channelsend uses the automatic visible custom-channel transport.")
end

local function ReportCommandResult(ok, err)
  if ok then
    WF.Print("SendAddonMessage call accepted or queued by the send gate; delivery is not yet proven.")
  else
    WF.Print("test not sent: " .. tostring(err))
  end
end

local function ChannelCommand(command, rest)
  if command == "join" then
    local channelName = TakeWord(rest)
    local joined, joinError = JoinDiagnosticChannel(channelName)
    if not joined and joinError then
      WF.Print("Warfront could not connect: " .. tostring(joinError))
    end
  elseif command == "channels" then
    PrintJoinedChannels()
  elseif command == "twhisper" then
    local target, option = TakeTarget(rest, { hello = true, ping = true })
    local ok, err
    if option == "hello" then
      ok, err = SendTwWhisper(target, "HELLO", WF.version)
    else
      ok, err = SendPing(nil, target)
    end
    if ok then
      WF.Print("hidden TW whisper sent to " .. tostring(target) .. "; only a PONG or a capture on that client proves delivery.")
    else
      WF.Print("TW whisper not sent: " .. tostring(err))
    end
  elseif command == "channelauto" then
    local ok, err, attempted, accepted = SendAutomaticChannelProbes()
    if ok then
      WF.Print("automatic hidden CHANNEL probes completed: " .. tostring(attempted) .. " attempted, " .. tostring(accepted) .. " submitted to the send gate (0.25 s apart, 1.1 s pause after 6 close sends); no Enter was required.")
    else
      WF.Print("automatic hidden CHANNEL probes not completed: " .. tostring(err))
    end
  elseif command == "channelvisibleauto" then
    local ok, err, attempted, accepted = SendVisibleAutomaticChannelProbes()
    if ok then
      WF.Print("automatic visible CHANNEL probes completed: " .. tostring(attempted) .. " attempted, " .. tostring(accepted) .. " submitted to the send gate (0.25 s apart, 1.1 s pause after 6 close sends); no Enter is required.")
    else
      WF.Print("automatic visible CHANNEL probes not started: " .. tostring(err))
    end
  elseif command == "channelsend" then
    local ok, err, sequence = P2P.SendChannelData(rest)
    if ok then
      WF.Print("automatic visible CHANNEL DATA sent as sequence " .. tostring(sequence) .. "; no user confirmation was required.")
    else
      WF.Print("automatic visible CHANNEL DATA not sent: " .. tostring(err))
    end
  elseif command == "invisible" then
    local target = TakeTarget(rest)
    local ok, err, attempted, accepted = SendInvisibleTransportProbes(target)
    if ok then
      WF.Print("non-group invisible probes completed: " .. tostring(attempted) .. " attempted, " .. tostring(accepted) .. " submitted to the send gate (0.25 s apart, 1.1 s pause after 6 close sends); no Enter was required.")
    else
      WF.Print("non-group invisible probes not completed: " .. tostring(err))
    end
  elseif command == "channelhello" then
    local channelName = TakeWord(rest)
    local ok, err = PrepareChannelHello(channelName)
    if not ok then WF.Print("channel HELLO not prepared: " .. tostring(err)) end
  elseif command == "channeldata" then
    local ok, err = PrepareChannelData(rest)
    if not ok then WF.Print("channel DATA not prepared: " .. tostring(err)) end
  else
    return false
  end
  return true
end

local function SlashCommand(message)
  local scope, rest = TakeWord(message)
  if scope == nil or string.lower(scope) == "ui" then
    if not WF.MainWindow or not WF.MainWindow.Toggle then
      WF.Print("the Warfront window is unavailable (restart the client after an update)")
      return
    end
    WF.MainWindow:Toggle()
    return
  end
  if string.lower(scope) == "welcome" then
    if not WF.Welcome or not WF.Welcome.Toggle or not WF.Welcome:Toggle() then
      WF.Print("the welcome window is unavailable (restart the client after an update)")
    end
    return
  end
  if string.lower(scope) == "tab" then
    if not SetChannelTabDeclined(false) then
      WF.Print("Warfront chat tab not restored: settings are unavailable")
      return
    end
    local channel, channelError = FindJoinedChannel(nil)
    if not channel then
      WF.Print("Warfront chat tab restored; it opens once Warfront connects.")
      return
    end
    local applied, applyError = ApplyChannelDisplay(channel, true)
    if applied then
      WF.Print("Warfront chat tab restored")
    else
      WF.Print("Warfront chat tab not restored: " .. tostring(applyError))
    end
    return
  end
  if string.lower(scope or "") == "groups" or string.lower(scope or "") == "group" then
    if not WF.MainWindow or not WF.MainWindow.OpenGroups or not WF.MainWindow:OpenGroups() then
      WF.Print("the Warfront window is unavailable (restart the client after an update)")
    end
    return
  end
  if string.lower(scope or "") == "layerhelp" then
    local jump = WF.LayerJump
    if not jump or not jump.SetHelpOff then
      WF.Print("layer help is unavailable (restart the client after an update)")
      return
    end
    local action = string.lower(TakeWord(rest) or "")
    if action == "on" or action == "off" then
      if jump:SetHelpOff(action == "off") then
        WF.Print(action == "off" and "You no longer invite players who ask to join your layer's fight."
          or "You invite players who ask to join your layer's fight.")
      else
        WF.Print("layer help cannot be saved right now (read-only storage)")
      end
      return
    end
    WF.Print(jump:HelpOff() and "Layer help is off (/wf layerhelp on)." or "Layer help is on (/wf layerhelp off).")
    return
  end
  if string.lower(scope or "") == "where" then
    if not WF.Presence or not WF.Presence.PrintStatus then
      WF.Print("POI presence detection is unavailable")
      return
    end
    WF.Presence:PrintStatus()
    return
  end
  if string.lower(scope or "") == "companion" then
    if not WF.Companion then
      WF.Print("companion bridge is unavailable (restart the client after an update)")
      return
    end
    local action = string.lower(TakeWord(rest) or "")
    if action == "hide" or action == "show" then
      if WF.Companion:SetHintHidden(action == "hide") then
        WF.Print(action == "hide" and "Companion tips hidden. /wf companion show brings them back."
          or "Companion tips shown when the Companion would help.")
      else
        WF.Print("companion tips cannot be saved right now (read-only storage)")
      end
      return
    end
    WF.Companion:PrintStatus()
    return
  end
  if string.lower(scope or "") == "match" or string.lower(scope or "") == "allies" then
    if not WF.Allies or not WF.Allies.Command then
      WF.Print("matchmaking is unavailable (restart the client after an update)")
      return
    end
    WF.Allies:Command(rest)
    return
  end
  if string.lower(scope or "") == "res" or string.lower(scope or "") == "resources" then
    if not WF.Stock or not WF.Stock.PrintStatus then
      WF.Print("resources are unavailable")
      return
    end
    WF.Stock:PrintStatus()
    return
  end
  if string.lower(scope or "") == "army" or string.lower(scope or "") == "recruit" then
    if not WF.Army or not WF.Army.PrintStatus then
      WF.Print("army is unavailable")
      return
    end
    if string.lower(scope) == "recruit" then
      WF.Army:RecruitCommand(rest)
    else
      WF.Army:PrintStatus()
    end
    return
  end
  if string.lower(scope or "") == "garrison" or string.lower(scope or "") == "pledge" then
    if not WF.Garrison or not WF.Garrison.PrintStatus then
      WF.Print("garrisons are unavailable")
      return
    end
    if string.lower(scope) == "pledge" then
      WF.Garrison:PledgeCommand(rest)
    else
      WF.Garrison:PrintStatus()
    end
    return
  end
  if string.lower(scope or "") == "scout" then
    if not WF.Scout or not WF.Scout.Command then
      WF.Print("scouting is unavailable")
      return
    end
    WF.Scout:Command(rest)
    return
  end
  if string.lower(scope or "") == "attack" then
    if not WF.Attack or not WF.Attack.Command then
      WF.Print("attacks are unavailable")
      return
    end
    WF.Attack:Command(rest)
    return
  end
  PrintHelp()
end

-- /wfd p2p (WarfrontDev addon, decision 0115). The probes stay in this file,
-- beside the locals they use; WarfrontDev only routes to them.
function P2P.DevCommand(message)
  local command, rest = TakeWord(message)
  command = string.lower(command or "")
  if ChannelCommand(command, rest) then return end
  if command == "status" then
    PrintStatus()
  elseif command == "report" then
    PrintLog(20)
    PrintStatus()
  elseif command == "hello" then
    local transport = TakeWord(rest)
    ReportCommandResult(SendHello(transport))
  elseif command == "ping" then
    local transport = TakeWord(rest)
    local normalized = Upper(transport)
    if not SAFE_AUTO_REPLY[normalized] then
      WF.Print("automatic PONG is limited to PARTY, RAID, and GUILD until targeting semantics are known")
      return
    end
    ReportCommandResult(SendPing(normalized))
  elseif command == "send" then
    local transport, text = TakeWord(rest)
    if text == "" then
      WF.Print("test not sent: text is required")
      return
    end
    ReportCommandResult(P2P.SendEnvelope("DATA", transport, text))
  elseif command == "size" then
    local transport, sizeText = TakeWord(rest)
    local requestedSize = tonumber(sizeText)
    if not requestedSize or requestedSize ~= math.floor(requestedSize) then
      WF.Print("test not sent: size must be a whole number")
      return
    end
    WF.Print("SIZE TRY bytes=" .. requestedSize .. " profile=manual step=1/1")
    local ok, err = SendExactSize(transport, requestedSize)
    if ok then
      WF.Print("SIZE ACCEPTED bytes=" .. requestedSize)
    else
      WF.Print("SIZE FAILED bytes=" .. requestedSize .. " error=" .. tostring(err))
    end
  elseif command == "sizes" then
    local transport, tail = TakeWord(rest)
    local profile = TakeWord(tail)
    local ok, err, activeProfile, messageCount, intervalSeconds = StartSizeSweep(transport, profile)
    if ok then
      WF.Print("automatic " .. activeProfile .. " size sweep started: " .. messageCount .. " messages, one every " .. intervalSeconds .. " second(s)")
    else
      WF.Print("size sweep not started: " .. tostring(err))
    end
  elseif command == "burst" then
    local transport, tail = TakeWord(rest)
    local countText
    countText, tail = TakeWord(tail)
    local dataBytesText
    dataBytesText, tail = TakeWord(tail)
    local rateText = TakeWord(tail)
    local count = tonumber(countText)
    local dataBytes = tonumber(dataBytesText)
    local rate = tonumber(rateText) or 1
    if not count or count ~= math.floor(count) or not dataBytes or dataBytes ~= math.floor(dataBytes) then
      WF.Print("burst not started: count and data bytes must be whole numbers")
      return
    end
    local ok, err = StartBurst(transport, count, dataBytes, rate)
    if ok then
      WF.Print("bounded burst started; use /wfd p2p stop to cancel")
    else
      WF.Print("burst not started: " .. tostring(err))
    end
  elseif command == "stop" then
    if burstState then
      StopBurst("USER_STOPPED")
    elseif sizeSweepState then
      StopSizeSweep("USER_STOPPED")
    else
      WF.Print("no burst or size sweep is active")
    end
  elseif command == "log" then
    local amount = TakeWord(rest)
    PrintLog(amount)
  elseif command == "clear" then
    if burstState then StopBurst("DIAGNOSTICS_CLEARED") end
    if sizeSweepState then StopSizeSweep("DIAGNOSTICS_CLEARED") end
    pendingPings = {}
    pendingPingOrder = {}
    seen = {}
    seenOrder = {}
    lastSequence = { bySession = {}, order = {} }
    Storage:ClearDiagnostics()
    WF.Print("P2P diagnostics cleared; session and sequence were preserved.")
  else
    P2P.PrintDevHelp()
  end
end

if type(SlashCmdList) == "table" then
  SLASH_WARFRONT1 = "/wf"
  SLASH_WARFRONT2 = "/warfront"
  SlashCmdList.WARFRONT = SlashCommand
else
  WF.RecordError("slash registration", "SlashCmdList is unavailable; /wf was not registered")
end

WF.Record("P2P_READY", {
  prefix = PREFIX,
  protocol = "V1",
  registrationAccepted = registered and prefixRegistered and true or false,
  maxMessageBytes = MAX_MESSAGE_BYTES,
})
