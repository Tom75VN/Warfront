Warfront = Warfront or {}

local WF = Warfront
local Economy = {}

WF.Economy = Economy

-- Gold, wood and food of this account's characters (docs/gathering.md,
-- decision 0048). Private and local: never sent on the channel. Caps from the
-- V1 balance sheet (decision 0047, tools/balance_sim.py BALANCE.inventoryCap).
local SCHEMA = 1
local CAPS = { gold = 2000, wood = 1000, food = 1500 }
local RESOURCES = { "gold", "wood", "food" }
local MAX_CHARACTERS = 50

Economy.CAPS = CAPS
Economy.RESOURCES = RESOURCES

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

-- Per-realm bucket shared with modules/stock.lua: { chars = {}, stocks = {} }.
function Economy:RealmBucket()
  local storage = WF.Storage
  if not storage or type(storage.GetDB) ~= "function" or storage.readOnly then return nil end
  local db = storage:GetDB()
  if type(db) ~= "table" then return nil end
  -- This ruleset scope's table (decision 0072: the realm never partitions it);
  -- a newer schema belongs to a newer build: leave it untouched.
  local bucket = WF.Ruleset and WF.Ruleset:Module("economy")
  if not bucket then return nil end
  if type(bucket.schema) == "number" and bucket.schema > SCHEMA then return nil end
  bucket.schema = SCHEMA
  if type(bucket.chars) ~= "table" then bucket.chars = {} end
  if type(bucket.stocks) ~= "table" then bucket.stocks = {} end
  if not bucket.realmAdopted or bucket.realmsAdopted then
    local fn = GetGlobal("GetRealmName")
    local ok, realm = false, nil
    if type(fn) == "function" then ok, realm = pcall(fn) end
    if ok then Economy.AdoptRealm(bucket, db, realm) end
  end
  return bucket
end

-- Decision 0073, amended by 0096: once per technical realm, the wallets and
-- stocks an older build saved for the current realm
-- (WarfrontDB.economy.realms[realm], before decision 0072) join the scope. The
-- current realm's record chose this scope, so no other realm is read at that
-- login. A scope wallet started empty at the update, so the old amounts are
-- added to it, capped; a stock the scope holds is kept. The realm archive is
-- never changed. A bucket marked by a build without realmsAdopted does not say
-- which realm it took: it stays closed, adding again could double a wallet.
function Economy.AdoptRealm(bucket, db, realm)
  if bucket.realmAdopted and not bucket.realmsAdopted then return 0 end
  if type(realm) ~= "string" or realm == "" then return 0 end
  if type(bucket.realmsAdopted) ~= "table" then bucket.realmsAdopted = {} end
  if bucket.realmsAdopted[realm] then return 0 end
  bucket.realmAdopted, bucket.realmsAdopted[realm] = true, true
  local legacy = type(db) == "table" and db.economy
  if type(legacy) ~= "table" then return 0 end
  if type(legacy.schema) == "number" and legacy.schema > SCHEMA then return 0 end
  local old = type(legacy.realms) == "table" and legacy.realms[realm]
  if type(old) ~= "table" then return 0 end
  local count = 0
  if type(old.chars) == "table" then
    for who, wallet in pairs(old.chars) do
      local into = type(who) == "string" and type(wallet) == "table" and bucket.chars[who]
      if type(who) == "string" and type(wallet) == "table" and type(into) ~= "table"
          and Count(bucket.chars) < MAX_CHARACTERS then
        into = {}
        bucket.chars[who] = into
      end
      if type(into) == "table" then
        for index = 1, #RESOURCES do
          local resource = RESOURCES[index]
          local value = math.floor(tonumber(wallet[resource]) or 0)
          if value > 0 then
            local current = math.max(0, math.floor(tonumber(into[resource]) or 0))
            into[resource] = math.min(CAPS[resource], current + value)
          end
        end
        count = count + 1
      end
    end
  end
  if type(old.stocks) == "table" then
    for id, entry in pairs(old.stocks) do
      if type(id) == "string" and type(entry) == "table" and bucket.stocks[id] == nil then
        bucket.stocks[id] = { stock = tonumber(entry.stock), t = tonumber(entry.t), epoch = tonumber(entry.epoch) }
        count = count + 1
      end
    end
  end
  if WF.Record then WF.Record("ECONOMY_REALM_ADOPTED", { count = count }) end
  return count
end

-- The character's wallet, its values bounded; nil without storage or identity.
function Economy:Wallet()
  local me = WF.Capture and WF.Capture:Me()
  local bucket = self:RealmBucket()
  if not me or not bucket or (WF.Names and not WF.Names.Complete(me)) then return nil end
  if WF.Names then WF.Names.Adopt(bucket.chars, me) end
  local wallet = bucket.chars[me]
  if type(wallet) ~= "table" then
    if Count(bucket.chars) >= MAX_CHARACTERS then return nil end
    wallet = {}
    bucket.chars[me] = wallet
  end
  for index = 1, #RESOURCES do
    local resource = RESOURCES[index]
    local value = tonumber(wallet[resource]) or 0
    value = math.floor(value)
    if value < 0 then value = 0 end
    if value > CAPS[resource] then value = CAPS[resource] end
    wallet[resource] = value
  end
  return wallet
end

function Economy:Get(resource)
  local wallet = self:Wallet()
  return wallet and wallet[resource] or 0
end

function Economy:Full(resource)
  local cap = CAPS[resource]
  return cap ~= nil and self:Get(resource) >= cap
end

-- Adds up to the cap; returns what was actually added.
function Economy:Add(resource, amount)
  local cap = CAPS[resource]
  local wallet = cap and self:Wallet()
  if not wallet or type(amount) ~= "number" or amount <= 0 then return 0 end
  local added = math.min(math.floor(amount), cap - wallet[resource])
  if added <= 0 then return 0 end
  wallet[resource] = wallet[resource] + added
  return added
end
