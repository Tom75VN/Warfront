local WF = Warfront

-- World layer of the local player (decision 0142, replacing 0119 § 1).
--
-- From game build 71037 every creature carries a GUID number of its own
-- (ForeverRuntimeProbe `layer.v3`, 2026-11-23, knowledge base § Units and
-- nameplates), so no creature names a layer any more. A layer is a tag `a:b`
-- of our own instead:
--   * Drawn at random at login, at a loading screen, on leaving an instance and
--     at a SHARD_TRANSFER, unless the move came from a known player: the
--     helper of a jump (Layer:Expect) or the leader of our group, whose tag we
--     adopt. None inside an instance.
--   * Contact: in a POI, a player of either faction whom the client draws (a
--     nameplate, or a unit token with UnitIsVisible) and who has a live
--     presence there stands on our layer. That makes our tag shared, and the
--     POI's arena tag is kept when either of us holds it, else the smaller of
--     the two tags (a, then b), so players who see each other converge on one
--     tag without renaming the arena; players on two layers never see each
--     other. A unit token on another layer (UnitPhaseReason) is never drawn.
--   * Current() is the tag once shared, nil before: an unshared tag counts as
--     an unknown layer (decision 0119 § 5). Mine() is the tag, shared or not.
--   * A /reload within RESTORE_FOR s in the same zone keeps the tag
--     (WarfrontDB.settings.layerTag, one row, written at logout).
-- Read only; nothing is sent here. A bounded diagnostic journal
-- (WarfrontDB.layerLog, last LOG_MAX entries) records new, shared, adopted and
-- reset tags, zone, group and instance changes; no rule reads it.

local Layer = {
  key = nil, shared = false, at = 0, origin = nil,
  news = 0, adopts = 0, shares = 0, contacts = 0, restores = 0, resets = 0, transfers = 0, scans = 0,
}
WF.Layer = Layer

-- Contact scan every SCAN_GAP s while we stand in a POI.
local SCAN_GAP, MAX_PLATES, TICK = 2, 40, 1
local UNITS = {
  "target", "mouseover", "focus", "softenemy", "softfriend", "targettarget", "focustarget", "mouseovertarget",
  "party1target", "party2target", "party3target", "party4target",
}
-- A /reload keeps the tag within RESTORE_FOR s of the logout, in the same zone,
-- if the zone is readable within RESTORE_WINDOW s of the loading screen.
local RESTORE_FOR, RESTORE_WINDOW = 120, 10
local TAG_MAX_A, TAG_MAX_B = 999999999, 99
local LOG_MAX = 300

local expected -- { key, untilAt }: the tag a jump's move brings (Layer:Expect)
local restore -- { key, shared, zone, untilAt }: the tag kept across a /reload
local nextTickAt, nextScanAt = 0, 0
local grouped, lastZone, inside = nil, nil, false

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

local function InInstance()
  local ok, inside = Call("IsInInstance")
  return ok and inside == true
end

-- True, false, or nil when unreadable.
local function Flag(name, unit)
  local ok, value = Call(name, unit)
  if not ok or IsSecret(value) then return nil end
  return value and true or false
end

local function InGroup()
  return Flag("UnitExists", "party1") == true or Flag("UnitExists", "raid1") == true
end

local function ZoneKey()
  local map = WF.Map
  if type(map) ~= "table" or type(map.PlayerZoneKey) ~= "function" then return nil end
  local ok, zone = pcall(map.PlayerZoneKey, map)
  if ok and type(zone) == "string" then return zone end
  return nil
end

local function Settings()
  local storage = WF.Storage
  if type(storage) ~= "table" or type(storage.GetDB) ~= "function" or storage.readOnly then return nil end
  local db = storage:GetDB()
  return type(db) == "table" and type(db.settings) == "table" and db.settings or nil
end

local function Me()
  local capture = WF.Capture
  return capture and capture.Me and capture:Me() or nil
end

local function Wall()
  local value = WF.Epoch and WF.Epoch() or nil
  return type(value) == "number" and value > 0 and value or nil
end

-- "a:b" -> a, b (numbers), or nil when malformed (each part 1-9 digits).
local function Parts(key)
  if type(key) ~= "string" then return nil end
  local a, b = string.match(key, "^(%d+):(%d+)$")
  if not a or #a > 9 or #b > 9 then return nil end
  return tonumber(a), tonumber(b)
end

-- Is tag x before tag y (a, then b)? Malformed tags are never before.
local function Before(x, y)
  local ax, bx = Parts(x)
  local ay, by = Parts(y)
  if not ax or not ay then return false end
  if ax ~= ay then return ax < ay end
  return bx < by
end
Layer.Before = Before

-- Does their tag win over ours at contact? The POI's arena tag first (so a
-- merge never renames the fight's layer), then the smaller tag.
local function Wins(theirs, mine, arena)
  if not Parts(theirs) then return false end
  if arena and theirs == arena then return true end
  if arena and mine == arena then return false end
  return Before(theirs, mine)
end
Layer.Wins = Wins

local function NewTag()
  return math.random(1, TAG_MAX_A) .. ":" .. math.random(1, TAG_MAX_B)
end

-- One journal entry: `kind`, the current tag `key`, the zone and the time.
local function Journal(kind, fields)
  local storage = WF.Storage
  if type(storage) ~= "table" or not storage.initialized or storage.readOnly then return end
  local db = storage:GetDB()
  if type(db) ~= "table" then return end
  if type(db.layerLog) ~= "table" then db.layerLog = {} end
  fields = fields or {}
  fields.kind = kind
  fields.key = Layer.key
  fields.shared = Layer.shared
  fields.zone = fields.zone or ZoneKey()
  fields.at = WF.Epoch and WF.Epoch() or nil
  fields.t = math.floor(Now())
  local list = db.layerLog
  list[#list + 1] = fields
  while #list > LOG_MAX do table.remove(list, 1) end
end

-- Tag changes -----------------------------------------------------------------------

-- A new tag of our own, not shared yet.
function Layer:Fresh(reason)
  local was = self.key
  self.key, self.shared, self.at, self.origin = NewTag(), false, Now(), "new"
  self.news = self.news + 1
  Journal("new", { reason = reason or "?", was = was })
end

-- Another player's tag, which stands on our layer: kept and shared.
function Layer:Adopt(key, origin)
  if not Parts(key) then return false end
  local was = self.key
  if key ~= was then self.adopts = self.adopts + 1 end
  self.key, self.shared, self.at, self.origin = key, true, Now(), origin or "?"
  Journal("adopt", { origin = origin or "?", was = was })
  return true
end

-- No tag (inside an instance).
function Layer:Reset(reason)
  local was = self.key
  if was then self.resets = self.resets + 1 end
  self.key, self.shared, self.at, self.origin = nil, false, 0, nil
  Journal("reset", { reason = reason or "?", was = was })
end

-- A jump's move will bring us to `key` (the helper's tag) until `untilAt`.
function Layer:Expect(key, untilAt)
  expected = Parts(key) and { key = key, untilAt = untilAt or (Now() + 60) } or nil
end

-- The tag our group's leader states in our POI, when it is live.
local function LeaderTag(now)
  local capture = WF.Capture
  local here = capture and capture.here
  local list = here and here.id and capture.presence and capture.presence[here.id]
  local names = WF.Names
  if not list or not names then return nil end
  for i = 1, 4 do
    local unit = "party" .. i
    if Flag("UnitIsGroupLeader", unit) == true then
      local ok, first, surname = Call("UnitName", unit)
      if not ok or IsSecret(first) or IsSecret(surname) or type(first) ~= "string" then return nil end
      local name = names.Full(first, surname)
      local identity = name and capture.Identity and capture.Identity(name)
      local entry = identity and list.entries and list.entries[identity]
      if entry and entry.layer and now <= (entry.expireAt or 0) and Parts(entry.layer) then return entry.layer end
      return nil
    end
  end
  return nil
end

-- The game moved us to another layer.
function Layer:OnTransfer(now)
  self.transfers = self.transfers + 1
  if InInstance() then return end
  if expected and now <= expected.untilAt then
    local key = expected.key
    expected = nil
    self:Adopt(key, "helper")
    return
  end
  expected = nil
  local leader = InGroup() and LeaderTag(now) or nil
  if leader then
    self:Adopt(leader, "leader")
  else
    self:Fresh("transfer")
  end
end

-- Contact ---------------------------------------------------------------------------

-- The identity of a player the client draws, or nil.
local function DrawnPlayer(unit, plate)
  if type(unit) ~= "string" or IsSecret(unit) then return nil end
  if Flag("UnitExists", unit) ~= true or Flag("UnitIsPlayer", unit) ~= true then return nil end
  local okSelf, isSelf = Call("UnitIsUnit", unit, "player")
  if okSelf and isSelf == true then return nil end
  -- A nameplate is drawn by definition; a unit token may name a far group mate.
  if not plate and Flag("UnitIsVisible", unit) ~= true then return nil end
  -- A phase reason (1: another layer, measured 2026-11-23) vetoes any token.
  local okPhase, phase = Call("UnitPhaseReason", unit)
  if okPhase and phase ~= nil then return nil end
  local ok, first, surname = Call("UnitName", unit)
  local names = WF.Names
  if not ok or IsSecret(first) or IsSecret(surname) or type(first) ~= "string" or not names then return nil end
  local name = names.Full(first, surname)
  if not name or not names.Valid(name) then return nil end
  if names.Complete and not names.Complete(name) then return nil end
  local capture = WF.Capture
  return capture and capture.Identity and capture.Identity(name) or nil
end

local function ReadPlateToken(plate) return plate.unitToken end

-- The arena tag of the POI we stand in (decision 0119 § 3), or nil.
local function ArenaHere()
  local capture = WF.Capture
  local here = capture and capture.here
  local st = here and here.id and capture.states and capture.states[here.id]
  local arena = st and st.arena
  return Parts(arena) and arena or nil
end

-- One drawn player: a live presence in our POI shares our tag, and its tag
-- replaces ours when it wins (Wins: the arena's, then the smaller).
function Layer:Contact(identity, entries, now)
  local entry = identity and entries[identity]
  if not entry or now > (entry.expireAt or 0) then return false end
  self.contacts = self.contacts + 1
  local theirs = entry.layer
  if theirs and theirs ~= self.key and Wins(theirs, self.key, ArenaHere()) then
    return self:Adopt(theirs, "contact")
  end
  if not self.shared then
    self.shared = true
    self.shares = self.shares + 1
    Journal("shared", { with = theirs and "tag" or "unknown" })
  end
  return true
end

function Layer:Scan(now)
  local capture = WF.Capture
  local here = capture and capture.here
  local list = here and here.id and capture.presence and capture.presence[here.id]
  if not list or type(list.entries) ~= "table" or not self.key then return end
  self.scans = self.scans + 1
  local me = Me()
  local done = {}
  local function Try(unit, plate)
    local identity = DrawnPlayer(unit, plate)
    if identity and identity ~= me and not done[identity] then
      done[identity] = true
      self:Contact(identity, list.entries, now)
    end
  end
  for i = 1, #UNITS do Try(UNITS[i], false) end
  local plates = Global("C_NamePlate")
  if type(plates) ~= "table" or type(plates.GetNamePlates) ~= "function" then return end
  local ok, frames = pcall(plates.GetNamePlates)
  if not ok or type(frames) ~= "table" then return end
  for i = 1, math.min(#frames, MAX_PLATES) do
    local readable, token = pcall(ReadPlateToken, frames[i])
    if readable then Try(token, true) end
  end
end

-- Reload ------------------------------------------------------------------------------

function Layer:SaveForReload()
  local settings, me, wall = Settings(), Me(), Wall()
  if not settings then return end
  if not self.key or not me or not wall or InInstance() then
    settings.layerTag = nil
    return
  end
  settings.layerTag = { who = me, key = self.key, shared = self.shared and true or nil, at = wall, zone = ZoneKey() }
end

-- At a loading screen: the saved tag becomes a restore candidate after a /reload.
function Layer:OnEnteringWorld(isInitialLogin, isReloadingUi)
  restore = nil
  local settings = Settings()
  local row = settings and settings.layerTag
  if settings then settings.layerTag = nil end
  self:Fresh(isReloadingUi and "reload" or (isInitialLogin and "login" or "loading"))
  if isReloadingUi ~= true or type(row) ~= "table" then return end
  local wall = Wall()
  if not wall or type(row.at) ~= "number" or wall - row.at < 0 or wall - row.at > RESTORE_FOR then return end
  if type(row.who) ~= "string" or not Parts(row.key) or type(row.zone) ~= "string" then return end
  restore = { who = row.who, key = row.key, shared = row.shared == true, zone = row.zone, untilAt = Now() + RESTORE_WINDOW }
end

local function TryRestore(now)
  if not restore then return end
  if now > restore.untilAt then
    restore = nil
    return
  end
  local me, zone = Me(), ZoneKey()
  if not me or not zone then return end
  local row = restore
  restore = nil
  if row.who ~= me or row.zone ~= zone then return end
  Layer.key, Layer.shared, Layer.at, Layer.origin = row.key, row.shared, now, "reload"
  Layer.restores = Layer.restores + 1
  Journal("restore", {})
end

-- Tick --------------------------------------------------------------------------------

function Layer:Tick(now)
  if now < nextTickAt then return end
  nextTickAt = now + TICK
  if InInstance() then
    if not inside then
      inside = true
      Journal("instance", { inside = true })
    end
    if self.key then self:Reset("instance") end
    restore = nil
    return
  end
  if inside then
    inside = false
    Journal("instance", { inside = false })
    self:Fresh("instance")
  end
  if not self.key then self:Fresh("start") end
  TryRestore(now)
  local zoneKey = ZoneKey()
  if zoneKey ~= lastZone then
    if lastZone ~= nil then Journal("zone", { from = lastZone, zone = zoneKey }) end
    lastZone = zoneKey
  end
  local inGroup = InGroup()
  if grouped ~= nil and inGroup ~= grouped then Journal("group", { inGroup = inGroup }) end
  grouped = inGroup
  if now >= nextScanAt then
    nextScanAt = now + SCAN_GAP
    self:Scan(now)
  end
end

-- Public view -----------------------------------------------------------------------

-- The shared tag `a:b` (what P states and the arena compares), or nil.
function Layer:Current()
  return self.shared and self.key or nil
end

-- Our tag, shared or not (a jump compares it with the arena).
function Layer:Mine()
  return self.key
end

-- Short form shown to the player.
function Layer:Label()
  local key = self:Current()
  if not key then return "not known yet" end
  return (string.gsub(key, ":", "-", 1))
end

function Layer:Summary()
  local age = self.key and string.format("%.0fs", Now() - self.at) or "-"
  return "layer key=" .. tostring(self.key) .. " shared=" .. tostring(self.shared) .. " origin=" .. tostring(self.origin)
    .. " age=" .. age .. " new=" .. self.news .. " adopted=" .. self.adopts .. " shares=" .. self.shares
    .. " contacts=" .. self.contacts .. " restores=" .. self.restores .. " transfers=" .. self.transfers
    .. " resets=" .. self.resets .. " scans=" .. self.scans .. " expected=" .. tostring(expected and expected.key)
end

function Layer:PrintStatus()
  WF.Print(self:Summary())
end

-- Wiring ------------------------------------------------------------------------------

if WF.RegisterEvent then
  WF.RegisterEvent("SHARD_TRANSFER", function() Layer:OnTransfer(Now()) end)
  WF.RegisterEvent("PLAYER_ENTERING_WORLD", function(_, isInitialLogin, isReloadingUi)
    Layer:OnEnteringWorld(isInitialLogin == true, isReloadingUi == true)
  end)
  WF.RegisterEvent("PLAYER_LOGOUT", function() Layer:SaveForReload() end)
end

if CreateFrame then
  local frame = CreateFrame("Frame", "WarfrontLayerFrame", UIParent)
  frame:SetScript("OnUpdate", function()
    local ok, err = pcall(Layer.Tick, Layer, Now())
    if not ok and WF.RecordError then WF.RecordError("layer driver", err) end
  end)
end
