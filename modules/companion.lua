Warfront = Warfront or {}

local WF = Warfront
local Companion = {
  active = false,
  state = "OPTIONAL",
  line = nil,
  seenAt = nil,
  startedAt = nil,
  session = nil,
  beat = nil,
  importSeq = nil,
  cloud = nil,
  applied = nil,
  importStatus = nil,
  importReason = nil,
  polls = 0,
  readErrors = 0,
}

WF.Companion = Companion

-- Optional companion bridge (decision 0046): never required to play. When
-- compatible custom-file functions are present it can import a launch
-- snapshot; its absence never locks, pauses or delays any Warfront feature.
--
-- Status line: WFB1 <session> <beat> <importSeq> <cloud>
--   session   1-32 letters/digits, random per companion start
--   beat      counter raised every 10 s (liveness)
--   importSeq 0 until the launch snapshot is written, then raised per rewrite
--   cloud     ok | offline | pending (informative: offline never locks)
-- Import file: warfront_import_<crc>.txt, <crc> = 8 lowercase hex digits of
-- the CRC-32 of the import's realm-free char ("First Surname"); content
-- "WFI1 <check>\n" then
-- the decision 0032 canonical form of the import without its check field.
local STATUS_FILE = "warfront_status.txt"
local IMPORT_PREFIX = "warfront_import_"
local POLL_INTERVAL = 5
local STALE_AFTER = 60
local MAX_STATUS = 128
local MAX_IMPORT = 262144
local MAX_COUNTER = 1000000000
local CLOUD = { ok = true, offline = true, pending = true }

Companion.STATUS_FILE = STATUS_FILE
Companion.STALE_AFTER = STALE_AFTER

local function Now()
  if WF.Now then return WF.Now() end
  return 0
end

local function Print(text)
  if WF.Print then WF.Print(text) end
end

local function Record(kind, fields)
  if WF.Record then WF.Record(kind, fields) end
end

-- nampower counts arguments and refuses a trailing nil: exactly one here.
local function Read(name)
  return pcall(function() return ReadCustomFile(name) end)
end

local function Hex8(n)
  local digits = "0123456789abcdef"
  local out = ""
  for i = 1, 8 do
    local d = n - math.floor(n / 16) * 16
    out = string.sub(digits, d + 1, d + 1) .. out
    n = math.floor(n / 16)
  end
  return out
end

function Companion:Available()
  return type(ReadCustomFile) == "function"
end

-- session, beat, importSeq, cloud of a valid status line, else nil.
function Companion.ParseStatus(text)
  if type(text) ~= "string" or #text > MAX_STATUS then return nil end
  local _, _, session, beat, seq, cloud = string.find(text, "^WFB1 (%w+) (%d+) (%d+) (%a+)\r?\n?$")
  if not session or #session > 32 or not CLOUD[cloud] then return nil end
  if #beat > 10 or #seq > 10 then return nil end
  beat, seq = tonumber(beat), tonumber(seq)
  if beat > MAX_COUNTER or seq > MAX_COUNTER then return nil end
  return session, beat, seq, cloud
end

-- The bridge file name of a character, or nil without the bit library.
function Companion.ImportFile(identity)
  local Import = WF.Import
  if type(identity) ~= "string" or not Import or not Import.Crc32 then return nil end
  if not bit or type(bit.bxor) ~= "function" then return nil end
  return IMPORT_PREFIX .. Hex8(Import.Crc32(identity)) .. ".txt"
end

-- An import file's text as a raw table for Import:Validate, or nil and a reason.
function Companion.Decode(text)
  if text == nil then return nil, "none" end
  if type(text) ~= "string" or #text > MAX_IMPORT then return nil, "too large" end
  local _, last, check = string.find(text, "^WFI1 (%d+)\r?\n")
  if not last or #check > 10 then return nil, "header" end
  local body = string.sub(text, last + 1)
  body = (string.gsub(body, "\r?\n$", ""))
  local raw, reason = WF.Import.ParseCanonical(body)
  if type(raw) ~= "table" then return nil, reason or "not a table" end
  if raw.check ~= nil then return nil, "check in body" end
  raw.check = tonumber(check)
  return raw
end

-- State -----------------------------------------------------------------------------

function Companion:SetState(state)
  local old = self.state
  if state == old then return end
  self.state = state
  Record("COMPANION", { state = state, from = old })
  if state == "OK" and old ~= "OK" then
    Print("Warfront Companion connected; optional import data is available.")
  end
end

-- Polling ---------------------------------------------------------------------------

function Companion:LoadImport()
  if not self.importSeq or self.importSeq < 1 or not self.session then return end
  local key = self.session .. ":" .. self.importSeq
  if key == self.applied then return end
  local Import = WF.Import
  local me = WF.Progress and WF.Progress.Me and WF.Progress:Me()
  if not Import or not Import.Validate or not Import.Merge or not me then return end
  local name = Companion.ImportFile(me)
  if not name then
    self.applied = key
    self.importStatus, self.importReason = "REJECTED", "no bit library"
    return
  end
  local ok, text = Read(name)
  if not ok then
    -- Most likely read during the companion's rename: retried at the next poll.
    self.readErrors = self.readErrors + 1
    return
  end
  self.applied = key
  local data, reason = Companion.Decode(text)
  if data then data, reason = Import:Validate(data) end
  if data then
    Import:Merge(data)
    self.importStatus, self.importReason = "OK", nil
    return
  end
  self.importStatus = (reason == "none") and "NONE" or "REJECTED"
  self.importReason = reason
  Record("IMPORT", { status = self.importStatus, source = "bridge", reason = reason })
  if reason == "future schema" or reason == "level" then
    Print("Companion data needs another addon version; it is ignored until you update.")
  end
end

function Companion:Poll(now)
  now = now or Now()
  self.polls = self.polls + 1
  if not self.startedAt then self.startedAt = now end
  if not self:Available() then
    self:SetState("OPTIONAL")
    return
  end
  local ok, text = Read(STATUS_FILE)
  if not ok then
    self.readErrors = self.readErrors + 1
  elseif text ~= nil then
    local session, beat, seq, cloud = Companion.ParseStatus(text)
    if session then
      local line = session .. " " .. beat .. " " .. seq .. " " .. cloud
      -- Only a change proves a live companion: a file left by an earlier
      -- session never does.
      if self.line ~= nil and line ~= self.line then self.seenAt = now end
      self.line = line
      self.session, self.beat, self.importSeq, self.cloud = session, beat, seq, cloud
    end
  end
  if self.seenAt and now - self.seenAt < STALE_AFTER then
    self:SetState("OK")
    self:LoadImport()
  elseif not self.seenAt and now - self.startedAt < STALE_AFTER then
    self:SetState("WAITING")
  else
    self:SetState("MISSING")
  end
end

function Companion:PrintStatus()
  local now = Now()
  Print("companion " .. self.state .. " (optional)"
    .. " nampower=" .. tostring(self:Available())
    .. " session=" .. tostring(self.session or "none")
    .. " lastChange=" .. (self.seenAt and (string.format("%.0f", now - self.seenAt) .. "s ago") or "never")
    .. " cloud=" .. tostring(self.cloud or "?"))
  Print("companion import=" .. tostring(self.importStatus or "none")
    .. (self.importReason and (" (" .. self.importReason .. ")") or "")
    .. " importSeq=" .. tostring(self.importSeq or "?")
    .. " polls=" .. self.polls .. " readErrors=" .. self.readErrors)
  -- The import this character loaded at login (WarfrontImport, decision 0069).
  local import = WF.Import
  local loaded = import and import.data
  Print("companion loginImport=" .. tostring(import and import.status or "?")
    .. (import and import.reason and (" (" .. tostring(import.reason) .. ")") or "")
    .. " id=" .. tostring(loaded and loaded.importId or "none"))
  local reason = self:HintReason(now, WF.Epoch and WF.Epoch() or 0)
  local age = WF.Import and WF.Import.Age and WF.Import:Age(WF.Epoch and WF.Epoch() or 0)
  Print("companion hint=" .. tostring(reason or "none") .. (self:HintHidden() and " (hidden)" or "")
    .. " importAge=" .. (age and (string.format("%.0f", age / 3600) .. "h") or "?")
    .. " nudged=" .. tostring(self.nudged == true))
end

-- Recommendation (decision 0046) ----------------------------------------------------

-- Proposed values, not measured: tune them with live players.
local HINT_STALE = 3 * 86400
local HINT_ALONE = 300
local HINT_DELAY = 120
local HINT_CHAT_GAP = 7 * 86400

Companion.HINT_STALE = HINT_STALE
Companion.HINT_ALONE = HINT_ALONE

local HINT_TEXTS = {
  none = "No Companion snapshot: your map starts from the players online.",
  stale = "Your Companion snapshot is more than 3 days old.",
  alone = "No other Warfront player heard for 5 minutes.",
  unconfirmed = "Some owners on your map are unconfirmed.",
}
Companion.HINT_TEXTS = HINT_TEXTS
Companion.HINT_PITCH = "Optional: the Warfront Companion keeps your map up to date between sessions."
Companion.HINT_LIMIT = "Syncs your map with the cloud while the game is closed."

local function HintDB()
  local storage = WF.Storage
  if not storage or not storage.GetDB or storage.readOnly then return nil end
  local db = storage:GetDB()
  if type(db) ~= "table" then return nil end
  if type(db.companionHint) ~= "table" then db.companionHint = {} end
  return db.companionHint
end

function Companion:HintHidden()
  local db = HintDB()
  return db ~= nil and db.off == true
end

function Companion:SetHintHidden(hidden)
  local db = HintDB()
  if not db then return false end
  db.off = hidden and true or nil
  Record("COMPANION_HINT", { hidden = hidden and true or false })
  return true
end

-- True while the companion already feeds Warfront: live, or a fresh import.
function Companion:Helping(epoch)
  if self.state == "OK" then return true end
  local Import = WF.Import
  if not Import or Import.status ~= "OK" or not Import.Age then return false end
  -- An unknown age (read-only storage) never nags.
  local age = Import:Age(epoch or (WF.Epoch and WF.Epoch()) or 0)
  return age == nil or age < HINT_STALE
end

-- The strongest reason to recommend the companion now, or nil. While it does
-- not help, what the player sees first (alone | unconfirmed), else the
-- snapshot (none | stale). Never a requirement.
function Companion:HintReason(now, epoch)
  now = now or Now()
  if self:Helping(epoch) then return nil end
  local catchup = WF.Catchup
  if catchup and catchup.onlineAt and now - catchup.onlineAt >= HINT_ALONE and catchup.NewsAge then
    local age = catchup:NewsAge(now)
    if not age or age >= HINT_ALONE then return "alone" end
  end
  if catchup and catchup.HintAge and catchup:HintAge(now) ~= nil then return "unconfirmed" end
  local Import = WF.Import
  if not Import or Import.status ~= "OK" then return "none" end
  return "stale"
end

-- The reason when a hint may be shown (not hidden), or nil.
function Companion:ShownHint(now, epoch)
  if self:HintHidden() then return nil end
  return self:HintReason(now, epoch)
end

local function InCombat()
  local api = C_RestrictedActions
  if type(api) ~= "table" or type(api.InCombatLockdown) ~= "function" then return false end
  local ok, combat = pcall(api.InCombatLockdown)
  return ok and combat == true
end

-- One chat line at most once per session and once per HINT_CHAT_GAP per
-- account, only when the player is alone or sees unconfirmed owners with no
-- usable snapshot; never in combat, inside a capture area or below level 5.
function Companion:Nudge(now, epoch)
  if self.nudged or not self.activeAt or now - self.activeAt < HINT_DELAY then return false end
  local db = HintDB()
  if not db or db.off then return false end
  if type(db.chatAt) == "number" and epoch >= db.chatAt and epoch - db.chatAt < HINT_CHAT_GAP then return false end
  local capture = WF.Capture
  if not capture or capture.here or (capture.CanTalk and not capture:CanTalk()) or InCombat() then return false end
  local reason = self:HintReason(now, epoch)
  if reason ~= "alone" and reason ~= "unconfirmed" then return false end
  self.nudged = true
  db.chatAt = epoch
  Record("COMPANION_HINT", { reason = reason })
  Print(HINT_TEXTS[reason] .. " " .. Companion.HINT_PITCH .. " Type /wf companion hide to stop these tips.")
  return true
end

-- Ticker: polls start once the player is in the world.
local elapsed = POLL_INTERVAL
local function OnUpdate(_, delta)
  if not Companion.active then return end
  elapsed = elapsed + (delta or 0)
  if elapsed < POLL_INTERVAL then return end
  elapsed = 0
  local now = Now()
  Companion:Poll(now)
  Companion:Nudge(now, WF.Epoch and WF.Epoch() or 0)
end

local function OnEnteringWorld()
  Companion.active = true
  if not Companion.activeAt then Companion.activeAt = Now() end
end

if type(CreateFrame) == "function" then
  local ok, frame = pcall(CreateFrame, "Frame", nil, UIParent)
  if ok and frame and frame.SetScript then frame:SetScript("OnUpdate", OnUpdate) end
end
if WF.RegisterEvent then
  WF.RegisterEvent("PLAYER_ENTERING_WORLD", OnEnteringWorld)
end
