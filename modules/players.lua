Warfront = Warfront or {}

local WF = Warfront

-- Who plays Warfront right now: the members of the hidden Warfront channel,
-- read from the client's channel roster (C_ChatInfo.GetChannelRosterInfo),
-- plus the Warfront players this client already knows elsewhere (decision
-- 0080): guild mates and group mates heard sending Warfront lines, and
-- contacts made through a Battle.net friendship or near us. The roster is
-- loaded by the directory's guarded fetch (modules/directory.lua: another
-- display channel, then ours, never in combat, an instance or with the Channels
-- window open, off after a blocked action); this module never selects a display
-- channel itself. CHANNEL_ROSTER_UPDATE / CHANNEL_COUNT_UPDATE say it changed.
-- Nothing is sent, so it costs nothing (rule R17). Names come from the server
-- roster or the chat event sender, never from a message body. The local
-- character is listed as soon as the channel is joined, under its full Forever
-- name (core/names.lua), as the roster writes it.
local Players = {
  CHANNEL = "Warfront",
  -- A new request while the tab is open; never more than one per MIN_GAP.
  REFRESH = 30,
  MIN_GAP = 5,
  -- A roster read waiting for missing entries retries at most this often.
  READ_GAP = 1,
  -- The other sources are read again this often while the tab is open.
  MERGE_GAP = 5,
  MAX_NAMES = 500,
  names = {},
  -- name -> "near" | "group" | "guild" | "friend" for players known beyond the roster.
  tags = {},
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

-- Warfront players known beyond the roster, as { name, tag }, the strongest tag
-- kept per name: near us, then group, guild, friend (decision 0080).
local TAG_RANK = { near = 4, group = 3, guild = 2, friend = 1 }

local function KnownElsewhere(now)
  local found = {}
  local function Add(name, tag)
    name = Players.CleanName(name)
    if not name then return end
    if not found[name] or TAG_RANK[tag] > TAG_RANK[found[name]] then found[name] = tag end
  end
  local transport, directory = WF.Transport, WF.Directory
  if transport and type(transport.KnownPlayers) == "function" then
    local ok, list = pcall(transport.KnownPlayers, transport, now)
    if ok and type(list) == "table" then
      for i = 1, #list do Add(list[i].name, list[i].tag) end
    end
  end
  if directory and type(directory.KnownPlayers) == "function" then
    local ok, list = pcall(directory.KnownPlayers, directory, now)
    if ok and type(list) == "table" then
      for i = 1, #list do Add(list[i].name, list[i].tag) end
    end
  end
  return found
end

-- Rebuilds names from the roster and the other sources. Returns true when
-- anything was read.
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
  local tags = {}
  self.tags = tags
  local seen = {}
  local me = MyName()
  self.me = me
  local elsewhere = KnownElsewhere(now)
  for name, tag in pairs(elsewhere) do
    if name ~= me and #names < self.MAX_NAMES then
      seen[name] = true
      names[#names + 1] = name
      tags[name] = tag
    end
  end
  if not self:Joined() then
    self.displayIndex = nil
    if me and #names > 0 then names[#names + 1] = me end
    table.sort(names, function(a, b) return string.lower(a) < string.lower(b) end)
    self.count = #names
    self.updatedAt = #names > 0 and now or self.updatedAt
    return #names > 0
  end
  if me then
    seen[me] = true
    names[#names + 1] = me
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

-- Asks for a fresh member list through the directory's guarded fetch. False
-- when too soon or not joined.
function Players:Request(now)
  now = now or Now()
  if self.requestedAt and now - self.requestedAt < self.MIN_GAP then return false end
  if not self:Joined() then
    self:Read(now)
    return false
  end
  self.requestedAt = now
  local directory = WF.Directory
  if directory and type(directory.RequestFetch) == "function" then
    local ok, asked = pcall(directory.RequestFetch, directory, now)
    if ok and asked then self.requests = self.requests + 1 end
  end
  self:Read(now)
  return true
end

-- Called by the Players tab once per second while it is shown.
function Players:Tick(now)
  now = now or Now()
  local last = self.requestedAt
  if not last or now - last >= self.REFRESH then return self:Request(now) end
  if (self.dirty and (not self.readAt or now - self.readAt >= self.READ_GAP))
      or not self.readAt or now - self.readAt >= self.MERGE_GAP then
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
