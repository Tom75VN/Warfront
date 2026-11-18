Warfront = Warfront or {}

local WF = Warfront

-- Every P2P send, on every transport, goes through this gate: at most one
-- client send call every MIN_GAP seconds (decision 0023). Bursts wait in a
-- bounded FIFO drained by OnUpdate.
--
-- VMangos anti-flood (decision 0040, MasterPlayer::UpdateSpeakTime): on whole
-- server seconds, a message in the same second as the previous one adds one to
-- a counter, a later one resets it, and the 10th addition mutes for 10 s.
-- floodChain mirrors that counter from above: a send less than FLOOD_GAP after
-- the previous one adds one, a longer gap resets it, and once FLOOD_BURST is
-- reached the gate waits FLOOD_GAP. The margin under 10 leaves room for chat
-- the player types and for messages the network delivers closer together.
local SendQueue = {
  MIN_GAP = 0.25,
  FLOOD_GAP = 1.1,
  FLOOD_BURST = 5,
  MAX_QUEUED = 16,
  queue = {},
  lastSentAt = nil,
  floodChain = 0,
  sent = 0,
  -- Bytes of the lines handed to the client; read by the activity meter only.
  sentBytes = 0,
  delayed = 0,
  coalesced = 0,
  dropped = 0,
  maxWait = 0,
  -- Submission counter: the age order for drops once live entries go first.
  submitted = 0,
}

WF.SendQueue = SendQueue

local frame

local function Call(entry)
  local n = entry.n or 4
  if n == 1 then return pcall(entry.fn, entry.a1) end
  if n == 2 then return pcall(entry.fn, entry.a1, entry.a2) end
  if n == 3 then return pcall(entry.fn, entry.a1, entry.a2, entry.a3) end
  return pcall(entry.fn, entry.a1, entry.a2, entry.a3, entry.a4)
end

-- The line is the longest string argument in every send shape (prefix, chat
-- type and target are shorter than any envelope). Counting only, no effect.
local function Longer(value, longest)
  if type(value) == "string" and #value > longest then return #value end
  return longest
end

local function CountBytes(entry)
  local n = entry.n or 4
  local longest = Longer(entry.a1, 0)
  if n >= 2 then longest = Longer(entry.a2, longest) end
  if n >= 3 then longest = Longer(entry.a3, longest) end
  if n >= 4 then longest = Longer(entry.a4, longest) end
  SendQueue.sentBytes = SendQueue.sentBytes + longest
end

-- done(ok, err, skipped): skipped is true when the entry never reached the client.
local function Finish(entry, ok, err, skipped)
  if not entry.done then return end
  local cbOk, cbErr = pcall(entry.done, ok, err, skipped)
  if not cbOk and WF.RecordError then WF.RecordError("send queue callback", cbErr) end
end

local function Dispatch(entry, now)
  -- Queuing is not permission to send later: the route may have disappeared or
  -- entered backoff/lockdown. A cancelled entry never spends a client call.
  if entry.guard then
    local checked, allowed = pcall(entry.guard)
    if not checked or allowed ~= true then
      SendQueue.cancelled = (SendQueue.cancelled or 0) + 1
      Finish(entry, false, "route unavailable", true)
      return false, "route unavailable"
    end
  end
  if SendQueue.lastSentAt and now - SendQueue.lastSentAt < SendQueue.FLOOD_GAP then
    SendQueue.floodChain = SendQueue.floodChain + 1
  else
    SendQueue.floodChain = 0
  end
  SendQueue.lastSentAt = now
  SendQueue.sent = SendQueue.sent + 1
  if entry.queuedAt and now - entry.queuedAt > SendQueue.maxWait then
    SendQueue.maxWait = now - entry.queuedAt
  end
  local ok, err = Call(entry)
  if ok then err = nil; CountBytes(entry) else err = tostring(err) end
  Finish(entry, ok, err, false)
  return ok, err
end

function SendQueue:Ready(now)
  if not self.lastSentAt then return true end
  local gap = now - self.lastSentAt
  if gap >= self.FLOOD_GAP then return true end
  return gap >= self.MIN_GAP and self.floodChain < self.FLOOD_BURST
end

function SendQueue:Pending()
  return #self.queue
end

function SendQueue:Pump()
  local now = WF.Now()
  if #self.queue > 0 and self:Ready(now) then
    Dispatch(table.remove(self.queue, 1), now)
  end
  if #self.queue == 0 and frame then frame:SetScript("OnUpdate", nil) end
end

local function OnUpdate()
  SendQueue:Pump()
end

-- What a full queue drops first (risk B9): a replaceable state (key), whose
-- newer copy will follow; then an ordinary message; an event (priority:
-- START/CAPTURED state, kill) only when nothing else is left.
local function DropRank(entry)
  if entry.key then return 1 end
  if not entry.priority then return 2 end
  return 3
end
SendQueue.DropRank = DropRank

-- entry = { fn, n (argument count, so a probe can omit trailing arguments),
-- a1..a4, done, key, priority, live, guard }. guard must return true at dispatch.
-- A queued entry with the same key is
-- superseded: removed and replaced by the new one at the tail (the live tail for
-- a live entry), which keeps sequence order. Returns accepted, error, queued; an immediate send reports
-- its own result.
-- The lowest lane (decision 0110): sends entry at once only when nothing waits
-- in the gate and nothing left it for `quiet` seconds, else refuses it. It
-- never queues and never touches lastSentAt or floodChain, so a gameplay line
-- submitted next is never held back by it. One such send every 4 s at most
-- (modules/boards.lua) stays inside the anti-flood margin above FLOOD_BURST.
function SendQueue:SendIdle(entry, quiet)
  if type(entry) ~= "table" or type(entry.fn) ~= "function" then return false, "send function is unavailable", false end
  local now = WF.Now()
  if #self.queue > 0 then return false, "gate busy", false end
  if self.lastSentAt and now - self.lastSentAt < (quiet or self.FLOOD_GAP) then return false, "gate recently used", false end
  if entry.accounted then
    local ok, err = Dispatch(entry, now)
    return ok, err, true
  end
  self.idleSent = (self.idleSent or 0) + 1
  local ok, err = Call(entry)
  if ok then err = nil; CountBytes(entry) else err = tostring(err) end
  Finish(entry, ok, err, false)
  return ok, err, true
end

function SendQueue:Submit(entry)
  if type(entry) ~= "table" or type(entry.fn) ~= "function" then
    return false, "send function is unavailable"
  end
  local now = WF.Now()
  local queue = self.queue
  if #queue == 0 and self:Ready(now) then
    local ok, err = Dispatch(entry, now)
    if not ok then return false, err end
    return true, nil, false
  end

  if entry.key then
    local index = 1
    while index <= #queue do
      if queue[index].key == entry.key then
        local old = table.remove(queue, index)
        self.coalesced = self.coalesced + 1
        Finish(old, false, "superseded by a newer message", true)
      else
        index = index + 1
      end
    end
  end
  while #queue >= self.MAX_QUEUED do
    -- The oldest submitted entry of the lowest rank goes; the new entry itself
    -- goes when everything queued matters more. Queue order is never changed.
    local victim, rank = 1, DropRank(queue[1])
    local index = 2
    while index <= #queue do
      local candidate = DropRank(queue[index])
      if candidate < rank or (candidate == rank and queue[index].submitted < queue[victim].submitted) then
        victim, rank = index, candidate
      end
      index = index + 1
    end
    self.dropped = self.dropped + 1
    if DropRank(entry) < rank then
      Finish(entry, false, "dropped: send queue full", true)
      return false, "dropped: send queue full"
    end
    local old = table.remove(queue, victim)
    Finish(old, false, "dropped: send queue full", true)
  end
  entry.queuedAt = now
  self.submitted = self.submitted + 1
  entry.submitted = self.submitted
  if entry.live then
    -- Presence and state lines carry age 0 when built (risk B10, decision
    -- 0095): after the last live entry, ahead of the others, order kept.
    local at = 1
    for index = 1, #queue do
      if queue[index].live then at = index + 1 end
    end
    table.insert(queue, at, entry)
  else
    queue[#queue + 1] = entry
  end
  self.delayed = self.delayed + 1
  if frame then frame:SetScript("OnUpdate", OnUpdate) end
  return true, nil, true
end

-- Drops the queued entries whose text argument stale(text) names (a line of
-- an ended campaign, decision 0103 § 4b); each reports a skipped send.
function SendQueue:Purge(stale)
  local queue, dropped, index = self.queue, 0, 1
  while index <= #queue do
    local entry = queue[index]
    local hit = false
    local args = { entry.a1, entry.a2, entry.a3, entry.a4 }
    for i = 1, 4 do
      if type(args[i]) == "string" and stale(args[i]) then hit = true end
    end
    if hit then
      table.remove(queue, index)
      dropped = dropped + 1
      Finish(entry, false, "dropped: campaign over", true)
    else
      index = index + 1
    end
  end
  self.dropped = self.dropped + dropped
  return dropped
end

function SendQueue:Summary()
  return "send gate gap=" .. self.MIN_GAP .. "s flood=" .. self.floodChain .. "/" .. self.FLOOD_BURST
    .. " (pause " .. self.FLOOD_GAP .. "s) queued=" .. #self.queue .. "/" .. self.MAX_QUEUED
    .. " sent=" .. self.sent .. " delayed=" .. self.delayed .. " superseded=" .. self.coalesced
    .. " dropped=" .. self.dropped .. " maxWait=" .. string.format("%.2f", self.maxWait) .. "s"
end

if CreateFrame then
  frame = CreateFrame("Frame", "WarfrontSendQueueFrame", UIParent)
  frame:SetScript("OnUpdate", nil)
end
