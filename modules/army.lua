Warfront = Warfront or {}

local WF = Warfront
local Army = {}

WF.Army = Army

-- Military units, personal reserve and recruitment (roadmap WP6,
-- docs/game-design.md §§ 6-7). Private and local: never sent on the channel.
-- Values from the V1 balance sheet (decision 0047, amended by 0124): every
-- combat unit is worth the same per Unit Size (150 resources, ATK 60, DEF 90),
-- so only the counter sets them apart. One entry per unit, the same for both
-- factions, only the names differ. `beats` mirrors BEATS in
-- modules/attack.lua (display only; tools/smoke.py checks both match). Units
-- leave the reserve as garrison pledges (modules/garrison.lua), scouts
-- (modules/scout.lua) or attacking armies (modules/attack.lua).
local SCHEMA = 1
local RESERVE_CAPACITY = 25
local MAX_CHARACTERS = 50
local UNITS = {
  FOOTMAN = { names = { A = "Footman", H = "Grunt" }, gold = 75, wood = 25, food = 50, size = 1, atk = 60, def = 90, beats = "MORTAR" },
  RIFLEMAN = { names = { A = "Rifleman", H = "Headhunter" }, gold = 75, wood = 25, food = 50, size = 1, atk = 60, def = 90, beats = "FOOTMAN" },
  MORTAR = { names = { A = "Mortar Team", H = "Demolisher" }, gold = 150, wood = 60, food = 90, size = 2, atk = 120, def = 180, beats = "RIFLEMAN" },
  -- The scout never fights: no ATK, no DEF, no Assault Capacity.
  SCOUT = { names = { A = "Knight", H = "Wolf Rider" }, gold = 250, wood = 100, food = 150, size = 1, scout = true },
}
local ORDER = { "FOOTMAN", "RIFLEMAN", "MORTAR", "SCOUT" }
local ALIASES = {
  footman = "FOOTMAN", grunt = "FOOTMAN",
  rifleman = "RIFLEMAN", headhunter = "RIFLEMAN",
  mortar = "MORTAR", ["mortar team"] = "MORTAR", demolisher = "MORTAR",
  scout = "SCOUT", knight = "SCOUT", wolf = "SCOUT", ["wolf rider"] = "SCOUT",
}
local PLACE_NAMES = { OUTPOST = "Outpost", SETTLEMENT = "Settlement", CAPITAL = "Capital", WAR_CAMP = "War Camp" }
local FACTION_CODES = { HORDE = "H", ALLIANCE = "A" }

Army.UNITS = UNITS
Army.ORDER = ORDER
Army.RESERVE_CAPACITY = RESERVE_CAPACITY

local function GetGlobal(name)
  if WF.Compat and WF.Compat.Global then return WF.Compat.Global(name) end
  if _G then return _G[name] end
  return nil
end

local function Realm()
  local fn = GetGlobal("GetRealmName")
  local ok, realm = false, nil
  if type(fn) == "function" then ok, realm = pcall(fn) end
  if ok and type(realm) == "string" and realm ~= "" then return realm end
  return "unknown"
end

local function Count(t)
  local n = 0
  for key in pairs(t) do n = n + 1 end
  return n
end

local function Print(text)
  if WF.Print then WF.Print(text) end
end

local function Faction()
  return WF.Capture and WF.Capture:MyFaction()
end

function Army:Key(text)
  if type(text) ~= "string" then return nil end
  local lower = string.lower(text)
  if ALIASES[lower] then return ALIASES[lower] end
  local upper = string.upper(text)
  if UNITS[upper] then return upper end
  return nil
end

function Army:Name(key, faction)
  local unit = UNITS[key]
  if not unit then return tostring(key) end
  local name = unit.names[faction or Faction() or "A"] or unit.names.A
  return WF.L and WF.L(name) or name
end

-- The unit key beaten by key and the one that beats it; nil for the scout.
function Army:Counters(key)
  local unit = UNITS[key]
  if not unit or not unit.beats then return nil, nil end
  local weak
  for other, u in pairs(UNITS) do
    if u.beats == key then weak = other end
  end
  return unit.beats, weak
end

-- "strong vs Rifleman, weak vs Mortar Team" in the player's faction names.
function Army:CounterText(key, faction)
  local strong, weak = self:Counters(key)
  if not strong or not weak then return nil end
  return "strong vs " .. self:Name(strong, faction) .. ", weak vs " .. self:Name(weak, faction)
end

-- The character's reserve { FOOTMAN, RIFLEMAN, MORTAR, SCOUT, op }, its
-- values bounded; nil without storage or identity, or for a newer schema.
function Army:Reserve(owner)
  local storage = WF.Storage
  local current = WF.Capture and WF.Capture:Me()
  local me = owner or current
  if not me or not storage or type(storage.GetDB) ~= "function" or storage.readOnly then return nil end
  if WF.Names and not WF.Names.Complete(me) then return nil end
  local db = storage:GetDB()
  if type(db) ~= "table" then return nil end
  -- This ruleset scope's table (decision 0072: the realm never partitions it);
  -- a newer schema belongs to a newer build: leave it untouched.
  local bucket = WF.Ruleset and WF.Ruleset:Module("army")
  if not bucket then return nil end
  if type(bucket.schema) == "number" and bucket.schema > SCHEMA then return nil end
  bucket.schema = SCHEMA
  if type(bucket.chars) ~= "table" then bucket.chars = {} end
  if WF.Names then WF.Names.Adopt(bucket.chars, me) end
  local reserve = bucket.chars[me]
  if type(reserve) ~= "table" then
    if owner and owner ~= current then return nil end -- Never create a peer's reserve for a refund.
    if Count(bucket.chars) >= MAX_CHARACTERS then return nil end
    reserve = {}
    bucket.chars[me] = reserve
  end
  for index = 1, #ORDER do
    local key = ORDER[index]
    local value = math.floor(tonumber(reserve[key]) or 0)
    local most = math.floor(RESERVE_CAPACITY / UNITS[key].size)
    if value < 0 then value = 0 end
    if value > most then value = most end
    reserve[key] = value
  end
  local op = math.floor(tonumber(reserve.op) or 0)
  if op < 0 or op > 1000000000 then op = 0 end
  reserve.op = op
  -- Garrison pledges (modules/garrison.lua): their own operation number and
  -- at most one pledge waiting for the keeper's answer.
  local gop = math.floor(tonumber(reserve.gop) or 0)
  if gop < 0 or gop > 1000000000 then gop = 0 end
  reserve.gop = gop
  -- Scouting orders (modules/scout.lua): their own operation number, sent
  -- with the order so that its copies are recognized.
  local sop = math.floor(tonumber(reserve.sop) or 0)
  if sop < 0 or sop >= 1000000000 then sop = 0 end
  reserve.sop = sop
  -- Attack orders (modules/attack.lua): the same, for armies.
  local aop = math.floor(tonumber(reserve.aop) or 0)
  if aop < 0 or aop >= 1000000000 then aop = 0 end
  reserve.aop = aop
  local p = reserve.pending
  if p ~= nil and (type(p) ~= "table" or not UNITS[p.kind or ""] and p.kind ~= "gold" and p.kind ~= "wood"
    or type(p.count) ~= "number" or p.count < 1 or p.count > 3600) then
    reserve.pending = nil
  end
  -- Campaign-end refunds still waiting for room (Army:Refund).
  local overflow = reserve.overflow
  if overflow ~= nil then
    if type(overflow) ~= "table" then
      reserve.overflow = nil
    else
      for key, value in pairs(overflow) do
        local n = math.floor(tonumber(value) or 0)
        if not UNITS[key] or n <= 0 then overflow[key] = nil else overflow[key] = math.min(n, 3600) end
      end
      Army:Settle(reserve)
    end
  end
  -- Units given back at a campaign end after their War effort was counted
  -- (decision 0126 § 5): sending them again counts no second time.
  local uncredited = reserve.uncredited
  if uncredited ~= nil then
    if type(uncredited) ~= "table" then
      reserve.uncredited = nil
    else
      for key, value in pairs(uncredited) do
        local n = math.floor(tonumber(value) or 0)
        if not UNITS[key] or n <= 0 then uncredited[key] = nil else uncredited[key] = math.min(n, 3600) end
      end
    end
  end
  return reserve
end

-- Remembers count units of kind as already counted (campaign-end refund).
function Army:MarkUncredited(kind, count, owner)
  local reserve = self:Reserve(owner)
  count = math.floor(tonumber(count) or 0)
  if not reserve or not UNITS[kind] or count <= 0 then return end
  if type(reserve.uncredited) ~= "table" then reserve.uncredited = {} end
  reserve.uncredited[kind] = math.min(math.floor(tonumber(reserve.uncredited[kind]) or 0) + count, 3600)
end

-- How many of count units of kind sent now were already counted; uses them up.
function Army:TakeUncredited(kind, count)
  local reserve = self:Reserve()
  local uncredited = reserve and type(reserve.uncredited) == "table" and reserve.uncredited
  local have = uncredited and math.floor(tonumber(uncredited[kind]) or 0) or 0
  count = math.floor(tonumber(count) or 0)
  if have <= 0 or count <= 0 then return 0 end
  local used = math.min(have, count)
  uncredited[kind] = have - used > 0 and have - used or nil
  return used
end

-- Units given back to this character at a campaign end (decision 0102 § 4):
-- never truncated by the reserve bound. What does not fit waits in
-- reserve.overflow (bounded per unit) and joins the reserve as room appears
-- (Army:Settle). Returns the count left waiting.
local MAX_OVERFLOW = 3600

function Army:Refund(kind, count, owner)
  local reserve = self:Reserve(owner)
  local unit = UNITS[kind]
  count = math.floor(tonumber(count) or 0)
  if not reserve or not unit or count <= 0 then return 0 end
  if type(reserve.overflow) ~= "table" then reserve.overflow = {} end
  local waiting = math.floor(tonumber(reserve.overflow[kind]) or 0) + count
  if waiting > MAX_OVERFLOW then waiting = MAX_OVERFLOW end
  reserve.overflow[kind] = waiting
  self:Settle(reserve)
  return math.floor(tonumber(reserve.overflow and reserve.overflow[kind]) or 0)
end

-- Prepare every field before touching the live reserve. The caller commits all
-- plans together, then removes the orders in the same non-yielding Lua call.
-- No journal/schema migration is needed: client saves cannot run mid-call.
function Army:PlanCampaignRefund(owner, op, counts)
  local storage = WF.Storage
  local bucket = storage and not storage.readOnly and storage:GetDB()
    and WF.Ruleset and WF.Ruleset:Module("army")
  if not bucket or (type(bucket.schema) == "number" and bucket.schema > SCHEMA) then
    error("campaign refund: army storage unavailable", 0)
  end
  local reserve = self:Reserve(owner)
  if not reserve or tonumber(op) ~= reserve.aop then return nil end
  local copy = {}
  for key, value in pairs(reserve) do copy[key] = value end
  copy.overflow, copy.uncredited = {}, {}
  for key, value in pairs(reserve.overflow or {}) do copy.overflow[key] = value end
  for key, value in pairs(reserve.uncredited or {}) do copy.uncredited[key] = value end
  local total = 0
  for key, value in pairs(counts) do
    local n = tonumber(value)
    if not UNITS[key] or not n or n ~= math.floor(n) or n < 0 or n > 3600 then
      error("campaign refund: invalid composition", 0)
    end
    local waiting = (copy.overflow[key] or 0) + n
    local credited = (copy.uncredited[key] or 0) + n
    if waiting > MAX_OVERFLOW or credited > 3600 then
      error("campaign refund: pending reserve full", 0)
    end
    copy.overflow[key], copy.uncredited[key] = waiting, credited
    total = total + n
  end
  self:Settle(copy)
  return { reserve = reserve, values = copy, count = total }
end

-- Moves waiting refunds into the reserve, within its bound per unit.
function Army:Settle(reserve)
  reserve = reserve or self:Reserve()
  if not reserve or type(reserve.overflow) ~= "table" then return end
  local left = 0
  for index = 1, #ORDER do
    local key = ORDER[index]
    local waiting = math.floor(tonumber(reserve.overflow[key]) or 0)
    if waiting > 0 then
      local most = math.floor(RESERVE_CAPACITY / UNITS[key].size)
      local room = most - reserve[key]
      local moved = waiting < room and waiting or room
      if moved > 0 then
        reserve[key] = reserve[key] + moved
        waiting = waiting - moved
      end
      left = left + waiting
    end
    reserve.overflow[key] = waiting > 0 and math.min(waiting, MAX_OVERFLOW) or nil
  end
  if left == 0 then reserve.overflow = nil end
end

-- Units waiting to join the reserve, by unit key (nil when none).
function Army:Overflow()
  local reserve = self:Reserve()
  return reserve and reserve.overflow or nil
end

-- Sum of Unit Size in the reserve.
function Army:Used(reserve)
  local used = 0
  for index = 1, #ORDER do
    local key = ORDER[index]
    used = used + reserve[key] * UNITS[key].size
  end
  return used
end

-- A War Camp recruits every unit but is never a departure point (decision
-- 0123 § 7): scouts and armies still leave from an Outpost, a Settlement or
-- the capital.
local DEPARTURE_TYPES = { OUTPOST = true, SETTLEMENT = true, CAPITAL = true }
local RECRUITMENT_TYPES = { SETTLEMENT = true, CAPITAL = true, WAR_CAMP = true }

local function OwnedPlace(types, outsideReason)
  local faction = Faction()
  if not faction then return nil, "faction unknown" end
  local dead = GetGlobal("UnitIsDeadOrGhost")
  if type(dead) == "function" then
    local ok, flag = pcall(dead, "player")
    if ok and flag then return nil, "you are dead" end
  end
  local area = WF.Presence and WF.Presence.current
  if not area or not types[area.type] then
    return nil, outsideReason
  end
  local owner
  if area.type == "CAPITAL" then
    -- Always its zone's faction (decision 0103); never the owner registry.
    local capitals = WF.Map and WF.Map.CAPITAL_FACTIONS
    owner = FACTION_CODES[capitals and capitals[area.mapKey or ""] or ""] or "N"
  else
    -- Outposts, Settlements and War Camps follow the owner registry (decisions
    -- 0053, 0123): never a hint or a cloud row.
    owner = WF.Capture and WF.Capture:GetOwner(area.id) or "N"
  end
  if owner ~= faction then
    if area.type == "CAPITAL" then return nil, "this is the enemy capital" end
    return nil, "this " .. PLACE_NAMES[area.type] .. " is not held by your faction"
  end
  return area, nil
end

-- An army or scout may leave from any allied military place.
function Army:DeparturePlace()
  return OwnedPlace(DEPARTURE_TYPES, "go inside your capital or a friendly Outpost or Settlement")
end

-- Recruitment is stricter than an attack or scout departure: units can only
-- be recruited inside a Settlement or War Camp held by the player's faction
-- or in its own capital (decisions 0103, 0123), so a faction holding no
-- Settlement still recruits.
function Army:Place()
  return OwnedPlace(RECRUITMENT_TYPES, "go inside your capital, or a Settlement or War Camp held by your faction")
end

-- Largest count of a unit the resources and the free capacity allow.
function Army:MostAffordable(key, reserve, wallet)
  local unit = UNITS[key]
  local most = math.floor((RESERVE_CAPACITY - self:Used(reserve)) / unit.size)
  for index = 1, #WF.Economy.RESOURCES do
    local resource = WF.Economy.RESOURCES[index]
    local can = math.floor(wallet[resource] / unit[resource])
    if can < most then most = can end
  end
  if most < 0 then most = 0 end
  return most
end

-- Checks a recruitment without changing anything. Returns reserve, wallet or
-- nil, reason.
function Army:Check(key, count)
  local unit = UNITS[key]
  if not unit then return nil, "unknown unit" end
  if type(count) ~= "number" or count < 1 or count > RESERVE_CAPACITY or math.floor(count) ~= count then
    return nil, "count must be 1 to " .. RESERVE_CAPACITY
  end
  local reserve = self:Reserve()
  local wallet = WF.Economy and WF.Economy:Wallet()
  if not reserve or not wallet then return nil, "no saved data or identity yet" end
  local _, where = self:Place()
  if where then return nil, where end
  local used = self:Used(reserve)
  local size = unit.size * count
  if used + size > RESERVE_CAPACITY then
    return nil, "reserve full: needs " .. size .. " Unit Size, " .. used .. "/" .. RESERVE_CAPACITY .. " used"
  end
  for index = 1, #WF.Economy.RESOURCES do
    local resource = WF.Economy.RESOURCES[index]
    local cost = unit[resource] * count
    if wallet[resource] < cost then
      return nil, "not enough " .. resource .. ": needs " .. cost .. ", you have " .. wallet[resource]
    end
  end
  return reserve, wallet
end

-- Pays every cost and adds the units in one step, or changes nothing. op is
-- the reserve's operation number read by the caller: a repeated or stale
-- request (op already used) is refused, so one action recruits once.
function Army:Recruit(key, count, op)
  local reserve, wallet = self:Check(key, count)
  if not reserve then return false, wallet end
  if op ~= reserve.op then return false, "request already done or out of date" end
  local unit = UNITS[key]
  for index = 1, #WF.Economy.RESOURCES do
    local resource = WF.Economy.RESOURCES[index]
    wallet[resource] = wallet[resource] - unit[resource] * count
  end
  reserve[key] = reserve[key] + count
  reserve.op = reserve.op + 1
  if WF.Record then
    WF.Record("RECRUIT", { unit = key, count = count, op = reserve.op, used = self:Used(reserve) })
  end
  return true, nil
end

-- /wf recruit <unit> [count]
function Army:RecruitCommand(text)
  local _, _, name, number = string.find(string.lower(text or ""), "^%s*(.-)%s*(%d*)%s*$")
  local key = self:Key(name)
  if not key then
    Print("usage: /wf recruit footman|rifleman|mortar|scout [count] (faction names work too)")
    return
  end
  local count = 1
  if number ~= "" then count = #number <= 3 and tonumber(number) or 0 end
  local reserve = self:Reserve()
  local ok, reason = self:Recruit(key, count, reserve and reserve.op)
  if not ok then
    Print("recruitment refused: " .. tostring(reason))
    return
  end
  local unit = UNITS[key]
  Print("recruited " .. count .. " " .. self:Name(key) .. " for " .. unit.gold * count .. " gold, "
    .. unit.wood * count .. " wood, " .. unit.food * count .. " food - reserve "
    .. self:Used(reserve) .. "/" .. RESERVE_CAPACITY)
end

-- /wf army
function Army:PrintStatus()
  local reserve = self:Reserve()
  local wallet = WF.Economy and WF.Economy:Wallet()
  if not reserve or not wallet then
    Print("army unavailable (no saved data or identity yet)")
    return
  end
  local used = self:Used(reserve)
  local parts = {}
  local index = 1
  for index = 1, #ORDER do
    local key = ORDER[index]
    parts[#parts + 1] = self:Name(key) .. " " .. reserve[key]
  end
  Print("reserve " .. used .. "/" .. RESERVE_CAPACITY .. " Unit Size" .. (used >= RESERVE_CAPACITY and " (full)" or "")
    .. ": " .. table.concat(parts, ", "))
  Print("resources gold " .. wallet.gold .. "  wood " .. wallet.wood .. "  food " .. wallet.food)
  local area, where = self:Place()
  if area then
    Print("recruitment open here: " .. PLACE_NAMES[area.type] .. " " .. tostring(area.label or area.id))
  else
    Print("recruitment closed: " .. where)
  end
  index = 1
  for index = 1, #ORDER do
    local key = ORDER[index]
    local unit = UNITS[key]
    local stats = unit.scout and "scout, no combat"
      or ("ATK " .. unit.atk .. " DEF " .. unit.def .. ", " .. (self:CounterText(key) or ""))
    Print("  " .. self:Name(key) .. ": " .. unit.gold .. " gold, " .. unit.wood .. " wood, " .. unit.food
      .. " food, size " .. unit.size .. ", " .. stats .. " - up to " .. self:MostAffordable(key, reserve, wallet))
  end
end
