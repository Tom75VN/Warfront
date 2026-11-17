local WF = Warfront

-- The Warfront channel's member list as a directory of contacts (decision 0077
-- step 4a). The server refuses sends on the channel, but its member list stays
-- readable: every Warfront player of our faction who joined it, "First Surname"
-- without a realm. An addon whisper reaches such a name (observed on Forever,
-- sources in docs/decisions/0077-same-faction-transport.md).
--   * The list is read every REFRESH s. When the game holds none, it fetches one
--     when our channel becomes the selected display channel: another entry is
--     selected, then ours (decision 0077 § 5c). Never in
--     combat, an instance or while the Channels window is open; at most once per
--     STALE s; a method that brings nothing waits STALE s. A blocked action
--     blamed on Warfront right after a selection stops fetching for the session.
--   * While fewer than MAX_CONTACTS answer, one listed player we do not hear yet
--     gets our NP presence by whisper, about once a minute. A Warfront client
--     answers with its own; each side then holds the other as a contact. A
--     greeted player who stays silent is left alone QUIET s (24 h, session
--     memory, capped at MAX_QUIET names).
--   * A contact gets our presence again every CONTACT_REFRESH s, so the owner
--     digest it carries stays current (modules/catchup.lua pulls on a difference),
--     and our own critical events first-hand (modules/transport.lua).
--   * Same-faction Battle.net friends on our realm (modules/relay.lua's friend
--     scan) are listed names too, so a player outside the channel, a guild and
--     a group still finds contacts (decision 0077 § 5f).
--   * How many contacts we keep and how far a fact goes hand to hand grow with
--     the number of listed names (TIERS, § 5f).
--   * Join and leave notices (decision 0113): a player joining our channel is
--     listed at once and greeted first, within the usual greeting gap; one
--     leaving it is unlisted and stops being a contact unless a guild, a
--     friendship or nearness keeps it. A player joining a local zone channel
--     (General, Trade...) is kept LOCAL_TTL s as a last-choice candidate, never
--     counted in TIERS. Once a notice has been read, the full list is read
--     every REFRESH_NOTICED s only.
-- Nothing is persisted; nothing runs inside an instance. Values are provisional.

local Directory = {
  names = {}, nameCount = 0, friends = {}, friendCount = 0, readAt = nil, nextReadAt = 0, fetchAt = nil,
  failed = {}, rows = {}, rowCount = 0, replies = { at = -1000, count = 0 },
  locals = {}, localCount = 0, joinedAt = {}, noticedAt = nil, lastGreetAt = nil,
  quiet = {}, quietCount = 0,
  disabled = nil, lastSelectAt = nil, state = "starting",
  reads = 0, fetches = 0, fetchFailed = 0, greeted = 0, answered = 0, greetedUs = 0,
  repliesSent = 0, repliesCapped = 0, silent = 0, unreachable = 0, refreshes = 0,
  joins = 0, leaves = 0, localJoins = 0, dropped = 0,
}
WF.Directory = Directory

local CHANNEL = "warfront"
local TICK = 5
local REFRESH, STALE, RETRY = 600, 1800, 60
local POLLS = { 3, 8 }
local METHODS = { "group", "custom", "world" }
local MAX_NAMES, MAX_DISPLAY = 500, 60
local GREET_GAP, GREET_JITTER = 60, 30
local MAX_FRIENDS = 200
-- By listed names (channel members and same-faction friends), at most: the
-- contacts we greet for, the author's own fan-out (modules/transport.lua) and
-- the fan-outs of the next three hands (modules/chain.lua). The first tier is
-- the one measured since step 4b; the others keep about four whispers per
-- client and per fact (decision 0077 § 5f, simulation only).
local TIERS = {
  { upto = 60, contacts = 6, author = 4, fans = { 3, 3, 2 } },
  { upto = 150, contacts = 8, author = 5, fans = { 4, 3, 3 } },
  { upto = math.huge, contacts = 10, author = 6, fans = { 5, 4, 3 } },
}
local PRESENCE_GAP, ANSWER_WAIT, SILENT = 150, 30, 1800
-- A greeted player who never answers runs no Warfront: not greeted again for
-- QUIET s (session memory only, at most MAX_QUIET names). If it installs
-- Warfront later, its own greeting reaches us and clears the entry.
local QUIET, MAX_QUIET = 86400, 2000
local REPLIES_PER_MIN = 6
local CONTACT_TTL, CONTACT_REFRESH, REFRESH_JITTER = 1800, 600, 60
local UNREACHABLE_WAIT = 600
local MAX_ROWS = 400
local BLOCK_WINDOW = 1
-- Notices (decision 0113): a joiner is "fresh" JOIN_FRESH s; its greeting
-- comes JOIN_DELAY to JOIN_DELAY + JOIN_JITTER s later, never before
-- GREET_GAP s after the previous one.
local REFRESH_NOTICED = 1800
local JOIN_FRESH, JOIN_DELAY, JOIN_JITTER = 120, 5, 10
local LOCAL_TTL, MAX_LOCAL = 900, 64

local strLower, strFind, mathRandom, mathMin = string.lower, string.find, math.random, math.min
local nextTickAt, fetching = 0, nil

-- Helpers -------------------------------------------------------------------------

local function Now()
  local now = WF.Now and WF.Now() or 0
  if type(now) ~= "number" then return 0 end
  return now
end

local function Global(name)
  if WF.Compat and WF.Compat.Global then return WF.Compat.Global(name) end
  return _G and _G[name] or nil
end

local function Call(name, ...)
  local fn = Global(name)
  if type(fn) ~= "function" then return false end
  return pcall(fn, ...)
end

local function IsSecret(value)
  local fn = Global("issecretvalue")
  if type(fn) ~= "function" then return false end
  local ok, secret = pcall(fn, value)
  return ok and secret and true or false
end

local function Plain(value)
  return value == nil or not IsSecret(value)
end

local function InInstance()
  local ok, inside = Call("IsInInstance")
  return ok and inside == true
end

local function InCombat()
  local restricted = Global("C_RestrictedActions")
  if type(restricted) ~= "table" or type(restricted.InCombatLockdown) ~= "function" then return false end
  local ok, locked = pcall(restricted.InCombatLockdown)
  return ok and locked == true
end

-- The Channels window shows the selected channel's members: never select under it.
local function WindowOpen()
  local frame = Global("ChannelFrame")
  if type(frame) ~= "table" or type(frame.IsShown) ~= "function" then return false end
  local ok, shown = pcall(frame.IsShown, frame)
  return not ok or shown == true
end

local function Identity(name)
  local capture = WF.Capture
  return capture and capture.Identity and capture.Identity(name) or nil
end

local function Me()
  local capture = WF.Capture
  return capture and capture.Me and capture:Me() or nil
end

local function IsGuildPeer(identity, now)
  local transport = WF.Transport
  return transport and transport.IsGuildPeer and transport:IsGuildPeer(identity, now) or false
end

-- The member list -----------------------------------------------------------------

-- Our channel's display index and member count (nil until fetched), and one
-- entry of each kind that can be selected before it.
local function ScanDisplay()
  local okSize, size = Call("GetNumDisplayChannels")
  size = okSize and tonumber(size) or MAX_DISPLAY
  local ours, members, entries = nil, nil, {}
  for index = 1, mathMin(size, MAX_DISPLAY) do
    local ok, name, header, _, _, count, _, category = Call("GetChannelDisplayInfo", index)
    if ok and type(name) == "string" and Plain(name) and Plain(header) and Plain(count) and Plain(category)
        and not header and name ~= "" then
      if strLower(name) == CHANNEL then
        ours, members = index, tonumber(count)
      elseif category == "CHANNEL_CATEGORY_GROUP" then
        if (tonumber(count) or 0) > 0 then entries.group = entries.group or index end
      elseif category == "CHANNEL_CATEGORY_CUSTOM" then
        entries.custom = entries.custom or index
      elseif category == "CHANNEL_CATEGORY_WORLD" then
        entries.world = entries.world or index
      end
    end
  end
  return ours, members, entries
end

local function ReadList(index, members)
  local chat = Global("C_ChatInfo")
  if type(chat) ~= "table" or type(chat.GetChannelRosterInfo) ~= "function" then return nil end
  local me = Me()
  local names, count = {}, 0
  for k = 1, mathMin(members, MAX_NAMES) do
    local ok, name = pcall(chat.GetChannelRosterInfo, index, k)
    if ok and type(name) == "string" and Plain(name) and name ~= "" then
      local identity = Identity(name)
      if identity and identity ~= me and not names[identity] then
        names[identity] = name
        count = count + 1
      end
    end
  end
  return names, count
end

-- A player who answered us before it was listed becomes a contact as soon as a
-- list names it (risk B71): it need not greet us again.
local function Upgrade(directory, now)
  for identity, row in pairs(directory.rows) do
    if row.answered and not row.contact and row.heardAt and now - row.heardAt <= CONTACT_TTL
        and directory:Lists(identity) then
      row.contact = true
      directory.upgraded = (directory.upgraded or 0) + 1
    end
  end
end

function Directory:Take(index, members, now)
  local names, count = ReadList(index, members)
  if not names then
    self.state = "member list unreadable"
    return false
  end
  self.names, self.nameCount, self.readAt, self.state = names, count, now, "listed"
  self.nextReadAt = now + (self.noticedAt and REFRESH_NOTICED or REFRESH)
  self.reads = self.reads + 1
  Upgrade(self, now)
  return true
end

local function Select(index, now)
  if not index then return false end
  Directory.lastSelectAt = now
  return Call("SetSelectedDisplayChannel", index)
end

function Directory:CanFetch()
  return not self.disabled and not InInstance() and not InCombat() and not WindowOpen()
end

-- The Players tab asks for a fresh member list: read within a tick through the
-- same guarded fetch (a fresh list is read without selecting anything). False
-- when fetching is off.
function Directory:RequestFetch(now)
  if self.disabled then return false end
  if self.nextReadAt > now then self.nextReadAt = now end
  return true
end

-- Contacts by where they came from, for the Players tab: { name, tag }.
function Directory:KnownPlayers(now)
  local list = {}
  local nearby = WF.Nearby
  for identity, row in pairs(self.rows) do
    if self:IsContact(identity, now) and row.target then
      local tag
      if nearby and nearby.IsNearby and nearby:IsNearby(identity, now) then tag = "near"
      elseif self.friends[identity] then tag = "friend" end
      if tag then list[#list + 1] = { name = row.target, tag = tag } end
    end
  end
  return list
end

function Directory:Refresh(now)
  self.nextReadAt = now + RETRY
  if not self:CanFetch() then return false end
  local index, members, entries = ScanDisplay()
  if not index then
    self.state = "not in the channel"
    return false
  end
  local fresh = self.fetchAt and now - self.fetchAt < STALE
  if members and members > 0 and fresh then return self:Take(index, members, now) end
  local method, other
  for i = 1, #METHODS do
    local candidate = METHODS[i]
    local failedAt = self.failed[candidate]
    if entries[candidate] and entries[candidate] ~= index and not (failedAt and now - failedAt < STALE) then
      method, other = candidate, entries[candidate]
      break
    end
  end
  if not method then
    if members and members > 0 then return self:Take(index, members, now) end
    self.state = "member list not loaded"
    return false
  end
  if not (Select(other, now) and Select(index, now)) then
    self.failed[method] = now
    self.state = "member list not loaded"
    return false
  end
  self.fetches = self.fetches + 1
  fetching = { method = method, at = now, polls = 1, fromNothing = not (members and members > 0) }
  return true
end

function Directory:Poll(now)
  local fetch = fetching
  if not fetch or now < fetch.at + POLLS[fetch.polls] then return end
  if InInstance() or InCombat() or WindowOpen() then
    fetching = nil
    self.nextReadAt = now + RETRY
    return
  end
  local index, members = ScanDisplay()
  if index and members and members > 0 then
    fetching, self.fetchAt = nil, now
    self.failed[fetch.method] = nil
    self:Take(index, members, now)
    return
  end
  if fetch.polls < #POLLS then
    fetch.polls = fetch.polls + 1
    return
  end
  fetching = nil
  self.failed[fetch.method] = now
  self.fetchFailed = self.fetchFailed + 1
  self.state = "member list not loaded"
end

-- A blocked action blamed on Warfront right after our selection: stop for the session.
function Directory:OnBlocked(source, now)
  if self.disabled or source ~= "Warfront" or not self.lastSelectAt then return end
  if now - self.lastSelectAt <= BLOCK_WINDOW then
    self.disabled = "selection blocked"
    self.state = "fetching off (blocked)"
    fetching = nil
  end
end

function Directory:Lists(identity)
  return type(identity) == "string" and (self.names[identity] ~= nil or self.friends[identity] ~= nil)
end

-- Same-faction Battle.net friends' chat names from the relay's friend scan.
function Directory:TakeFriends(list, now)
  if type(list) ~= "table" then return false end
  local me = Me()
  local friends, count = {}, 0
  for i = 1, mathMin(#list, MAX_FRIENDS) do
    local name = list[i]
    if type(name) == "string" and name ~= "" and Plain(name) then
      local identity = Identity(name)
      if identity and identity ~= me and not friends[identity] then
        friends[identity] = name
        count = count + 1
      end
    end
  end
  self.friends, self.friendCount = friends, count
  Upgrade(self, now)
  return true
end

-- The tier for the names we list now.
local function Tier(directory)
  local listed = (directory.nameCount or 0) + (directory.friendCount or 0)
  for i = 1, #TIERS do
    if listed <= TIERS[i].upto then return TIERS[i] end
  end
  return TIERS[#TIERS]
end

function Directory:MaxContacts()
  return Tier(self).contacts
end

-- Fan-outs of the three hands after the author, and the author's own.
function Directory:Fans()
  local tier = Tier(self)
  return tier.fans, tier.author
end

local function ListedName(directory, identity)
  return directory.names[identity] or directory.friends[identity]
end

-- Contacts ----------------------------------------------------------------------------

local function Row(identity, create, now)
  local row = Directory.rows[identity]
  if row or not create then return row end
  if Directory.rowCount >= MAX_ROWS then
    for other, entry in pairs(Directory.rows) do
      local last = entry.heardAt or entry.greetedAt or entry.presenceAt or -1e9
      if now - last > SILENT then
        Directory.rows[other] = nil
        Directory.rowCount = Directory.rowCount - 1
      end
    end
    if Directory.rowCount >= MAX_ROWS then return nil end
  end
  row = { rank = mathRandom() }
  Directory.rows[identity] = row
  Directory.rowCount = Directory.rowCount + 1
  return row
end

-- A contact: a listed player or a guild peer whose presence came to us by
-- whisper, heard within CONTACT_TTL. A whisper alone makes no contact.
function Directory:IsContact(identity, now)
  local row = self.rows[identity]
  return row ~= nil and row.contact == true and row.heardAt ~= nil and now - row.heardAt <= CONTACT_TTL
end

function Directory:ContactCount(now)
  local count = 0
  for identity in pairs(self.rows) do
    if self:IsContact(identity, now) then count = count + 1 end
  end
  return count
end

-- Whisper names of up to `limit` contacts, the least recently given a fact
-- first, skipping `skip(identity)`. Ties go by a rank each client draws for
-- each row: by name, every client would pick the same contacts and the end of
-- the alphabet would never be served.
function Directory:Contacts(now, limit, skip)
  local list = {}
  for identity, row in pairs(self.rows) do
    if self:IsContact(identity, now) and row.target and not (skip and skip(identity)) then
      list[#list + 1] = { identity = identity, row = row }
    end
  end
  table.sort(list, function(a, b)
    local ta, tb = a.row.factAt or 0, b.row.factAt or 0
    if ta ~= tb then return ta < tb end
    if a.row.rank ~= b.row.rank then return a.row.rank < b.row.rank end
    return a.identity < b.identity
  end)
  local targets = {}
  for i = 1, mathMin(limit, #list) do
    list[i].row.factAt = now
    targets[#targets + 1] = list[i].row.target
  end
  return targets
end

-- Every live contact as { identity, target, at = last heard }, no side effect
-- (modules/transport.lua picks addressed catch-up targets from them).
function Directory:ContactTargets(now)
  local list = {}
  for identity, row in pairs(self.rows) do
    if self:IsContact(identity, now) and row.target then
      list[#list + 1] = { identity = identity, target = row.target, at = row.heardAt }
    end
  end
  return list
end

local function SendPresence(row, target, now)
  local transport = WF.Transport
  if not transport or type(transport.SendPresenceTo) ~= "function" then return false end
  local ok, sent = pcall(transport.SendPresenceTo, transport, target)
  if not ok or not sent then return false end
  row.presenceAt = now
  return true
end

local function Quiet(directory, identity, now)
  local untilAt = directory.quiet[identity]
  return untilAt ~= nil and untilAt > now
end

local function Unquiet(directory, identity)
  if directory.quiet[identity] then
    directory.quiet[identity] = nil
    directory.quietCount = directory.quietCount - 1
  end
end

-- Left alone QUIET s; when the registry is full, expired entries go first,
-- then the one that ends soonest.
local function Hush(directory, identity, now)
  if not directory.quiet[identity] and directory.quietCount >= MAX_QUIET then
    local soonest, soonestAt
    for other, untilAt in pairs(directory.quiet) do
      if untilAt <= now then
        Unquiet(directory, other)
      elseif not soonest or untilAt < soonestAt then
        soonest, soonestAt = other, untilAt
      end
    end
    if directory.quietCount >= MAX_QUIET and soonest then Unquiet(directory, soonest) end
  end
  if not directory.quiet[identity] then directory.quietCount = directory.quietCount + 1 end
  directory.quiet[identity] = now + QUIET
end

local function Eligible(directory, identity, now)
  local row = directory.rows[identity]
  return not directory:IsContact(identity, now) and not IsGuildPeer(identity, now) and not Quiet(directory, identity, now)
    and not (row and ((row.silentUntil or 0) > now or now - (row.presenceAt or -1e9) < PRESENCE_GAP))
end

-- A player we neither hear nor greeted lately, not left alone: a fresh joiner
-- of our channel first, then a listed player, then a local channel joiner.
function Directory:PickNew(now)
  local best, bestAt
  for identity, at in pairs(self.joinedAt) do
    if now - at > JOIN_FRESH or not self.names[identity] then
      self.joinedAt[identity] = nil
    elseif Eligible(self, identity, now) and (not best or at > bestAt) then
      best, bestAt = identity, at
    end
  end
  if best then return best end
  local list, added = {}, {}
  for identity in pairs(self.names) do list[#list + 1], added[identity] = identity, true end
  for identity in pairs(self.friends) do
    if not added[identity] then list[#list + 1] = identity end
  end
  local size = #list
  if size > 0 then
    table.sort(list)
    local start = mathRandom(1, size)
    for step = 0, mathMin(size, 40) - 1 do
      local identity = list[(start + step - 1) % size + 1]
      if Eligible(self, identity, now) then return identity end
    end
  end
  for identity, entry in pairs(self.locals) do
    if now - entry.at <= LOCAL_TTL and not self:Lists(identity) and Eligible(self, identity, now)
        and (not best or entry.at > bestAt) then
      best, bestAt = identity, entry.at
    end
  end
  return best
end

function Directory:Greet(identity, now)
  local name = ListedName(self, identity)
  if not name and self.locals[identity] then name = self.locals[identity].name end
  return self:GreetName(identity, name, now)
end

-- Join and leave notices (decision 0113) -------------------------------------------

local function IsOurChannel(channelName, baseName)
  if type(baseName) == "string" and Plain(baseName) and baseName ~= "" then
    return strLower(baseName) == CHANNEL
  end
  if type(channelName) == "string" and Plain(channelName) then
    return strLower((string.gsub(channelName, "^%d+%.%s*", ""))) == CHANNEL
  end
  return false
end

local function ChatName(name)
  local names = WF.Names
  if names and type(names.Split) == "function" then
    local ok, chat = pcall(names.Split, name)
    if ok and type(chat) == "string" and chat ~= "" then return chat end
  end
  return nil
end

local function DropLocal(directory, identity)
  if directory.locals[identity] then
    directory.locals[identity] = nil
    directory.localCount = directory.localCount - 1
  end
end

-- A listed name brings the next greeting forward, never closer than GREET_GAP
-- to the previous one.
local function GreetSoon(directory, now)
  if directory:ContactCount(now) >= directory:MaxContacts() then return end
  local at = now + JOIN_DELAY + mathRandom() * JOIN_JITTER
  if directory.lastGreetAt and at < directory.lastGreetAt + GREET_GAP then at = directory.lastGreetAt + GREET_GAP end
  if at < (directory.nextGreetAt or 0) then directory.nextGreetAt = at end
end

-- `joined`: true for CHAT_MSG_CHANNEL_JOIN, false for CHAT_MSG_CHANNEL_LEAVE.
-- Names come from the server; a secret or unreadable field drops the notice.
function Directory:OnChannelNotice(joined, playerName, channelName, zoneChannelID, baseName, now)
  if type(playerName) ~= "string" or playerName == "" or not Plain(playerName)
      or not Plain(channelName) or not Plain(zoneChannelID) or not Plain(baseName) then
    return false
  end
  local identity, target = Identity(playerName), ChatName(playerName)
  if not identity or not target or identity == Me() then return false end
  if IsOurChannel(channelName, baseName) then
    self.noticedAt = now
    if self.readAt and self.nextReadAt < self.readAt + REFRESH_NOTICED then
      self.nextReadAt = self.readAt + REFRESH_NOTICED
    end
    if joined then
      if not self.names[identity] then
        if self.nameCount >= MAX_NAMES then return false end
        self.names[identity] = target
        self.nameCount = self.nameCount + 1
      end
      DropLocal(self, identity)
      self.joinedAt[identity] = now
      self.joins = self.joins + 1
      Upgrade(self, now)
      GreetSoon(self, now)
    else
      if self.names[identity] then
        self.names[identity] = nil
        self.nameCount = self.nameCount - 1
      end
      self.joinedAt[identity] = nil
      self.leaves = self.leaves + 1
      local row = self.rows[identity]
      local nearby = WF.Nearby
      local near = nearby ~= nil and type(nearby.IsNearby) == "function" and nearby:IsNearby(identity, now)
      if row and row.contact and not self.friends[identity] and not IsGuildPeer(identity, now) and not near then
        row.contact = nil
        self.dropped = self.dropped + 1
      end
    end
    return true
  end
  if type(zoneChannelID) ~= "number" or zoneChannelID <= 0 then return false end
  if not joined then
    DropLocal(self, identity)
    return true
  end
  if self:Lists(identity) then return false end
  local entry = self.locals[identity]
  if entry then
    entry.at, entry.name = now, target
  else
    if self.localCount >= MAX_LOCAL then
      local oldest, oldestAt
      for other, item in pairs(self.locals) do
        if not oldest or item.at < oldestAt then oldest, oldestAt = other, item.at end
      end
      DropLocal(self, oldest)
    end
    self.locals[identity] = { name = target, at = now }
    self.localCount = self.localCount + 1
  end
  self.localJoins = self.localJoins + 1
  return true
end

local function JoinedLocally(directory, identity, now)
  local entry = directory.locals[identity]
  return entry ~= nil and now - entry.at <= LOCAL_TTL
end

-- Our presence whispered to `name` (a listed player, or one seen near us,
-- modules/nearby.lua).
function Directory:GreetName(identity, name, now)
  if type(identity) ~= "string" or type(name) ~= "string" or name == "" then return false end
  local row = Row(identity, true, now)
  if not row then return false end
  row.target = name
  if not SendPresence(row, name, now) then return false end
  row.greetedAt, row.answered = now, nil
  self.greeted = self.greeted + 1
  return true
end

-- Whether a player may be greeted now: not left alone, not greeted lately.
function Directory:MayGreet(identity, now)
  if Quiet(self, identity, now) then return false end
  local row = self.rows[identity]
  if not row then return true end
  if (row.silentUntil or 0) > now then return false end
  return now - (row.presenceAt or -1e9) >= PRESENCE_GAP
end

local function SeenNearby(identity, now)
  local nearby = WF.Nearby
  return nearby ~= nil and type(nearby.IsNearby) == "function" and nearby:IsNearby(identity, now) or false
end

-- Our NP presence came back whispered: a greeting or the answer to ours
-- (modules/transport.lua). `sender` is the whisper name the event gave.
function Directory:OnWhisperPresence(identity, sender, now)
  if type(identity) ~= "string" or type(sender) ~= "string" then return false end
  local row = Row(identity, true, now)
  if not row then return false end
  if row.greetedAt and not row.answered and now - row.greetedAt <= ANSWER_WAIT then
    self.answered = self.answered + 1
  elseif not row.heardAt or now - row.heardAt > PRESENCE_GAP then
    self.greetedUs = self.greetedUs + 1
  end
  row.answered, row.heardAt, row.silentUntil, row.target = true, now, nil, sender
  Unquiet(self, identity)
  local listed = self:Lists(identity)
  -- A player we saw near us is a contact too (decision 0080), and one who
  -- joined our local channel lately (decision 0113).
  row.contact = listed or IsGuildPeer(identity, now) or SeenNearby(identity, now) or JoinedLocally(self, identity, now)
  -- A newcomer to the list: read it again soon.
  if not listed and self.readAt and now - self.readAt >= RETRY and self.nextReadAt > now + RETRY then
    self.nextReadAt = now + RETRY
  end
  if now - (row.presenceAt or -1e9) < PRESENCE_GAP then return row.contact end
  local replies = self.replies
  if now - replies.at >= 60 then replies.at, replies.count = now, 0 end
  if replies.count >= REPLIES_PER_MIN then
    self.repliesCapped = self.repliesCapped + 1
    return row.contact
  end
  if SendPresence(row, sender, now) then
    replies.count = replies.count + 1
    self.repliesSent = self.repliesSent + 1
  end
  return row.contact
end

-- A whisper to `target` came back "no player named": no contact until it greets us again.
function Directory:NoteUnreachable(target, now)
  if type(target) ~= "string" then return end
  local lowered = strLower(target)
  for _, row in pairs(self.rows) do
    if row.target and strLower(row.target) == lowered then
      row.contact, row.heardAt = nil, nil
      row.silentUntil = now + UNREACHABLE_WAIT
      self.unreachable = self.unreachable + 1
    end
  end
end

-- Ticks -----------------------------------------------------------------------------

function Directory:Tick(now)
  if now < nextTickAt then return end
  nextTickAt = now + TICK
  if InInstance() then
    fetching = nil
    return
  end
  if fetching then
    self:Poll(now)
  elseif now >= self.nextReadAt then
    self:Refresh(now)
  end
  -- Silent greetings, and old rows.
  for identity, row in pairs(self.rows) do
    if row.greetedAt and not row.answered and now - row.greetedAt > ANSWER_WAIT then
      row.greetedAt, row.silentUntil = nil, now + SILENT
      Hush(self, identity, now)
      self.silent = self.silent + 1
    end
    local last = row.heardAt or row.greetedAt or row.presenceAt or row.silentUntil or -1e9
    if now - last > SILENT and not (row.silentUntil and row.silentUntil > now) then
      self.rows[identity] = nil
      self.rowCount = self.rowCount - 1
    end
  end
  for identity, entry in pairs(self.locals) do
    if now - entry.at > LOCAL_TTL then DropLocal(self, identity) end
  end
  local capture = WF.Capture
  if capture and capture.CanTalk and not capture:CanTalk() then return end
  -- One contact refreshed per tick: its presence keeps our digest current there.
  for identity, row in pairs(self.rows) do
    if self:IsContact(identity, now) and row.target then
      row.refreshAt = row.refreshAt or (now + CONTACT_REFRESH + mathRandom() * REFRESH_JITTER)
      if now >= row.refreshAt then
        row.refreshAt = now + CONTACT_REFRESH + mathRandom() * REFRESH_JITTER
        if SendPresence(row, row.target, now) then self.refreshes = self.refreshes + 1 end
        break
      end
    end
  end
  if self.nameCount + self.friendCount + self.localCount > 0 and now >= (self.nextGreetAt or 0) then
    local greeted = false
    if self:ContactCount(now) < self:MaxContacts() then
      local identity = self:PickNew(now)
      greeted = identity ~= nil and self:Greet(identity, now)
    end
    if greeted then self.lastGreetAt = now end
    self.nextGreetAt = greeted and (now + GREET_GAP + mathRandom() * GREET_JITTER) or (now + TICK)
  end
end

function Directory:Summary()
  local now = Now()
  return "directory " .. tostring(self.state) .. " names=" .. self.nameCount .. " friends=" .. self.friendCount
    .. " contacts=" .. self:ContactCount(now) .. "/" .. self:MaxContacts() .. " greeted=" .. self.greeted .. " answered=" .. self.answered
    .. " greetedUs=" .. self.greetedUs .. " replies=" .. self.repliesSent .. " silent=" .. self.silent
    .. " unreachable=" .. self.unreachable .. " reads=" .. self.reads .. " fetches=" .. self.fetches
    .. " fetchFailed=" .. self.fetchFailed .. " joins=" .. self.joins .. " leaves=" .. self.leaves
    .. " dropped=" .. self.dropped .. " local=" .. self.localCount .. "/" .. self.localJoins .. " quiet=" .. self.quietCount
    .. (self.disabled and (" off=" .. self.disabled) or "")
end

-- Wiring ------------------------------------------------------------------------------

if WF.RegisterEvent then
  local function OnBlocked(_, source)
    if IsSecret(source) then return end
    Directory:OnBlocked(source, Now())
  end
  WF.RegisterEvent("ADDON_ACTION_BLOCKED", OnBlocked)
  WF.RegisterEvent("ADDON_ACTION_FORBIDDEN", OnBlocked)
  -- CHAT_MSG_CHANNEL_JOIN/LEAVE(text, playerName, languageName, channelName,
  -- playerName2, specialFlags, zoneChannelID, channelIndex, channelBaseName).
  local function OnNotice(joined)
    return function(_, _, playerName, _, channelName, _, _, zoneChannelID, _, baseName)
      if InInstance() then return end
      Directory:OnChannelNotice(joined, playerName, channelName, zoneChannelID, baseName, Now())
    end
  end
  WF.RegisterEvent("CHAT_MSG_CHANNEL_JOIN", OnNotice(true))
  WF.RegisterEvent("CHAT_MSG_CHANNEL_LEAVE", OnNotice(false))
end

if CreateFrame then
  local frame = CreateFrame("Frame", "WarfrontDirectoryFrame", UIParent)
  frame:SetScript("OnUpdate", function() Directory:Tick(Now()) end)
end
