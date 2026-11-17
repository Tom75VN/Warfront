Warfront = Warfront or {}

local WF = Warfront
local Capture = WF.Capture
local Catchup = {
  joinedAt = nil,
  lastSeriesAt = nil,
  digestAt = nil,
  sentAt = nil,
  retries = 0,
  round = nil,
  pending = {},
  answeredAt = {},
  skipped = {},
  out = {},
  nextSendAt = 0,
  sendTries = 0,
  refreshCheckAt = 0,
  refreshes = 0,
  digests = 0,
  answers = 0,
  ignored = 0,
  -- Guild anti-entropy (decision 0077 step 3).
  onlineAt = nil,
  peers = {},
  peerCount = 0,
  pullTimes = {},
  replyTimes = {},
  repliedTo = {},
  lastPullAt = nil,
  pullCheckAt = 0,
  pulls = 0,
  replies = 0,
  series = 0,
  -- Battle.net links (decision 0081 § 1) and guild welcomes (§ 4).
  linkPulled = {},
  linkAsks = {},
  linkPullTimes = {},
  linkReplied = {},
  linkReplyTimes = {},
  linkPulls = 0,
  linkReplies = 0,
  linkHints = 0,
  welcomes = {},
  welcomeCount = 0,
  welcomeTimes = {},
  welcomed = 0,
}

WF.Catchup = Catchup

-- Owner catch-up after joining the channel (decision 0038). The joiner sends
-- one hash per map (OD); a peer whose hash differs sends that map's confirmed
-- owners (OL). Every OL entry is only a hint of its chat sender (Capture:NoteHint):
-- the registry moves only through the quorum. Values proposed, not measured.
local DIGEST_DELAY = 10
local SERIES_GAP = 60
local RETRY_DELAY = 30
local MAX_RETRIES = 2
local GROUPS_PER_DIGEST = 20
local MAX_DIGEST_PARTS = 3
local ENTRIES_PER_LINE = 10
local MAX_LINE_PARTS = 4
local SENIORITY = 300
local LOCAL_DELAY, LOCAL_SPREAD = 1, 2
local PEER_DELAY, PEER_SPREAD = 3, 3
-- Rule R14 with two answers: drop ours after two answers carrying our own
-- hash, or four answers of any hash, for that map.
local ANSWER_MATCHES = 2
local ANSWER_ANY = 4
-- Shorter than RETRY_DELAY, and a peer whose answer was dropped answers first
-- at the joiner's retry: retries bring the third sender quorum Q2 needs.
local ANSWER_GAP = 25
local SKIPPED_DELAY, SKIPPED_SPREAD = 0.5, 0.5
local LINES_PER_DIGEST = 12
local MAX_OUT = 24
local SEND_GAP = 1
local QUEUE_ROOM = 4
-- Decision 0066: a series due while this client may not talk yet (level
-- under 5) is held, never dropped; a send the queue refused
-- is tried again SEND_RETRY later, at most MAX_SEND_TRIES times.
local SEND_RETRY = 5
local MAX_SEND_TRIES = 12
-- Decision 0066: unconfirmed owners (hints) live 900 s (Capture HINT_TTL).
-- Once one still shown is REFRESH_AGE old, a new series (at most one per
-- REFRESH_GAP), so the same peers refresh it before it expires, even after a
-- lost answer, and newly arrived peers can confirm it.
local REFRESH_AGE = 600
local REFRESH_GAP = 120
local REFRESH_CHECK = 10
-- Decision 0077 step 3: a guild peer whose registry digest (carried by its NP
-- presence) differs from ours is asked by whisper: our OD digest, its OL
-- answer, both addressed. Each OL entry stays a hint (quorum unchanged).
-- One pull per PULL.GAP at most, PULL.PER_WINDOW per PULL.WINDOW; one peer is
-- asked again after FIRST s, then twice as long each time up to MAX, and from
-- FIRST again when its digest or ours changes. An addressed digest is answered
-- once per REPLY_GAP per asker, REPLIES_PER_WINDOW per PULL.WINDOW, and only
-- after SENIORITY online. Values proposed, not measured.
local PULL = {
  -- MAX stays under the hints' 900 s lifetime (Capture HINT_TTL): an owner
  -- still unconfirmed is refreshed before it fades (as decision 0066 does).
  GAP = 60, WINDOW = 600, PER_WINDOW = 4, FIRST = 60, MAX = 600,
  CHECK = 5, PEER_TTL = 1800, MAX_PEERS = 64, AFTER_PRESENCE = 15,
  REPLY_GAP = 60, REPLIES_PER_WINDOW = 6, MAX_REPLIED = 64,
}
Catchup.PULL = PULL
-- Decision 0081 § 1: a client with Battle.net links of the other faction asks
-- them for owners, FIRST s after a link appears, then each link every AGAIN s
-- (under the hints' 900 s lifetime), one ask per GAP s, PER_WINDOW per WINDOW.
-- Answers are accepted only from a link asked within ANSWER_WAIT s, MAX_LINES
-- lines per ask. A link is answered once per REPLY_GAP s for each digest part,
-- REPLIES_PER_WINDOW times per WINDOW, after SENIORITY online. Proposed values.
local LINK = {
  FIRST = 15, AGAIN = 600, GAP = 60, PER_WINDOW = 4, WINDOW = 600,
  ANSWER_WAIT = 120, MAX_LINES = 12, REPLY_GAP = 60, REPLIES_PER_WINDOW = 6, KEEP = 1800,
}
Catchup.LINK = LINK
-- Decision 0081 § 4: a senior client that first hears a peer whose digest
-- differs, holding at least as many owners, whispers it our presence after
-- DELAY..DELAY+SPREAD s with chance SPEAKERS / guild peers, PER_WINDOW times
-- per WINDOW, at most MAX waiting: the newcomer can pull at once instead of
-- waiting for the next presence (300 s or more). SPEAKERS 3: the senders a
-- quorum needs (Capture:Quorum).
local WELCOME = { SPEAKERS = 3, DELAY = 2, SPREAD = 6, PER_WINDOW = 4, WINDOW = 600, MAX = 8 }
Catchup.WELCOME = WELCOME
local HASH_MODULUS = 16777213
local EMPTY_HASH = "00000"
local DIGITS = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"

Catchup.SENIORITY = SENIORITY
Catchup.DIGEST_DELAY = DIGEST_DELAY
Catchup.REFRESH_AGE = REFRESH_AGE
Catchup.REFRESH_GAP = REFRESH_GAP

local function Now()
  return WF.Now and WF.Now() or 0
end

local function Floor(value)
  return math.floor(value)
end

local function Record(kind, fields)
  if WF.Record then WF.Record(kind, fields) end
end

-- A positive integer without leading zero, within bounds.
local function Int(text, minimum, maximum)
  if type(text) ~= "string" or not string.find(text, "^[1-9]%d*$") or #text > 7 then return nil end
  local value = tonumber(text)
  if not value or value < minimum or value > maximum then return nil end
  return value
end

local function Base36(value, width)
  local text = ""
  while value > 0 do
    local digit = value - Floor(value / 36) * 36
    text = string.sub(DIGITS, digit + 1, digit + 1) .. text
    value = Floor(value / 36)
  end
  while #text < width do text = "0" .. text end
  return text
end

local function IsCode(text)
  return type(text) == "string" and string.find(text, "^[0-9A-Z][0-9A-Z]$") ~= nil
end

local function IsHash(text)
  return type(text) == "string" and string.find(text, "^[0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z]$") ~= nil
end

-- "a,b,,c" -> { "a", "b", "", "c" }: the fields of a Battle.net body.
local function SplitFields(text)
  local parts, start = {}, 1
  while true do
    local position = string.find(text, ",", start, true)
    if not position then
      parts[#parts + 1] = string.sub(text, start)
      return parts
    end
    parts[#parts + 1] = string.sub(text, start, position - 1)
    start = position + 1
  end
end

local function IsPoi(text)
  return type(text) == "string" and string.find(text, "^[0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z]$") ~= nil
end

-- Capturable POIs grouped by map: the MM prefix of the id (decision 0038 makes
-- this exception to decision 0016). Codes and ids sorted.
function Catchup:Groups()
  local groups, codes = {}, {}
  local map = WF.Map
  if not map or type(map.order) ~= "table" then return groups, codes end
  for index = 1, #map.order do
    local id = map.order[index]
    if Capture:Capturable(id) then
      local code = string.sub(id, 1, 2)
      if not groups[code] then
        groups[code] = {}
        codes[#codes + 1] = code
      end
      groups[code][#groups[code] + 1] = id
    end
  end
  table.sort(codes)
  for code in pairs(groups) do table.sort(groups[code]) end
  return groups, codes
end

-- The confirmed registry only, never a hint: { id, generation, owner, source }.
-- An OL line keeps the 1,000,000 bound and is refused whole for one entry
-- above it, so a higher (only forged) generation is neither digested nor sent
-- (decision 0089).
function Catchup:Entries(ids)
  local entries = {}
  for index = 1, #(ids or {}) do
    local entry = Capture.owners[ids[index]]
    if entry and entry.generation and entry.generation >= 1 and entry.generation <= 1000000
        and (entry.owner == "H" or entry.owner == "A" or entry.owner == "N") then
      table.insert(entries, { id = ids[index], generation = entry.generation, owner = entry.owner,
        source = entry.source })
    end
  end
  return entries
end

-- h = (h * 31 + byte) mod 16777213 over "id:generation:owner;", base 36 on 5
-- characters; 00000 for an empty map, 00001 when a non-empty one hashes to 0.
function Catchup:Hash(ids)
  local entries = self:Entries(ids)
  if #entries == 0 then return EMPTY_HASH, entries end
  local h = 0
  for index = 1, #entries do
    local entry = entries[index]
    local text = entry.id .. ":" .. entry.generation .. ":" .. entry.owner .. ";"
    for position = 1, #text do
      h = h * 31 + string.byte(text, position)
      h = h - Floor(h / HASH_MODULUS) * HASH_MODULUS
    end
  end
  if h == 0 then h = 1 end
  return Base36(h, 5), entries
end

-- One digest of the whole confirmed registry, for the guild presence: the
-- same polynomial over "MM:hash;" for every map in order, and the number of
-- confirmed owners (00000 and 0 when there is none).
function Catchup:RegistryDigest()
  local groups, codes = self:Groups()
  local h, owned = 0, 0
  for index = 1, #codes do
    local code = codes[index]
    local hash, entries = self:Hash(groups[code])
    owned = owned + #entries
    local text = code .. ":" .. hash .. ";"
    for position = 1, #text do
      h = h * 31 + string.byte(text, position)
      h = h - Floor(h / HASH_MODULUS) * HASH_MODULUS
    end
  end
  if owned == 0 then return EMPTY_HASH, 0 end
  if h == 0 then h = 1 end
  return Base36(h, 5), owned
end

-- Channel join (modules/p2ptest.lua): one digest series 10 s later, at most one
-- series per minute. Seniority, needed to answer, restarts at each join.
function Catchup:OnJoined(now)
  now = now or Now()
  self.joinedAt = now
  return self:RequestSeries(now)
end

-- A digest series without a channel join (decision 0077 step 3): on entering
-- a group, whose members answer like the channel did. Same one-per-minute gap.
function Catchup:RequestSeries(now)
  now = now or Now()
  if self.lastSeriesAt and now - self.lastSeriesAt < SERIES_GAP then return false end
  self.lastSeriesAt = now
  self.digestAt = now + DIGEST_DELAY
  self.retries = 0
  self.sendTries = 0
  self.series = self.series + 1
  return true
end

-- Seniority counts from the channel join when there was one, else from login.
function Catchup:Senior(now)
  local since = self.joinedAt or self.onlineAt
  return since ~= nil and now - since >= SENIORITY
end

-- Returns the lines sent and the lines built. Nothing is recorded as sent
-- (round, retry clock) unless one line left.
-- The OD lines of our digest and our hash per map.
function Catchup:DigestBodies()
  local groups, codes = self:Groups()
  local count = #codes
  if count > GROUPS_PER_DIGEST * MAX_DIGEST_PARTS then count = GROUPS_PER_DIGEST * MAX_DIGEST_PARTS end
  local bodies, mine = {}, {}
  if count == 0 then return bodies, mine end
  local parts = Floor((count + GROUPS_PER_DIGEST - 1) / GROUPS_PER_DIGEST)
  local part = 1
  while part <= parts do
    local first = (part - 1) * GROUPS_PER_DIGEST + 1
    local last = math.min(count, part * GROUPS_PER_DIGEST)
    local fields = { part, parts, last - first + 1 }
    local index = first
    while index <= last do
      local code = codes[index]
      local hash = self:Hash(groups[code])
      mine[code] = hash
      fields[#fields + 1] = code
      fields[#fields + 1] = hash
      index = index + 1
    end
    bodies[#bodies + 1] = table.concat(fields, ",")
    part = part + 1
  end
  return bodies, mine
end

function Catchup:SendDigest(now)
  local bodies, mine = self:DigestBodies()
  local parts, count = #bodies, 0
  for _ in pairs(mine) do count = count + 1 end
  if parts == 0 then return 0, 0 end
  local round = { mine = mine, answers = {} }
  local sent = 0
  for index = 1, parts do
    if Capture:Send("OD", bodies[index]) then sent = sent + 1 end
  end
  if sent == 0 then return 0, parts end
  self.round = round
  self.sentAt = now
  self.digests = self.digests + 1
  Record("CATCHUP_DIGEST", { groups = count, parts = parts, retry = self.retries })
  return sent, parts
end

-- The age of the oldest unconfirmed owner (hint) still shown, or nil.
function Catchup:HintAge(now)
  local oldest
  for id in pairs(Capture.hints or {}) do
    local best = Capture:BestHint(id, now)
    if best and (not oldest or best.age > oldest) then oldest = best.age end
  end
  return oldest
end

-- Retry only while an answer seen still carries another hash than ours.
function Catchup:StillDiffers()
  if not self.round then return false end
  local groups = self:Groups()
  for code, hashes in pairs(self.round.answers) do
    local mine = self:Hash(groups[code])
    for hash in pairs(hashes) do
      if hash ~= mine then return true end
    end
  end
  return false
end

-- Incoming ---------------------------------------------------------------------

function Catchup:OnMessage(kind, parts, sender, now)
  if kind == "OD" then return self:OnDigestLine(parts, sender, now) end
  return self:OnAnswerLine(parts, sender, now)
end

-- OD <part>,<parts>,<n>,<MM>,<hash>,... : exactly 3 + 2n fields, codes increasing.
-- Capture.addressedFrom: the whisper sender while modules/transport.lua
-- delivers an addressed line (decision 0077 step 3), nil otherwise.
-- The { code, hash } list of a valid OD body, its part number, or nil.
function Catchup:ParseDigest(parts)
  local part = Int(parts[1], 1, MAX_DIGEST_PARTS)
  local total = Int(parts[2], 1, MAX_DIGEST_PARTS)
  local n = Int(parts[3], 1, GROUPS_PER_DIGEST)
  if not part or not total or not n or part > total or #parts ~= 3 + 2 * n then return nil end
  local list = {}
  local previous = ""
  local index = 1
  while index <= n do
    local code, hash = parts[2 + 2 * index], parts[3 + 2 * index]
    if not IsCode(code) or not IsHash(hash) or not (code > previous) then return nil end
    list[#list + 1] = { code = code, hash = hash }
    previous = code
    index = index + 1
  end
  return list, part
end

function Catchup:OnDigestLine(parts, sender, now)
  local list = self:ParseDigest(parts)
  if not list then return Capture:Reject("bad OD", sender) end
  if Capture.addressedFrom then
    self:OnAddressedDigest(sender, Capture.addressedFrom, list, now)
  else
    self:OnDigest(sender, list, now)
  end
  return true
end

-- Only a peer in the channel for SENIORITY seconds answers, for each map whose
-- hash differs and whose registry is not empty; LOCAL entries answer sooner.
function Catchup:OnDigest(sender, list, now)
  if not self:Senior(now) then return end
  local groups = self:Groups()
  local budget = LINES_PER_DIGEST
  for index = 1, #list do
    local code, theirs = list[index].code, list[index].hash
    local ids = groups[code]
    local answered = self.answeredAt[code]
    if ids and not self.pending[code] and not (answered and now - answered < ANSWER_GAP) then
      local mine, entries = self:Hash(ids)
      local count = #entries
      if mine ~= theirs and count > 0 then
        local lines = math.min(MAX_LINE_PARTS, Floor((count + ENTRIES_PER_LINE - 1) / ENTRIES_PER_LINE))
        if lines > budget then return end
        budget = budget - lines
        local hasLocal = false
        local entry = 1
        while entry <= count do
          if entries[entry].source == "LOCAL" then hasLocal = true end
          entry = entry + 1
        end
        local delay = hasLocal and LOCAL_DELAY + math.random() * LOCAL_SPREAD
          or PEER_DELAY + math.random() * PEER_SPREAD
        if self.skipped[code] then delay = SKIPPED_DELAY + math.random() * SKIPPED_SPREAD end
        self.pending[code] = { at = now + delay, hash = mine, any = {}, match = {}, anyCount = 0, matchCount = 0 }
      end
    end
  end
end

-- OL <MM>,<hash>,<part>,<parts>,<n>,<poi>,<generation>,<owner>,... : exactly
-- 5 + 3n fields. Validated whole before any effect (rule R2).
-- The map code, hash and { id, generation, owner } entries of a valid OL
-- body, or nil.
function Catchup:ParseAnswer(parts)
  local code, hash = parts[1], parts[2]
  local part = Int(parts[3], 1, MAX_LINE_PARTS)
  local total = Int(parts[4], 1, MAX_LINE_PARTS)
  local n = Int(parts[5], 1, ENTRIES_PER_LINE)
  if not IsCode(code) or not IsHash(hash) or not part or not total or not n or part > total
      or #parts ~= 5 + 3 * n then
    return nil
  end
  local entries = {}
  local index = 1
  while index <= n do
    local base = 3 + 3 * index
    local poi, generation, owner = parts[base], Int(parts[base + 1], 1, 1000000), parts[base + 2]
    -- N: an Outpost set neutral by a failed siege (decision 0098).
    if not IsPoi(poi) or not generation or (owner ~= "H" and owner ~= "A" and owner ~= "N") then return nil end
    entries[#entries + 1] = { id = poi, generation = generation, owner = owner }
    index = index + 1
  end
  return code, hash, entries
end

-- Each entry of one OL line as a hint of `sender`; returns the hints noted.
function Catchup:NoteEntries(code, entries, sender, now)
  local noted = 0
  for index = 1, #entries do
    local entry = entries[index]
    -- Another build of the same level may hold another catalog: skip, count.
    if string.sub(entry.id, 1, 2) == code and Capture:Capturable(entry.id) then
      if Capture:NoteHint(entry.id, sender, entry.owner, entry.generation, now) then noted = noted + 1 end
    else
      self.ignored = self.ignored + 1
    end
  end
  return noted
end

function Catchup:OnAnswerLine(parts, sender, now)
  local code, hash, entries = self:ParseAnswer(parts)
  if not code then return Capture:Reject("bad OL", sender) end

  self:SeeAnswer(code, hash, sender, now)
  if self.round and self.round.mine[code] then
    local hashes = self.round.answers[code] or {}
    local known = 0
    for seen in pairs(hashes) do known = known + 1 end
    if hashes[hash] or known < ANSWER_ANY then hashes[hash] = true end
    self.round.answers[code] = hashes
  end
  self:NoteEntries(code, entries, sender, now)
  return true
end

function Catchup:SeeAnswer(code, hash, sender, now)
  local pending = self.pending[code]
  if not pending then return end
  if not pending.any[sender] then
    pending.any[sender] = true
    pending.anyCount = pending.anyCount + 1
  end
  if hash == pending.hash and not pending.match[sender] then
    pending.match[sender] = true
    pending.matchCount = pending.matchCount + 1
  end
  if pending.matchCount >= ANSWER_MATCHES or pending.anyCount >= ANSWER_ANY then
    -- Dropped, not answered: free to answer, and first, at the next digest.
    self.pending[code] = nil
    self.skipped[code] = true
  end
end

-- Guild anti-entropy (decision 0077 step 3) --------------------------------------

local function Recent(times, now, window)
  while times[1] and now - times[1] >= window do table.remove(times, 1) end
  return #times
end

-- An OD whispered to us by a guild peer: its differing maps answered to it
-- alone, without the broadcast cancellation of rule R14 (nobody else hears it).
function Catchup:OnAddressedDigest(sender, replyTo, list, now)
  if not self:Senior(now) then return end
  local last = self.repliedTo[sender]
  if last and now - last < PULL.REPLY_GAP then return end
  if Recent(self.replyTimes, now, PULL.WINDOW) >= PULL.REPLIES_PER_WINDOW then return end
  local groups = self:Groups()
  local budget, queued = LINES_PER_DIGEST, 0
  for index = 1, #list do
    local code, theirs = list[index].code, list[index].hash
    local ids = groups[code]
    if ids then
      local mine, entries = self:Hash(ids)
      if mine ~= theirs and #entries > 0 then
        local lines = self:Lines(code)
        for line = 1, #lines do
          if budget > 0 and #self.out < MAX_OUT then
            self.out[#self.out + 1] = { body = lines[line].body, target = replyTo,
              key = "OL:" .. replyTo .. ":" .. code .. ":" .. line }
            budget, queued = budget - 1, queued + 1
          end
        end
      end
    end
  end
  if queued == 0 then return end
  self.replies = self.replies + 1
  self.replyTimes[#self.replyTimes + 1] = now
  self.repliedTo[sender] = now
  local count = 0
  for asker, at in pairs(self.repliedTo) do
    if now - at >= PULL.REPLY_GAP then self.repliedTo[asker] = nil else count = count + 1 end
  end
  if count > PULL.MAX_REPLIED then self.repliedTo = { [sender] = now } end
end

-- A guild peer's presence: its registry digest and owner count
-- (modules/transport.lua). `target` is the whisper name the event gave.
function Catchup:OnPeerDigest(identity, target, digest, owned, now)
  if type(identity) ~= "string" or type(target) ~= "string" or type(digest) ~= "string" then return end
  local row = self.peers[identity]
  if not row then
    if self.peerCount >= PULL.MAX_PEERS then
      local oldest, oldestAt
      for other, entry in pairs(self.peers) do
        if not oldestAt or entry.at < oldestAt then oldest, oldestAt = other, entry.at end
      end
      if oldest then
        self.peers[oldest] = nil
        self.peerCount = self.peerCount - 1
      end
    end
    row = { tries = 0, nextAt = 0 }
    self.peers[identity] = row
    self.peerCount = self.peerCount + 1
    self:MaybeWelcome(identity, target, digest, owned or 0, now)
  end
  if row.digest ~= digest then row.tries, row.nextAt = 0, 0 end
  row.target, row.digest, row.owned, row.at = target, digest, owned or 0, now
end

-- A peer heard for the first time (decision 0081 § 4): about SPEAKERS senior
-- clients that hold at least as many owners whisper it our presence soon.
function Catchup:MaybeWelcome(identity, target, digest, owned, now)
  if not self:Senior(now) or self.welcomes[identity] or self.welcomeCount >= WELCOME.MAX then return false end
  local mine, mineOwned = self:RegistryDigest()
  if digest == mine or mineOwned == 0 or mineOwned < owned then return false end
  local hearers = 1
  local transport = WF.Transport
  if transport and type(transport.Hearers) == "function" then
    local ok, list = pcall(transport.Hearers, transport, "GUILD", now)
    if ok and type(list) == "table" and #list > hearers then hearers = #list end
  end
  if math.random() >= WELCOME.SPEAKERS / hearers then return false end
  self.welcomes[identity] = { target = target, at = now + WELCOME.DELAY + math.random() * WELCOME.SPREAD }
  self.welcomeCount = self.welcomeCount + 1
  return true
end

-- Due welcomes, within PER_WINDOW per WINDOW; one held back is dropped.
function Catchup:SendWelcomes(now)
  for identity, welcome in pairs(self.welcomes) do
    if now >= welcome.at then
      self.welcomes[identity] = nil
      self.welcomeCount = self.welcomeCount - 1
      local transport = WF.Transport
      if Recent(self.welcomeTimes, now, WELCOME.WINDOW) < WELCOME.PER_WINDOW and Capture:CanTalk()
          and transport and type(transport.SendPresenceTo) == "function" then
        local ok, sent = pcall(transport.SendPresenceTo, transport, welcome.target)
        if ok and sent then
          self.welcomeTimes[#self.welcomeTimes + 1] = now
          self.welcomed = self.welcomed + 1
        end
      end
    end
  end
end

-- A whisper to `target` came back "no player named" (modules/transport.lua):
-- that peer is forgotten until its next presence.
function Catchup:NoteUnreachable(target, now)
  if type(target) ~= "string" then return end
  local lowered = string.lower(target)
  for identity, row in pairs(self.peers) do
    if row.target and string.lower(row.target) == lowered then
      self.peers[identity] = nil
      self.peerCount = self.peerCount - 1
    end
  end
end

-- At most one addressed pull per call: the peer least asked, then the one
-- asked longest ago, whose digest differs from ours and who holds owners.
function Catchup:MaybePull(now)
  if self.lastPullAt and now - self.lastPullAt < PULL.GAP then return false end
  if Recent(self.pullTimes, now, PULL.WINDOW) >= PULL.PER_WINDOW then return false end
  if not Capture:CanTalk() then return false end
  -- Peers answer only a client they heard: wait until our own NP presence left.
  local transport = WF.Transport
  if not transport or not transport.presenceAt or now - transport.presenceAt < PULL.AFTER_PRESENCE then return false end
  local mine, mineOwned = self:RegistryDigest()
  -- A peer announcing more owners than us likely holds what we miss: asked
  -- first (decision 0081 § 4). The digest itself says nothing of direction.
  local function Ahead(row, other)
    local a, b = row.owned > mineOwned, other.owned > mineOwned
    if a ~= b then return a end
    if row.tries ~= other.tries then return row.tries < other.tries end
    return (row.pulledAt or 0) < (other.pulledAt or 0)
  end
  local best
  for identity, row in pairs(self.peers) do
    if now - row.at > PULL.PEER_TTL then
      self.peers[identity] = nil
      self.peerCount = self.peerCount - 1
    else
      if row.mine and row.mine ~= mine then row.tries, row.nextAt = 0, 0 end
      if row.owned > 0 and row.digest ~= mine and now >= row.nextAt and (not best or Ahead(row, best)) then
        best = row
      end
    end
  end
  if not best then return false end
  local bodies = self:DigestBodies()
  if #bodies == 0 then return false end
  local sent = 0
  for index = 1, #bodies do
    if Capture:SendTo(best.target, "OD", bodies[index]) then sent = sent + 1 end
  end
  best.tries = best.tries + 1
  best.nextAt = now + math.min(PULL.MAX, PULL.FIRST * 2 ^ (best.tries - 1))
  best.mine, best.pulledAt = mine, now
  if sent == 0 then return false end
  self.lastPullAt = now
  self.pullTimes[#self.pullTimes + 1] = now
  self.pulls = self.pulls + 1
  Record("CATCHUP_PULL", { parts = sent, tries = best.tries })
  return true
end

-- Owner catch-up with Battle.net links (decision 0081 § 1) ----------------------

local function LinkRelay()
  local relay = WF.Relay
  if relay and type(relay.CatchupLinks) == "function" and type(relay.SendCatchup) == "function" then return relay end
  return nil
end

-- At most one ask per call: a link never asked, else the one asked longest
-- ago, once it is due.
function Catchup:MaybePullLink(now)
  local relay = LinkRelay()
  if not relay or not Capture:CanTalk() then return false end
  if self.linkPullAt and now - self.linkPullAt < LINK.GAP then return false end
  if Recent(self.linkPullTimes, now, LINK.WINDOW) >= LINK.PER_WINDOW then return false end
  local ok, list = pcall(relay.CatchupLinks, relay, now)
  if not ok or type(list) ~= "table" then return false end
  for id, at in pairs(self.linkPulled) do
    if now - at > LINK.KEEP then self.linkPulled[id], self.linkAsks[id] = nil, nil end
  end
  local best, bestLast
  for index = 1, #list do
    local link = list[index]
    local last = self.linkPulled[link.id]
    local due = last and (last + LINK.AGAIN) or ((link.firstAt or now) + LINK.FIRST)
    if now >= due and (not best or (last or -1) < (bestLast or -1)) then best, bestLast = link, last end
  end
  if not best then return false end
  local bodies = self:DigestBodies()
  if #bodies == 0 then return false end
  local sent = 0
  for index = 1, #bodies do
    local okSend, queued = pcall(relay.SendCatchup, relay, best.id, "D", bodies[index], "D" .. index, now)
    if okSend and queued then sent = sent + 1 end
  end
  if sent == 0 then return false end
  self.linkPulled[best.id] = now
  self.linkAsks[best.id] = { at = now, lines = 0 }
  self.linkPullAt = now
  self.linkPullTimes[#self.linkPullTimes + 1] = now
  self.linkPulls = self.linkPulls + 1
  Record("CATCHUP_LINK_PULL", { parts = sent })
  return true
end

-- A D digest from link `id` (modules/relay.lua): our differing maps go back
-- to that link alone.
function Catchup:OnLinkDigest(id, identity, rest, now)
  local list, part = self:ParseDigest(type(rest) == "string" and SplitFields(rest) or {})
  if not list then return Capture:Reject("bad link OD", identity) end
  local relay = LinkRelay()
  if not relay or not self:Senior(now) then return false end
  local key = tostring(id) .. ":" .. part
  local last = self.linkReplied[key]
  if last and now - last < LINK.REPLY_GAP then return false end
  if Recent(self.linkReplyTimes, now, LINK.WINDOW) >= LINK.REPLIES_PER_WINDOW then return false end
  local groups = self:Groups()
  local budget, queued = LINK.MAX_LINES, 0
  for index = 1, #list do
    local code, theirs = list[index].code, list[index].hash
    local ids = groups[code]
    if ids then
      local mine, entries = self:Hash(ids)
      if mine ~= theirs and #entries > 0 then
        local lines = self:Lines(code)
        for line = 1, #lines do
          if budget > 0 then
            local ok, accepted = pcall(relay.SendCatchup, relay, id, "O", lines[line].body, lines[line].key, now)
            if ok and accepted then budget, queued = budget - 1, queued + 1 end
          end
        end
      end
    end
  end
  if queued == 0 then return true end
  for other, at in pairs(self.linkReplied) do
    if now - at >= LINK.REPLY_GAP then self.linkReplied[other] = nil end
  end
  self.linkReplied[key] = now
  self.linkReplyTimes[#self.linkReplyTimes + 1] = now
  self.linkReplies = self.linkReplies + 1
  return true
end

-- An O line from link `id`: only an answer to our own recent ask, each entry
-- one hint of the link's character (rule R1: Battle.net names it).
function Catchup:OnLinkAnswer(id, identity, rest, now)
  local code, _, entries = self:ParseAnswer(type(rest) == "string" and SplitFields(rest) or {})
  if not code then return Capture:Reject("bad link OL", identity) end
  local ask = self.linkAsks[id]
  if not ask or now - ask.at > LINK.ANSWER_WAIT then return Capture:Reject("unasked link OL", identity) end
  if ask.lines >= LINK.MAX_LINES then return Capture:Reject("link OL flood", identity) end
  ask.lines = ask.lines + 1
  self.linkHints = self.linkHints + self:NoteEntries(code, entries, identity, now)
  return true
end

-- Outgoing ---------------------------------------------------------------------

-- The confirmed owners of one map, ten per line, four lines at most.
function Catchup:Lines(code)
  local groups = self:Groups()
  local hash, entries = self:Hash(groups[code])
  local count = math.min(#entries, ENTRIES_PER_LINE * MAX_LINE_PARTS)
  if count == 0 then return {} end
  local parts = Floor((count + ENTRIES_PER_LINE - 1) / ENTRIES_PER_LINE)
  local lines = {}
  local part = 1
  while part <= parts do
    local first = (part - 1) * ENTRIES_PER_LINE + 1
    local last = math.min(count, part * ENTRIES_PER_LINE)
    local fields = { code, hash, part, parts, last - first + 1 }
    local index = first
    while index <= last do
      local entry = entries[index]
      fields[#fields + 1] = entry.id
      fields[#fields + 1] = entry.generation
      fields[#fields + 1] = entry.owner
      index = index + 1
    end
    lines[#lines + 1] = { body = table.concat(fields, ","), key = "OL:" .. code .. ":" .. part }
    part = part + 1
  end
  return lines
end

local function QueueRoom()
  local queue = WF.SendQueue
  if not queue or type(queue.Pending) ~= "function" then return true end
  return queue:Pending() < QUEUE_ROOM
end

function Catchup:Tick(now)
  if not self.onlineAt then self.onlineAt = now end
  if now >= self.pullCheckAt then
    self.pullCheckAt = now + PULL.CHECK
    self:MaybePull(now)
    self:MaybePullLink(now)
  end
  if self.welcomeCount > 0 then self:SendWelcomes(now) end
  if self.digestAt and now >= self.digestAt then
    -- Held while this client may not talk: it leaves as soon as it can.
    if Capture:CanTalk() then
      local sent, parts = self:SendDigest(now)
      if sent > 0 or parts == 0 or self.sendTries >= MAX_SEND_TRIES then
        self.digestAt, self.sendTries = nil, 0
      else
        self.sendTries = self.sendTries + 1
        self.digestAt = now + SEND_RETRY
      end
    end
  elseif self.sentAt and now - self.sentAt >= RETRY_DELAY then
    if self.retries < MAX_RETRIES and self:StillDiffers() then
      if Capture:CanTalk() then
        self.retries = self.retries + 1
        self:SendDigest(now)
      end
    else
      self.sentAt = nil
    end
  elseif self.lastSeriesAt and now >= self.refreshCheckAt and now - self.lastSeriesAt >= REFRESH_GAP then
    self.refreshCheckAt = now + REFRESH_CHECK
    local age = self:HintAge(now)
    if age and age >= REFRESH_AGE and Capture:CanTalk() then
      self.refreshes = self.refreshes + 1
      self.lastSeriesAt = now
      self.digestAt = now
      self.retries = 0
      self.sendTries = 0
    end
  end

  for code, pending in pairs(self.pending) do
    if now >= pending.at then
      self.pending[code] = nil
      self.skipped[code] = nil
      self.answeredAt[code] = now
      local lines = self:Lines(code)
      local index = 1
      while index <= #lines and #self.out < MAX_OUT do
        self.out[#self.out + 1] = lines[index]
        index = index + 1
      end
    end
  end

  -- One OL per second, only while the send queue has room: catch-up never
  -- delays a capture state (rule R13); its key makes it dropped first.
  if #self.out > 0 and now >= self.nextSendAt and QueueRoom() then
    local line = table.remove(self.out, 1)
    local sent
    if line.target then
      sent = Capture:SendTo(line.target, "OL", line.body, line.key)
    else
      sent = Capture:Send("OL", line.body, line.key)
    end
    if sent then self.answers = self.answers + 1 end
    self.nextSendAt = now + SEND_GAP
  end
end

-- Seconds since another Warfront player was last heard (a capture line, or a
-- guild peer's or contact's presence), or nil (decision 0081 § 2).
function Catchup:NewsAge(now)
  local newest = Capture.heardAt
  for _, row in pairs(self.peers) do
    if row.at and (not newest or row.at > newest) then newest = row.at end
  end
  if not newest then return nil end
  return math.max(0, now - newest)
end

-- Whether war news reach us now: a player heard within NEWS_LIVE s, or a live
-- Battle.net link. Replaces the channel join, unused since decision 0075.
local NEWS_LIVE = 600
Catchup.NEWS_LIVE = NEWS_LIVE
function Catchup:NewsLive(now)
  local age = self:NewsAge(now)
  if age and age <= NEWS_LIVE then return true, age end
  local relay = WF.Relay
  if relay and type(relay.LinkCount) == "function" then
    local ok, links = pcall(relay.LinkCount, relay, now)
    if ok and type(links) == "number" and links > 0 then return true, age end
  end
  return false, age
end

-- The Synchronization dot (2026-11-15): "live" when a player was heard within
-- NEWS_LIVE s; "quiet" when only a Battle.net link is up (reachable, nothing
-- recent); "waiting" otherwise. Returns the state and the news age (or nil).
function Catchup:NewsState(now)
  local live, age = self:NewsLive(now)
  if age and age <= NEWS_LIVE then return "live", age end
  if live then return "quiet", age end
  return "waiting", age
end

function Catchup:Summary()
  local pending = 0
  for code in pairs(self.pending) do pending = pending + 1 end
  return "catch-up digests=" .. self.digests .. " answers=" .. self.answers .. " pending=" .. pending
    .. " queued=" .. #self.out .. " ignored=" .. self.ignored .. " promoted=" .. Capture.promoted
    .. " held=" .. (self.digestAt and "yes" or "no") .. " refreshes=" .. self.refreshes
    .. " series=" .. self.series .. " guildPeers=" .. self.peerCount .. " pulls=" .. self.pulls
    .. " addressedReplies=" .. self.replies .. " welcomed=" .. self.welcomed
    .. " linkPulls=" .. self.linkPulls .. " linkReplies=" .. self.linkReplies .. " linkHints=" .. self.linkHints
end
