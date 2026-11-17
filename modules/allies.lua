Warfront = Warfront or {}

local WF = Warfront
local Allies = {}
WF.Allies = Allies

-- Allies across the front (decision 0127): the player's opt-in, the limits
-- that keep BattleTags from being harvested, and Blizzard's Add Friend frame
-- opened pre-filled for the player to confirm. Local only: nothing here sends
-- a message; the offer exchange builds on these functions.
--
-- Saved in WarfrontDB.allies (account-wide, all new keys):
--   optIn     true while the player volunteers
--   popupOff  true once "Don't show again" was ticked
--   partners  [character] = { at = epoch, revealed = bool }, 3 at most
--   blocked   [character] = epoch, 200 at most, oldest out
--   reveals   epochs of own BattleTag reveals, kept 7 days, 3 at most
Allies.MAX_PARTNERS = 3
Allies.MAX_REVEALS = 3
Allies.REVEAL_WINDOW = 7 * 86400
Allies.EXPIRY = 14 * 86400
Allies.MAX_BLOCKED = 200

local function DB()
  local storage = WF.Storage
  if not storage or not storage.GetDB or storage.readOnly then return nil end
  local db = storage:GetDB()
  if type(db) ~= "table" then return nil end
  local a = db.allies
  if type(a) ~= "table" then
    a = {}
    db.allies = a
  end
  if type(a.partners) ~= "table" then a.partners = {} end
  if type(a.blocked) ~= "table" then a.blocked = {} end
  if type(a.reveals) ~= "table" then a.reveals = {} end
  return a
end

local function Epoch()
  return WF.Epoch and WF.Epoch() or 0
end

local function Call(name, ...)
  local fn = _G[name]
  if type(fn) ~= "function" then return false end
  return pcall(fn, ...)
end

function Allies:OptedIn()
  local a = DB()
  return a ~= nil and a.optIn == true and not self:CloudLocked()
end

-- The complete exchange engine must be loaded before volunteering.
function Allies:IsAvailable()
  return self.MatchTick ~= nil and WF.AlliesMesh ~= nil and WF.X25519 ~= nil and WF.X25519.Available()
end

function Allies:State() return DB() end
function Allies:CloudLocked()
  local a = DB()
  return a and tonumber(a.cloudUntil) and a.cloudUntil > Epoch() or false
end

function Allies:SetOptIn(on)
  if on and (not self:IsAvailable() or self:CloudLocked()) then return false end
  local a = DB()
  if not a then return false end
  a.optIn = on and true or nil
  if not on then
    a.partners = {}
    if self.ResetMatches then self:ResetMatches() end
  end
  return true
end

function Allies:PopupHidden()
  local a = DB()
  return a ~= nil and a.popupOff == true
end

function Allies:SetPopupHidden(hidden)
  local a = DB()
  if not a then return false end
  a.popupOff = hidden and true or nil
  return true
end

function Allies:IsBlocked(name)
  local a = DB()
  return a ~= nil and type(name) == "string" and a.blocked[name] ~= nil
end

-- Blocks a character for good and ends any match with it.
function Allies:Block(name, epoch)
  local a = DB()
  if not a or type(name) ~= "string" or name == "" then return false end
  a.partners[name] = nil
  a.blocked[name] = epoch or Epoch()
  local count, oldest, oldestAt = 0, nil, nil
  for key, at in pairs(a.blocked) do
    count = count + 1
    if type(at) ~= "number" or not oldestAt or at < oldestAt then oldest, oldestAt = key, tonumber(at) or 0 end
  end
  if count > self.MAX_BLOCKED and oldest and oldest ~= name then a.blocked[oldest] = nil end
  return true
end

-- Ends matches older than EXPIRY that never reached a reveal; their
-- characters are blocked so they are never proposed again (decision 0121).
function Allies:Expire(epoch)
  local a = DB()
  if not a then return 0 end
  epoch = epoch or Epoch()
  local ended = 0
  for name, p in pairs(a.partners) do
    local at = type(p) == "table" and tonumber(p.at) or nil
    if not at or (not p.revealed and epoch - at >= self.EXPIRY) then
      a.partners[name] = nil
      if at then self:Block(name, epoch) end
      ended = ended + 1
    end
  end
  return ended
end

function Allies:OpenPartners()
  local a = DB()
  local count = 0
  if a then for _ in pairs(a.partners) do count = count + 1 end end
  return count
end

-- True when a new match with `name` may start now.
function Allies:CanTakePartner(name)
  local a = DB()
  if not a or not self:OptedIn() or type(name) ~= "string" or name == "" then return false end
  local count = 0 for _ in pairs(a.blocked) do count = count + 1 end
  if count >= self.MAX_BLOCKED or a.blocked[name] or a.partners[name] then return false end
  return self:OpenPartners() < self.MAX_PARTNERS
end

function Allies:TakePartner(name, epoch)
  if not self:CanTakePartner(name) then return false end
  DB().partners[name] = { at = epoch or Epoch() }
  return true
end

-- Reveals in the last REVEAL_WINDOW, pruning older ones.
function Allies:RecentReveals(epoch)
  local a = DB()
  if not a then return 0 end
  epoch = epoch or Epoch()
  local kept = {}
  for i = 1, #a.reveals do
    local at = tonumber(a.reveals[i])
    if at and at <= epoch and epoch - at < self.REVEAL_WINDOW then kept[#kept + 1] = at end
  end
  a.reveals = kept
  return #kept
end

function Allies:CanReveal(name, epoch)
  local a = DB()
  if not a or a.optIn ~= true or type(a.partners[name]) ~= "table" then return false end
  if a.partners[name].revealed then return false end
  return self:RecentReveals(epoch) < self.MAX_REVEALS
end

function Allies:NoteReveal(name, epoch)
  if not self:CanReveal(name, epoch) then return false end
  local a = DB()
  epoch = epoch or Epoch()
  a.reveals[#a.reveals + 1] = epoch
  a.partners[name].revealed = true
  return true
end

-- The player's own BattleTag, read only when about to reveal it.
function Allies:OwnBattleTag()
  local ok, _, tag = Call("BNGetInfo")
  if ok and type(tag) == "string" and string.find(tag, "^[^%s#]+#%d+$") and string.len(tag) <= 32 then return tag end
  return nil
end

function Allies:BattleNetReady()
  local ok, ready = Call("BNFeaturesEnabledAndConnected")
  return ok and ready == true
end

-- Opens Blizzard's Add Friend frame holding `tag`; the player sends it there.
-- Never with a target selected: AddFriendFrame_Show may add the target instead.
function Allies:ShowAddFriend(tag)
  if type(tag) ~= "string" or not string.find(tag, "^[^%s#]+#%d+$") then return false end
  local ok, hasTarget = Call("UnitExists", "target")
  if ok and hasTarget then
    WF.Print("Clear your target, then try again.")
    return false
  end
  if not Call("AddFriendFrame_Show") then return false end
  local box = _G.AddFriendNameEditBox
  if type(box) ~= "table" or type(box.SetText) ~= "function" then return false end
  return pcall(box.SetText, box, tag)
end

local function InCombat()
  local api = _G.C_RestrictedActions
  if type(api) ~= "table" or type(api.InCombatLockdown) ~= "function" then return false end
  local ok, combat = pcall(api.InCombatLockdown)
  return ok and combat == true
end

local function InInstance()
  local ok, inside = Call("IsInInstance")
  return ok and inside == true
end

function Allies:CanPrompt()
  return self:BattleNetReady() and not InCombat() and not InInstance()
end

-- The invitation popup: once per session, a few seconds after loading, out
-- of combat and instances, while the player neither volunteers nor hid it.
Allies.POPUP_DELAY = 8

function Allies:PopupDue()
  if not self:IsAvailable() then return false end
  if self.popupShown or self:OptedIn() or self:PopupHidden() or self:CloudLocked() then return false end
  if not self:BattleNetReady() or InCombat() or InInstance() then return false end
  return true
end

local elapsed, active = 0, false
local function OnUpdate(_, delta)
  if Allies:IsAvailable() then Allies:MatchTick(WF.Now()) end
  if not active then return end
  elapsed = elapsed + (delta or 0)
  if elapsed < Allies.POPUP_DELAY then return end
  elapsed = 0
  if Allies:PopupDue() and Allies.ShowPopup then
    Allies.popupShown = true
    active = false
    Allies:ShowPopup()
  elseif Allies.popupShown or Allies:OptedIn() or Allies:PopupHidden() then
    active = false
  end
end

local function OnEnteringWorld()
  if not Allies:IsAvailable() then return end
  if not Allies.popupShown then
    elapsed = 0
    active = true
  end
  Allies:Expire()
end

if type(CreateFrame) == "function" then
  local ok, frame = pcall(CreateFrame, "Frame", nil, UIParent)
  if ok and frame and frame.SetScript then frame:SetScript("OnUpdate", OnUpdate) end
end
if WF.RegisterEvent then
  WF.RegisterEvent("PLAYER_ENTERING_WORLD", OnEnteringWorld)
end
