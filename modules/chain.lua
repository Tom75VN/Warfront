local WF = Warfront

-- Passing our faction's live facts hand to hand (decision 0077 step 4b).
--
-- Which facts: a capture start or end (S carrying START or CAPTURED), an
-- attack order (AC), a battle result (AR) and a scouting order (SC), for a
-- POI of our catalog. Never a kill (frequent, and only the bar's neighbours
-- need it), never a pledge (addressed to its keeper), never a presence, a
-- state, a request or an answer.
--
-- Who passes what on, once per fact (the relay's duplicate key):
--   * a fact whispered first-hand by a contact (modules/directory.lua): to
--     fans[1] of our contacts;
--   * a fact heard first-hand in our guild or group: only by its SPEAKERS
--     best-ranked hearers (a hash of each known hearer's name and the fact,
--     the same ranking on every client), plus each hearer with a small chance,
--     so a fact whose best-ranked hearers left still goes on (decision 0077
--     § 5f);
--   * a fact passed on to us (an F line, h hands so far): to fans[h + 1]
--     contacts while h < MAX_HOPS; a bridge's F line has h = 0 (step 5).
--     With the author's own fan-out (modules/transport.lua) a fact travels at
--     most four hands. The fan-outs grow with the directory (Directory:Fans,
--     § 5f): 4, then 3, 3 and 2 contacts up to 60 listed players.
-- Never to the forwarder or the origin. At most PER_ORIGIN facts a minute
-- passed on for one origin, PER_VIA for one forwarder, PER_MIN for all; past
-- them a fact is still delivered here. Every send takes a chain token, and
-- forwards leave RESERVE tokens for our own facts.
--
-- An origin we hear ourselves (Relay:AcceptChain): its copy passed on to us is
-- never applied. When it matches the line we heard first-hand it is still
-- passed on once; when that line has not come yet it is held HOLD_TTL s and
-- passed on only if the same line then comes first-hand (§ 5f).
--
-- Step 5: a bridge that received one of these facts from the other faction over
-- Battle.net (Relay Accept, hop B) starts it down the chain too, so our whole
-- faction hears it without the channel. Such a fact keeps its origin's faction.
--
-- Acceptance is the relay's (Relay:AcceptChain): a forwarded origin is a
-- message field, never server-authenticated, so it stays a relayed claim
-- (decision 0068): hints once per forwarder, no quorum through one hand,
-- an origin we hear ourselves refused. Values are provisional.

local Chain = {
  forwarded = 0, received = 0, delivered = 0, elected = 0, notElected = 0, capped = 0, noContact = 0,
  held = 0, released = 0, facts = 0,
  rejects = {},
  -- Spread diagnostics (decision 0077 § 5g), no network cost: facts first
  -- delivered here by an F line, by the hands it had ("1".."3", "0" from a
  -- bridge's start), and by Battle.net ("bn"), with their age on arrival in
  -- server seconds since the first hand's stamp. Fixed keys, so bounded.
  spread = {},
}
WF.Chain = Chain

local FORWARD = { S = true, AC = true, AR = true, SC = true, FW = true }
-- The wire bounds the hands (an F line above MAX_HOPS is refused); the fan-outs
-- come from the directory, these when it has none.
local MAX_HOPS = 3
local DEFAULT_FANS = { 3, 3, 2 }
local DEFAULT_AUTHOR_FAN = 4
local SPEAKERS = 2
local PER_ORIGIN, PER_VIA, PER_MIN = 8, 8, 30
local RESERVE = 5
local MAX_ORIGINS = 128
local HOLD_TTL, HOLD_MAX = 20, 64

local strMatch, strByte, mathFloor, mathMax = string.match, string.byte, math.floor, math.max

local minute = { at = -1000, count = 0 }
-- Facts already passed on (origin|session:sequence:id), oldest out: one each,
-- whether it came first-hand or passed on.
local PASSED_TTL, PASSED_MAX = 300, 512
local passed, passedKeys, passedHead, passedTail = {}, {}, 1, 0
-- Copies held for an origin we hear ourselves, until its own line comes.
local heldCopies, heldCount = {}, 0

local function FirstPass(key, now)
  while passedHead <= passedTail do
    local oldest = passedKeys[passedHead]
    if passedTail - passedHead + 1 < PASSED_MAX and now - passed[oldest] <= PASSED_TTL then break end
    passed[oldest] = nil
    passedKeys[passedHead] = nil
    passedHead = passedHead + 1
  end
  if passed[key] then return false end
  passed[key] = now
  passedTail = passedTail + 1
  passedKeys[passedTail] = key
  return true
end

local function Now()
  local now = WF.Now and WF.Now() or 0
  if type(now) ~= "number" then return 0 end
  return now
end

local function Reject(reason)
  Chain.rejects[reason] = (Chain.rejects[reason] or 0) + 1
  return false
end

local function FactKey(identity, session, sequence, id)
  return tostring(identity) .. "|" .. tostring(session) .. ":" .. tostring(sequence) .. ":" .. tostring(id)
end

-- djb2 over the text, in [0, 1): the same few hearers speak for one fact.
local function HashFrac(text)
  local h = 5381
  for i = 1, #text do
    h = h * 33 + strByte(text, i)
    h = h - mathFloor(h / 2147483647) * 2147483647
  end
  return h / 2147483647
end

local function Capturable(body)
  local capture = WF.Capture
  local poi = type(body) == "string" and strMatch(body, "^([^,]+),") or nil
  return poi ~= nil and capture ~= nil and type(capture.Capturable) == "function" and capture:Capturable(poi) ~= nil
end

local function Passable(id, body)
  if not FORWARD[id] or not Capturable(body) then return false end
  local capture = WF.Capture
  if not capture or type(capture.RelayClass) ~= "function" then return false end
  local ok, class = pcall(capture.RelayClass, capture, id, body)
  return ok and class == "C"
end

-- Fan-outs for the hands after the author, and the author's (or a bridge's) own.
local function Fans(now)
  local directory = WF.Directory
  if directory and type(directory.Fans) == "function" then
    local ok, fans, author = pcall(directory.Fans, directory, now)
    if ok and type(fans) == "table" and #fans == MAX_HOPS and type(author) == "number" then return fans, author end
  end
  return DEFAULT_FANS, DEFAULT_AUTHOR_FAN
end

-- A per-minute window of counts by key, bounded at MAX_ORIGINS keys.
local function NewWindow() return { rows = {}, count = 0 } end
local origins, forwarders = NewWindow(), NewWindow()

local function Room(window, key, limit, now)
  local entry = window.rows[key]
  if not entry or now - entry.at >= 60 then
    if not entry then
      if window.count >= MAX_ORIGINS then
        for other, row in pairs(window.rows) do
          if now - row.at >= 60 then
            window.rows[other] = nil
            window.count = window.count - 1
          end
        end
        if window.count >= MAX_ORIGINS then return nil end
      end
      window.count = window.count + 1
    end
    entry = { at = now, count = 0 }
    window.rows[key] = entry
  end
  if entry.count >= limit then return nil end
  return entry
end

-- The minute's budget for all facts, for one origin and for one forwarder: a
-- contact inventing origins cannot take the whole minute (decision 0077 § 5f).
local function Allowed(origin, via, now)
  if now - minute.at >= 60 then minute.at, minute.count = now, 0 end
  if minute.count >= PER_MIN then return false end
  local byOrigin = Room(origins, tostring(origin), PER_ORIGIN, now)
  if not byOrigin then return false end
  local byVia = Room(forwarders, tostring(via), PER_VIA, now)
  if not byVia then return false end
  byOrigin.count, byVia.count, minute.count = byOrigin.count + 1, byVia.count + 1, minute.count + 1
  return true
end

-- One fact (its relayed-line body) to `fan` contacts as "<hops>,<line>", never
-- `skipA` or `skipB`, nor anyone in `heard` (identity -> true: the hearers of the
-- guild or group line that brought it); `via` is who gave it to us (the author
-- when first-hand).
local function Forward(line, hops, fan, origin, via, skipA, skipB, now, heard)
  local directory, transport = WF.Directory, WF.Transport
  if not directory or type(directory.Contacts) ~= "function" or not transport
      or type(transport.SendChain) ~= "function" then
    return 0
  end
  if not Allowed(origin, via, now) then
    Chain.capped = Chain.capped + 1
    return 0
  end
  local targets = directory:Contacts(now, fan, function(identity)
    return identity == skipA or identity == skipB or (heard ~= nil and heard[identity] == true)
  end)
  if #targets == 0 then
    Chain.noContact = Chain.noContact + 1
    return 0
  end
  local sent = 0
  for i = 1, #targets do
    if transport:SendChain(targets[i], hops .. "," .. line, RESERVE) then sent = sent + 1 end
  end
  Chain.forwarded = Chain.forwarded + sent
  if sent > 0 then Chain.facts = Chain.facts + 1 end
  return sent
end

-- One fact delivered here for the first time (see Chain.spread).
function Chain.NoteSpread(hand, stampText)
  local stamp = tonumber(stampText)
  if not stamp or type(GetServerTime) ~= "function" then return end
  local ok, clock = pcall(GetServerTime)
  if not ok or type(clock) ~= "number" then return end
  local age = mathMax(0, mathFloor(clock) - stamp)
  local row = Chain.spread[hand]
  if not row then
    row = { n = 0, sum = 0, max = 0 }
    Chain.spread[hand] = row
  end
  row.n, row.sum, row.max = row.n + 1, row.sum + age, mathMax(row.max, age)
end

-- Whether we speak for a fact heard in a guild or group by `hearers` (the
-- Warfront clients known there, us excluded): the SPEAKERS best ranked by a
-- hash of name and fact, the same ranking on every client that knows the same
-- hearers; else with chance 1 / (hearers + 1), so a fact whose best-ranked
-- hearers have left still goes on.
local function Elected(me, author, factKey, hearers)
  local mine = HashFrac(me .. "|" .. factKey)
  local ahead, count = 0, 0
  for i = 1, #hearers do
    local other = hearers[i]
    if type(other) == "string" and other ~= me and other ~= author then
      count = count + 1
      local score = HashFrac(other .. "|" .. factKey)
      if score < mine or (score == mine and other < me) then ahead = ahead + 1 end
    end
  end
  if ahead < SPEAKERS then return true end
  return HashFrac("#" .. me .. "|" .. factKey) < 1 / (count + 1)
end

local function PurgeHeld(now)
  for key, copy in pairs(heldCopies) do
    if now - copy.at > HOLD_TTL then
      heldCopies[key] = nil
      heldCount = heldCount - 1
    end
  end
end

local function Hold(key, packet, line, hops, via, now)
  if heldCopies[key] then return end
  if heldCount >= HOLD_MAX then
    PurgeHeld(now)
    if heldCount >= HOLD_MAX then return end
  end
  heldCopies[key] = { body = packet.body, line = line, hops = hops, via = via, at = now }
  heldCount = heldCount + 1
  Chain.held = Chain.held + 1
end

-- A critical line heard first-hand and delivered (modules/transport.lua):
-- `identity` its author, `chatType` where it was heard, `hearers` the Warfront
-- clients known there (guild peers or group mates; a number is read as their
-- count, with the older share rule).
function Chain:OnDirect(identity, parsed, chatType, hearers, now)
  now = now or Now()
  if type(identity) ~= "string" or type(parsed) ~= "table" or not Passable(parsed.id, parsed.data) then return false end
  local key = FactKey(identity, parsed.session, parsed.sequence, parsed.id)
  local fans = Fans(now)
  -- The known hearers of a guild or group line already have the fact: no
  -- whisper goes to them (decision 0077 § 5g).
  local heard
  if chatType ~= "WHISPER" and type(hearers) == "table" then
    heard = {}
    for i = 1, #hearers do
      if type(hearers[i]) == "string" then heard[hearers[i]] = true end
    end
  end
  -- A copy passed on to us earlier, now confirmed by the author's own line:
  -- it goes on from the hand it reached us at.
  local copy = heldCopies[key]
  if copy then
    heldCopies[key] = nil
    heldCount = heldCount - 1
    if copy.body == parsed.data and now - copy.at <= HOLD_TTL and copy.hops < MAX_HOPS and FirstPass(key, now) then
      self.released = self.released + 1
      return Forward(copy.line, copy.hops + 1, fans[copy.hops + 1], identity, copy.via, copy.via, identity, now,
        heard) > 0
    end
  end
  if chatType ~= "WHISPER" then
    local capture = WF.Capture
    local me = tostring(capture and capture.Me and capture:Me() or "")
    local factKey = identity .. "|" .. parsed.session .. ":" .. parsed.sequence
    local speak
    if type(hearers) == "table" then
      speak = Elected(me, identity, factKey, hearers)
    else
      local share = SPEAKERS / mathMax(1, tonumber(hearers) or 1)
      speak = share >= 1 or HashFrac(me .. "|" .. factKey) < share
    end
    if not speak then
      self.notElected = self.notElected + 1
      return false
    end
    self.elected = self.elected + 1
  end
  local relay = WF.Relay
  if not relay or type(relay.ChainLine) ~= "function" then return false end
  if not FirstPass(key, now) then return false end
  local line = relay.ChainLine(identity, parsed.session, parsed.sequence, parsed.id, parsed.data)
  if not line then return Reject("line") end
  return Forward(line, 1, fans[1], identity, identity, identity, nil, now, heard) > 0
end

-- An F line whispered by a guild peer or a contact (`via`, rule R1):
-- "<hops>,<relayed-line body>".
function Chain:OnForward(via, data, now)
  now = now or Now()
  self.received = self.received + 1
  local hopsText, rest = strMatch(type(data) == "string" and data or "", "^(%d),(.*)$")
  local hops = tonumber(hopsText)
  if not hops or hops < 0 or hops > MAX_HOPS then return Reject("hops") end
  local relay = WF.Relay
  if not relay or type(relay.ParseChainLine) ~= "function" or type(relay.AcceptChain) ~= "function" then
    return Reject("relay")
  end
  local packet, reason = relay.ParseChainLine(rest, now)
  if not packet then return Reject(reason or "packet") end
  if not Passable(packet.id, packet.body) then return Reject("kind") end
  -- A valid copy of a fact we already had by another path (a group
  -- rebroadcast, a guild line, the author's own line) is not applied again,
  -- but is still passed on once if we never did: the path that brought it may
  -- not pass things on.
  local accepted, duplicate, heard = relay:AcceptChain(packet, via, now)
  local key = FactKey(packet.identity, packet.session, packet.sequence, packet.id)
  if heard then
    -- The author's own line has not come yet: wait for it before passing on.
    if hops < MAX_HOPS then Hold(key, packet, relay.PacketLine(packet), hops, via, now) end
    return false
  end
  if not accepted and not duplicate then return false end
  if accepted then
    self.delivered = self.delivered + 1
    self.NoteSpread(tostring(hops), packet.stamp)
  end
  if hops < MAX_HOPS and FirstPass(key, now) then
    local fans = Fans(now)
    Forward(relay.PacketLine(packet), hops + 1, fans[hops + 1], packet.identity, via, via, packet.identity, now)
  end
  return true
end

-- A packet of the other faction a Battle.net link just delivered here
-- (modules/relay.lua, decision 0077 step 5): to the author's fan-out of
-- contacts, as hand 0. `via`: the link's character.
function Chain:OnBridged(packet, now, via)
  now = now or Now()
  if type(packet) ~= "table" or not Passable(packet.id, packet.body) then return false end
  if not FirstPass(FactKey(packet.identity, packet.session, packet.sequence, packet.id), now) then
    return false
  end
  local relay = WF.Relay
  if not relay or type(relay.PacketLine) ~= "function" then return false end
  self.bridged = (self.bridged or 0) + 1
  self.NoteSpread("bn", packet.stamp)
  local _, authorFan = Fans(now)
  return Forward(relay.PacketLine(packet), 0, authorFan, packet.identity, via or "battle.net",
    packet.identity, nil, now) > 0
end

function Chain:Summary()
  local parts = {}
  for reason, count in pairs(self.rejects) do parts[#parts + 1] = reason .. "=" .. count end
  table.sort(parts)
  return "chain forwarded=" .. self.forwarded .. " received=" .. self.received .. " delivered=" .. self.delivered
    .. " bridged=" .. (self.bridged or 0)
    .. " elected=" .. self.elected .. " notElected=" .. self.notElected .. " capped=" .. self.capped .. " noContact=" .. self.noContact
    .. " held=" .. self.held .. " released=" .. self.released
    .. " facts=" .. self.facts .. " perFact=" .. (self.facts > 0 and string.format("%.1f", self.forwarded / self.facts) or "0")
    .. " rejects " .. (#parts > 0 and table.concat(parts, " ") or "none")
end

-- "spread h1=3 (avg 2s, max 4s) bn=1 (avg 1s, max 1s)", hands in order.
function Chain:SpreadSummary()
  local parts = {}
  local keys = { "0", "1", "2", "3", "bn" }
  for i = 1, #keys do
    local row = self.spread[keys[i]]
    if row and row.n > 0 then
      parts[#parts + 1] = (keys[i] == "bn" and "bn" or ("h" .. keys[i])) .. "=" .. row.n
        .. " (avg " .. string.format("%.1f", row.sum / row.n) .. "s, max " .. row.max .. "s)"
    end
  end
  return "chain spread " .. (#parts > 0 and table.concat(parts, " ") or "none")
end
