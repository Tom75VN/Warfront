Warfront = Warfront or {}

local WF = Warfront

-- Automatic Warfront channel join on the player's own click (decision 0140).
-- Forever blocks a join made at login without input (decision 0074) but
-- accepted one from a click (decision 0118). While the client is outside the
-- channel, a mouse press in the game makes one direct join call, so a player
-- who never joined, or whose channel vanished, reconnects without Connect.
-- Bounded: never before START_DELAY, one call per MIN_GAP, MAX_PER_SESSION a
-- session, never in combat. A blocked call stops it for that client build.
local AutoJoin = {
  START_DELAY = 10,       -- seconds after load: let the client rejoin first
  MIN_GAP = 60,           -- seconds between two calls
  MAX_PER_SESSION = 5,
  CHECK_GAP = 2,          -- seconds between two membership checks
  BLOCK_WINDOW = 0.5,     -- blocked action attributed to our call
  attempts = 0,
}
AutoJoin.nextAt = WF.Now() + AutoJoin.START_DELAY
AutoJoin.checkAt = AutoJoin.nextAt
WF.ChannelAutoJoin = AutoJoin

local function InCombat()
  local restricted = WF.Compat.Global("C_RestrictedActions")
  if type(restricted) ~= "table" or type(restricted.InCombatLockdown) ~= "function" then return false end
  local ok, locked = pcall(restricted.InCombatLockdown)
  return ok and locked == true
end

local function ClientBuild()
  local info = WF.Compat.Global("GetBuildInfo")
  if type(info) ~= "function" then return nil end
  local ok, _, build = pcall(info)
  if ok and build ~= nil then return tostring(build) end
  return nil
end

local function WritableDB()
  local storage = WF.Storage
  if not (storage and storage.initialized) or storage.readOnly then return nil end
  local db = storage:GetDB()
  if type(db) == "table" then return db end
  return nil
end

function AutoJoin:OnMouseDown()
  local now = WF.Now()
  if self.attempts >= self.MAX_PER_SESSION or now < self.nextAt or now < self.checkAt then return end
  self.checkAt = now + self.CHECK_GAP
  local p2p = WF.P2PTest
  if not (p2p and p2p.ChannelJoined and p2p.JoinChannelAuto) or p2p.ChannelJoined() then return end
  if InCombat() then return end
  local db, build = WritableDB(), ClientBuild()
  if not (db and build) or db.channelAutoJoinBlocked == build then return end

  self.attempts = self.attempts + 1
  self.nextAt = now + self.MIN_GAP
  self.attemptAt = now
  local status, err = p2p.JoinChannelAuto()
  WF.Storage:AddResult({
    kind = "CHANNEL_AUTO_JOIN",
    status = status or "CALL_FAILED",
    attempt = self.attempts,
    error = err,
  })
end

function AutoJoin:OnBlocked(source)
  local at = self.attemptAt
  if not at then return end
  local secret = WF.Compat.Global("issecretvalue")
  if type(secret) == "function" then
    local ok, isSecret = pcall(secret, source)
    if not ok or isSecret then return end
  end
  if source ~= "Warfront" then return end
  self.attemptAt = nil
  if WF.Now() - at > self.BLOCK_WINDOW then return end
  local db, build = WritableDB(), ClientBuild()
  if db and build then db.channelAutoJoinBlocked = build end
  WF.Storage:AddResult({ kind = "CHANNEL_AUTO_JOIN", status = "BLOCKED", build = build })
end

WF.RegisterEvent("GLOBAL_MOUSE_DOWN", function() AutoJoin:OnMouseDown() end)
WF.RegisterEvent("ADDON_ACTION_BLOCKED", function(_, source) AutoJoin:OnBlocked(source) end)
WF.RegisterEvent("ADDON_ACTION_FORBIDDEN", function(_, source) AutoJoin:OnBlocked(source) end)
