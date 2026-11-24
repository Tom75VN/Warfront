Warfront = Warfront or {}

local WF = Warfront

-- Mixed addon versions on the channel (decision 0029). Every WF<n> line carries
-- the sender's addon version right after "WF<n>:", whatever n is, so any build
-- learns that a newer one exists. A claimed version is unverified P2P data: it
-- only ever produces a warning, never a capture decision.
local Version = {
  -- A newer version heard from players is recalled at every login until the
  -- installed version reaches it, or after this long without two players
  -- showing it again (decision 0108).
  CONFIRM_SECONDS = 30 * 24 * 3600,
  -- While a newer version is known, the chat warning repeats this often.
  REPEAT_SECONDS = 3600,
  repeating = false,
  -- A reply to an older announce waits 1 to 5 s and is cancelled when a peer at
  -- least as new answers first (rule R14); at most one per REPLY_GAP seconds.
  REPLY_DELAY = 1,
  REPLY_SPREAD = 4,
  REPLY_GAP = 60,
  -- Per sender identity, the newest { version, level, at } it showed (decision
  -- 0094); local memory only, the least recently heard dropped first.
  MAX_SENDERS = 32,
  senders = {},
  senderCount = 0,
  -- Newest known version: the larger of what players showed (p2p) and the
  -- release named by the companion import (cloud, decision 0108).
  newest = nil,
  newestLevel = nil,
  p2p = nil,
  p2pLevel = nil,
  cloud = nil,
  cloudLevel = nil,
  confirmed = false,
  warnedFor = nil,
  replyAt = nil,
  lastAnnounceAt = nil,
  lastReplyAt = nil,
  announced = 0,
  replies = 0,
  suppressed = 0,
}

WF.Version = Version

local frame

local function Parts(text)
  if type(text) ~= "string" or #text > 11 then return nil end
  local _, _, a, b, c = string.find(text, "^(%d+)%.(%d+)%.(%d+)$")
  if not a or #a > 3 or #b > 3 or #c > 3 then return nil end
  return tonumber(a), tonumber(b), tonumber(c)
end

function Version.Valid(text)
  return Parts(text) ~= nil
end

-- > 0 when a is newer than b, 0 when equal, < 0 when older; nil if either is invalid.
function Version.Compare(a, b)
  local a1, a2, a3 = Parts(a)
  local b1, b2, b3 = Parts(b)
  if not a1 or not b1 then return nil end
  if a1 ~= b1 then return a1 - b1 end
  if a2 ~= b2 then return a2 - b2 end
  return a3 - b3
end

local function DB()
  local storage = WF.Storage
  if not storage or type(storage.GetDB) ~= "function" or storage.readOnly then return nil end
  local db = storage:GetDB()
  if type(db) ~= "table" then return nil end
  return db
end

-- True when the newest known build speaks a higher WF<n>: this client's lines
-- are then ignored by it, and its captures are not shared with those players.
function Version:Incompatible()
  return self.newestLevel ~= nil and self.newestLevel > (WF.channelLevel or 0)
end

function Version:Text()
  if not self.newest then return nil end
  if self:Incompatible() then
    return "Warfront " .. tostring(WF.version) .. " is outdated: players on " .. self.newest
      .. " no longer see your captures. Update the addon."
  end
  return "Warfront " .. tostring(WF.version) .. " is outdated: version " .. self.newest
    .. " is available. Please update."
end

-- Short line for the capture HUD.
function Version:Notice()
  if not self.newest then return nil end
  if self:Incompatible() then return "Addon outdated: captures not shared. Update to " .. self.newest end
  return "Addon outdated: update to " .. self.newest
end

local function PrintWarning(self)
  if WF.Print then WF.Print("|cffff4040" .. self:Text() .. "|r") end
end

-- One chain of hourly repeats per session; it stops once nothing is newer.
local function ScheduleRepeat(self)
  if self.repeating or type(C_Timer) ~= "table" or type(C_Timer.After) ~= "function" then return end
  self.repeating = true
  C_Timer.After(self.REPEAT_SECONDS, function()
    self.repeating = false
    if not self.newest then return end
    pcall(PrintWarning, self)
    ScheduleRepeat(self)
  end)
end

function Version:Warn()
  if not self.newest or self.warnedFor == self.newest then return end
  self.warnedFor = self.newest
  PrintWarning(self)
  if WF.Record then WF.Record("VERSION_OUTDATED", { newest = self.newest, level = self.newestLevel }) end
  ScheduleRepeat(self)
end

local function Epoch()
  return WF.Epoch and WF.Epoch() or 0
end

-- newest = the larger of both sources; at equal versions the cloud level wins.
local function Pick(self)
  local version, level = self.p2p, self.p2pLevel
  if self.cloud and (not version or Version.Compare(self.cloud, version) >= 0) then
    version, level = self.cloud, self.cloudLevel
  end
  self.newest, self.newestLevel = version, level
end

-- The newest version that two distinct senders showed or exceeded, at the
-- lowest level among them (decision 0094, risk B18): one liar is not enough.
local function Supported(senders)
  local best, bestLevel
  for _, a in pairs(senders) do
    if not best or Version.Compare(a.version, best) > 0 then
      local support, low = 0, nil
      for _, b in pairs(senders) do
        if Version.Compare(b.version, a.version) >= 0 then
          support = support + 1
          if not low or b.level < low then low = b.level end
        end
      end
      if support >= 2 then best, bestLevel = a.version, low end
    end
  end
  return best, bestLevel
end

-- Called for every readable WF<n> line, valid or not, whatever its level.
-- sender: the line's author (chat sender or Battle.net character).
function Version:Note(remote, level, sender)
  local newer = Version.Compare(remote, WF.version)
  if not newer or newer <= 0 or type(level) ~= "number" or type(sender) ~= "string" or sender == "" then
    return false
  end
  local capture = WF.Capture
  local who = capture and type(capture.Identity) == "function" and capture.Identity(sender) or sender
  if type(who) ~= "string" then return false end
  local now = WF.Now and WF.Now() or 0
  local seen = self.senders[who]
  if seen then
    seen.at = now
    if Version.Compare(remote, seen.version) <= 0 then return false end
    seen.version, seen.level = remote, level
  else
    if self.senderCount >= self.MAX_SENDERS then
      local oldest, at
      for name, entry in pairs(self.senders) do
        if not at or entry.at < at then oldest, at = name, entry.at end
      end
      self.senders[oldest] = nil
      self.senderCount = self.senderCount - 1
    end
    self.senders[who] = { version = remote, level = level, at = now }
    self.senderCount = self.senderCount + 1
  end
  remote, level = Supported(self.senders)
  if not remote then return false end
  local db = DB()
  local order = self.p2p and Version.Compare(remote, self.p2p)
  if order and order <= 0 then
    -- Two players show the remembered version again: keep it 30 more days,
    -- once per session (decision 0108).
    if order == 0 and not self.confirmed then
      self.confirmed = true
      local saved = db and db.newestVersion
      if type(saved) == "table" and saved.version == self.p2p then saved.confirmedAt = Epoch() end
    end
    return false
  end
  self.p2p, self.p2pLevel, self.confirmed = remote, level, true
  if db then db.newestVersion = { version = remote, level = level, seenAt = Epoch(), confirmedAt = Epoch() } end
  Pick(self)
  self:Warn()
  return true
end

-- The release named by the companion import (decision 0108): trusted alone,
-- reread at each import rebuild, never copied into newestVersion.
function Version:FromImport()
  local import = WF.Import
  local release = import and type(import.data) == "table" and import.data.release
  local version, level
  if type(release) == "table" and type(release.wf) == "number" then
    local newer = Version.Compare(release.v, WF.version)
    if newer and newer > 0 then version, level = release.v, release.wf end
  end
  self.cloud, self.cloudLevel = version, level
  Pick(self)
  if self.restored then self:Warn() end
end

-- At every login or /reload: recall the newest known version and warn once
-- this session; forget the players' one once installed or unconfirmed for 30
-- days (decision 0108).
function Version:Restore()
  if self.restored then return end
  self.restored = true
  self:FromImport()
  local db = DB()
  local saved = db and db.newestVersion
  if type(saved) == "table" then
    local at = tonumber(saved.confirmedAt) or tonumber(saved.seenAt) or 0
    local age = Epoch() - at
    local newer = Version.Compare(saved.version, WF.version)
    local level = tonumber(saved.level)
    if not newer or newer <= 0 or not level or age < 0 or age > self.CONFIRM_SECONDS then
      db.newestVersion = nil
    elseif not self.p2p or Version.Compare(saved.version, self.p2p) > 0 then
      self.p2p, self.p2pLevel = saved.version, level
    end
  end
  Pick(self)
  self:Warn()
end

local function Send(flag)
  local p2p = WF.P2PTest
  if not p2p or type(p2p.SendVersion) ~= "function" then return false end
  local ok, accepted = pcall(p2p.SendVersion, flag)
  return ok and accepted
end

-- One V,A per channel join (login, /reload, rejoin), at most once per REPLY_GAP.
function Version:Announce(now)
  now = now or WF.Now()
  if self.lastAnnounceAt and now - self.lastAnnounceAt < self.REPLY_GAP then return false end
  if not Send("A") then return false end
  self.lastAnnounceAt = now
  self.announced = self.announced + 1
  return true
end

local function OnUpdate()
  Version:Tick(WF.Now())
end

function Version:Tick(now)
  if not self.replyAt or now < self.replyAt then return end
  self.replyAt = nil
  if frame then frame:SetScript("OnUpdate", nil) end
  if self.lastReplyAt and now - self.lastReplyAt < self.REPLY_GAP then return end
  if Send("R") then
    self.lastReplyAt = now
    self.replies = self.replies + 1
  end
end

-- V from another player; the caller has already ignored our own echo. flag A is
-- an announce at join, R a reply. A peer at least as new as us answering first
-- cancels our pending reply, so one older announce draws about one reply.
function Version:OnAnnounce(remote, flag, now)
  if flag ~= "A" and flag ~= "R" then return false end
  local order = Version.Compare(remote, WF.version)
  if not order then return false end
  now = now or WF.Now()
  if order >= 0 then
    if self.replyAt then
      self.replyAt = nil
      self.suppressed = self.suppressed + 1
      if frame then frame:SetScript("OnUpdate", nil) end
    end
    return true
  end
  if flag == "A" and not self.replyAt then
    if self.lastReplyAt and now - self.lastReplyAt < self.REPLY_GAP then return true end
    self.replyAt = now + self.REPLY_DELAY + math.random() * self.REPLY_SPREAD
    if frame then frame:SetScript("OnUpdate", OnUpdate) end
  end
  return true
end

function Version:Summary()
  return "version " .. tostring(WF.version) .. " level " .. tostring(WF.channelLevel)
    .. " newest=" .. tostring(self.newest or "-") .. " cloud=" .. tostring(self.cloud or "-") .. " announced=" .. self.announced
    .. " replies=" .. self.replies .. " suppressed=" .. self.suppressed
end

if CreateFrame then
  frame = CreateFrame("Frame", "WarfrontVersionFrame", UIParent)
  frame:SetScript("OnUpdate", nil)
end

if WF.RegisterEvent then
  WF.RegisterEvent("PLAYER_ENTERING_WORLD", function() Version:Restore() end)
end
