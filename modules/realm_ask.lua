local WF = Warfront

-- Ruleset question for unknown realms (decision 0147).
--
-- Every Warfront line names its sender's ruleset in the campaign header field
-- (decision 0139), and Players remembers it per GUID server. An idle member
-- sends nothing, so a client whose roster lists realms no source labels asks
-- once, and one member per listed realm answers:
--   * RQ, body "<server>,<server>,..." (decimal GUID servers, at most 12): sent
--     20-40 s after the channel lane is confirmed, while the roster is fresh,
--     only for servers not yet asked this session; at most one per 5 minutes.
--   * RA, body "<server>" (the answerer's own GUID server): a member whose
--     server is listed waits a random delay and answers once, unless a line
--     from another member of its server arrives first; at most one per minute.
--     The window is 3 s, plus 1 s per listed member of its own server (at most
--     15 s), so a large realm still draws about one or two answers. The header
--     field is the answer; the body only lets others of that realm stay quiet.
-- Display only: nothing here enters shared state, admission or gameplay, and
-- the label comes from the sender's roster GUID, never from the body (R1).
local Ask = { asked = 0, answered = 0, questions = 0, answers = 0, cancelled = 0, rejected = 0 }
WF.RealmAsk = Ask

local K = {
  ASK_MIN = 20, ASK_MAX = 40, ASK_GAP = 300, ROSTER_FRESH = 60, MAX_SERVERS = 12,
  ANSWER_MIN_WINDOW = 3, ANSWER_MAX_WINDOW = 15, ANSWER_GAP = 60, MAX_ASKED = 256, TICK = 1,
}
Ask.K = K

local nextTickAt = 0
local askAt, lastAskAt, lastAnswerAt = nil, nil, nil
local pending = nil -- answer due time
local asked, askedCount = {}, 0 -- servers already asked this session

local function Now()
  return WF.Now and WF.Now() or (GetTime and GetTime()) or 0
end

-- Strict server list: decimal, at most 10 digits each, `max` servers, no repeat.
function Ask.ParseServers(body, max)
  if type(body) ~= "string" or #body > 200 or not string.find(body, "^%d+[%d,]*$") then return nil end
  local list, seen = {}, {}
  for part in string.gmatch(body .. ",", "([^,]*),") do
    if not string.find(part, "^%d+$") or #part > 10 or seen[part] then return nil end
    seen[part] = true
    list[#list + 1] = part
    if #list > max then return nil end
  end
  return #list > 0 and list or nil
end

local function OwnServer()
  local players = WF.Players
  return players and type(players.OwnServer) == "function" and players:OwnServer() or nil
end

-- The answer window: wider when more listed members share our server.
local function AnswerWindow(own)
  local players, count = WF.Players, 0
  local info = players and type(players.info) == "table" and players.info or {}
  for _, entry in pairs(info) do
    if type(entry) == "table" and entry.server == own then count = count + 1 end
  end
  return math.min(K.ANSWER_MAX_WINDOW, math.max(K.ANSWER_MIN_WINDOW, 1 + count))
end

-- A line from `identity` was heard: a pending answer is cancelled when that
-- sender's roster GUID names our own server (it already labelled our realm).
function Ask:Heard(identity)
  if not pending then return end
  local players, own = WF.Players, OwnServer()
  if not players or not own or type(players.ServerOf) ~= "function" then return end
  local names = WF.Names
  local chatName = names and names.Split and names.Split(identity) or identity
  if players:ServerOf(chatName) == own then
    pending = nil
    self.cancelled = self.cancelled + 1
  end
end

-- An RQ or RA line, already deduplicated, quota-checked and admitted.
function Ask:OnLine(id, body, identity, now)
  now = now or Now()
  if id == "RQ" then
    local list = Ask.ParseServers(body, K.MAX_SERVERS)
    if not list then
      self.rejected = self.rejected + 1
      return false
    end
    self.questions = self.questions + 1
    local own = OwnServer()
    if not own or pending or (lastAnswerAt and now - lastAnswerAt < K.ANSWER_GAP) then return true end
    for i = 1, #list do
      if list[i] == own then
        pending = now + math.random() * AnswerWindow(own)
        break
      end
    end
    return true
  elseif id == "RA" then
    local list = Ask.ParseServers(body, 1)
    if not list then
      self.rejected = self.rejected + 1
      return false
    end
    self.answers = self.answers + 1
    if pending and list[1] == OwnServer() then
      pending = nil
      self.cancelled = self.cancelled + 1
    end
    return true
  end
  return false
end

local function AskQuestion(now)
  local players, transport = WF.Players, WF.Transport
  if not players or type(players.UnknownServers) ~= "function" then return end
  if not transport or type(transport.SendRealmAsk) ~= "function" then return end
  if not players.readAt or now - players.readAt > K.ROSTER_FRESH then return end
  local unknown = players:UnknownServers(K.MAX_ASKED)
  local list = {}
  for i = 1, #unknown do
    if not asked[unknown[i]] and #list < K.MAX_SERVERS then list[#list + 1] = unknown[i] end
  end
  if #list == 0 then return end
  if not transport:SendRealmAsk("RQ", table.concat(list, ",")) then return end
  lastAskAt = now
  Ask.asked = Ask.asked + 1
  for i = 1, #list do
    if askedCount >= K.MAX_ASKED then asked, askedCount = {}, 0 end
    asked[list[i]] = true
    askedCount = askedCount + 1
  end
end

function Ask:Tick(now)
  -- A due answer leaves on the first frame past its time, not on the 1 s tick,
  -- so members of one realm do not answer together.
  if now < nextTickAt and not (pending and now >= pending) then return end
  local transport = WF.Transport
  if not transport or not transport.channelConfirmed then return end
  if pending and now >= pending then
    pending = nil
    local own = OwnServer()
    if own and type(transport.SendRealmAsk) == "function" and transport:SendRealmAsk("RA", own) then
      lastAnswerAt = now
      self.answered = self.answered + 1
    end
  end
  if now < nextTickAt then return end
  nextTickAt = now + K.TICK
  if not askAt then askAt = now + K.ASK_MIN + math.random(0, K.ASK_MAX - K.ASK_MIN) end
  if now >= askAt and (not lastAskAt or now - lastAskAt >= K.ASK_GAP) then AskQuestion(now) end
end

function Ask:Summary()
  return "realm ask asked=" .. self.asked .. " answered=" .. self.answered .. " questions=" .. self.questions
    .. " answers=" .. self.answers .. " cancelled=" .. self.cancelled .. " rejected=" .. self.rejected
end

-- Wiring ------------------------------------------------------------------------------

if CreateFrame then
  local frame = CreateFrame("Frame", "WarfrontRealmAskFrame", UIParent)
  frame:SetScript("OnUpdate", function()
    local ok, err = pcall(Ask.Tick, Ask, Now())
    if not ok and WF.RecordError then WF.RecordError("realm ask", err) end
  end)
end
