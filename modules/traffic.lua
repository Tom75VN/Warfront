Warfront = Warfront or {}

local WF = Warfront

-- Activity meter of the Synchronization panel: Warfront bytes received and sent
-- per second over the last minute, and the Warfront players heard recently.
-- Local only: it reads chat events and the send counters of the gate and the
-- relay (SendQueue.sentBytes, Relay.sentBytes, Relay.boardBytes), sends
-- nothing, saves nothing, and no rule reads it. Its receive filters mirror the
-- transports' first checks (prefix, "WF"/"WR" start, channel base name, chat
-- type) without parsing a line, so a counted line may still be refused later.
-- Identities come from the event sender (rule R1); our own copies are skipped.
local Traffic = {
  WINDOW = 60,          -- seconds kept and drawn, one slot per second
  ACTIVE = 300,         -- a player counts as active this long after its last line
  MAX_PLAYERS = 256,    -- heard table bound (rule R9); the oldest heard leaves first
  inBytes = {},
  outBytes = {},
  stamps = {},
  heard = {},
  heardCount = 0,
  lastOut = nil,
  sampledAt = nil,
  me = nil,
}
WF.Traffic = Traffic

local floor = math.floor
local strSub = string.sub
local ADDON_TYPES = { PARTY = true, RAID = true, GUILD = true, WHISPER = true }
local CHANNEL_KEY = "warfront"
-- Battle.net senders are game accounts, never names: a key no name can take.
local BN_KEY = "\001bn:"

local function Now()
  return WF.Now and WF.Now() or 0
end

local function Global(name)
  if WF.Compat and WF.Compat.Global then return WF.Compat.Global(name) end
  if _G then return _G[name] end
  return nil
end

-- Forever chat payloads can be secret; a secret value is never read.
local function Secret(value)
  local check = Global("issecretvalue")
  if type(check) ~= "function" then return false end
  local ok, secret = pcall(check, value)
  return ok and secret and true or false
end

function Traffic:Me()
  if self.me then return self.me end
  local names = WF.Names
  if not names or type(names.Mine) ~= "function" then return nil end
  local name, final = names.Mine()
  if final then self.me = name end
  return name
end

-- The slot of the second holding `now`, cleared when it last served an older one.
function Traffic:Slot(now)
  local second = floor(now)
  local index = second % self.WINDOW + 1
  if self.stamps[index] ~= second then
    self.stamps[index] = second
    self.inBytes[index] = 0
    self.outBytes[index] = 0
  end
  return index
end

function Traffic:Heard(who, now)
  local heard = self.heard
  if heard[who] == nil then
    if self.heardCount >= self.MAX_PLAYERS then
      local oldest, oldestAt
      for name, at in pairs(heard) do
        if not oldestAt or at < oldestAt then oldest, oldestAt = name, at end
      end
      if oldest then
        heard[oldest] = nil
        self.heardCount = self.heardCount - 1
      end
    end
    self.heardCount = self.heardCount + 1
  end
  heard[who] = now
end

function Traffic:Received(bytes, who, now)
  now = now or Now()
  local index = self:Slot(now)
  self.inBytes[index] = self.inBytes[index] + bytes
  if who then self:Heard(who, now) end
end

function Traffic:SentTotal()
  local queue, relay = WF.SendQueue, WF.Relay
  return (queue and queue.sentBytes or 0) + (relay and relay.sentBytes or 0) + (relay and relay.boardBytes or 0)
end

-- Moves the bytes sent since the last sample into the current second.
function Traffic:Sample(now)
  now = now or Now()
  self.sampledAt = now
  local total = self:SentTotal()
  if self.lastOut and total > self.lastOut then
    local index = self:Slot(now)
    self.outBytes[index] = self.outBytes[index] + (total - self.lastOut)
  end
  self.lastOut = total
end

-- Players heard within ACTIVE seconds; older entries are forgotten.
function Traffic:ActivePlayers(now)
  now = now or Now()
  local count = 0
  for name, at in pairs(self.heard) do
    if now - at > self.ACTIVE then
      self.heard[name] = nil
      self.heardCount = self.heardCount - 1
    else
      count = count + 1
    end
  end
  return count
end

-- Writes the last WINDOW whole seconds, oldest first, into the two arrays.
-- Returns the totals received and sent, and the busiest second (in + out).
function Traffic:Fill(received, sent, now)
  now = now or Now()
  local second = floor(now) - 1
  local window = self.WINDOW
  local totalIn, totalOut, peak = 0, 0, 0
  for k = 1, window do
    local at = second - window + k
    local index = at % window + 1
    local inB, outB = 0, 0
    if self.stamps[index] == at then inB, outB = self.inBytes[index], self.outBytes[index] end
    received[k], sent[k] = inB, outB
    totalIn, totalOut = totalIn + inB, totalOut + outB
    if inB + outB > peak then peak = inB + outB end
  end
  return totalIn, totalOut, peak
end

-- A rate for display: whole bytes per second under 1 KB/s, else one decimal.
function Traffic.Rate(bytes)
  if bytes < 1024 then return string.format("%d B/s", floor(bytes + 0.5)) end
  return string.format("%.1f KB/s", bytes / 1024)
end

-- Event filters --------------------------------------------------------------

function Traffic:OnAddon(prefix, text, chatType, sender, now)
  if Secret(prefix) or Secret(text) or Secret(chatType) or Secret(sender) then return end
  if prefix ~= "WF" or type(text) ~= "string" or strSub(text, 1, 2) ~= "WF" then return end
  if not ADDON_TYPES[chatType] then return end
  local names = WF.Names
  local who = names and type(sender) == "string" and names.Identity(sender) or nil
  if who and who == self:Me() then return end
  self:Received(#text, who, now)
end

function Traffic:OnChannel(text, author, baseName, now)
  if Secret(text) or Secret(author) or Secret(baseName) then return end
  if type(text) ~= "string" or strSub(text, 1, 2) ~= "WF" then return end
  if type(baseName) ~= "string" or string.lower(baseName) ~= CHANNEL_KEY then return end
  local names = WF.Names
  local who = names and type(author) == "string" and author ~= "" and names.Identity(author) or nil
  if not who or who == self:Me() then return end
  self:Received(#text, who, now)
end

function Traffic:OnGameData(prefix, text, senderID, now)
  if Secret(prefix) or Secret(text) or Secret(senderID) then return end
  if prefix ~= "WF" or type(text) ~= "string" or strSub(text, 1, 2) ~= "WR" then return end
  local who = (type(senderID) == "number" or type(senderID) == "string") and (BN_KEY .. tostring(senderID)) or nil
  self:Received(#text, who, now)
end

-- Wiring ---------------------------------------------------------------------

if WF.RegisterEvent then
  WF.RegisterEvent("CHAT_MSG_ADDON", function(_, prefix, text, chatType, sender)
    Traffic:OnAddon(prefix, text, chatType, sender)
  end)
  WF.RegisterEvent("CHAT_MSG_CHANNEL", function(_, text, author, _, _, _, _, _, _, baseName)
    Traffic:OnChannel(text, author, baseName)
  end)
  WF.RegisterEvent("BN_CHAT_MSG_ADDON", function(_, prefix, text, _, senderID)
    Traffic:OnGameData(prefix, text, senderID)
  end)
end

if CreateFrame then
  local frame = CreateFrame("Frame", "WarfrontTrafficFrame", UIParent)
  frame:SetScript("OnUpdate", function()
    local now = Now()
    if not Traffic.sampledAt or now - Traffic.sampledAt >= 1 then Traffic:Sample(now) end
  end)
end
