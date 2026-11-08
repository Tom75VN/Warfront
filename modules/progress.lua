Warfront = Warfront or {}

local WF = Warfront
local Progress = {
  refused = 0,
}

WF.Progress = Progress

-- Achievement progress of this account's own characters (docs/data-model.md,
-- decision 0031), read by the optional companion after logout. Local only:
-- never sent on the channel. One record per (character, campaignId,
-- achievementId), ordered by (correctionEpoch, value) so that only a higher
-- correction epoch, set by the server, can lower a value (C9, risk B20).
local SCHEMA = 1
local DEFAULT_CAMPAIGN = "permanent"
-- No eviction: a progress is never dropped; a new id over the bound is refused.
local MAX_ACHIEVEMENTS = 500
local MAX_CAMPAIGNS = 20
local MAX_ID = 64
local MAX_EPOCH = 1000000
local MAX_VALUE = 1000000000

Progress.DEFAULT_CAMPAIGN = DEFAULT_CAMPAIGN
Progress.MAX_ACHIEVEMENTS = MAX_ACHIEVEMENTS

local function Realm()
  if type(GetRealmName) ~= "function" then return "unknown" end
  local ok, realm = pcall(GetRealmName)
  if ok and type(realm) == "string" and realm ~= "" then return realm end
  return "unknown"
end

local function Record(kind, fields)
  if WF.Record then WF.Record(kind, fields) end
end

local function ValidId(text)
  return type(text) == "string" and text ~= "" and #text <= MAX_ID
    and not string.find(text, "[^%w_%.%-]")
end

local function ValidInt(value, maximum)
  return type(value) == "number" and value >= 0 and value <= maximum and value == math.floor(value)
end

local function Count(t)
  local n = 0
  for key in pairs(t) do n = n + 1 end
  return n
end

-- "Name@Realm" of the player, as Capture.Identity builds it.
function Progress:Me()
  if WF.Capture and WF.Capture.Me then return WF.Capture:Me() end
  local name = WF.Names and WF.Names.Mine()
  if name then return name .. "@" .. Realm() end
  return nil
end

-- The character table of `char` in this ruleset scope (decision 0072: the realm
-- never partitions it), or nil when SavedVariables are read-only or come from a
-- newer schema (left untouched), or the ruleset is not supported.
function Progress:Bucket(char)
  local bucket = WF.Ruleset and WF.Ruleset:Module("progress")
  if not bucket then return nil end
  if type(bucket.schema) == "number" and bucket.schema > SCHEMA then
    return nil
  end
  bucket.schema = SCHEMA
  if type(bucket.chars) ~= "table" then bucket.chars = {} end
  if WF.Names then WF.Names.Adopt(bucket.chars, char) end
  local entry = bucket.chars[char]
  if type(entry) ~= "table" then
    entry = {}
    bucket.chars[char] = entry
  end
  if type(entry.campaigns) ~= "table" then entry.campaigns = {} end
  entry.sequence = tonumber(entry.sequence) or 0
  return entry
end

-- Monotone merge of one value for the player. Idempotent: the same or an older
-- (correctionEpoch, value) changes nothing. Returns true when stored.
-- The correction epoch defaults to the imported one (decision 0032): a value of
-- an older epoch is refused, so it never rises again over a server correction.
function Progress:Set(achievementId, value, campaignId, correctionEpoch)
  campaignId = campaignId or DEFAULT_CAMPAIGN
  local floor = WF.Import and ValidId(campaignId) and WF.Import:Epoch(campaignId) or 0
  correctionEpoch = correctionEpoch or floor
  local char = self:Me()
  if not char or not ValidId(achievementId) or not ValidId(campaignId)
      or not ValidInt(value, MAX_VALUE) or not ValidInt(correctionEpoch, MAX_EPOCH)
      or correctionEpoch < floor then
    self.refused = self.refused + 1
    return false
  end
  local entry = self:Bucket(char)
  if not entry then return false end
  local campaign = entry.campaigns[campaignId]
  if type(campaign) ~= "table" then
    if Count(entry.campaigns) >= MAX_CAMPAIGNS then
      self.refused = self.refused + 1
      Record("PROGRESS_FULL", { campaign = campaignId })
      return false
    end
    campaign = {}
    entry.campaigns[campaignId] = campaign
  end
  local current = campaign[achievementId]
  if type(current) ~= "table" then
    if Count(campaign) >= MAX_ACHIEVEMENTS then
      self.refused = self.refused + 1
      Record("PROGRESS_FULL", { campaign = campaignId, id = achievementId })
      return false
    end
  else
    local epoch, old = tonumber(current.correctionEpoch) or 0, tonumber(current.value) or 0
    if correctionEpoch < epoch or (correctionEpoch == epoch and value <= old) then return false end
  end
  entry.sequence = entry.sequence + 1
  campaign[achievementId] = { correctionEpoch = correctionEpoch, value = value, sequence = entry.sequence }
  return true
end

-- value, correctionEpoch, source of the player: the (correctionEpoch, value)
-- merge of the local record and the import, which is never copied locally (C12).
function Progress:Get(achievementId, campaignId)
  campaignId = campaignId or DEFAULT_CAMPAIGN
  local char = self:Me()
  if not char then return nil end
  local entry = self:Bucket(char)
  local campaign = entry and entry.campaigns[campaignId]
  local current = type(campaign) == "table" and campaign[achievementId]
  local value, epoch, source
  if type(current) == "table" then value, epoch, source = current.value, current.correctionEpoch, "LOCAL" end
  local cloudValue, cloudEpoch
  if WF.Import then cloudValue, cloudEpoch = WF.Import:Progress(campaignId, achievementId) end
  if cloudValue and (not value or cloudEpoch > epoch or (cloudEpoch == epoch and cloudValue > value)) then
    value, epoch, source = cloudValue, cloudEpoch, "CLOUD_SYNCED"
  end
  return value, epoch, source
end
