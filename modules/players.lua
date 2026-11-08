Warfront = Warfront or {}

local WF = Warfront

-- Who plays Warfront right now: the members of the hidden Warfront channel,
-- read from the client's channel roster (C_ChatInfo.GetChannelRosterInfo).
-- Selecting the channel as the display channel asks the server for its roster;
-- CHANNEL_ROSTER_UPDATE / CHANNEL_COUNT_UPDATE then say it changed. Nothing is
-- sent on the channel, so it costs nothing to its budget (rule R17). Names
-- come from the server roster, never from a message body. The local character
-- is listed as soon as the channel is joined, before any roster answer, under
-- its full Forever name (core/names.lua), as the roster writes it.
local Players = {
  CHANNEL = "Warfront",
  -- A new request while the tab is open; never more than one per MIN_GAP.
  REFRESH = 30,
  MIN_GAP = 5,
  -- A roster read waiting for missing entries retries at most this often.
  READ_GAP = 1,
  MAX_NAMES = 500,
  names = {},
  me = nil,
  count = 0,
  updatedAt = nil,
  requestedAt = nil,
  readAt = nil,
  dirty = true,
  displayIndex = nil,
  requests = 0,
  answers = 0,
}

WF.Players = Players

local function GetGlobal(name)
  if WF.Compat and WF.Compat.Global then return WF.Compat.Global(name) end
  return _G and _G[name] or nil
end

local function Now()
  return WF.Now and WF.Now() or 0
end

local function IsSecret(value)
  local isSecret = GetGlobal("issecretvalue")
  return type(isSecret) == "function" and isSecret(value) and true or false
end

-- "5. Warfront" or "Warfront".
function Players.IsChannel(value)
  if type(value) ~= "string" or IsSecret(value) then return false end
  local name = string.gsub(value, "^%d+%.%s*", "")
  return string.lower(name) == string.lower(Players.CHANNEL)
end

-- A roster entry as chat shows it ("First Surname", decision 0070), with
-- "-Realm" only for another realm; nil for anything else.
function Players.CleanName(name)
  local names = WF.Names
  if not names or IsSecret(name) then return nil end
  local chatName, realm = names.Split(name)
  if not names.Valid(chatName) then return nil end
  if realm then
    if string.find(realm, "[%c|@]") or #realm > 48 then return nil end
    return chatName .. "-" .. realm
  end
  return chatName
end

local function MyName()
  local name = WF.Names and WF.Names.Mine()
  if name and WF.Names.Valid(name) then return name end
  return nil
end

-- The local channel number, 0 when not joined.
function Players:ChannelNumber()
  local get = GetGlobal("GetChannelName")
  if type(get) ~= "function" then return 0 end
  local ok, id = pcall(get, self.CHANNEL)
  if ok and type(id) == "number" and id > 0 then return id end
  return 0
end

function Players:Joined()
  return self:ChannelNumber() > 0
end

-- The roster API takes the channel's position in the display channel list,
-- not its chat number. Returns that position and the member count it shows.
function Players:FindDisplay()
  local num = GetGlobal("GetNumDisplayChannels")
  local info = GetGlobal("GetChannelDisplayInfo")
  if type(num) ~= "function" or type(info) ~= "function" then return nil end
  local number = self:ChannelNumber()
  if number == 0 then return nil end
  local ok, total = pcall(num)
  if not ok or type(total) ~= "number" then return nil end
  local index = 1
  while index <= total do
    local got, name, header, _, channelNumber, count = pcall(info, index)
    if got and not header and (channelNumber == number or Players.IsChannel(name)) then
      return index, type(count) == "number" and count or 0
    end
    index = index + 1
  end
  return nil
end

-- Rebuilds names from the roster. Returns true when the list was read.
function Players:Read(now)
  now = now or Now()
  self.readAt = now
  self.dirty = false
  local names = self.names
  local index = #names
  while index > 0 do
    table.remove(names)
    index = index - 1
  end
  if not self:Joined() then
    self.count, self.displayIndex = 0, nil
    return false
  end
  local seen = {}
  local me = MyName()
  self.me = me
  if me then
    seen[me] = true
    names[1] = me
  end
  local display, count = self:FindDisplay()
  self.displayIndex = display
  local chat = GetGlobal("C_ChatInfo")
  local roster = type(chat) == "table" and chat.GetChannelRosterInfo or nil
  local missing = false
  if display and type(roster) == "function" then
    local member = 1
    while member <= count and #names < self.MAX_NAMES do
      local ok, name = pcall(roster, display, member)
      name = ok and Players.CleanName(name) or nil
      if not name then
        missing = true
      else
        if not seen[name] then
          seen[name] = true
          names[#names + 1] = name
        end
      end
      member = member + 1
    end
    if count > 0 then self.answers = self.answers + 1 end
  end
  -- Entries the server has not sent yet: read again shortly.
  if missing then self.dirty = true end
  table.sort(names, function(a, b) return string.lower(a) < string.lower(b) end)
  self.count = #names
  self.updatedAt = now
  return true
end

-- Selecting a display channel changes the Chat Channels window's selection:
-- never do it while the player has that window open.
local function CanSelect()
  local frame = GetGlobal("ChannelFrame")
  if type(frame) == "table" and type(frame.IsShown) == "function" then
    local ok, shown = pcall(frame.IsShown, frame)
    if ok and shown then return false end
  end
  return true
end

-- Asks the server for the member list. False when too soon or not joined.
function Players:Request(now)
  now = now or Now()
  if self.requestedAt and now - self.requestedAt < self.MIN_GAP then return false end
  if not self:Joined() then
    self:Read(now)
    return false
  end
  self.requestedAt = now
  local display = self:FindDisplay()
  local selectChannel = GetGlobal("SetSelectedDisplayChannel")
  if display and type(selectChannel) == "function" and CanSelect() then
    if pcall(selectChannel, display) then self.requests = self.requests + 1 end
  end
  self:Read(now)
  return true
end

-- Called by the Players tab once per second while it is shown.
function Players:Tick(now)
  now = now or Now()
  local last = self.requestedAt
  if not last or now - last >= self.REFRESH then return self:Request(now) end
  if self.dirty and (not self.readAt or now - self.readAt >= self.READ_GAP) then
    self:Read(now)
  end
  return false
end

function Players:Summary()
  return "players=" .. self.count .. " requests=" .. self.requests .. " answers=" .. self.answers
    .. " display=" .. tostring(self.displayIndex)
end

local function OnRosterEvent(_, displayIndex)
  -- Our display position is checked at read time; any roster change marks dirty.
  if Players.displayIndex == nil or displayIndex == nil or displayIndex == Players.displayIndex then
    Players.dirty = true
  end
end

local function OnChannelsChanged()
  Players.displayIndex = nil
  Players.dirty = true
end

if WF.RegisterEvent then
  WF.RegisterEvent("CHANNEL_ROSTER_UPDATE", OnRosterEvent)
  WF.RegisterEvent("CHANNEL_COUNT_UPDATE", OnRosterEvent)
  WF.RegisterEvent("CHANNEL_UI_UPDATE", OnChannelsChanged)
end
