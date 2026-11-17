Warfront = Warfront or {}

local WF = Warfront

-- Opt-in retry of the custom channel (decision 0076). Forever blocks
-- Warfront's channel sends (decision 0075); this rarely checks whether that
-- has changed and warns the developer once it has. Developer diagnostics
-- only: off by default, driven by the WarfrontDev addon.
local Watch = {
  FIRST_DELAY = 120,           -- seconds after login before a due test
  RETRY_DELAY = 600,           -- channel not joined yet, instance, ...
  MAX_RETRIES = 6,             -- per session
  RECHECK_DELAY = 3600,        -- long sessions
  HIDDEN_EVERY = 86400,        -- addon message on the channel
  VISIBLE_EVERY = 7 * 86400,   -- chat line; also on a new client build
  ECHO_WAIT = 15,
  BLOCK_WINDOW = 0.05,         -- blocked action in the frame of the call
  MAX_HISTORY = 20,
  CHANNEL = "warfront",
  retries = 0,
}
WF.ChannelWatch = Watch

-- Notices that say a channel refuses our messages (reference names, not
-- Forever proof; sources in .claude/networking.md, Current evidence).
local REFUSAL_NOTICES = {
  NOT_ALLOWED_IN_CHANNEL = true, TRIAL_RESTRICTED = true, MUTED = true, BANNED = true, NOT_MEMBER = true,
}

local function Global(name)
  if WF.Compat and WF.Compat.Global then return WF.Compat.Global(name) end
  if _G then return _G[name] end
  return nil
end

-- Forever chat payloads can be secret; a secret value is never compared.
local function Readable(value)
  local secret = Global("issecretvalue")
  if type(secret) ~= "function" then return true end
  local ok, isSecret = pcall(secret, value)
  return ok and not isSecret
end

local function Data()
  local storage = WF.Storage
  if not storage or not storage.GetDB or storage.readOnly then return nil end
  local db = storage:GetDB()
  if type(db) ~= "table" then return nil end
  local data = db.channelWatch
  if type(data) ~= "table" then
    data = {}
    db.channelWatch = data
  end
  if type(data.history) ~= "table" then data.history = {} end
  data.enabled = data.enabled and true or false
  data.lastHiddenAt = tonumber(data.lastHiddenAt) or 0
  data.lastVisibleAt = tonumber(data.lastVisibleAt) or 0
  while #data.history > Watch.MAX_HISTORY do table.remove(data.history, 1) end
  return data
end

local function Build()
  local fn = Global("GetBuildInfo")
  if type(fn) ~= "function" then return nil end
  local ok, _, build = pcall(fn)
  if ok and build ~= nil then return tostring(build) end
  return nil
end

local function InInstance()
  local fn = Global("IsInInstance")
  if type(fn) ~= "function" then return false end
  local ok, inside = pcall(fn)
  return ok and inside and true or false
end

local function After(seconds, fn)
  local timer = Global("C_Timer")
  if type(timer) ~= "table" or type(timer.After) ~= "function" then return false end
  return pcall(timer.After, seconds, fn) and true or false
end

local function Stamp(epoch)
  if not epoch or epoch <= 0 then return "never" end
  local ok, text = pcall(date, "%Y-%m-%d %H:%M", epoch)
  if ok and text then return text end
  return tostring(epoch)
end

local function Sanitize(value)
  if WF.Sanitize then return WF.Sanitize(value, 80) end
  return tostring(value)
end

-- Scheduling ----------------------------------------------------------------

function Watch:DueKinds(data, now)
  local hidden = now - data.lastHiddenAt >= self.HIDDEN_EVERY
  local build = Build()
  local visible = now - data.lastVisibleAt >= self.VISIBLE_EVERY
    or (build ~= nil and data.lastBuild ~= nil and build ~= data.lastBuild)
  return hidden, visible
end

function Watch:Schedule(delay)
  if self.scheduled then return end
  self.scheduled = After(delay, function() Watch:Check() end)
end

function Watch:Check()
  self.scheduled = false
  local data = Data()
  if not data or not data.enabled then return end
  if not self.pending then
    local hidden, visible = self:DueKinds(data, WF.Epoch())
    if hidden or visible then
      local started = self:Run(hidden, visible, false)
      if not started and self.retries < self.MAX_RETRIES then
        self.retries = self.retries + 1
        self:Schedule(self.RETRY_DELAY)
        return
      end
    end
  end
  self:Schedule(self.RECHECK_DELAY)
end

-- A test run ----------------------------------------------------------------

-- Starts the due tests. Returns false, reason when nothing could be sent;
-- then no slot is consumed.
function Watch:Run(hidden, visible, manual)
  if self.pending then return false, "a test is already running" end
  if InInstance() then return false, "inside an instance" end
  local p2p = WF.P2PTest
  if type(p2p) ~= "table" or type(p2p.TestChannelSend) ~= "function" or type(p2p.TestChannelAddon) ~= "function" then
    return false, "channel transport unavailable"
  end

  local run = { at = WF.Epoch(), build = Build(), manual = manual and true or nil }
  self.pending = run
  if hidden then
    local test = {}
    run.hidden = test
    local ok, err, payload = p2p.TestChannelAddon(
      function(now) test.callAt = now end,
      function(result) test.result = result end)
    if ok then test.payload = payload else test.error = Sanitize(err) end
  end
  if visible then
    local test = {}
    run.visible = test
    local ok, err, _, payload = p2p.TestChannelSend(function(now) test.callAt = now end)
    if ok then test.payload = payload else test.error = Sanitize(err) end
  end

  local sent = (run.hidden and run.hidden.payload) or (run.visible and run.visible.payload)
  if not sent then
    self.pending = nil
    return false, (run.hidden and run.hidden.error) or (run.visible and run.visible.error) or "nothing is due"
  end
  if not After(self.ECHO_WAIT, function() Watch:Finish(run) end) then
    self.pending = nil
    return false, "C_Timer.After is unavailable"
  end
  return true
end

local function Outcome(test, success)
  if not test then return nil end
  if test.echo then return "works" end
  if test.blocked then return "blocked" end
  if test.refused then return "refused " .. test.refused end
  if success ~= nil and test.result ~= nil and test.result ~= success then
    return "refused result " .. tostring(test.result)
  end
  if not test.callAt then return test.error and ("not sent: " .. test.error) or "not sent" end
  return "silent"
end

function Watch:Finish(run)
  if self.pending ~= run then return end
  self.pending = nil
  local enum = Global("Enum")
  local results = type(enum) == "table" and enum.SendAddonMessageResult or nil
  local success = type(results) == "table" and results.Success or nil
  local entry = {
    at = run.at, build = run.build, manual = run.manual,
    hidden = Outcome(run.hidden, success), visible = Outcome(run.visible, nil),
  }

  local data = Data()
  if not data then return end
  table.insert(data.history, entry)
  while #data.history > self.MAX_HISTORY do table.remove(data.history, 1) end
  local hiddenCalled = run.hidden and run.hidden.callAt
  local visibleCalled = run.visible and run.visible.callAt
  if hiddenCalled then data.lastHiddenAt = run.at end
  if visibleCalled then
    data.lastVisibleAt = run.at
    data.lastBuild = run.build
  end

  if entry.hidden == "works" or entry.visible == "works" then
    local kinds = {}
    if entry.hidden == "works" then kinds[#kinds + 1] = "hidden" end
    if entry.visible == "works" then kinds[#kinds + 1] = "visible" end
    if not data.workingSince then
      data.workingSince = run.at
      data.acknowledged = false
    end
    data.workingKinds = table.concat(kinds, "+")
    self:PrintRun(entry)
    self:Warn(data, true)
  else
    if (hiddenCalled or visibleCalled) and data.workingSince then
      data.workingSince = nil
      data.workingKinds = nil
    end
    if run.manual then self:PrintRun(entry) end
  end
end

-- Detection -----------------------------------------------------------------

local function Near(test, now)
  if not test or not test.callAt then return false end
  local age = now - test.callAt
  return age >= 0 and age <= Watch.BLOCK_WINDOW
end

function Watch:OnBlocked(_, source)
  local run = self.pending
  if not run or not Readable(source) or source ~= "Warfront" then return end
  local now = WF.Now()
  if Near(run.visible, now) then
    run.visible.blocked = true
  elseif Near(run.hidden, now) then
    run.hidden.blocked = true
  end
end

function Watch:OnChannel(_, text)
  local run = self.pending
  local test = run and run.visible
  if not test or not test.payload or not Readable(text) or type(text) ~= "string" then return end
  if string.find(text, test.payload, 1, true) then test.echo = true end
end

function Watch:OnAddon(_, _, text)
  local run = self.pending
  local test = run and run.hidden
  if not test or not test.payload or not Readable(text) or type(text) ~= "string" then return end
  if text == test.payload then test.echo = true end
end

local function NamesChannel(channelName, baseName)
  if Readable(baseName) and type(baseName) == "string" and baseName ~= "" then
    return string.lower(baseName) == Watch.CHANNEL
  end
  if Readable(channelName) and type(channelName) == "string" then
    local plain = string.gsub(channelName, "^%d+%.%s*", "")
    return string.lower(plain) == Watch.CHANNEL
  end
  return false
end

-- CHAT_MSG_CHANNEL_NOTICE(text, playerName, languageName, channelName, ...,
-- channelIndex, channelBaseName): a1, a4 and a9 here.
function Watch:OnNotice(_, text, _, _, channelName, _, _, _, _, baseName)
  local run = self.pending
  if not run or not Readable(text) or type(text) ~= "string" or not REFUSAL_NOTICES[text] then return end
  if not NamesChannel(channelName, baseName) then return end
  local test = (run.hidden and run.hidden.callAt) and run.hidden or run.visible
  if test then test.refused = text end
end

-- Output --------------------------------------------------------------------

function Watch:PrintRun(entry)
  WF.Print("channel retry " .. Stamp(entry.at) .. ": hidden=" .. tostring(entry.hidden or "-")
    .. " visible=" .. tostring(entry.visible or "-"))
end

function Watch:Warn(data, fresh)
  WF.Print("|cff40ff40Custom channel test WORKS (" .. tostring(data.workingKinds or "?") .. ") since "
    .. Stamp(data.workingSince) .. ".|r")
  WF.Print("Review decision 0075 before turning channel sends back on; /wfd channel ok hides this.")
  if not fresh then return end
  local sound = Global("PlaySound")
  local kits = Global("SOUNDKIT")
  local kit = type(kits) == "table" and kits.RAID_WARNING or nil
  if type(sound) == "function" and type(kit) == "number" then pcall(sound, kit) end
end

function Watch:PrintStatus(data)
  local now = WF.Epoch()
  local hidden, visible = self:DueKinds(data, now)
  WF.Print("channel retry: " .. (data.enabled and "on" or "off (/wfd channel on)")
    .. (self.pending and ", test running" or "")
    .. "; due: hidden=" .. (hidden and "yes" or "no") .. " visible=" .. (visible and "yes" or "no"))
  WF.Print("last hidden " .. Stamp(data.lastHiddenAt) .. ", last visible " .. Stamp(data.lastVisibleAt)
    .. ", build " .. tostring(data.lastBuild or "?") .. " (now " .. tostring(Build() or "?") .. ")")
  if data.workingSince then
    WF.Print("|cff40ff40works (" .. tostring(data.workingKinds) .. ") since " .. Stamp(data.workingSince)
      .. (data.acknowledged and ", acknowledged" or "") .. "|r")
  else
    WF.Print("not working yet")
  end
  local count = #data.history
  for i = math.max(1, count - 2), count do self:PrintRun(data.history[i]) end
end

function Watch:Command(rest)
  local word = string.lower(string.match(rest or "", "^%s*(%S*)") or "")
  local data = Data()
  if not data then
    WF.Print("channel retry: saved data unavailable")
    return
  end
  if word == "on" then
    data.enabled = true
    self.retries = 0
    self:Schedule(self.FIRST_DELAY)
    WF.Print("channel retry: on; a due test runs " .. self.FIRST_DELAY .. " s after login (hidden daily, visible weekly)")
  elseif word == "off" then
    data.enabled = false
    WF.Print("channel retry: off")
  elseif word == "now" then
    local ok, err = self:Run(true, true, true)
    if ok then
      WF.Print("channel retry: testing, result in about " .. self.ECHO_WAIT .. " s")
    else
      WF.Print("channel retry: not started (" .. tostring(err) .. ")")
    end
  elseif word == "ok" then
    data.acknowledged = true
    WF.Print("channel retry: warning acknowledged")
  elseif word == "" or word == "status" then
    self:PrintStatus(data)
  else
    WF.Print("/wfd channel [on|off|now|ok]")
  end
end

function Watch:OnEnteringWorld()
  if self.started then return end
  self.started = true
  local data = Data()
  if not data then return end
  if data.workingSince and not data.acknowledged then
    After(10, function()
      local current = Data()
      if current and current.workingSince and not current.acknowledged then Watch:Warn(current, false) end
    end)
  end
  if data.enabled then self:Schedule(self.FIRST_DELAY) end
end

if WF.RegisterEvent then
  WF.RegisterEvent("PLAYER_ENTERING_WORLD", function() Watch:OnEnteringWorld() end)
  WF.RegisterEvent("ADDON_ACTION_BLOCKED", function(...) Watch:OnBlocked(...) end)
  WF.RegisterEvent("ADDON_ACTION_FORBIDDEN", function(...) Watch:OnBlocked(...) end)
  WF.RegisterEvent("CHAT_MSG_CHANNEL", function(...) Watch:OnChannel(...) end)
  WF.RegisterEvent("CHAT_MSG_ADDON", function(...) Watch:OnAddon(...) end)
  WF.RegisterEvent("CHAT_MSG_CHANNEL_NOTICE", function(...) Watch:OnNotice(...) end)
  WF.RegisterEvent("CHAT_MSG_CHANNEL_NOTICE_USER", function(...) Watch:OnNotice(...) end)
end
