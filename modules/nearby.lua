local WF = Warfront

-- Nearby Warfront players of our faction (decision 0080, risk B70).
--
-- Without the custom channel, players at one POI who are not grouped heard
-- nothing of each other's presence, timer, stock or garrison: only group mates
-- got those lines. Here the client notices players of its faction near it, from
-- what it already shows (target, mouseover, focus, softfriend and nameplates),
-- greets them like the directory greets a listed player (our NP presence by
-- whisper), and the ones that answer become contacts. While we stand in a POI,
-- our local lines (presence, state, stock, garrison and their requests, pledges
-- and kills) also go by whisper to up to LOCAL_FAN of those contacts
-- (modules/transport.lua), the POI's authority first.
--   * Read only: units are read, never targeted or changed; nothing runs inside
--     an instance; a secret name or faction is skipped.
--   * An addon whisper never crosses factions: only our faction is kept.
--   * Greetings only while we stand in a POI: GREETS_PER_MIN a minute, one per
--     GREET_GAP s, UNLISTED_PER_MIN of them to players no list or friendship
--     says run Warfront; the directory's silence rules apply (a silent player
--     is left alone 24 hours, decision 0113 § 6).
-- Nothing is persisted. Values are provisional (decision 0080).

local Nearby = {
  seen = {}, seenCount = 0, reads = 0, secret = 0, otherFaction = 0, noSurname = 0, greeted = 0, capped = 0, scans = 0,
}
WF.Nearby = Nearby

local SEEN_TTL, MAX_SEEN = 180, 64
-- A greeting goes to a player seen within FRESH s.
local FRESH = 60
local SCAN_GAP, SCAN_GAP_OUTSIDE = 5, 20
local GREET_GAP, GREETS_PER_MIN, UNLISTED_PER_MIN = 3, 10, 4
local LOCAL_FAN = 4
local MAX_PLATES = 40
local UNITS = { "target", "mouseover", "focus", "softfriend" }
local TICK = 1

local nextTickAt, nextScanAt, nextGreetAt = 0, 0, 0
local minute = { at = -1000, greets = 0, unlisted = 0 }

-- Helpers ---------------------------------------------------------------------------

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
  return type(value) == "string" and value ~= "" and not IsSecret(value)
end

local function InInstance()
  local ok, inside = Call("IsInInstance")
  return ok and inside == true
end

local function Here()
  local presence = WF.Presence
  local area = presence and presence.current
  return type(area) == "table" and area.id or nil
end

local function Me()
  local capture = WF.Capture
  return capture and capture.Me and capture:Me() or nil
end

local function MyFactionTag()
  local ok, faction = Call("UnitFactionGroup", "player")
  if ok and Plain(faction) then return faction end
  return nil
end

-- Units -----------------------------------------------------------------------------

-- One unit the client shows: kept when it is another player of our faction
-- whose full name is readable.
function Nearby:Note(unit, now)
  if not Plain(unit) then return false end
  now = now or Now()
  local okExists, exists = Call("UnitExists", unit)
  if not okExists or exists ~= true then return false end
  local okPlayer, isPlayer = Call("UnitIsPlayer", unit)
  if not okPlayer or isPlayer ~= true then return false end
  local okSelf, isSelf = Call("UnitIsUnit", unit, "player")
  if okSelf and isSelf == true then return false end
  local okFaction, faction = Call("UnitFactionGroup", unit)
  local mine = MyFactionTag()
  if not okFaction or not Plain(faction) or not mine then
    self.secret = self.secret + 1
    return false
  end
  if faction ~= mine then
    self.otherFaction = self.otherFaction + 1
    return false
  end
  local okName, first, surname = Call("UnitName", unit)
  local names = WF.Names
  if not okName or not Plain(first) or not names then
    self.secret = self.secret + 1
    return false
  end
  local name = names.Full(first, surname)
  if not name or not names.Valid(name) then return false end
  -- No surname read: "Groumi" alone may be several characters (decision 0070).
  if names.Complete and not names.Complete(name) then
    self.noSurname = self.noSurname + 1
    return false
  end
  local capture = WF.Capture
  local identity = capture and capture.Identity and capture.Identity(name)
  if not identity or identity == Me() then return false end
  local entry = self.seen[identity]
  if not entry then
    if self.seenCount >= MAX_SEEN then
      local oldest, oldestAt
      for other, row in pairs(self.seen) do
        if not oldestAt or row.at < oldestAt then oldest, oldestAt = other, row.at end
      end
      if oldest then
        self.seen[oldest] = nil
        self.seenCount = self.seenCount - 1
      end
    end
    entry = {}
    self.seen[identity] = entry
    self.seenCount = self.seenCount + 1
  end
  entry.name, entry.at = name, now
  self.reads = self.reads + 1
  return true
end

-- Forever's nameplate frame keeps its unit in unitToken (Blizzard_NamePlateBase.lua
-- NamePlateBaseMixin:SetUnit); namePlateUnitToken is never set (nearby probe, 2026-11-09).
local function ReadPlateToken(plate) return plate.unitToken end

function Nearby:Scan(now)
  self.scans = self.scans + 1
  for i = 1, #UNITS do self:Note(UNITS[i], now) end
  local plates = Global("C_NamePlate")
  if type(plates) ~= "table" or type(plates.GetNamePlates) ~= "function" then return end
  local ok, list = pcall(plates.GetNamePlates)
  if not ok or type(list) ~= "table" then return end
  for i = 1, math.min(#list, MAX_PLATES) do
    local readable, token = pcall(ReadPlateToken, list[i])
    if readable then self:Note(token, now) end
  end
end

function Nearby:IsNearby(identity, now)
  local entry = type(identity) == "string" and self.seen[identity] or nil
  return entry ~= nil and (now or Now()) - entry.at <= SEEN_TTL
end

function Nearby:Name(identity, now)
  if not self:IsNearby(identity, now) then return nil end
  return self.seen[identity].name
end

function Nearby:Count(now)
  now = now or Now()
  local count = 0
  for identity in pairs(self.seen) do
    if self:IsNearby(identity, now) then count = count + 1 end
  end
  return count
end

-- Local targets -----------------------------------------------------------------------

-- Whisper names of up to `limit` contacts for our local lines while we stand in
-- a POI: contacts seen near us or present in that POI, the POI's authority
-- first, then the most recently seen; never `skip(identity)`.
function Nearby:Targets(now, limit, skip)
  now = now or Now()
  local here = Here()
  local directory, capture = WF.Directory, WF.Capture
  if not here or not directory or type(directory.ContactTargets) ~= "function" then return {} end
  local ok, contacts = pcall(directory.ContactTargets, directory, now)
  if not ok or type(contacts) ~= "table" then return {} end
  local st = capture and capture.states and capture.states[here]
  local authority = st and st.authority
  local list = {}
  for i = 1, #contacts do
    local entry = contacts[i]
    local identity = entry.identity
    if not (skip and skip(identity)) then
      local seenAt = self:IsNearby(identity, now) and self.seen[identity].at or nil
      local present = capture and type(capture.HasPresence) == "function" and capture:HasPresence(here, identity, now)
      if seenAt or present then
        list[#list + 1] = { target = entry.target, identity = identity, first = identity == authority,
          at = seenAt or now }
      end
    end
  end
  table.sort(list, function(a, b)
    if a.first ~= b.first then return a.first end
    if a.at ~= b.at then return a.at > b.at end
    return a.identity < b.identity
  end)
  local targets = {}
  for i = 1, math.min(limit or LOCAL_FAN, #list) do targets[i] = list[i].target end
  return targets
end

Nearby.LOCAL_FAN = LOCAL_FAN

-- Greetings -------------------------------------------------------------------------

local function Skip(identity, now)
  local transport, directory = WF.Transport, WF.Directory
  if transport and transport.IsGuildPeer and transport:IsGuildPeer(identity, now) then return true end
  if transport and transport.IsGroupMate and transport:IsGroupMate(identity, now) then return true end
  if directory and directory.IsContact and directory:IsContact(identity, now) then return true end
  return directory and directory.MayGreet and not directory:MayGreet(identity, now) or false
end

-- One greeting per call at most: a listed player (channel member or friend)
-- first, then the most recently seen.
function Nearby:Greet(now)
  local directory = WF.Directory
  if not directory or type(directory.GreetName) ~= "function" then return false end
  if now - minute.at >= 60 then minute.at, minute.greets, minute.unlisted = now, 0, 0 end
  if minute.greets >= GREETS_PER_MIN then return false end
  local best, bestListed, bestAt
  for identity, entry in pairs(self.seen) do
    if now - entry.at <= FRESH and not Skip(identity, now) then
      local listed = directory.Lists and directory:Lists(identity) or false
      if listed or minute.unlisted < UNLISTED_PER_MIN then
        if not best or (listed and not bestListed) or (listed == bestListed and entry.at > bestAt) then
          best, bestListed, bestAt = identity, listed, entry.at
        end
      end
    end
  end
  if not best then return false end
  if not directory:GreetName(best, self.seen[best].name, now) then return false end
  minute.greets = minute.greets + 1
  if not bestListed then minute.unlisted = minute.unlisted + 1 end
  self.greeted = self.greeted + 1
  return true
end

-- Ticks -----------------------------------------------------------------------------

function Nearby:Tick(now)
  if now < nextTickAt then return end
  nextTickAt = now + TICK
  if InInstance() then return end
  for identity, entry in pairs(self.seen) do
    if now - entry.at > SEEN_TTL then
      self.seen[identity] = nil
      self.seenCount = self.seenCount - 1
    end
  end
  local here = Here()
  if now >= nextScanAt then
    nextScanAt = now + (here and SCAN_GAP or SCAN_GAP_OUTSIDE)
    self:Scan(now)
  end
  local capture = WF.Capture
  if not here or (capture and capture.CanTalk and not capture:CanTalk()) then return end
  if now >= nextGreetAt and self:Greet(now) then nextGreetAt = now + GREET_GAP end
end

function Nearby:Summary()
  local now = Now()
  return "nearby seen=" .. self:Count(now) .. " reads=" .. self.reads .. " greeted=" .. self.greeted
    .. " unreadable=" .. self.secret .. " otherFaction=" .. self.otherFaction .. " noSurname=" .. self.noSurname .. " scans=" .. self.scans
    .. " targets=" .. #self:Targets(now, LOCAL_FAN)
end

-- Wiring ------------------------------------------------------------------------------

if WF.RegisterEvent then
  WF.RegisterEvent("NAME_PLATE_UNIT_ADDED", function(_, unit)
    if not InInstance() then Nearby:Note(unit, Now()) end
  end)
  WF.RegisterEvent("PLAYER_TARGET_CHANGED", function()
    if not InInstance() then Nearby:Note("target", Now()) end
  end)
  WF.RegisterEvent("UPDATE_MOUSEOVER_UNIT", function()
    if not InInstance() then Nearby:Note("mouseover", Now()) end
  end)
end

if CreateFrame then
  local frame = CreateFrame("Frame", "WarfrontNearbyFrame", UIParent)
  frame:SetScript("OnUpdate", function() Nearby:Tick(Now()) end)
end
