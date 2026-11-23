local WF = Warfront

-- Joining the arena's layer (decision 0119 § 7, step 4).
--
-- A player present in a POI whose arena is on another layer may ask to join
-- it. The click asks one same-faction Warfront player standing on the arena
-- layer at a time, by addon whisper (LJ); that player's addon invites the
-- requester when it can, or answers why not (LN). Out of combat the game moves
-- a group member to the leader's layer and says so with SHARD_TRANSFER
-- (decision 0142 § 6): we take the helper's layer tag (WF.Layer:Expect) and
-- leave the pair LEAVE_AFTER_MOVE s later, never under LEAVE_MIN s after the
-- join; with no move NO_MOVE_LEAVE s after the join we leave. Saved: the helper's choice
-- (WarfrontDB.settings.layerHelpOff) and, per character, the time of the last
-- jump (WarfrontDB.settings.layerJumps), so a /reload never shortens the wait.
--   * No fleeing: the only destination is the arena layer, from a POI, out of
--     combat for COMBAT_GAP s, eligible to be counted, without a group, one
--     jump per JUMP_COOLDOWN s and no way back to the previous layer meanwhile.
--   * A request is data: same faction only (an addon whisper never crosses),
--     rate-limited per requester and per helper, refused in combat, in an
--     instance or in a group the helper does not lead or that is full; it
--     never changes Warfront state.
--   * The jump pair is isolated: the two-player group carries no group
--     transport, and lines from the partner in a group are never trusted
--     (modules/transport.lua).
-- Values are provisional (decision 0119).

local LayerJump = {
  asked = 0, invites = 0, refusals = 0, helped = 0, refused = 0, jumps = 0, timeouts = 0,
  lastResult = nil,
}
WF.LayerJump = LayerJump

local ASK_WAIT, MAX_ASKED = 8, 4
local JUMP_TIMEOUT, JUMP_COOLDOWN, COMBAT_GAP = 60, 600, 15
-- After the game's move; never less than LEAVE_MIN s after the join.
local LEAVE_AFTER_MOVE, LEAVE_MIN, NO_MOVE_LEAVE = 2, 4, 15
local MAX_SAVED_JUMPS = 16
-- The game's own limit on layer changes: about MOVE_CAP moves of a character an
-- hour, the hour opening with the first move after the previous hour closed
-- (a lead from another addon's logs; unmeasured here). A move is the first
-- SHARD_TRANSFER in a group (measured 2026-11-23: 1.8 s after a moving join).
-- Saved per character in WarfrontDB.settings.layerMoves = { start, count }.
local MOVE_CAP, MOVE_HOUR, MAX_SAVED_MOVES = 10, 3600, 16
local movedInGroup = false
local HELP_GAP, HELP_PER_REQUESTER = 10, 120
local PARTNER_LIFE = 90
local MAX_REQUESTERS = 64
local TICK = 0.5
-- Refusal codes on the wire (LN).
local REASONS = { off = true, instance = true, combat = true, group = true, layer = true, busy = true }

-- Requester state.
local phase, request -- phase: nil | "asking" | "invited" | "jumping"
local lastCombatEnd, inCombat = -1000, false
local lastJumpAt, previousLayer, restored = -1000, nil, false
-- Helper state.
local lastHelpAt, requesters, requesterCount = -1000, {}, 0
local partner, partnerUntil = nil, 0
local nextTickAt = 0

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

local function Flag(name, unit)
  local ok, value = Call(name, unit)
  if not ok or IsSecret(value) then return nil end
  return value and true or false
end

local function InInstance()
  local ok, inside = Call("IsInInstance")
  return ok and inside == true
end

local function InCombat()
  return inCombat or Flag("UnitAffectingCombat", "player") == true
end

local function InGroup()
  return Flag("UnitExists", "party1") == true or Flag("UnitExists", "raid1") == true
end

local function InRaid()
  return Flag("UnitExists", "raid1") == true
end

-- Members of our party besides us (0..4); a raid counts as full.
local function PartyOthers()
  if InRaid() then return 40 end
  local count = 0
  for i = 1, 4 do
    if Flag("UnitExists", "party" .. i) == true then count = count + 1 end
  end
  return count
end

local function PartyInfo(method, ...)
  local api = Global("C_PartyInfo")
  if type(api) ~= "table" or type(api[method]) ~= "function" then return false, "unavailable" end
  return pcall(api[method], ...)
end

-- Our shared layer tag (what P states), or nil.
local function MyLayer()
  local layer = WF.Layer
  return layer and layer.Current and layer:Current() or nil
end

-- Our layer tag, shared or not: a requester compares it with the arena.
local function MyTag()
  local layer = WF.Layer
  return layer and layer.Mine and layer:Mine() or nil
end

local function Wire(key) return key and (string.gsub(key, ":", ".", 1)) or nil end

local function Unwire(text)
  if type(text) ~= "string" then return nil end
  local server, zone = string.match(text, "^(%d+)%.(%d+)$")
  if not server or #server > 9 or #zone > 9 then return nil end
  return server .. ":" .. zone
end

local function Settings()
  local storage = WF.Storage
  if not storage or type(storage.GetDB) ~= "function" or storage.readOnly then return nil end
  local db = storage:GetDB()
  return type(db) == "table" and type(db.settings) == "table" and db.settings or nil
end

-- Wall-clock seconds, for the saved jump time only (GetTime restarts at login).
local function Wall()
  local value = WF.Epoch and WF.Epoch() or nil
  return type(value) == "number" and value > 0 and value or nil
end

local function Me()
  local capture = WF.Capture
  return capture and capture.Me and capture:Me() or nil
end

-- The last jump of this character, saved across /reload and logins.
local function RestoreJump(now)
  if restored then return end
  restored = true
  local settings, me, wall = Settings(), Me(), Wall()
  local saved = settings and type(settings.layerJumps) == "table" and me and settings.layerJumps[me]
  if type(saved) ~= "table" or type(saved.at) ~= "number" or not wall then return end
  local ago = wall - saved.at
  if ago >= 0 and ago < JUMP_COOLDOWN then
    lastJumpAt = now - ago
    previousLayer = type(saved.from) == "string" and saved.from or nil
  end
end

local function SaveJump()
  local settings, me, wall = Settings(), Me(), Wall()
  if not settings or not me or not wall then return end
  local jumps = type(settings.layerJumps) == "table" and settings.layerJumps or {}
  settings.layerJumps = jumps
  local count, oldest, oldestAt = 0, nil, nil
  for name, row in pairs(jumps) do
    local at = type(row) == "table" and tonumber(row.at) or nil
    if not at or wall - at >= JUMP_COOLDOWN then
      jumps[name] = nil
    else
      count = count + 1
      if not oldestAt or at < oldestAt then oldest, oldestAt = name, at end
    end
  end
  if count >= MAX_SAVED_JUMPS and oldest and not jumps[me] then jumps[oldest] = nil end
  jumps[me] = { at = wall, from = previousLayer }
end

-- This character's running hour of layer changes, or nil.
local function MoveRow()
  local settings, me = Settings(), Me()
  local rows = settings and type(settings.layerMoves) == "table" and settings.layerMoves or nil
  local row = rows and me and rows[me]
  if type(row) ~= "table" or type(row.start) ~= "number" or type(row.count) ~= "number" then return nil end
  return row
end

-- Layer changes used in the running hour, and seconds until it closes (0, 0 when none runs).
function LayerJump:MovesUsed()
  local row, wall = MoveRow(), Wall()
  if not row or not wall then return 0, 0 end
  local left = row.start + MOVE_HOUR - wall
  if left <= 0 or left > MOVE_HOUR then return 0, 0 end
  return math.min(row.count, MOVE_CAP), left
end

function LayerJump:MoveCap() return MOVE_CAP end

-- One move of ours by the game: counted in the running hour, or opens a new one.
local function NoteMove()
  local settings, me, wall = Settings(), Me(), Wall()
  if not settings or not me or not wall then return end
  local row = MoveRow()
  if row and wall - row.start >= 0 and wall - row.start < MOVE_HOUR then
    row.count = row.count + 1
    return
  end
  local rows = type(settings.layerMoves) == "table" and settings.layerMoves or {}
  settings.layerMoves = rows
  local count, oldest, oldestAt = 0, nil, nil
  for name, other in pairs(rows) do
    local start = type(other) == "table" and tonumber(other.start) or nil
    if not start or wall - start >= MOVE_HOUR or wall - start < 0 then
      rows[name] = nil
    else
      count = count + 1
      if not oldestAt or start < oldestAt then oldest, oldestAt = name, start end
    end
  end
  if count >= MAX_SAVED_MOVES and oldest and not rows[me] then rows[oldest] = nil end
  rows[me] = { start = wall, count = 1 }
end

local function Say(text)
  LayerJump.lastResult = text
  if WF.Print then WF.Print(text) end
end

local function Clock(seconds)
  seconds = math.max(0, math.floor(seconds + 0.5))
  return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

-- Where we stand: the POI id, its arena key and our capture context, or nil.
local function Context()
  local capture = WF.Capture
  local here = capture and capture.here
  if type(here) ~= "table" or not here.id then return nil end
  if WF.Stock and WF.Stock.Resource and WF.Stock:Resource(here.id) then return nil end
  -- The arena its authority announced (S field 15), else our own reading.
  local st = capture.states and capture.states[here.id]
  local arenas = capture.arenas
  local arena = st and st.authority and st.arena or (arenas and arenas[here.id] and arenas[here.id].key)
  return here, arena, capture
end

-- Same-faction players present on the arena layer of this POI, sorted.
local function Helpers(capture, id, arena, now)
  local list = capture.presence and capture.presence[id]
  local faction = capture.MyFaction and capture:MyFaction()
  local me = capture.Me and capture:Me()
  local out = {}
  if not list or not faction then return out end
  for identity, entry in pairs(list.entries) do
    if identity ~= me and entry.faction == faction and entry.layer == arena and now <= (entry.expireAt or 0) then
      out[#out + 1] = identity
    end
  end
  table.sort(out)
  return out
end

-- Requester -------------------------------------------------------------------------

-- Why we cannot ask now (player-facing), or nil when we can.
function LayerJump:Blocked(now)
  RestoreJump(now)
  local here, arena, capture = Context()
  local mine = MyTag()
  if not here or not arena or not mine or mine == arena then return "no arena" end
  if phase then return "Joining..." end
  if InInstance() then return "Not available here." end
  if here.status ~= "IN" then return "You must be counted here to join." end
  if InGroup() then return "Leave your group first." end
  if InCombat() then return "Leave combat first." end
  if now - lastCombatEnd < COMBAT_GAP then return "Wait " .. Clock(COMBAT_GAP - (now - lastCombatEnd)) .. " after combat." end
  if now - lastJumpAt < JUMP_COOLDOWN then
    return "Wait " .. Clock(JUMP_COOLDOWN - (now - lastJumpAt)) .. " before joining again."
  end
  if arena == previousLayer and now - lastJumpAt < JUMP_COOLDOWN then return "Not available yet." end
  local used, left = self:MovesUsed()
  if used >= MOVE_CAP then return "Layer changes used up: back in " .. Clock(left) .. "." end
  if #Helpers(capture, here.id, arena, now) == 0 then return "No one can help right now." end
  return nil
end

-- What the HUD shows: nil, or { text, button, enabled }.
function LayerJump:HudState(now)
  local here, arena = Context()
  local mine = MyTag()
  if not here or not arena or not mine or mine == arena then
    if not phase then return nil end
  end
  -- moves: layer changes used this hour, shown beside the button against MOVE_CAP.
  local moves = (self:MovesUsed())
  if phase == "asking" then return { text = "Asking a player there...", button = "Join it", enabled = false, moves = moves, cap = MOVE_CAP } end
  if phase == "invited" then return { text = "Accept the group invitation to join the fight.", button = "Join it", enabled = false, moves = moves, cap = MOVE_CAP } end
  if phase == "jumping" then return { text = "Joining the fight...", button = "Join it", enabled = false, moves = moves, cap = MOVE_CAP } end
  local blocked = self:Blocked(now)
  return { text = "The fight is on another layer." .. (blocked and ("  " .. blocked) or ""), button = "Join it",
    enabled = blocked == nil, moves = moves, cap = MOVE_CAP }
end

local function AskNext(now)
  local capture = WF.Capture
  local helper = request.queue[request.next]
  if not helper or request.next > MAX_ASKED then
    phase, request = nil, nil
    Say("No one can help right now.")
    return
  end
  request.next = request.next + 1
  request.helper, request.askedAt = helper, now
  LayerJump.asked = LayerJump.asked + 1
  local ok = capture and capture.SendTo and capture:SendTo(helper, "LJ", request.id .. "," .. Wire(request.arena))
  if not ok then request.askedAt = now - ASK_WAIT end
end

-- The click (a hardware event): checks again, then asks the first helper.
function LayerJump:Click()
  local now = Now()
  local blocked = self:Blocked(now)
  if blocked then
    if blocked ~= "no arena" then Say(blocked) end
    return false
  end
  local here, arena, capture = Context()
  request = {
    id = string.format("%X", math.random(4096, 65535)), arena = arena, from = MyTag(),
    queue = Helpers(capture, here.id, arena, now), next = 1, startedAt = now,
  }
  phase = "asking"
  AskNext(now)
  return true
end

-- A refusal from the helper we asked: the next one.
function LayerJump:OnRefusal(identity, data, now)
  if phase ~= "asking" or not request or identity ~= request.helper then return false end
  local id, reason = string.match(data or "", "^(%x+),(%a+)$")
  if id ~= request.id or not REASONS[reason] then return false end
  self.refusals = self.refusals + 1
  AskNext(now)
  return true
end

function LayerJump:OnInvite(name)
  if phase ~= "asking" or not request or type(name) ~= "string" or IsSecret(name) then return end
  local capture = WF.Capture
  local identity = capture and capture.Identity and capture.Identity(name) or name
  if identity ~= request.helper then return end
  self.invites = self.invites + 1
  phase = "invited"
  -- The game's move brings us to the helper's layer: its tag becomes ours.
  if WF.Layer and WF.Layer.Expect then WF.Layer:Expect(request.arena, Now() + JUMP_TIMEOUT + NO_MOVE_LEAVE) end
  Say("Accept the group invitation to join the fight.")
end

local function Finish(now, text, jumped)
  if jumped then LayerJump.jumps = LayerJump.jumps + 1 end
  -- Only the pair of a jump is left; a real group is never left.
  if InGroup() and not InRaid() and PartyOthers() == 1 then PartyInfo("LeaveParty") end
  phase, request = nil, nil
  Say(text)
end

function LayerJump:TickRequester(now)
  if not phase then return end
  if phase == "asking" then
    if now - request.askedAt >= ASK_WAIT then AskNext(now) end
    return
  end
  if phase == "invited" then
    if InGroup() then
      if InRaid() or PartyOthers() ~= 1 then
        -- Joined a group that is not the pair: stop here, never leave it.
        if WF.Layer and WF.Layer.Expect then WF.Layer:Expect(nil) end
        phase, request = nil, nil
        return
      end
      phase, request.joinedAt = "jumping", now
      -- The wait starts once we joined the pair, whatever the outcome.
      lastJumpAt, previousLayer = now, request.from
      SaveJump()
    elseif now - request.startedAt >= JUMP_TIMEOUT then
      if WF.Layer and WF.Layer.Expect then WF.Layer:Expect(nil) end
      phase, request = nil, nil
      Say("The invitation did not arrive.")
    end
    return
  end
  -- jumping: the game's move (SHARD_TRANSFER) decides.
  if not request.movedAt then
    if not InGroup() then
      -- The helper's group ended before any move.
      if WF.Layer and WF.Layer.Expect then WF.Layer:Expect(nil) end
      phase, request = nil, nil
      return
    end
    if now - request.joinedAt >= NO_MOVE_LEAVE then
      self.timeouts = self.timeouts + 1
      if WF.Layer and WF.Layer.Expect then WF.Layer:Expect(nil) end
      Finish(now, "The layer did not change.", false)
    end
    return
  end
  if not InGroup() or now >= math.max(request.movedAt + LEAVE_AFTER_MOVE, request.joinedAt + LEAVE_MIN) then
    Finish(now, "You joined the fight.", true)
  end
end

-- The game moved us: the move a jump waits for, and one of the hour's moves.
function LayerJump:OnTransfer(now)
  if (phase == "invited" or phase == "jumping") and request and not request.movedAt and InGroup() then
    request.movedAt = now
  end
  if InGroup() and not movedInGroup then
    movedInGroup = true
    NoteMove()
  end
end

-- Helper ----------------------------------------------------------------------------

function LayerJump:HelpOff()
  local settings = Settings()
  return settings and settings.layerHelpOff and true or false
end

function LayerJump:SetHelpOff(off)
  local settings = Settings()
  if not settings then return false end
  settings.layerHelpOff = off and true or nil
  return true
end

local function Refuse(target, id, reason)
  LayerJump.refused = LayerJump.refused + 1
  local capture = WF.Capture
  if capture and capture.SendTo then capture:SendTo(target, "LN", id .. "," .. reason) end
end

local function NoteRequester(identity, now)
  if not requesters[identity] then
    if requesterCount >= MAX_REQUESTERS then
      for other, at in pairs(requesters) do
        if now - at > HELP_PER_REQUESTER then requesters[other] = nil; requesterCount = requesterCount - 1 end
      end
      if requesterCount >= MAX_REQUESTERS then return false end
    end
    requesterCount = requesterCount + 1
  end
  requesters[identity] = now
  return true
end

-- An LJ request: "<id>,<layer>". Answered with an invite or an LN refusal.
function LayerJump:OnRequest(identity, target, data, now)
  local id, wire = string.match(data or "", "^(%x+),([%d%.]+)$")
  local wanted = Unwire(wire)
  if not id or #id > 8 or not wanted then return false end
  local last = requesters[identity]
  if last and now - last < HELP_PER_REQUESTER then return false end
  if not NoteRequester(identity, now) then return false end
  if self:HelpOff() then return Refuse(target, id, "off") end
  if InInstance() then return Refuse(target, id, "instance") end
  if InCombat() then return Refuse(target, id, "combat") end
  if InGroup() then
    local leader = Flag("UnitIsGroupLeader", "player") == true
    if not leader or InRaid() or PartyOthers() >= 4 then return Refuse(target, id, "group") end
  end
  if MyLayer() ~= wanted then return Refuse(target, id, "layer") end
  if now - lastHelpAt < HELP_GAP then return Refuse(target, id, "busy") end
  local ok = PartyInfo("InviteUnit", target)
  if not ok then return Refuse(target, id, "busy") end
  lastHelpAt = now
  partner, partnerUntil = identity, now + PARTNER_LIFE
  self.helped = self.helped + 1
  return true
end

-- Isolation -------------------------------------------------------------------------

-- A jump partner (either side) for PARTNER_LIFE s, or for the whole jump.
function LayerJump:IsPartner(identity, now)
  now = now or Now()
  if partner and identity == partner and now <= partnerUntil then return true end
  return request ~= nil and phase ~= "asking" and identity == request.helper
end

-- Our group is only the pair of a jump: no group transport while it lasts.
function LayerJump:IsHopGroup(now)
  now = now or Now()
  if not InGroup() or InRaid() or PartyOthers() ~= 1 then return false end
  if phase == "invited" or phase == "jumping" then return true end
  return partner ~= nil and now <= partnerUntil
end

-- Transport entry point for LJ and LN whispers.
function LayerJump:OnWhisper(kind, data, identity, target, now)
  if InInstance() then return false end
  if kind == "LJ" then return self:OnRequest(identity, target, data, now) end
  if kind == "LN" then return self:OnRefusal(identity, data, now) end
  return false
end

-- Status ----------------------------------------------------------------------------

function LayerJump:Summary()
  return "jump phase=" .. tostring(phase) .. " asked=" .. self.asked .. " invites=" .. self.invites
    .. " refusals=" .. self.refusals .. " jumps=" .. self.jumps .. " timeouts=" .. self.timeouts
    .. " helped=" .. self.helped .. " refused=" .. self.refused .. " helpOff=" .. tostring(self:HelpOff())
end

function LayerJump:Tick(now)
  if now < nextTickAt then return end
  nextTickAt = now + TICK
  if partner and now > partnerUntil then partner = nil end
  self:TickRequester(now)
end

-- Wiring ------------------------------------------------------------------------------

if WF.RegisterEvent then
  WF.RegisterEvent("PLAYER_REGEN_DISABLED", function() inCombat = true end)
  WF.RegisterEvent("PLAYER_REGEN_ENABLED", function() inCombat = false; lastCombatEnd = Now() end)
  WF.RegisterEvent("PARTY_INVITE_REQUEST", function(_, name) LayerJump:OnInvite(name) end)
  -- Count the game's moves of this character: the first transfer in each group.
  WF.RegisterEvent("SHARD_TRANSFER", function() LayerJump:OnTransfer(Now()) end)
  WF.RegisterEvent("GROUP_ROSTER_UPDATE", function()
    if not InGroup() then movedInGroup = false end
  end)
end

if CreateFrame then
  local frame = CreateFrame("Frame", "WarfrontLayerJumpFrame", UIParent)
  frame:SetScript("OnUpdate", function()
    local ok, err = pcall(LayerJump.Tick, LayerJump, Now())
    if not ok and WF.RecordError then WF.RecordError("layer jump driver", err) end
  end)
end
