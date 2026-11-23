Warfront = Warfront or {}

local WF = Warfront

WF.Ruleset = WF.Ruleset or {}
local Ruleset = WF.Ruleset

-- Ruleset scope (decisions 0072 and 0143) and map (decision 0120). The scope is
-- chosen by the client's game-mode record
-- (C_GameRules.GetCurrentGameModeRecordID(), measured 14 = PvP and
-- 15 = Normal/PvE on 2026-11-07, 16 = RP and 18 = RP-PvP on 2026-11-23): PVP,
-- NORMAL, then R<record> for every later ruleset. Any other record (Hardcore,
-- unknown) disables Warfront with one notice. Shared gameplay is partitioned by
-- map: the scope and the commercial region (GetCurrentRegion()). While the
-- region is unknown the scope stays unresolved: nothing is written, sent or
-- imported. The realm name, realm id and the character's surname never decide
-- anything: they are bounded diagnostic metadata for the companion and the cloud,
-- optional since decision 0137.
--
-- SavedVariables, read by the companion (contract v2, docs/companion.md):
--   WarfrontDB.scopeSchema = 2
--   WarfrontDB.scopes["<region>:<SCOPE>"] = { context = { scope, rulesetRecord,
--     regionId, regionName, realmId, realmName, normalizedRealmName,
--     clientVersion, build, interface }, <module> = { ... } }
-- scopeSchema 1 kept one bucket per scope, scopes[SCOPE]. It is copied once
-- into the map of its recorded region, in a session of that region, and kept
-- untouched as an archive; a bucket without a valid recorded region is never
-- copied. Realm-keyed buckets of older builds stay in their module tables as an
-- archive too; nothing is deleted or merged (rule R7).

local SCHEMA = 2
local LEGACY_SCHEMA = 1
local RECORDS = { [14] = "PVP", [15] = "NORMAL", [16] = "R16", [18] = "R18" }
local SCOPES = {}
for _, scope in pairs(RECORDS) do SCOPES[scope] = true end
local MAX_REGION = 1000
local MAX_TEXT = 48

Ruleset.SCHEMA = SCHEMA
Ruleset.LEGACY_SCHEMA = LEGACY_SCHEMA
Ruleset.RECORDS = RECORDS
Ruleset.SCOPES = SCOPES
Ruleset.NOTICE = "Warfront is available only on the Normal, PvP, RP and RP-PvP rulesets."
Ruleset.scope = nil
Ruleset.region = nil
Ruleset.copyFailed = false
Ruleset.record = nil
Ruleset.context = nil
Ruleset.unsupported = false
Ruleset.conflict = false
Ruleset.noticed = false

local function Record(kind, fields)
  if WF.Record then WF.Record(kind, fields) end
end

local function Call(fn, a, b)
  if type(fn) ~= "function" then return nil end
  local ok, x, y, z, w = pcall(fn, a, b)
  if not ok then return nil end
  return x, y, z, w
end

local function Global(name)
  return _G and _G[name] or nil
end

local function Whole(value, minimum, maximum)
  if type(value) ~= "number" or value ~= math.floor(value) then return nil end
  if value < minimum or value > maximum then return nil end
  return value
end

-- A bounded diagnostic text the companion accepts as a realm name: letters,
-- digits, spaces and ' ( ) . _ -, 1 to 48 bytes, starting with a letter or a
-- digit. Anything else becomes "-"; a multi-byte letter is never cut in half.
function Ruleset.Clean(text)
  if type(text) ~= "string" or text == "" then return nil end
  local out, bytes = {}, 0
  local i = 1
  while i <= #text and bytes < MAX_TEXT do
    local c = string.sub(text, i, i)
    local byte = string.byte(c)
    if byte >= 128 then
      local length = byte >= 240 and 4 or byte >= 224 and 3 or byte >= 192 and 2 or 1
      if i + length - 1 > #text or bytes + length > MAX_TEXT then break end
      out[#out + 1] = string.sub(text, i, i + length - 1)
      bytes = bytes + length
      i = i + length
    else
      if string.find(c, "^[%w '%(%)%._%-]$") then out[#out + 1] = c else out[#out + 1] = "-" end
      bytes = bytes + 1
      i = i + 1
    end
  end
  local clean = table.concat(out)
  if not string.find(clean, "^[%w\128-\255]") then clean = "R" .. clean end
  return clean
end

-- The bucket key of a map: "<region>:<SCOPE>" (decision 0120), nil without both.
function Ruleset.BucketKey(scope, region)
  if type(scope) ~= "string" or not SCOPES[scope] then return nil end
  region = Whole(region, 1, MAX_REGION)
  if not region then return nil end
  return string.format("%d:%s", region, scope)
end

local function ReadRegion()
  return Whole(Call(Global("GetCurrentRegion")), 1, MAX_REGION)
end

-- The scope of a record: only the exact measured ids count.
function Ruleset.ScopeOf(record)
  if type(record) ~= "number" then return nil end
  return RECORDS[record]
end

function Ruleset:ReadRecord()
  local api = Global("C_GameRules")
  if type(api) ~= "table" then return nil end
  local record = Call(api.GetCurrentGameModeRecordID)
  if type(record) ~= "number" or record ~= math.floor(record) then return nil end
  return record
end

-- The realm id carried by the player's GUID ("Player-<id>-…"; the GUID server
-- was measured equal to GetRealmID() on 2026-11-10), or nil.
local function GuidRealm()
  local guid = Call(Global("UnitGUID"), "player")
  if type(guid) ~= "string" then return nil end
  local ok, _, _, server = pcall(string.find, guid, "^Player%-(%d+)%-")
  if not ok then return nil end
  return Whole(tonumber(server), 1, 4294967295)
end

-- Build 71037 answers GetRealmID() = 0 and empty realm names (decision 0137):
-- the GUID gives the id, and "Realm <id>" stands in for the name that released
-- companions still require. Diagnostics only.
local function ReadContext(scope, record, region)
  local context = { scope = scope, rulesetRecord = record }
  context.regionId = region
  context.regionName = Ruleset.Clean(Call(Global("GetCurrentRegionName")))
  context.realmId = Whole(Call(Global("GetRealmID")), 1, 4294967295) or GuidRealm()
  context.normalizedRealmName = Ruleset.Clean(Call(Global("GetNormalizedRealmName")))
  context.realmName = Ruleset.Clean(Call(Global("GetRealmName"))) or context.normalizedRealmName
  if not context.realmName and context.realmId then
    context.realmName = string.format("Realm %d", context.realmId)
  end
  local version, build, _, interface = Call(Global("GetBuildInfo"))
  context.clientVersion = Ruleset.Clean(version)
  context.build = Ruleset.Clean(build)
  context.interface = Whole(interface, 0, 4294967295)
  return context
end

local function Notice(self)
  if self.noticed then return end
  self.noticed = true
  if WF.Print then WF.Print(Ruleset.NOTICE) end
end

-- Reads the record and the region again. The first supported record with a
-- known region fixes the map for the whole session; a different record or
-- region afterwards (or a later unsupported record) is a conflict: Warfront
-- stops rather than move data between maps. An API that does not answer yet
-- changes nothing. Returns the scope or nil.
function Ruleset:Refresh()
  local record = self:ReadRecord()
  if record == nil then return self:Scope(true) end
  local scope = Ruleset.ScopeOf(record)
  local region = ReadRegion()
  if self.scope then
    if scope ~= self.scope or (region and region ~= self.region) then
      if not self.conflict then
        self.conflict = true
        Record("RULESET_CONFLICT", { from = self.record, to = record })
        Notice(self)
      end
      return nil
    end
  elseif not self.conflict then
    if scope == nil then
      if not self.unsupported then
        self.unsupported = true
        self.record = record
        Record("RULESET_UNSUPPORTED", {})
      end
      Notice(self)
      return nil
    end
    -- No region yet: the map is unknown, nothing is decided (decision 0120).
    if not region then return nil end
    self.scope = scope
    self.region = region
    self.record = record
    self.unsupported = false
  end
  if self.scope and not self.conflict then
    -- Realm and client details are diagnostics: refreshed as the game gives them.
    self.context = ReadContext(self.scope, self.record, self.region)
    self:Persist()
  end
  return self:Scope(true)
end

-- The session's scope, or nil: not resolved yet, unsupported or in conflict.
-- Resolves lazily once, so that storage written before the first event is
-- still scoped.
function Ruleset:Scope(quiet)
  if self.conflict or self.unsupported then return nil end
  if self.scope then return self.scope end
  if quiet then return nil end
  self:Refresh()
  if self.conflict or self.unsupported then return nil end
  return self.scope
end

function Ruleset:Supported()
  return self:Scope() ~= nil
end

function Ruleset:Context()
  if not self:Scope() then return nil end
  return self.context
end

-- The commercial region of the session's map, nil when unknown.
function Ruleset:Region()
  if not self:Scope() then return nil end
  return self.region
end

local function Db()
  local storage = WF.Storage
  if not storage or type(storage.GetDB) ~= "function" or storage.readOnly then return nil end
  local db = storage:GetDB()
  if type(db) ~= "table" then return nil end
  return db
end

-- A deep copy of saved data (a tree of plain values), nil past MAX_COPY_DEPTH.
local MAX_COPY_DEPTH = 64
local function Copy(value, depth)
  if type(value) ~= "table" then return value end
  if depth > MAX_COPY_DEPTH then return nil end
  local out = {}
  for key, item in pairs(value) do
    local copied = Copy(item, depth + 1)
    if copied == nil then return nil end
    out[Copy(key, depth + 1)] = copied
  end
  return out
end

-- The pre-0120 bucket scopes[SCOPE], copied once into its recorded region's map
-- (decision 0120 § 6), or nil: only in a session of that region, only when its
-- context records this scope and a valid region. The original stays as it is.
-- A bucket that should be copied but cannot be returns nil, true: no map is
-- created, so a later build can still copy it (nothing starts empty over it).
local function AdoptLegacy(scopes, scope, region)
  local legacy = scopes[scope]
  local context = type(legacy) == "table" and legacy.context
  if type(context) ~= "table" or context.scope ~= scope then return nil end
  if Whole(context.regionId, 1, MAX_REGION) ~= region then return nil end
  local copy = Copy(legacy, 1)
  if not copy then
    Record("RULESET_MAP_COPY_FAILED", { scope = scope, region = region })
    return nil, true
  end
  Record("RULESET_MAP_ADOPTED", { scope = scope, region = region })
  return copy
end

-- WarfrontDB.scopes["<region>:<SCOPE>"], or nil without storage, for a newer
-- scopes schema (left untouched) or without a resolved map.
function Ruleset:Bucket()
  local scope = self:Scope()
  local key = scope and not self.copyFailed and Ruleset.BucketKey(scope, self.region)
  local db = key and Db()
  if not db then return nil end
  if type(db.scopeSchema) == "number" and db.scopeSchema > SCHEMA then return nil end
  if type(db.scopes) ~= "table" then db.scopes = {} end
  local bucket = db.scopes[key]
  if type(bucket) ~= "table" then
    local copy, failed = AdoptLegacy(db.scopes, scope, self.region)
    if failed then
      self.copyFailed = true
      return nil
    end
    bucket = copy or {}
    db.scopes[key] = bucket
  end
  db.scopeSchema = SCHEMA
  return bucket
end

-- One module's table of the current map: scopes["<region>:<SCOPE>"][name].
function Ruleset:Module(name)
  local bucket = type(name) == "string" and self:Bucket()
  if not bucket then return nil end
  if type(bucket[name]) ~= "table" then bucket[name] = {} end
  return bucket[name]
end

-- Records the context the companion groups its uploads by.
function Ruleset:Persist()
  local bucket = self.scope and not self.conflict and self:Bucket()
  if not bucket or not self.context then return end
  local context = {}
  for key, value in pairs(self.context) do context[key] = value end
  context.schema = SCHEMA
  bucket.context = context
end

if WF.RegisterEvent then
  WF.RegisterEvent("PLAYER_LOGIN", function() Ruleset:Refresh() end)
  WF.RegisterEvent("PLAYER_ENTERING_WORLD", function() Ruleset:Refresh() end)
end
