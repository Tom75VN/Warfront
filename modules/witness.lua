Warfront = Warfront or {}

local WF = Warfront
local Witness = {
  -- realm -> { [key] = true }, rebuilt from the saved entries (never saved itself).
  seen = {},
  recorded = 0,
  duplicates = 0,
  evicted = 0,
  refused = 0,
}

WF.Witness = Witness

-- Witness journal for the optional companion (decision 0031): what this client
-- itself accepted first-hand from the author (channel, group, guild or whisper,
-- decision 0077), never a relayed, chained or catch-up copy. Local
-- persistence only: nothing here is sent to other players or read back into the
-- shared state (rule R16). The sender is the chat event author normalized by
-- Capture.Identity (rule R1), never a message field.
local SCHEMA = 1
-- Bounded (rule R9): oldest first out; the Worker accepts 500 per batch.
local MAX_ENTRIES = 500
local MAX_SENDER = 64
local MAX_POI = 16
local MAX_GENERATION = 1000000
-- NEUTRAL: an Outpost this client set neutral after a failed siege (decision
-- 0098); read by the cloud owner ledger only, never capture evidence.
local KINDS = { CAPTURED = true, NEUTRAL = true }
local OWNERS = { H = true, A = true }
-- A CAPTURED entry's participants (decision 0126 § 3): the capturing faction's
-- players this client counted inside during the capture's last 60 seconds,
-- realm-free full names, sorted, at most MAX_PARTICIPANTS. Field `p`.
local MAX_PARTICIPANTS = 40

-- The valid, distinct participant names of a list, or nil when none.
local function Participants(list)
  if type(list) ~= "table" then return nil end
  local names, seen = {}, {}
  for index = 1, #list do
    local name = list[index]
    if type(name) == "string" and #name <= MAX_SENDER and not seen[name]
        and WF.Names and WF.Names.Valid(name) and WF.Names.Complete(name) then
      seen[name] = true
      names[#names + 1] = name
      if #names >= MAX_PARTICIPANTS then break end
    end
  end
  if #names == 0 then return nil end
  return names
end

Witness.MAX_ENTRIES = MAX_ENTRIES

local function Realm()
  if type(GetRealmName) ~= "function" then return "unknown" end
  local ok, realm = pcall(GetRealmName)
  if ok and type(realm) == "string" and realm ~= "" then return realm end
  return "unknown"
end

local function Record(kind, fields)
  if WF.Record then WF.Record(kind, fields) end
end

-- Generations restart with each campaign (decision 0103 § 3): the campaign
-- number is part of the key. Entries saved before campaigns count as 0.
local function Key(level, sender, kind, poi, generation, campaign)
  return level .. ":" .. (campaign or 0) .. ":" .. sender .. ":" .. kind .. ":" .. poi .. ":" .. generation
end

-- The running campaign number and start (0 and nil before campaigns).
-- The server epoch of a capture (decision 0149 § 3), nil when unknown. Local
-- storage only (field `at`), never on the wire; the companion sends it to the
-- cloud for display.
local function ServerTime()
  if type(GetServerTime) ~= "function" then return nil end
  local ok, value = pcall(GetServerTime)
  if not ok or type(value) ~= "number" or value < 1 or value > 4294967295 then return nil end
  return math.floor(value)
end

local function CurrentCampaign()
  local campaign = WF.Campaign
  if not campaign or type(campaign.Current) ~= "function" then return 0, nil end
  local n, s = campaign:Current()
  return n or 0, s
end

local function Sender(text)
  local names = WF.Names
  local sender = names and names.Short(text) or text
  if type(sender) == "string" and #sender <= MAX_SENDER and names
      and names.Valid(sender) and names.Complete(sender) then
    return sender
  end
end

-- The journal of this ruleset scope (decision 0072: the realm never partitions
-- it), or nil when SavedVariables are read-only or come from a newer schema
-- (left untouched), or the ruleset is not supported.
function Witness:Bucket()
  local bucket = WF.Ruleset and WF.Ruleset:Module("witness")
  if not bucket then return nil end
  if type(bucket.schema) == "number" and bucket.schema > SCHEMA then
    return nil
  end
  bucket.schema = SCHEMA
  if type(bucket.entries) ~= "table" then bucket.entries = {} end
  bucket.next = tonumber(bucket.next) or 0
  local scope = WF.Ruleset:Scope()
  local seen = self.seen[scope]
  if not seen or seen.bucket ~= bucket then
    seen = { bucket = bucket, keys = {} }
    self.seen[scope] = seen
    local entries = bucket.entries
    local i = 1
    while i <= #entries do
      local e = entries[i]
      local sender = type(e) == "table" and Sender(e.sender) or nil
      local key = sender and type(e.wf) == "number" and type(e.kind) == "string"
        and type(e.poi) == "string" and type(e.generation) == "number"
        and Key(e.wf, sender, e.kind, e.poi, e.generation, tonumber(e.campaign)) or nil
      if key and not seen.keys[key] then
        e.sender = sender
        seen.keys[key] = true
        if type(e.n) == "number" and e.n > bucket.next then bucket.next = e.n end
        i = i + 1
      else
        table.remove(entries, i)
      end
    end
    while #entries > MAX_ENTRIES do table.remove(entries, 1) end
  end
  return bucket, seen.keys
end

-- One observation, idempotent by (level, sender, kind, POI, generation): the
-- same message delivered twice, or reported again later, is stored once.
-- Returns true when a new entry was added.
-- owner: the faction code (H/A) the capture gave the POI, read by the cloud
-- owner ledger (decision 0060). The player's own captures are noted with the
-- player as sender: the Worker treats them as claims, never as witness reports.
-- participants: optional list of names counted inside (CAPTURED only).
function Witness:Note(sender, kind, poi, generation, owner, participants)
  -- Never a relayed packet (decision 0068): a bridge, not the server, wrote its
  -- origin. The player's own captures are still noted.
  local capture = WF.Capture
  if capture and capture.relayVia and sender ~= capture:Me() then
    self.refused = self.refused + 1
    return false
  end
  if Sender(sender) ~= sender or not KINDS[kind]
      or type(poi) ~= "string" or poi == "" or #poi > MAX_POI
      or type(generation) ~= "number" or generation < 1 or generation > MAX_GENERATION
      or generation ~= math.floor(generation)
      or (kind == "NEUTRAL" and owner ~= "N")
      or (kind ~= "NEUTRAL" and owner ~= nil and not OWNERS[owner]) then
    self.refused = self.refused + 1
    return false
  end
  local level = WF.channelLevel
  if type(level) ~= "number" then return false end
  local bucket, keys = self:Bucket()
  if not bucket then return false end
  local campaignNumber, campaignStart = CurrentCampaign()
  local key = Key(level, sender, kind, poi, generation, campaignNumber)
  if keys[key] then
    self.duplicates = self.duplicates + 1
    return false
  end
  bucket.next = bucket.next + 1
  table.insert(bucket.entries, {
    n = bucket.next, wf = level, version = WF.version,
    sender = sender, kind = kind, poi = poi, generation = generation, owner = owner,
    campaign = campaignNumber, campaignStart = campaignStart,
    p = kind == "CAPTURED" and Participants(participants) or nil,
    at = kind == "CAPTURED" and ServerTime() or nil,
  })
  keys[key] = true
  while #bucket.entries > MAX_ENTRIES do
    local old = table.remove(bucket.entries, 1)
    keys[Key(old.wf, old.sender, old.kind, old.poi, old.generation, tonumber(old.campaign))] = nil
    self.evicted = self.evicted + 1
  end
  self.recorded = self.recorded + 1
  Record("WITNESS", { sender = sender, kind = kind, id = poi, generation = generation })
  return true
end

function Witness:Count()
  local bucket = self:Bucket()
  if not bucket then return 0 end
  return #bucket.entries
end
