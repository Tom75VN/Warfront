local WF = Warfront

WF.Storage = WF.Storage or {}
local Storage = WF.Storage

local SCHEMA_VERSION = 1
local MAX_LOG = 200
local MAX_MESSAGES = 100
local MAX_RESULTS = 100
local MAX_ERRORS = 50
local pendingLogs = {}
local pendingMessages = {}
local pendingResults = {}
local pendingErrors = {}

local function AppendBounded(list, value, maximum)
  list[#list + 1] = value
  while #list > maximum do
    table.remove(list, 1)
  end
end

local function NewSendStats()
  return {
    attempted = 0,
    acceptedCalls = 0,
    failedCalls = 0,
    byTransport = {},
  }
end

local function NewReceiveStats()
  return {
    events = 0,
    prefixMatches = 0,
    validMessages = 0,
    malformed = 0,
    oversized = 0,
    missingSequences = 0,
    duplicates = 0,
    outOfOrder = 0,
    echoes = 0,
    pongs = 0,
    rttCount = 0,
    rttTotalMs = 0,
    rttMinMs = nil,
    rttMaxMs = nil,
    byTransport = {},
  }
end

local function EnsureTable(parent, key)
  if type(parent[key]) ~= "table" then parent[key] = {} end
  return parent[key]
end

local function MakeSessionId()
  local value = math.floor((WF.Now() * 1000) + WF.Epoch())
  -- Full name (decision 0070): characters sharing a first name hash apart.
  local playerName = WF.Names and WF.Names.Mine() or (UnitName and UnitName("player")) or "unknown"
  for i = 1, #(playerName or "") do
    value = (((value * 33) + string.byte(playerName, i)) % 65536)
  end
  return string.format("%04X", (value % 65536))
end

function Storage:Initialize()
  if self.initialized then return not self.readOnly end
  self.initialized = true

  -- Transient first-profile marker. It is sampled before this initializer
  -- writes any defaults, so addon updates never look like a new profile.
  self.newProfile = type(WarfrontDB) ~= "table" or next(WarfrontDB) == nil
  if type(WarfrontDB) ~= "table" then WarfrontDB = {} end
  local db = WarfrontDB
  local existingVersion = tonumber(db.schemaVersion) or 0

  if existingVersion > SCHEMA_VERSION then
    self.readOnly = true
    self.futureVersion = existingVersion
    self.db = db
    WF.Print("SavedVariables schema " .. existingVersion .. " is newer than this addon; diagnostics are read-only.")
    return false
  end

  db.schemaVersion = SCHEMA_VERSION
  -- The build that last wrote this file, read by the companion (decision 0031).
  db.addonVersion = WF.version
  db.channelLevel = WF.channelLevel
  db.importSchema = WF.Import and WF.Import.SCHEMA or nil
  -- The import may carry the latest released version (decision 0108).
  db.importRelease = 1
  -- The import may carry the Worker-signed board copy (decision 0110).
  db.importBoards = 1
  db.sequence = tonumber(db.sequence) or 0
  db.session = {
    id = MakeSessionId(),
    startedAt = WF.Epoch(),
    addonVersion = WF.version,
    channelLevel = WF.channelLevel,
  }
  if type(db.sendStats) ~= "table" then db.sendStats = NewSendStats() end
  if type(db.receiveStats) ~= "table" then db.receiveStats = NewReceiveStats() end
  db.sendStats.attempted = tonumber(db.sendStats.attempted) or 0
  db.sendStats.acceptedCalls = tonumber(db.sendStats.acceptedCalls) or 0
  db.sendStats.failedCalls = tonumber(db.sendStats.failedCalls) or 0
  EnsureTable(db.sendStats, "byTransport")
  db.receiveStats.events = tonumber(db.receiveStats.events) or 0
  db.receiveStats.prefixMatches = tonumber(db.receiveStats.prefixMatches) or 0
  db.receiveStats.validMessages = tonumber(db.receiveStats.validMessages) or 0
  db.receiveStats.malformed = tonumber(db.receiveStats.malformed) or 0
  db.receiveStats.oversized = tonumber(db.receiveStats.oversized) or 0
  db.receiveStats.missingSequences = tonumber(db.receiveStats.missingSequences) or 0
  db.receiveStats.duplicates = tonumber(db.receiveStats.duplicates) or 0
  db.receiveStats.outOfOrder = tonumber(db.receiveStats.outOfOrder) or 0
  db.receiveStats.echoes = tonumber(db.receiveStats.echoes) or 0
  db.receiveStats.pongs = tonumber(db.receiveStats.pongs) or 0
  db.receiveStats.rttCount = tonumber(db.receiveStats.rttCount) or 0
  db.receiveStats.rttTotalMs = tonumber(db.receiveStats.rttTotalMs) or 0
  db.receiveStats.rttMinMs = tonumber(db.receiveStats.rttMinMs)
  db.receiveStats.rttMaxMs = tonumber(db.receiveStats.rttMaxMs)
  EnsureTable(db.receiveStats, "byTransport")
  EnsureTable(db, "log")
  EnsureTable(db, "lastMessages")
  EnsureTable(db, "lastResults")
  EnsureTable(db, "errors")
  EnsureTable(db, "settings")

  while #db.log > MAX_LOG do table.remove(db.log, 1) end
  while #db.lastMessages > MAX_MESSAGES do table.remove(db.lastMessages, 1) end
  while #db.lastResults > MAX_RESULTS do table.remove(db.lastResults, 1) end
  while #db.errors > MAX_ERRORS do table.remove(db.errors, 1) end

  self.db = db
  self:AddLog("SESSION_START", { session = db.session.id, version = WF.version })
  WF.FlushPendingLog()

  local queuedLogs = pendingLogs
  local queuedMessages = pendingMessages
  local queuedResults = pendingResults
  local queuedErrors = pendingErrors
  pendingLogs, pendingMessages, pendingResults, pendingErrors = {}, {}, {}, {}

  for i = 1, #queuedLogs do
    self:AddLog(queuedLogs[i].kind, queuedLogs[i].fields)
  end
  for i = 1, #queuedMessages do
    self:AddMessage(queuedMessages[i])
  end
  for i = 1, #queuedResults do
    self:AddResult(queuedResults[i])
  end
  for i = 1, #queuedErrors do
    self:AddError(queuedErrors[i].scope, queuedErrors[i].error)
  end
  return true
end

function Storage:GetDB()
  return self.db
end

function Storage:AddLog(kind, fields)
  local db = self:GetDB()
  if not self.initialized then
    AppendBounded(pendingLogs, { kind = kind, fields = fields }, MAX_LOG)
    return
  end
  if not db or self.readOnly then return end
  AppendBounded(db.log, {
    at = WF.Epoch(),
    elapsed = WF.Now(),
    kind = tostring(kind or "UNKNOWN"),
    fields = fields or {},
  }, MAX_LOG)
end

function Storage:AddMessage(message)
  local db = self:GetDB()
  if not self.initialized then
    AppendBounded(pendingMessages, message, MAX_MESSAGES)
    return
  end
  if not db or self.readOnly then return end
  AppendBounded(db.lastMessages, message, MAX_MESSAGES)
end

function Storage:AddResult(result)
  local db = self:GetDB()
  if not self.initialized then
    result.at = result.at or WF.Epoch()
    result.elapsed = result.elapsed or WF.Now()
    AppendBounded(pendingResults, result, MAX_RESULTS)
    return
  end
  if not db or self.readOnly then return end
  result.at = result.at or WF.Epoch()
  result.elapsed = result.elapsed or WF.Now()
  AppendBounded(db.lastResults, result, MAX_RESULTS)
end

function Storage:AddError(scope, errorText)
  local db = self:GetDB()
  if not self.initialized then
    AppendBounded(pendingErrors, { scope = scope, error = errorText }, MAX_ERRORS)
    return
  end
  if not db or self.readOnly then return end
  local cleanScope, cleanError = WF.Sanitize(scope, 100), WF.Sanitize(errorText, 240)
  local now = WF.Now()
  -- Alternating failures belong to the same burst too. Scan at most 50 rows;
  -- preserve chronological arrays and start a new episode after 10 s of quiet.
  for index = #db.errors, 1, -1 do
    local previous = db.errors[index]
    local at = previous.lastElapsed or previous.elapsed
    if previous.scope == cleanScope and previous.error == cleanError
      and type(at) == "number" and now >= at and now - at <= 10 then
      previous.count = (tonumber(previous.count) or 1) + 1
      previous.lastAt, previous.lastElapsed = WF.Epoch(), now
      return
    end
  end
  local entry = {
    at = WF.Epoch(),
    elapsed = WF.Now(),
    scope = cleanScope,
    error = cleanError,
  }
  AppendBounded(db.errors, entry, MAX_ERRORS)
  self:AddLog("ERROR", entry)
end

function Storage:NextSequence()
  local db = self:GetDB()
  if not db or self.readOnly then return nil end
  db.sequence = db.sequence + 1
  return db.sequence
end

function Storage:IncrementSend(transport, field)
  local db = self:GetDB()
  if not db or self.readOnly then return end
  local stats = db.sendStats
  stats[field] = (tonumber(stats[field]) or 0) + 1
  if field == "attempted" then
    stats.byTransport[transport] = (tonumber(stats.byTransport[transport]) or 0) + 1
  end
end

function Storage:IncrementReceive(field, transport)
  local db = self:GetDB()
  if not db or self.readOnly then return end
  local stats = db.receiveStats
  stats[field] = (tonumber(stats[field]) or 0) + 1
  if transport then
    stats.byTransport[transport] = (tonumber(stats.byTransport[transport]) or 0) + 1
  end
end

function Storage:AddReceiveAmount(field, amount)
  local db = self:GetDB()
  if not db or self.readOnly then return end
  db.receiveStats[field] = (tonumber(db.receiveStats[field]) or 0) + (tonumber(amount) or 0)
end

function Storage:RecordRTT(milliseconds)
  local db = self:GetDB()
  if not db or self.readOnly then return end
  local stats = db.receiveStats
  stats.rttCount = (tonumber(stats.rttCount) or 0) + 1
  stats.rttTotalMs = (tonumber(stats.rttTotalMs) or 0) + milliseconds
  if not stats.rttMinMs or milliseconds < stats.rttMinMs then stats.rttMinMs = milliseconds end
  if not stats.rttMaxMs or milliseconds > stats.rttMaxMs then stats.rttMaxMs = milliseconds end
end

function Storage:ClearDiagnostics()
  local db = self:GetDB()
  if not db or self.readOnly then return false end
  db.sendStats = NewSendStats()
  db.receiveStats = NewReceiveStats()
  db.log = {}
  db.lastMessages = {}
  db.lastResults = {}
  db.errors = {}
  self:AddLog("DIAGNOSTICS_CLEARED", { session = db.session.id })
  return true
end

local function OnAddonLoaded(eventName, addonName)
  if string.lower(tostring(addonName or "")) == string.lower(WF.name) then
    Storage:Initialize()
  end
end

local loadRegistered, loadRegistrationError = WF.RegisterEvent("ADDON_LOADED", OnAddonLoaded)
if not loadRegistered then
  WF.RecordError("RegisterEvent(ADDON_LOADED)", loadRegistrationError)
end
