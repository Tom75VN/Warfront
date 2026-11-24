local WF = Warfront

-- Online players of the other side (decision 0148).
--
-- The Warfront channel seems split by faction, so the Players tab never listed
-- the other faction. Each client sends every live Battle.net link (game link
-- or presence link of another ruleset) a summary of its own side, and a client
-- holding a fresh summary passes it once on its own channel:
--   * P (Battle.net kind), body "<seq>:<part>/<parts>:<entries>": our character
--     and the names the Players tab holds for our side, never a name learned
--     from the other side (one hop). Once per link after its hello, every
--     CADENCE s, and at most once per CHANGE_GAP s on change.
--   * PW (hidden channel line), body "<far faction>:<seq>:<part>/<parts>:<entries>":
--     the union of the summaries held from links of that far faction, after a
--     random SPREAD_MIN-SPREAD_MAX s, cancelled when a complete PW for that
--     faction was heard within SPREAD_QUIET s; one part per SPREAD_PACE s. A PW
--     is never sent on again.
--   * Entry "<encoded name>~<A|H|->~<record base 36|->", comma separated, at
--     most MAX_ENTRIES per summary and MAX_PARTS parts of PART_BYTES.
-- Display only: names here are claims (risk B94). They never become a contact,
-- a whisper target, a ticket, a score row or a realm memory, and reach no
-- gameplay rule. Bounded (R9): one held summary per link, MAX_ASSEMBLIES
-- assemblies (links and channel senders), MAX_SPREAD spread names; everything expires after EXPIRE s.
-- Order (R5, R8): a complete summary replaces the held one unless its sequence
-- is the same or slightly older (a late copy); a sender restarts from a random
-- sequence, so a reload is never taken for a late copy.

local Far = {
  sent = 0, summariesIn = 0, partsIn = 0, rejected = 0, stale = 0,
  spreads = 0, spreadParts = 0, spreadsIn = 0, cancelled = 0,
}
WF.FarPlayers = Far

local K = {
  MAX_ENTRIES = 120, MAX_PARTS = 16, PART_BYTES = 180, CADENCE = 300, CHANGE_GAP = 60, BUILD_GAP = 30,
  READ_GAP = 60, EXPIRE = 660, ASSEMBLY_TTL = 30, MAX_ASSEMBLIES = 12, MAX_SPREAD = 500,
  SPREAD_MIN = 5, SPREAD_MAX = 60, SPREAD_QUIET = 240, SPREAD_PACE = 2, LATE_WINDOW = 64,
  MAX_SEQ = 2176782335, TICK = 1,
}
Far.K = K

-- Labels as the Players tab shows them, for the records Warfront knows
-- (core/ruleset.lua RECORDS); any other record stays unlabelled.
local LABEL_OF_RECORD = { [14] = "PvP", [15] = "PvE", [16] = "RP", [18] = "RP-PvP" }
local RECORD_OF_LABEL = { PvP = 14, PvE = 15, RP = 16, ["RP-PvP"] = 18 }
local FACTION_OF_LETTER = { A = "Alliance", H = "Horde" }
local LETTER_OF_FACTION = { Alliance = "A", Horde = "H" }
local BASE36 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"

local held = {}         -- link id -> { faction, seq, entries = { name -> entry }, at }
local assemblies = {}   -- key -> { seq, parts, got, count, at }
local assemblyCount = 0
local spread = {}       -- name -> { faction, label, at }
local spreadCount = 0
local heardSpreadAt = {} -- far faction letter -> time a complete PW was heard or sent
local pending = {}      -- far faction letter -> { due } or { parts, index, nextAt, seq }
local linkSent = {}     -- link id -> { seq, at }
local out = { seq = nil, signature = nil, parts = nil, builtAt = nil, changedAt = nil }
local spreadSeq
local nextTickAt = 0

local function Now()
  return WF.Now and WF.Now() or (GetTime and GetTime()) or 0
end

local function Kit()
  local relay = WF.Relay
  return relay and relay.Kit or nil
end

local function Base36(value)
  value = math.floor(tonumber(value) or 0)
  if value <= 0 then return "0" end
  local text = ""
  while value > 0 do
    local digit = value % 36
    text = string.sub(BASE36, digit + 1, digit + 1) .. text
    value = math.floor(value / 36)
  end
  return text
end

local function NextSeq(seq)
  if not seq or seq >= K.MAX_SEQ then return math.random(1, 36 ^ 5) end
  return seq + 1
end

-- Strict entry list: at most `max` entries, valid names, no repeat.
function Far.ParseEntries(data, max)
  local kit = Kit()
  if not kit or type(data) ~= "string" or data == "" or #data > K.PART_BYTES then return nil end
  local list, seen = {}, {}
  for item in string.gmatch(data .. ",", "([^,]*),") do
    local encoded, letter, record = string.match(item, "^([%w%%]+)~([AH%-])~([0-9A-Z%-]+)$")
    if not encoded or #record > 3 then return nil end
    local name = kit.DecodeName(encoded)
    if not name or seen[name] then return nil end
    seen[name] = true
    local label = nil
    if record ~= "-" then
      if string.find(record, "%-") then return nil end
      label = LABEL_OF_RECORD[tonumber(record, 36)]
    end
    list[#list + 1] = { name = name, faction = FACTION_OF_LETTER[letter], label = label }
    if #list > max then return nil end
  end
  return list
end

-- "<seq>:<part>/<parts>:<entries>" -> seq, part, parts, entries, or nil.
function Far.ParseBody(body)
  if type(body) ~= "string" then return nil end
  local seqText, partText, partsText, data = string.match(body, "^([0-9A-Z]+):(%d+)/(%d+):(.*)$")
  if not seqText or #seqText > 6 or #partText > 2 or #partsText > 2 then return nil end
  local seq, part, parts = tonumber(seqText, 36), tonumber(partText), tonumber(partsText)
  if not seq or seq < 1 or part < 1 or parts < 1 or part > parts or parts > K.MAX_PARTS then return nil end
  local entries = Far.ParseEntries(data, K.MAX_ENTRIES)
  if not entries then return nil end
  return seq, part, parts, entries
end

-- Our side's entries packed into body parts of at most PART_BYTES:
-- "<seq>:<part>/<parts>:<entries>" (the PW prefix is added by the sender).
function Far.Pack(entries, seq)
  local kit = Kit()
  if not kit then return nil end
  local chunks, current, size = {}, {}, 0
  local seqText = Base36(seq)
  local room = K.PART_BYTES - #seqText - 7
  for i = 1, math.min(#entries, K.MAX_ENTRIES) do
    local entry = entries[i]
    local record = entry.label and RECORD_OF_LABEL[entry.label]
    local item = kit.EncodeName(entry.name) .. "~" .. (LETTER_OF_FACTION[entry.faction or ""] or "-")
      .. "~" .. (record and Base36(record) or "-")
    if #item <= room then
      if size > 0 and size + 1 + #item > room then
        if #chunks + 1 >= K.MAX_PARTS then break end
        chunks[#chunks + 1] = table.concat(current, ",")
        current, size = {}, 0
      end
      current[#current + 1] = item
      size = size + (size > 0 and 1 or 0) + #item
    end
  end
  if size > 0 then chunks[#chunks + 1] = table.concat(current, ",") end
  local parts = {}
  for i = 1, #chunks do parts[i] = seqText .. ":" .. i .. "/" .. #chunks .. ":" .. chunks[i] end
  return parts
end

-- A complete newer summary for `key`, or nil while parts are missing.
-- `current`: the sequence held for that key, if any.
local function Assemble(key, seq, part, parts, entries, current, now)
  if current and (seq == current or (seq < current and seq >= current - K.LATE_WINDOW)) then
    Far.stale = Far.stale + 1
    return nil
  end
  local asm = assemblies[key]
  if asm and (asm.seq ~= seq or asm.parts ~= parts or now - asm.at > K.ASSEMBLY_TTL) then
    if asm.seq > seq and asm.seq - seq <= K.LATE_WINDOW and now - asm.at <= K.ASSEMBLY_TTL then
      Far.stale = Far.stale + 1
      return nil
    end
    assemblies[key], assemblyCount, asm = nil, assemblyCount - 1, nil
  end
  if not asm then
    if assemblyCount >= K.MAX_ASSEMBLIES then
      local oldestKey, oldestAt
      for other, entry in pairs(assemblies) do
        if not oldestAt or entry.at < oldestAt then oldestKey, oldestAt = other, entry.at end
      end
      assemblies[oldestKey], assemblyCount = nil, assemblyCount - 1
    end
    asm = { seq = seq, parts = parts, got = {}, count = 0, at = now }
    assemblies[key], assemblyCount = asm, assemblyCount + 1
  end
  if asm.got[part] then return nil end
  asm.got[part], asm.count = entries, asm.count + 1
  if asm.count < parts then return nil end
  assemblies[key], assemblyCount = nil, assemblyCount - 1
  local merged, list = {}, {}
  for i = 1, parts do
    local got = asm.got[i]
    for j = 1, #got do
      local entry = got[j]
      if not merged[entry.name] and #list < K.MAX_ENTRIES then
        merged[entry.name] = entry
        list[#list + 1] = entry.name
      end
    end
  end
  return merged
end

local function SchedulePending(faction, now)
  if pending[faction] then return end
  local heardAt = heardSpreadAt[faction]
  if heardAt and now - heardAt < K.SPREAD_QUIET then return end
  pending[faction] = { due = now + K.SPREAD_MIN + math.random() * (K.SPREAD_MAX - K.SPREAD_MIN) }
end

-- A Battle.net summary part from link `id` (modules/relay_bnet.lua). True when
-- well formed (complete or not), false when malformed.
function Far:OnSummary(id, linkFaction, body, now)
  now = now or Now()
  if not FACTION_OF_LETTER[linkFaction or ""] then return false end
  local seq, part, parts, entries = Far.ParseBody(body)
  if not seq then
    self.rejected = self.rejected + 1
    return false
  end
  self.partsIn = self.partsIn + 1
  local current = held[id]
  local merged = Assemble("L:" .. tostring(id), seq, part, parts, entries, current and current.seq, now)
  if not merged then
    -- An unchanged summary keeps it fresh here and on our channel.
    if current and current.seq == seq then
      current.at = now
      SchedulePending(linkFaction, now)
    end
    return true
  end
  held[id] = { faction = linkFaction, seq = seq, entries = merged, at = now }
  self.summariesIn = self.summariesIn + 1
  SchedulePending(linkFaction, now)
  if WF.Players then WF.Players.dirty = true end
  return true
end

-- A PW line from `identity` on our hidden channel (modules/transport.lua).
function Far:OnLine(data, identity, now)
  now = now or Now()
  if type(data) ~= "string" or type(identity) ~= "string" then return false end
  local faction, body = string.match(data, "^([AH]):(.*)$")
  local seq, part, parts, entries
  if faction then seq, part, parts, entries = Far.ParseBody(body) end
  if not seq then
    self.rejected = self.rejected + 1
    return false
  end
  local merged = Assemble("C:" .. identity, seq, part, parts, entries, nil, now)
  if not merged then return true end
  self.spreadsIn = self.spreadsIn + 1
  heardSpreadAt[faction] = now
  if pending[faction] and pending[faction].due then
    pending[faction] = nil
    self.cancelled = self.cancelled + 1
  end
  for name, entry in pairs(merged) do
    if not spread[name] then
      if spreadCount >= K.MAX_SPREAD then
        local oldestName, oldestAt
        for other, row in pairs(spread) do
          if not oldestAt or row.at < oldestAt then oldestName, oldestAt = other, row.at end
        end
        spread[oldestName], spreadCount = nil, spreadCount - 1
      end
      spreadCount = spreadCount + 1
    end
    spread[name] = { faction = entry.faction, label = entry.label, at = now }
  end
  if WF.Players then WF.Players.dirty = true end
  return true
end

-- Link `id` dropped (modules/relay.lua DropLink): its summary, assembly and
-- send memory go at once, so a link formed again starts afresh.
function Far:OnLinkDropped(id)
  local key = "L:" .. tostring(id)
  if assemblies[key] then assemblies[key], assemblyCount = nil, assemblyCount - 1 end
  linkSent[id] = nil
  if held[id] then
    held[id] = nil
    if WF.Players then WF.Players.dirty = true end
  end
end

-- Every far player still fresh: { { name, faction, label } }, by name.
function Far:Entries(now)
  now = now or Now()
  local relay, list, seen = WF.Relay, {}, {}
  for id, summary in pairs(held) do
    local live = relay and type(relay.LinkLive) == "function" and relay:LinkLive(id, now)
    if not live or now - summary.at > K.EXPIRE then
      held[id] = nil
    else
      for name, entry in pairs(summary.entries) do
        if not seen[name] then
          seen[name] = true
          list[#list + 1] = { name = name, faction = entry.faction, label = entry.label }
        end
      end
    end
  end
  for name, row in pairs(spread) do
    if now - row.at > K.EXPIRE then
      spread[name], spreadCount = nil, spreadCount - 1
    elseif not seen[name] then
      seen[name] = true
      list[#list + 1] = { name = name, faction = row.faction, label = row.label }
    end
  end
  table.sort(list, function(a, b) return a.name < b.name end)
  return list
end

-- Our own side: our character first, then the names the Players tab read from
-- our channel roster (decision 0148 § 2; never a far name, a guild, group or
-- friend name heard elsewhere), each with what the tab knows of it.
local function OwnEntries(now)
  local players = WF.Players
  if not players then return nil end
  if not players.readAt or now - players.readAt >= K.READ_GAP then
    local ok, err = pcall(players.Read, players, now)
    if not ok and WF.RecordError then WF.RecordError("far players read", err) end
  end
  local me = players.me
  if type(me) ~= "string" then return nil end
  local capture, ruleset = WF.Capture, WF.Ruleset
  local letter = capture and type(capture.MyFaction) == "function" and capture:MyFaction() or nil
  local record = ruleset and type(ruleset.Scope) == "function" and ruleset:Scope(true) and ruleset.record or nil
  local list = { { name = me, faction = FACTION_OF_LETTER[letter or ""], label = LABEL_OF_RECORD[record or 0] } }
  local far, info, roster = players.far or {}, players.info or {}, players.roster or {}
  for i = 1, #(players.names or {}) do
    local name = players.names[i]
    if name ~= me and roster[name] and not far[name] and #list < K.MAX_ENTRIES then
      local entry = info[name]
      list[#list + 1] = { name = name, faction = entry and entry.faction or nil, label = entry and entry.ruleset or nil }
    end
  end
  return list
end

-- Our summary parts, rebuilt at most every BUILD_GAP s; a new sequence only
-- when the content changed.
local function Build(now)
  if out.builtAt and now - out.builtAt < K.BUILD_GAP then return out.parts end
  out.builtAt = now
  local entries = OwnEntries(now)
  if not entries then return out.parts end
  local keys = {}
  for i = 1, #entries do
    local entry = entries[i]
    keys[i] = entry.name .. "~" .. tostring(entry.faction) .. "~" .. tostring(entry.label)
  end
  local signature = table.concat(keys, ",")
  if signature ~= out.signature or not out.parts then
    out.seq = NextSeq(out.seq)
    out.signature, out.changedAt = signature, now
    out.parts = Far.Pack(entries, out.seq)
  end
  return out.parts
end

local function SendSummaries(now)
  local relay = WF.Relay
  if not relay or type(relay.PresenceTargets) ~= "function" or type(relay.SendPresence) ~= "function" then return end
  local targets = relay:PresenceTargets(now)
  if #targets > 0 then Build(now) end
  local live = {}
  for i = 1, #targets do
    local id = targets[i].id
    live[id] = true
    local last = linkSent[id]
    local due = not last or now - last.at >= K.CADENCE
    if not due and last.seq ~= out.seq and now - last.at >= K.CHANGE_GAP then due = true end
    -- The far client asked again (it started again): it holds nothing of ours.
    local asked = targets[i].askedAt
    if not due and asked and asked > last.at and now - last.at >= K.CHANGE_GAP then due = true end
    local parts = out.parts
    if due and parts and #parts > 0 then
      for part = 1, #parts do relay:SendPresence(id, part, parts[part], now) end
      linkSent[id] = { seq = out.seq, at = now }
      Far.sent = Far.sent + 1
    end
  end
  for id in pairs(linkSent) do
    if not live[id] then linkSent[id] = nil end
  end
end

-- The union of the summaries held from links of `faction`, as PW parts.
local function SpreadParts(faction, now)
  local relay, entries, seen = WF.Relay, {}, {}
  for id, summary in pairs(held) do
    local live = relay and type(relay.LinkLive) == "function" and relay:LinkLive(id, now)
    if live and summary.faction == faction and now - summary.at <= K.EXPIRE then
      for name, entry in pairs(summary.entries) do
        if not seen[name] then
          seen[name] = true
          entries[#entries + 1] = entry
        end
      end
    end
  end
  if #entries == 0 then return nil end
  table.sort(entries, function(a, b) return a.name < b.name end)
  spreadSeq = NextSeq(spreadSeq)
  local parts = Far.Pack(entries, spreadSeq)
  for i = 1, #parts do parts[i] = faction .. ":" .. parts[i] end
  return parts
end

local function Spread(now)
  local transport = WF.Transport
  if not transport or type(transport.SendFarPlayers) ~= "function" then return end
  for faction, job in pairs(pending) do
    if job.due then
      if now >= job.due then
        local heardAt = heardSpreadAt[faction]
        if heardAt and now - heardAt < K.SPREAD_QUIET then
          pending[faction] = nil
          Far.cancelled = Far.cancelled + 1
        else
          local parts = SpreadParts(faction, now)
          if parts then
            pending[faction] = { parts = parts, index = 1, nextAt = now }
            heardSpreadAt[faction] = now
            Far.spreads = Far.spreads + 1
          else
            pending[faction] = nil
          end
        end
      end
    elseif now >= job.nextAt then
      if transport:SendFarPlayers(job.index, job.parts[job.index]) then Far.spreadParts = Far.spreadParts + 1 end
      job.index, job.nextAt = job.index + 1, now + K.SPREAD_PACE
      if job.index > #job.parts then pending[faction] = nil end
    end
  end
end

function Far:Tick(now)
  if now < nextTickAt then return end
  nextTickAt = now + K.TICK
  SendSummaries(now)
  Spread(now)
end

function Far:Summary()
  local count = 0
  for _ in pairs(held) do count = count + 1 end
  return "far players links=" .. count .. " spread=" .. spreadCount .. " sent=" .. self.sent
    .. " summaries=" .. self.summariesIn .. " parts=" .. self.partsIn .. " spreads=" .. self.spreads .. "/"
    .. self.spreadsIn .. " cancelled=" .. self.cancelled .. " stale=" .. self.stale .. " rejected=" .. self.rejected
end

-- Wiring ------------------------------------------------------------------------------

if CreateFrame then
  local frame = CreateFrame("Frame", "WarfrontFarPlayersFrame", UIParent)
  frame:SetScript("OnUpdate", function()
    local ok, err = pcall(Far.Tick, Far, Now())
    if not ok and WF.RecordError then WF.RecordError("far players", err) end
  end)
end
