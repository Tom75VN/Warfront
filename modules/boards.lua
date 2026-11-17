local WF = Warfront

-- Worker-signed scoreboards relayed between players (decision 0110). A player
-- with the companion receives the Worker's signed copy of the current boards in
-- the import; any client holding a verified copy offers it to its guild and
-- group, and a client with an older one asks for it. Display data only (R16):
-- a copy is shown only once its Ed25519 signature verifies against
-- data/ticket_keys.lua and its scope and region are ours (WFB2, WFB3 or WFB4,
-- decisions 0120, 0123 and 0126: one map per region); it never enters shared state.
--
-- Lines (each through Transport:SendBoard, the lowest lane: a board line
-- leaves only when no gameplay line waits, out of combat and instances):
--   BD c,<version>,<pieces>,<hash>   a holder's offer (login, new copy, at most every 30 min)
--   BQ c,<version>                   a request for that version
--   BP c,<version>,<hash>,<index>,<pieces>,<data>   one piece, one every 4 s at most
-- version is the Worker's own generatedAt, inside the signed text (base 36).
-- The pieces carry the blob "<signature>/<payload>"; hash and piece count are
-- the blob's, so a receiver rebuilds and verifies the copy alone.
local Boards = {
  -- [period] = { p, s, k, blob, v, h, n, content, campaign, ranks }: the newest
  -- verified copy of the current campaign ("c") and of History ("h").
  copies = {},
  pending = {},     -- payloads being verified, by hash (one per source at most)
  asks = {},        -- [audience][period] = { v, at }: our due requests
  offerAt = {},     -- [audience] = time of our next offers
  offerDue = {},    -- [audience][period] = true once offered in the current round
  sentAt = {},      -- [audience][period] = { content, at } of our last full copy there
  job = nil,        -- { audience, period, v, h, index, nextAt, startedAt }: the copy we are sending
  started = {},     -- times we started a full copy (COPY_MAX per COPY_EVERY)
  wanted = {},      -- [audience .. "|" .. period] = { audience, period, v, at }: requests waiting for the lane
  assembly = {},    -- [period] = { sender, v, h, n, parts, have, at }: the copy we receive
  importSeen = nil,
  loaded = false,
  counts = { offers = 0, asks = 0, pieces = 0, received = 0, verified = 0, invalid = 0, rejected = 0,
    sentPieces = 0, standDown = 0, expired = 0 },
}
WF.Boards = Boards

-- c: the current campaign's boards; h: History (every ended campaign summed).
local PERIODS = { c = true, h = true }
local MAX_PAYLOAD = 40000
local CHUNK = 160
local MAX_PIECES = 256
local LINE_EVERY = 4        -- seconds between two pieces we send
local COPY_EVERY = 1800     -- a full copy to one audience at most this often
-- History changes only at a campaign end and in the week after: at most once a
-- day per audience, and never when the boards are unchanged.
local COPY_EVERY_OF = { c = 1800, h = 86400 }
local OFFER_EVERY = 1800
local OFFER_FIRST = { 60, 120 }
local OFFER_SOON = { 10, 30 }
local ASK_DELAY = { 5, 20 }
local ANSWER_DELAY = { 1, 5 }
local ASSEMBLY_TTL = 900
local JOB_TTL = 1200
local OTHER_SENDER_QUIET = 30
-- Full copies we start, every audience together: at most COPY_MAX per COPY_EVERY.
local COPY_MAX = 2
local MAX_VALUE = 1000000000
local MOD = 2147483647
local STATS = {
  "capO", "capS", "capC", "defO", "defS", "defC", "conf", "kills", "assists", "deaths",
  "gold", "wood", "atkF", "atkR", "atkM", "garF", "garR", "garM",
}
local GUILD_STATS = {}
for i = 1, #STATS do if STATS[i] ~= "conf" then GUILD_STATS[#GUILD_STATS + 1] = STATS[i] end end
-- WFB3 (decision 0123 § 9): the WFB2 rows plus the War Camp counters capW and
-- defW at the end. Both versions stay readable.
local STATS3, GUILD_STATS3 = {}, {}
for i = 1, #STATS do STATS3[i] = STATS[i] end
for i = 1, #GUILD_STATS do GUILD_STATS3[i] = GUILD_STATS[i] end
STATS3[#STATS3 + 1], STATS3[#STATS3 + 2] = "capW", "defW"
GUILD_STATS3[#GUILD_STATS3 + 1], GUILD_STATS3[#GUILD_STATS3 + 2] = "capW", "defW"
-- WFB4 (decision 0126 § 6): the WFB3 rows plus atkS, the scouts sent, at the
-- end. WFB2 and WFB3 stay readable.
local STATS4, GUILD_STATS4 = {}, {}
for i = 1, #STATS3 do STATS4[i] = STATS3[i] end
for i = 1, #GUILD_STATS3 do GUILD_STATS4[i] = GUILD_STATS3[i] end
STATS4[#STATS4 + 1], GUILD_STATS4[#GUILD_STATS4 + 1] = "atkS", "atkS"
local HEADERS = { WFB2 = { STATS, GUILD_STATS }, WFB3 = { STATS3, GUILD_STATS3 }, WFB4 = { STATS4, GUILD_STATS4 } }
local LISTS = {
  pp = { "players", "points" }, pc = { "players", "confirmed" }, pk = { "players", "pvp" }, pe = { "players", "effort" },
  gp = { "guilds", "points" }, gk = { "guilds", "pvp" }, ge = { "guilds", "effort" },
}
local FACTIONS = { A = "Alliance", H = "Horde" }
Boards.CHUNK, Boards.LINE_EVERY, Boards.COPY_EVERY, Boards.MAX_PAYLOAD = CHUNK, LINE_EVERY, COPY_EVERY, MAX_PAYLOAD

local function Now() return WF.Now and WF.Now() or 0 end
local function Random(range) return range[1] + math.random() * (range[2] - range[1]) end

local function Record(kind, fields)
  if WF.Record then WF.Record(kind, fields) end
end

-- Parsing ----------------------------------------------------------------------------

-- Plain split that keeps empty fields.
local function Split(text, sep)
  local out, start = {}, 1
  while true do
    local i = string.find(text, sep, start, true)
    if not i then
      out[#out + 1] = string.sub(text, start)
      return out
    end
    out[#out + 1] = string.sub(text, start, i - 1)
    start = i + 1
  end
end

local function Base36(text, max)
  if type(text) ~= "string" or text == "" or #text > 8 or string.find(text, "[^0-9a-z]") then return nil end
  local n = tonumber(text, 36)
  if not n or n < 0 then return nil end
  if max and n > max then return nil end
  return n
end

-- ~XX (hex) back to bytes; nil on any other character outside the payload set.
local function Unescape(text)
  if string.find(text, "[^%w ._%-~]") then return nil end
  local bad = false
  local out = string.gsub(text, "~(.?.?)", function(hex)
    if not string.find(hex, "^%x%x$") then bad = true return "" end
    return string.char(tonumber(hex, 16))
  end)
  if bad then return nil end
  return out
end

-- Stats of a row: absent = 0; conf only when given. Larger sums are shown at the bound.
local function ReadStats(row, fields, first, keys)
  for i = 1, #keys do
    local text = fields[first + i - 1]
    if text ~= "" then
      local n = Base36(text)
      if not n then return false end
      row[keys[i]] = n > MAX_VALUE and MAX_VALUE or n
    end
  end
  return true
end

function Boards.Hash(text)
  local h = 0
  for i = 1, #text do h = (h * 31 + string.byte(text, i)) % MOD end
  return h
end

-- The copy's header and boards, or nil and why. scope: ours (another scope is refused).
-- payload = "WFB2/<scope>/<region b36>/<campaign>/<c|h>/<generatedAt b36>/<keyId>/<players>/<guilds>/<boards>"
-- (Worker boards.ts), WFB3 with the War Camp counters, or WFB4 with the scouts too. Only a copy of our
-- own map is read: its scope and region.
function Boards.Parse(payload, scope, region)
  if type(payload) ~= "string" or #payload > MAX_PAYLOAD or string.find(payload, "[^%w ._%-~,;=/]") then
    return nil, "format"
  end
  local parts = Split(payload, "/")
  local header = #parts == 10 and HEADERS[parts[1]]
  if not header then return nil, "header" end
  local STATS, GUILD_STATS = header[1], header[2]
  if parts[2] ~= scope then return nil, "scope" end
  if type(region) ~= "number" or region < 1 or region > 1000 or parts[3] ~= Boards.B36(region) then
    return nil, "region"
  end
  table.remove(parts, 3)
  if not PERIODS[parts[4]] then return nil, "header" end
  local period = parts[4]
  local campaign = Unescape(parts[3])
  if period == "h" then
    if campaign ~= "*" then return nil, "campaign" end
  elseif not campaign or campaign == "" or #campaign > 64 or not string.find(campaign, "^[%w_.%-]+$") then
    return nil, "campaign"
  end
  local version = Base36(parts[5])
  if not version or not string.find(parts[6], "^[0-9a-z]$") then return nil, "version" end
  local players, guilds = {}, {}
  if parts[7] ~= "" then
    local entries = Split(parts[7], ";")
    if #entries > 400 then return nil, "players" end
    for i = 1, #entries do
      local f = Split(entries[i], ",")
      if #f ~= 5 + #STATS then return nil, "player fields" end
      local name = Unescape(f[1])
      local names = WF.Names
      if not name or #name > 64 or not (names and names.Valid and names.Valid(name) and names.Complete(name)) then
        return nil, "player name"
      end
      local row = { char = name, region = Base36(f[2], 1000) }
      if not row.region or row.region < 1 then return nil, "player region" end
      if f[3] ~= "" then if #f[3] > 16 or not string.find(f[3], "^%u+$") then return nil, "class" end row.class = f[3] end
      if f[4] ~= "" then if #f[4] > 16 or not string.find(f[4], "^%a+$") then return nil, "race" end row.race = f[4] end
      if f[5] ~= "" then row.faction = FACTIONS[f[5]] if not row.faction then return nil, "faction" end end
      if not ReadStats(row, f, 6, STATS) then return nil, "player stats" end
      players[i] = row
    end
  end
  if parts[8] ~= "" then
    local entries = Split(parts[8], ";")
    if #entries > 300 then return nil, "guilds" end
    for i = 1, #entries do
      local f = Split(entries[i], ",")
      if #f ~= 4 + #GUILD_STATS then return nil, "guild fields" end
      if #f[1] > 16 or not string.find(f[1], "^[1-9]%d*$") then return nil, "guild id" end
      local row = { guild = f[1], region = Base36(f[2], 1000) }
      if not row.region or row.region < 1 then return nil, "guild region" end
      if f[3] ~= "" then
        local name = Unescape(f[3])
        if not name or #name > 64 or string.find(name, "[%c|]") then return nil, "guild name" end
        row.name = name
      end
      if f[4] ~= "" then row.faction = FACTIONS[f[4]] if not row.faction then return nil, "faction" end end
      if not ReadStats(row, f, 5, GUILD_STATS) then return nil, "guild stats" end
      guilds[i] = row
    end
  end
  local current = { campaign = campaign, players = {}, guilds = {} }
  local seen = 0
  local lists = Split(parts[9], ",")
  if #lists ~= 7 then return nil, "boards" end
  for i = 1, #lists do
    local _, _, code, items = string.find(lists[i], "^(%l%l)=(.*)$")
    local where = code and LISTS[code]
    if not where or current[where[1]][where[2]] then return nil, "board code" end
    local source = where[1] == "players" and players or guilds
    local list = {}
    if items ~= "" then
      local ids = Split(items, ".")
      if #ids > 100 then return nil, "board size" end
      for j = 1, #ids do
        local n = Base36(ids[j], 1000)
        local row = n and source[n + 1]
        if not row then return nil, "board index" end
        list[j] = row
      end
    end
    current[where[1]][where[2]] = list
    seen = seen + 1
  end
  if seen ~= 7 then return nil, "boards" end
  -- A cloud campaign "N.S" is the war record's key N, shown only while S is
  -- the running campaign's start (decisions 0103 § 4, 0104).
  local _, _, n, start = string.find(campaign, "^(%d+)%.(%d+)$")
  if n then
    current.campaign, current.start = n, tonumber(start)
  end
  if period == "h" then current.campaign = nil end
  -- The boards alone, without the Worker time or the key: a newer copy with
  -- the same boards is never sent nor verified again.
  local content = Boards.Hash(parts[7] .. "/" .. parts[8] .. "/" .. parts[9])
  return { period = period, version = version, keyId = parts[6], campaign = campaign, content = content, current = current }
end

-- Verification and the held copy -----------------------------------------------------

local function Scope()
  local ruleset = WF.Ruleset
  return ruleset and ruleset.Scope and ruleset:Scope(true) or nil
end

local function Region()
  local ruleset = WF.Ruleset
  return ruleset and ruleset.Region and ruleset:Region() or nil
end

local function Saved()
  local ruleset = WF.Ruleset
  return ruleset and ruleset.Module and ruleset:Module("boards") or nil
end

function Boards:Version(period)
  local copy = self.copies[period or "c"]
  return copy and copy.v or nil
end

-- The ranks of the newest verified copies, in the import's shape, or nil:
-- { current = ..., history = ..., version = <current's>, historyVersion = <History's> }.
function Boards:Ranks()
  local c, h = self.copies.c, self.copies.h
  if not c and not h then return nil end
  return { current = c and c.ranks or nil, history = h and h.ranks or nil,
    version = c and c.v or nil, historyVersion = h and h.v or nil }
end

local function Pieces(blob)
  return math.max(1, math.ceil(#blob / CHUNK))
end

function Boards:Accept(p, s, k, parsed, source)
  local now = Now()
  local period = parsed.period
  local old = self.copies[period]
  if old and (old.v >= parsed.version or old.content == parsed.content) then return false end
  local blob = s .. "/" .. p
  self.copies[period] = { p = p, s = s, k = k, blob = blob, v = parsed.version, h = Boards.Hash(blob), n = Pieces(blob),
    content = parsed.content, campaign = parsed.campaign, ranks = parsed.current }
  self.counts.verified = self.counts.verified + 1
  local saved = Saved()
  if saved then saved[period] = { p = p, s = s, k = k } end
  -- Offer the new copy soon to the audiences we have.
  for audience in pairs(self.offerAt) do self.offerAt[audience] = math.min(self.offerAt[audience], now + Random(OFFER_SOON)) end
  for _, asks in pairs(self.asks) do asks[period] = nil end
  Record("BOARDS", { source = source, period = period, version = parsed.version, pieces = self.copies[period].n })
  return true
end

-- Checks a candidate (import, saved copy or a copy received whole) and keeps it
-- once its signature verifies. A copy whose boards equal the held ones is not
-- verified again (its newer Worker time changes nothing shown).
function Boards:Consider(p, s, k, source)
  local parsed, why = Boards.Parse(p, Scope(), Region())
  if not parsed then
    self.counts.rejected = self.counts.rejected + 1
    return false, why
  end
  if parsed.keyId ~= k then return false, "key id" end
  local held = self.copies[parsed.period]
  if held and (held.v >= parsed.version or held.content == parsed.content) then return false, "not newer" end
  local h = Boards.Hash(p)
  if self.pending[h] then return false, "pending" end
  local ed, keys, ticket = WF.Ed25519, WF.TicketKeys, WF.Ticket
  local hex = type(keys) == "table" and type(keys.keys) == "table" and keys.keys[k] or nil
  local key = hex and ed and ed.FromHex(hex)
  local sig = type(s) == "string" and ed and ed.FromBase64Url(s)
  if not key or not sig or not ticket or type(ticket.Enqueue) ~= "function" then
    self.counts.invalid = self.counts.invalid + 1
    return false, "no key"
  end
  self.pending[h] = true
  local ok = ticket:Enqueue(key, p, sig, function(valid)
    self.pending[h] = nil
    if valid then
      self:Accept(p, s, k, parsed, source)
    else
      self.counts.invalid = self.counts.invalid + 1
    end
  end)
  if not ok then
    self.pending[h] = nil
    return false, "queue"
  end
  return true
end

-- Network ----------------------------------------------------------------------------

local function Send(audience, id, body, now)
  if now < (Boards.nextLineAt or 0) then return false end
  local transport = WF.Transport
  if not transport or type(transport.SendBoard) ~= "function" then return false end
  if transport:SendBoard(audience, id, body) ~= true then return false end
  Boards.nextLineAt = now + LINE_EVERY
  return true
end

local function Audiences()
  local transport = WF.Transport
  local out = {}
  if transport and transport.BoardAudiences then out = transport:BoardAudiences() end
  return out
end

function Boards:OnJoined(now, audience)
  if audience and not self.offerAt[audience] then self.offerAt[audience] = now + Random(OFFER_SOON) end
end

local function AsksOf(self, audience)
  local asks = self.asks[audience]
  if not asks then
    asks = {}
    self.asks[audience] = asks
  end
  return asks
end

function Boards:OnLine(id, data, sender, audience, now)
  local f
  if id == "BP" then
    -- The piece itself holds commas: the five header fields first, the rest whole.
    local _, _, period, v, h, i, n, piece = string.find(data, "^([ch]),(%w+),(%w+),(%w+),(%w+),(.+)$")
    if not period then return false end
    f = { period, v, h, i, n, piece }
  else
    f = Split(data, ",")
  end
  local period = f[1]
  if not PERIODS[period] then return false end
  local version = Base36(f[2])
  if not version then return false end
  local held = self.copies[period]
  local mine = held and held.v or -1
  if id == "BD" then
    if #f ~= 5 then return false end
    local content = Base36(f[5])
    if not content then return false end
    self.counts.offers = self.counts.offers + 1
    if version > mine and not (held and held.content == content) then
      local asks = AsksOf(self, audience)
      local ask = asks[period]
      local a = self.assembly[period]
      local flowing = a and a.v >= version and now - a.at < OTHER_SENDER_QUIET
      if not flowing and (not ask or ask.v < version) then asks[period] = { v = version, at = now + Random(ASK_DELAY) } end
    elseif version < mine and not (held and held.content == content) then
      -- Someone holds older boards: offer ours soon, once per OFFER_SOON window.
      local at = self.offerAt[audience]
      if not at or at > now + OFFER_SOON[2] then self.offerAt[audience] = now + Random(OFFER_SOON) end
    end
    return true
  elseif id == "BQ" then
    if #f ~= 2 then return false end
    self.counts.asks = self.counts.asks + 1
    local asks = self.asks[audience]
    if asks and asks[period] and asks[period].v <= version then asks[period] = nil end -- someone asked for us
    -- Kept until the lane is free (one per audience and period, bounded by them).
    if held and held.v == version then
      self.wanted[audience .. "|" .. period] = { audience = audience, period = period, v = version, at = now }
      self:StartJob(now)
    end
    return true
  elseif id == "BP" then
    local h, index, count = Base36(f[3]), Base36(f[4], MAX_PIECES - 1), Base36(f[5], MAX_PIECES)
    local piece = f[6]
    if not h or not index or not count or count < 1 or index >= count or #piece > CHUNK or piece == ""
        or string.find(piece, "[^%w ._%-~,;=/]") then
      return false
    end
    self.counts.pieces = self.counts.pieces + 1
    -- Another holder sends this copy here: the smaller name continues, we stand down.
    local job = self.job
    if job and job.audience == audience and job.period == period and job.v == version and job.h == h
        and sender < (WF.Capture and WF.Capture:Me() or "") then
      self.job = nil
      self.wanted[audience .. "|" .. period] = nil
      self.counts.standDown = self.counts.standDown + 1
    end
    if version <= mine then return true end
    local asks = self.asks[audience]
    if asks and asks[period] and asks[period].v <= version then asks[period] = nil end
    local a = self.assembly[period]
    if a and now - (a.startedAt or a.at) > ASSEMBLY_TTL + MAX_PIECES * LINE_EVERY then
      self.assembly[period], a = nil, nil
      self.counts.expired = self.counts.expired + 1
    end
    if not a or (now - a.at > OTHER_SENDER_QUIET
        and (a.sender ~= sender or a.v ~= version or a.h ~= h or a.n ~= count)) then
      a = { sender = sender, v = version, h = h, n = count, parts = {}, have = 0, at = now, startedAt = now }
      self.assembly[period] = a
    end
    if a.sender ~= sender or a.v ~= version or a.h ~= h or a.n ~= count then return true end
    if not a.parts[index + 1] then
      a.at = now -- Only new pieces extend the lease; unsigned versions cannot preempt it.
      a.parts[index + 1] = piece
      a.have = a.have + 1
    elseif a.parts[index + 1] ~= piece then
      self.assembly[period] = nil -- two different pieces for one place: not this copy
      return false
    end
    if a.have == a.n then
      self.assembly[period] = nil
      local blob = table.concat(a.parts)
      local _, _, sig, payload = string.find(blob, "^([%w%-_]+)/(.*)$")
      local parsed = payload and Boards.Parse(payload, Scope(), Region())
      local keyId = parsed and parsed.keyId
      if Boards.Hash(blob) ~= a.h or not sig or #sig ~= 86 or not keyId then
        self.counts.invalid = self.counts.invalid + 1
        return false
      end
      self.counts.received = self.counts.received + 1
      self:Consider(payload, sig, keyId, "relay")
    end
    return true
  end
  return false
end

-- Starts the next full copy a request waits for, the current campaign first,
-- within COPY_MAX per COPY_EVERY and each audience's own ceiling.
function Boards:StartJob(now)
  if self.job then return end
  local recent = 0
  for i = #self.started, 1, -1 do
    if now - self.started[i] < COPY_EVERY then recent = recent + 1 else table.remove(self.started, i) end
  end
  if recent >= COPY_MAX then return end
  local pick
  for key, w in pairs(self.wanted) do
    local held = self.copies[w.period]
    local sent = self.sentAt[w.audience] and self.sentAt[w.audience][w.period]
    if not held or held.v ~= w.v or now - w.at > JOB_TTL
        or (sent and sent.content == held.content and now - sent.at < COPY_EVERY_OF[w.period]) then
      self.wanted[key] = nil
    elseif not pick or (w.period == "c" and pick.period ~= "c") or (w.period == pick.period and w.at < pick.at) then
      pick = w
    end
  end
  if not pick then return end
  self.wanted[pick.audience .. "|" .. pick.period] = nil
  local held = self.copies[pick.period]
  self.job = { audience = pick.audience, period = pick.period, v = held.v, h = held.h, index = 0,
    nextAt = now + Random(ANSWER_DELAY), startedAt = now }
  self.started[#self.started + 1] = now
end

-- A piece of the copy, or nil past the end.
local function Piece(copy, index)
  if index >= copy.n then return nil end
  return string.sub(copy.blob, index * CHUNK + 1, (index + 1) * CHUNK)
end

function Boards.B36(n)
  local digits, s = "0123456789abcdefghijklmnopqrstuvwxyz", ""
  n = math.floor(n)
  repeat
    local r = n % 36
    s = string.sub(digits, r + 1, r + 1) .. s
    n = (n - r) / 36
  until n == 0
  return s
end

local ORDER = { "c", "h" }

function Boards:Tick(now)
  -- Sources: the companion import (when it changes), then our saved copies once,
  -- both only once our map (scope and region) is known.
  local import = WF.Import
  local data = import and import.status == "OK" and import.data or nil
  local mapKnown = Scope() and Region()
  if mapKnown and data ~= self.importSeen then
    local retry = false
    local boards = type(data) == "table" and type(data.boards) == "table" and data.boards or nil
    for _, period in ipairs(ORDER) do
      local c = boards and boards[period]
      if type(c) == "table" then
        local _, why = self:Consider(c.p, c.s, c.k, "import")
        if why == "queue" then retry = true end
      end
    end
    if not retry then self.importSeen = data end
  end
  if not self.loaded and mapKnown then
    local saved = Saved()
    local retry = not saved
    for _, period in ipairs(ORDER) do
      local c = saved and saved[period]
      if type(c) == "table" then
        local _, why = self:Consider(c.p, c.s, c.k, "saved")
        if why == "queue" then retry = true end
      end
    end
    if not retry then self.loaded = true end
  end
  for _, period in ipairs(ORDER) do
    local a = self.assembly[period]
    if a and (now - a.at > ASSEMBLY_TTL or now - (a.startedAt or a.at) > ASSEMBLY_TTL + MAX_PIECES * LINE_EVERY) then
      self.assembly[period] = nil
      self.counts.expired = self.counts.expired + 1
    end
  end
  local audiences = Audiences()
  for audience in pairs(audiences) do
    if not self.offerAt[audience] then self.offerAt[audience] = now + Random(OFFER_FIRST) end
  end
  for audience in pairs(self.offerAt) do
    if not audiences[audience] then
      self.offerAt[audience], self.asks[audience], self.sentAt[audience], self.offerDue[audience] = nil, nil, nil, nil
      self.wanted[audience .. "|c"], self.wanted[audience .. "|h"] = nil, nil
    end
  end
  local B36 = Boards.B36
  self:StartJob(now)
  -- One line per tick at most: the job's piece first, then a request, then an offer.
  local job = self.job
  if job then
    local copy = self.copies[job.period]
    if not copy or copy.v ~= job.v or not audiences[job.audience] or now - job.startedAt > JOB_TTL then
      self.job = nil
    elseif now >= job.nextAt then
      local piece = Piece(copy, job.index)
      if not piece then
        local sent = self.sentAt[job.audience] or {}
        sent[job.period] = { content = copy.content, at = now }
        self.sentAt[job.audience] = sent
        self.job = nil
      else
        local body = job.period .. "," .. B36(copy.v) .. "," .. B36(copy.h) .. "," .. B36(job.index) .. "," .. B36(copy.n) .. "," .. piece
        if Send(job.audience, "BP", body, now) then
          job.index = job.index + 1
          job.nextAt = now + LINE_EVERY
          self.counts.sentPieces = self.counts.sentPieces + 1
        end
      end
      return
    end
  end
  for audience, asks in pairs(self.asks) do
    for _, period in ipairs(ORDER) do
      local ask = asks[period]
      if ask and now >= ask.at then
        if Send(audience, "BQ", period .. "," .. B36(ask.v), now) then
          asks[period] = nil
          return
        end
      end
    end
  end
  for audience, at in pairs(self.offerAt) do
    if now >= at then
      -- One offer line per held copy, the current campaign first.
      local due = self.offerDue[audience] or {}
      self.offerDue[audience] = due
      for _, period in ipairs(ORDER) do
        local copy = self.copies[period]
        if copy and not due[period] then
          if Send(audience, "BD", period .. "," .. B36(copy.v) .. "," .. B36(copy.n) .. "," .. B36(copy.h) .. "," .. B36(copy.content), now) then
            due[period] = true
          end
          return
        end
      end
      self.offerAt[audience] = now + OFFER_EVERY
      self.offerDue[audience] = nil
      return
    end
  end
end

function Boards:Summary()
  local c = self.counts
  return "boards current=" .. tostring(self:Version("c") or "none") .. " history=" .. tostring(self:Version("h") or "none")
    .. " offers=" .. c.offers .. " asks=" .. c.asks .. " pieces=" .. c.pieces .. " received=" .. c.received
    .. " verified=" .. c.verified .. " invalid=" .. c.invalid .. " sent=" .. c.sentPieces .. " standDown=" .. c.standDown
end
