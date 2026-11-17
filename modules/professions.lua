local WF = Warfront

-- Profession rewards (decision 0099): small personal resources for gathering
-- outside POIs. Local to the character, nothing travels on the wire.
--   * Mining and herbs: at LOOT_READY, a slot whose source is a game object
--     and whose item is Metal & Stone (ore) or Herb. One reward per node, so
--     no list of world objects is needed.
--   * Fishing: IsFishingLoot with a fish in the loot, one reward per catch.
--   * Cooking: the client's own "you create" loot line for a Food & Drink item
--     while a profession window is open, which leaves out conjured food.
-- Item classes, loot functions and loot lines measured 2026-11-11 by the
-- ForeverRuntimeProbe groups gatheritems and gather, on one client without a
-- profession. Every reward goes through Economy:Add, which applies the caps.
local Professions = { seen = {}, seenCount = 0, windowOpen = false, rewarded = 0 }
WF.Professions = Professions

local REWARDS = {
  ore = { resource = "gold", amount = 5, name = "gold" },
  herb = { resource = "wood", amount = 5, name = "wood" },
  fish = { resource = "food", amount = 3, name = "food" },
  dish = { resource = "food", amount = 5, name = "food" },
}
Professions.REWARDS = REWARDS

local CLASS_CONSUMABLE, SUB_FOOD = 0, 5
local CLASS_TRADE, SUB_METAL, SUB_COOKING, SUB_HERB = 7, 7, 8, 9
local OBJECT_PREFIX = "GameObject-"
-- LOOT_READY fires more than once per loot. A node is rewarded once however
-- many times it is mined; a catch once within a moment.
local NODE_WINDOW, FISH_WINDOW = 300, 2
local MAX_SEEN = 64

local function Global(name)
  if getglobal then return getglobal(name) end
  return _G and _G[name] or nil
end

local function Now()
  local now = WF.Now and WF.Now() or 0
  return type(now) == "number" and now or 0
end

local function Call(name, ...)
  local fn = Global(name)
  if type(fn) ~= "function" then return false end
  return pcall(fn, ...)
end

-- A value the client hides from addons: never compare or index it.
local function Secret(value)
  local fn = Global("issecretvalue")
  return type(fn) == "function" and fn(value) and true or false
end

-- classID and subClassID of an item link, or nil.
local function ItemClass(link)
  if type(link) ~= "string" or Secret(link) then return nil end
  local found, id = pcall(string.match, link, "|Hitem:(%d+)")
  id = found and tonumber(id) or nil
  local items = Global("C_Item")
  if not id or type(items) ~= "table" or type(items.GetItemInfoInstant) ~= "function" then return nil end
  local ok, _, _, _, _, _, classID, subClassID = pcall(items.GetItemInfoInstant, id)
  if not ok then return nil end
  return classID, subClassID
end

-- Remembers key for window seconds; false when it is still remembered.
function Professions:Mark(key, window, now)
  for other, expires in pairs(self.seen) do
    if expires <= now then
      self.seen[other] = nil
      self.seenCount = self.seenCount - 1
    end
  end
  if self.seen[key] then return false end
  if self.seenCount >= MAX_SEEN then return false end
  self.seen[key] = now + window
  self.seenCount = self.seenCount + 1
  return true
end

function Professions:Credit(kind, count)
  local reward = REWARDS[kind]
  if not reward or not WF.Economy then return 0 end
  local added = WF.Economy:Add(reward.resource, reward.amount * (count or 1))
  if added > 0 then
    self.rewarded = self.rewarded + added
    if WF.Print then WF.Print("+" .. added .. " " .. reward.name) end
  end
  return added
end

local function Supported()
  return not WF.Ruleset or WF.Ruleset:Supported()
end

function Professions:OnLootReady(now)
  if not Supported() then return end
  local counted, slots = Call("GetNumLootItems")
  if not counted or Secret(slots) or type(slots) ~= "number" or slots < 1 then return end
  local isFishing, fishing = Call("IsFishingLoot")
  fishing = isFishing and not Secret(fishing) and fishing == true
  local caught = false
  for slot = 1, slots do
    local linked, link = Call("GetLootSlotLink", slot)
    local classID, subClassID
    if linked then classID, subClassID = ItemClass(link) end
    if classID then
      if fishing then
        if (classID == CLASS_TRADE and subClassID == SUB_COOKING)
            or (classID == CLASS_CONSUMABLE and subClassID == SUB_FOOD) then
          caught = true
        end
      elseif classID == CLASS_TRADE and (subClassID == SUB_METAL or subClassID == SUB_HERB) then
        local sourced, guid = Call("GetLootSourceInfo", slot)
        if sourced and type(guid) == "string" and not Secret(guid)
            and string.sub(guid, 1, #OBJECT_PREFIX) == OBJECT_PREFIX
            and self:Mark(guid, NODE_WINDOW, now) then
          self:Credit(subClassID == SUB_METAL and "ore" or "herb", 1)
        end
      end
    end
  end
  if caught and self:Mark("fish", FISH_WINDOW, now) then self:Credit("fish", 1) end
end

-- A client format string ("You create: %s.") as a Lua pattern, in any language.
local function FormatPattern(format)
  if type(format) ~= "string" then return nil end
  local pattern = string.gsub(format, "([%^%$%(%)%.%[%]%*%+%-%?])", "%%%1")
  pattern = string.gsub(pattern, "%%s", "(.+)")
  pattern = string.gsub(pattern, "%%d", "(%%d+)")
  return "^" .. pattern .. "$"
end
Professions.FormatPattern = FormatPattern

-- The item link and count of a "you create" line, or nil.
function Professions.ParseCreated(text)
  local pattern = FormatPattern(Global("LOOT_ITEM_CREATED_SELF_MULTIPLE"))
  if pattern then
    local ok, link, count = pcall(string.match, text, pattern)
    if ok and link and tonumber(count) then return link, tonumber(count) end
  end
  pattern = FormatPattern(Global("LOOT_ITEM_CREATED_SELF"))
  if pattern then
    local ok, link = pcall(string.match, text, pattern)
    if ok and link then return link, 1 end
  end
  return nil
end

function Professions:OnLootLine(text)
  if not self.windowOpen or type(text) ~= "string" or Secret(text) or not Supported() then return end
  local link, count = Professions.ParseCreated(text)
  if not link then return end
  local classID, subClassID = ItemClass(link)
  if classID == CLASS_CONSUMABLE and subClassID == SUB_FOOD then self:Credit("dish", count) end
end

function Professions:OnEvent(event, text)
  if event == "LOOT_READY" then
    self:OnLootReady(Now())
  elseif event == "CHAT_MSG_LOOT" then
    self:OnLootLine(text)
  elseif event == "TRADE_SKILL_SHOW" then
    self.windowOpen = true
  elseif event == "TRADE_SKILL_CLOSE" then
    self.windowOpen = false
  end
end

local create = Global("CreateFrame")
if type(create) == "function" then
  local ok, frame = pcall(create, "Frame")
  if ok and frame then
    frame:SetScript("OnEvent", function(_, event, text)
      local handled, err = pcall(Professions.OnEvent, Professions, event, text)
      if not handled and WF.RecordError then WF.RecordError("professions", err) end
    end)
    frame:RegisterEvent("LOOT_READY")
    frame:RegisterEvent("CHAT_MSG_LOOT")
    frame:RegisterEvent("TRADE_SKILL_SHOW")
    frame:RegisterEvent("TRADE_SKILL_CLOSE")
    Professions.frame = frame
  end
end
