Warfront = Warfront or {}

local WF = Warfront

WF.Ruleset = WF.Ruleset or {}
local Ruleset = WF.Ruleset

-- Ruleset scope (decision 0072). Shared gameplay has exactly two partitions,
-- PVP and NORMAL, chosen by the client's game-mode record
-- (C_GameRules.GetCurrentGameModeRecordID(), measured 14 = PvP and
-- 15 = Normal/PvE on 2026-11-07). The realm name, realm id, region and the
-- character's surname never decide it: they are bounded diagnostic metadata
-- recorded next to the scope for the companion and the cloud. Any other record
-- (RP, RP-PvP, Hardcore, unknown) disables Warfront with one notice.
--
-- SavedVariables, read by the companion (contract v2, docs/companion.md):
--   WarfrontDB.scopeSchema = 1
--   WarfrontDB.scopes[scope] = { context = { scope, rulesetRecord, regionId,
--     regionName, realmId, realmName, normalizedRealmName, clientVersion,
--     build, interface }, <module> = { ... } }
-- Realm-keyed buckets of older builds stay in their module tables as an
-- archive; nothing is deleted or merged (rule R7).

local SCHEMA = 1
local RECORDS = { [14] = "PVP", [15] = "NORMAL" }
local MAX_REGION = 1000
local MAX_TEXT = 48

Ruleset.SCHEMA = SCHEMA
Ruleset.RECORDS = RECORDS
Ruleset.NOTICE = "Warfront is available only on the Normal and PvP rulesets."
Ruleset.scope = nil
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

local function ReadContext(scope, record)
  local context = { scope = scope, rulesetRecord = record }
  context.regionId = Whole(Call(Global("GetCurrentRegion")), 1, MAX_REGION)
  context.regionName = Ruleset.Clean(Call(Global("GetCurrentRegionName")))
  context.realmId = Whole(Call(Global("GetRealmID")), 1, 4294967295)
  context.realmName = Ruleset.Clean(Call(Global("GetRealmName")))
  context.normalizedRealmName = Ruleset.Clean(Call(Global("GetNormalizedRealmName")))
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

-- Reads the record again. The first supported record fixes the scope for the
-- whole session; a different record afterwards (or a later unsupported one) is a
-- conflict: Warfront stops rather than move data between scopes. An API that
-- does not answer yet changes nothing. Returns the scope or nil.
function Ruleset:Refresh()
  local record = self:ReadRecord()
  if record == nil then return self:Scope(true) end
  local scope = Ruleset.ScopeOf(record)
  if self.scope then
    if scope ~= self.scope then
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
    self.scope = scope
    self.record = record
    self.unsupported = false
  end
  if self.scope and not self.conflict then
    -- Region and realm are diagnostics: refreshed as the game gives them.
    self.context = ReadContext(self.scope, self.record)
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

-- The commercial region (actor identity and diagnostics), nil when unknown.
function Ruleset:Region()
  local context = self:Context()
  return context and context.regionId or nil
end

local function Db()
  local storage = WF.Storage
  if not storage or type(storage.GetDB) ~= "function" or storage.readOnly then return nil end
  local db = storage:GetDB()
  if type(db) ~= "table" then return nil end
  return db
end

-- WarfrontDB.scopes[scope], or nil without storage, for a newer scopes schema
-- (left untouched) or without a supported scope.
function Ruleset:Bucket()
  local scope = self:Scope()
  local db = scope and Db()
  if not db then return nil end
  if type(db.scopeSchema) == "number" and db.scopeSchema > SCHEMA then return nil end
  db.scopeSchema = SCHEMA
  if type(db.scopes) ~= "table" then db.scopes = {} end
  local bucket = db.scopes[scope]
  if type(bucket) ~= "table" then
    bucket = {}
    db.scopes[scope] = bucket
  end
  return bucket
end

-- One module's table of the current scope: scopes[scope][name].
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
