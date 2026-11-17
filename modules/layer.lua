local WF = Warfront

-- World layer of the local player (decision 0119 § 1, step 1).
--
-- A creature GUID reads `Creature-0-<server>-0-<zoneUID>-<npc>-<spawn>`; after a
-- group invite moved the player to another layer, pieces 3 and 5 both changed
-- (ForeverRuntimeProbe `layer` v2, 2026-11-14, knowledge base § Units and
-- nameplates). The layer key is the pair `server:zoneUID`.
--   * Read only, from what the client already shows: target, mouseover, focus,
--     soft targets, nameplates, vignettes, the corpse we loot and the creature
--     we kill ourselves. Nothing is sent. A bounded diagnostic journal
--     (`WarfrontDB.layerLog`, last LOG_MAX entries) records accepted pairs,
--     resets, zone, group and instance changes, owned units and loot or kill
--     reads, for single-client checks without screenshots; no rule reads it.
--   * Players and player-owned creatures (pets, totems, summons) are skipped; a
--     new pair is believed only once two different world objects agree.
--   * The pair is kept until a loading screen, or a change of our own group
--     while we do not lead it (a group member moves to its leader's layer);
--     then the layer is unknown until two objects agree again. A zone change
--     keeps it: Elwynn Forest and Stormwind read the same pair (layer v1); two
--     agreeing objects of another pair still replace it (decision 0119
--     amendment, 2026-11-14).
--   * Nothing runs inside an instance; a secret value is skipped.
-- No rule uses it yet (steps 2-4 of decision 0119).

local Layer = {
  key = nil, server = nil, zone = nil, at = 0,
  reads = 0, accepted = 0, owned = 0, secret = 0, unparsed = 0,
  changes = 0, resets = 0, scans = 0,
  -- Reads per source (unit token, nameplate, vignette), for /wfd layer.
  sources = {},
}
WF.Layer = Layer

-- A candidate pair waits CANDIDATE_TTL s for a second, different object.
local CANDIDATE_TTL = 30
-- Known layer: events re-read at most every FRESH s; the fallback scan runs
-- every SCAN_KNOWN s, or every SCAN_UNKNOWN s while the layer is unknown.
local FRESH, SCAN_KNOWN, SCAN_UNKNOWN = 2, 30, 2
local MAX_PLATES = 40
local UNITS = { "target", "mouseover", "focus", "softenemy", "softfriend", "softinteract" }
local KINDS = { Creature = true, Vehicle = true, GameObject = true, Vignette = true }
local TICK = 1
-- Diagnostic journal: entries kept, and one owned-unit entry per OWNED_GAP s.
local LOG_MAX, OWNED_GAP = 300, 5

local candidate -- { key, server, zone, first = guid, at }
local lastGuid, nextTickAt, nextScanAt = nil, 0, 0
local grouped, leading = nil, false
-- Journal state: sources already noted for the current pair, last zone,
-- instance flag, last owned-unit entry.
local noted, lastZone, inside, ownedAt = {}, nil, false, -1000

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

local function Leading()
  return Flag("UnitIsGroupLeader", "player") == true
end

-- `Kind-0-server-instance-zoneUID-...` -> server, zoneUID (numbers as strings).
local function Parse(guid)
  local pieces, start = {}, 1
  while #pieces < 6 do
    local stop = string.find(guid, "-", start, true)
    if not stop then
      pieces[#pieces + 1] = string.sub(guid, start)
      break
    end
    pieces[#pieces + 1] = string.sub(guid, start, stop - 1)
    start = stop + 1
  end
  if not KINDS[pieces[1]] or pieces[2] ~= "0" then return nil end
  local server, zone = pieces[3], pieces[5]
  if not server or not zone or not string.find(server, "^%d+$") or not string.find(zone, "^%d+$") then
    return nil
  end
  return server, zone
end

local function ZoneKey()
  local map = WF.Map
  if type(map) ~= "table" or type(map.PlayerZoneKey) ~= "function" then return nil end
  local ok, zone = pcall(map.PlayerZoneKey, map)
  if ok and type(zone) == "string" then return zone end
  return nil
end

-- One journal entry: `kind`, the current pair `key`, the zone and the time.
local function Journal(kind, fields)
  local storage = WF.Storage
  if type(storage) ~= "table" or not storage.initialized or storage.readOnly then return end
  local db = storage:GetDB()
  if type(db) ~= "table" then return end
  if type(db.layerLog) ~= "table" then db.layerLog = {} end
  fields = fields or {}
  fields.kind = kind
  fields.key = Layer.key
  fields.zone = fields.zone or ZoneKey()
  fields.at = WF.Epoch and WF.Epoch() or nil
  fields.t = math.floor(Now())
  local list = db.layerLog
  list[#list + 1] = fields
  while #list > LOG_MAX do table.remove(list, 1) end
end

-- Reading ---------------------------------------------------------------------------

function Layer:Reset(reason)
  local was = self.key
  if self.key then self.resets = self.resets + 1 end
  self.key, self.server, self.zone, self.at = nil, nil, nil, 0
  candidate, lastGuid, nextScanAt = nil, nil, 0
  noted = {}
  Journal("reset", { reason = reason or "?", was = was })
end

-- Journal a read: loot and kill always, other sources once per pair.
local function NoteRead(source, pair, result)
  if source ~= "loot" and source ~= "kill" then
    if result ~= "same" and result ~= "accepted" then return end
    if noted[source] then return end
    noted[source] = true
  end
  Journal("read", { source = source, pair = pair, result = result })
end

-- One GUID of a world object (never a player's or a player-owned one).
function Layer:Observe(guid, now, source)
  if guid == nil then return false end
  if IsSecret(guid) then
    self.secret = self.secret + 1
    return false
  end
  if type(guid) ~= "string" or guid == "" then return false end
  if guid == lastGuid then
    -- Usually the creature we just targeted: nothing new, journaled only.
    NoteRead(source, nil, "repeat")
    return false
  end
  lastGuid = guid
  self.reads = self.reads + 1
  source = source or "?"
  self.sources[source] = (self.sources[source] or 0) + 1
  local server, zone = Parse(guid)
  if not server then
    self.unparsed = self.unparsed + 1
    NoteRead(source, nil, "unparsed")
    return false
  end
  local key = server .. ":" .. zone
  if key == self.key then
    self.at = now
    candidate = nil
    NoteRead(source, key, "same")
    return true
  end
  if not candidate or candidate.key ~= key or now - candidate.at > CANDIDATE_TTL then
    candidate = { key = key, server = server, zone = zone, first = guid, at = now }
    NoteRead(source, key, "candidate")
    return false
  end
  if candidate.first == guid then return false end
  local was = self.key
  if self.key then self.changes = self.changes + 1 end
  self.key, self.server, self.zone, self.at = key, server, zone, now
  self.accepted = self.accepted + 1
  candidate = nil
  noted = {}
  Journal("accept", { source = source, was = was })
  NoteRead(source, key, "accepted")
  return true
end

function Layer:ReadUnit(unit, now, source)
  if type(unit) ~= "string" or IsSecret(unit) then return false end
  if Flag("UnitExists", unit) ~= true then return false end
  local player, owned = Flag("UnitIsPlayer", unit), Flag("UnitPlayerControlled", unit)
  if player ~= false or owned ~= false then
    if owned == true and player == false then
      self.owned = self.owned + 1
      if now - ownedAt >= OWNED_GAP then
        ownedAt = now
        Journal("owned", { source = source or unit, count = self.owned })
      end
    end
    return false
  end
  local ok, guid = Call("UnitGUID", unit)
  return ok and self:Observe(guid, now, source or unit) or false
end

local function ReadPlateToken(plate) return plate.unitToken end
local function ReadObjectGuid(info) return info.objectGUID end

function Layer:Scan(now)
  self.scans = self.scans + 1
  for i = 1, #UNITS do self:ReadUnit(UNITS[i], now) end
  local plates = Global("C_NamePlate")
  if type(plates) == "table" and type(plates.GetNamePlates) == "function" then
    local ok, list = pcall(plates.GetNamePlates)
    if ok and type(list) == "table" then
      for i = 1, math.min(#list, MAX_PLATES) do
        local readable, token = pcall(ReadPlateToken, list[i])
        if readable then self:ReadUnit(token, now, "nameplate") end
      end
    end
  end
  local vignettes = Global("C_VignetteInfo")
  if type(vignettes) ~= "table" or type(vignettes.GetVignettes) ~= "function" then return end
  local ok, list = pcall(vignettes.GetVignettes)
  if not ok or type(list) ~= "table" then return end
  for i = 1, #list do
    local vignette = list[i]
    self:Observe(vignette, now, "vignette")
    if type(vignettes.GetVignetteInfo) == "function" and not IsSecret(vignette) then
      local okInfo, info = pcall(vignettes.GetVignetteInfo, vignette)
      if okInfo and type(info) == "table" then
        local okObject, object = pcall(ReadObjectGuid, info)
        if okObject then self:Observe(object, now, "vignette.object") end
      end
    end
  end
end

-- An event read: skipped while a known layer was confirmed under FRESH s ago.
function Layer:OnUnitEvent(unit, source)
  if InInstance() then return end
  local now = Now()
  if self.key and now - self.at < FRESH then return end
  self:ReadUnit(unit, now, source)
end

function Layer:Tick(now)
  if now < nextTickAt then return end
  nextTickAt = now + TICK
  if InInstance() then
    if not inside then
      inside = true
      Journal("instance", { inside = true })
    end
    if self.key or candidate then self:Reset("instance") end
    return
  end
  if inside then
    inside = false
    Journal("instance", { inside = false })
  end
  local zoneKey = ZoneKey()
  if zoneKey ~= lastZone then
    if lastZone ~= nil then Journal("zone", { from = lastZone, zone = zoneKey }) end
    lastZone = zoneKey
  end
  -- Joining or leaving a group may move us to another layer, unless we lead
  -- it: the others come to the leader's layer.
  local inGroup = InGroup()
  local lead = inGroup and Leading()
  if grouped ~= nil and inGroup ~= grouped then
    local reset = not lead and not leading
    Journal("group", { inGroup = inGroup, lead = lead and true or false, wasLead = leading, reset = reset })
    if reset then self:Reset("group") end
  end
  grouped, leading = inGroup, lead
  if now >= nextScanAt then
    nextScanAt = now + (self.key and SCAN_KNOWN or SCAN_UNKNOWN)
    self:Scan(now)
  end
end

-- The corpse we loot stands on our layer (GetLootSourceInfo, measured
-- readable, knowledge base § Loot and professions).
function Layer:OnLoot(now)
  local okCount, count = Call("GetNumLootItems")
  if not okCount or type(count) ~= "number" or IsSecret(count) then
    NoteRead("loot", nil, "unreadable")
    return
  end
  if count < 1 then NoteRead("loot", nil, "empty") end
  for slot = 1, math.min(count, 4) do
    local ok, guid = Call("GetLootSourceInfo", slot)
    if ok then self:Observe(guid, now, "loot") end
  end
end

-- A creature we killed ourselves stood on our layer; a group member's kill
-- may come from another layer and is skipped.
function Layer:OnKill(attacker, target, now)
  if IsSecret(attacker) or IsSecret(target) or type(attacker) ~= "string" then
    NoteRead("kill", nil, "unreadable")
    return
  end
  local ok, mine = Call("UnitGUID", "player")
  if not ok or IsSecret(mine) or attacker ~= mine then
    NoteRead("kill", nil, "not mine")
    return
  end
  self:Observe(target, now, "kill")
end

-- Public view -----------------------------------------------------------------------

-- The layer key `server:zoneUID`, or nil while unknown.
function Layer:Current()
  return self.key
end

-- Short form shown to the player.
function Layer:Label()
  if not self.key then return "not known yet" end
  return self.server .. "-" .. self.zone
end

-- "mouseover:2,nameplate:1", sorted, or "-".
function Layer:SourceList()
  local names = {}
  for name in pairs(self.sources) do names[#names + 1] = name end
  if #names == 0 then return "-" end
  table.sort(names)
  for i = 1, #names do names[i] = names[i] .. ":" .. self.sources[names[i]] end
  return table.concat(names, ",")
end

function Layer:Summary()
  local age = self.key and string.format("%.0fs", Now() - self.at) or "-"
  return "layer key=" .. tostring(self.key) .. " age=" .. age .. " reads=" .. self.reads
    .. " accepted=" .. self.accepted .. " changes=" .. self.changes .. " resets=" .. self.resets
    .. " owned=" .. self.owned .. " unparsed=" .. self.unparsed .. " unreadable=" .. self.secret
    .. " scans=" .. self.scans .. " candidate=" .. tostring(candidate and candidate.key)
    .. " sources=" .. self:SourceList()
end

function Layer:PrintStatus()
  WF.Print(self:Summary())
end

-- Wiring ------------------------------------------------------------------------------

if WF.RegisterEvent then
  WF.RegisterEvent("NAME_PLATE_UNIT_ADDED", function(_, unit) Layer:OnUnitEvent(unit, "nameplate.added") end)
  WF.RegisterEvent("PLAYER_TARGET_CHANGED", function() Layer:OnUnitEvent("target") end)
  WF.RegisterEvent("UPDATE_MOUSEOVER_UNIT", function() Layer:OnUnitEvent("mouseover") end)
  WF.RegisterEvent("PLAYER_SOFT_ENEMY_CHANGED", function() Layer:OnUnitEvent("softenemy") end)
  WF.RegisterEvent("PLAYER_SOFT_FRIEND_CHANGED", function() Layer:OnUnitEvent("softfriend") end)
  WF.RegisterEvent("PLAYER_SOFT_INTERACT_CHANGED", function() Layer:OnUnitEvent("softinteract") end)
  WF.RegisterEvent("LOOT_READY", function() if not InInstance() then Layer:OnLoot(Now()) end end)
  WF.RegisterEvent("PARTY_KILL", function(_, attacker, target)
    if not InInstance() then Layer:OnKill(attacker, target, Now()) end
  end)
  WF.RegisterEvent("PLAYER_ENTERING_WORLD", function() Layer:Reset("loading") end)
end

if CreateFrame then
  local frame = CreateFrame("Frame", "WarfrontLayerFrame", UIParent)
  frame:SetScript("OnUpdate", function()
    local ok, err = pcall(Layer.Tick, Layer, Now())
    if not ok and WF.RecordError then WF.RecordError("layer driver", err) end
  end)
end
