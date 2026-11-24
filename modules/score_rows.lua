local WF = Warfront

-- Scoreboard rows from other players (decision 0146).
--
-- Every client announces its own row of the running campaign (the counters of
-- its war record) so a player without the companion appears in the Players
-- boards of everyone who hears it. Display only: a row never enters capture,
-- owners or any other shared state, and never feeds a gameplay rule.
--   * One producer per row: the chat or Battle.net sender (R1); a row never
--     names its player and is never passed on to anyone else.
--   * Total order (R5, R8): a row replaces the held one only when its counter
--     total is larger, or equal with a greater text. Duplicates, loss and
--     reordering end on the same row.
--   * Claimed values: a player can inflate only their own row (accepted by
--     the user, 2026-11-24, while players are few; hardening comes later).
--   * Bounded (R9): MAX_ROWS rows per scope, the one heard longest ago leaves.
--   * Saved: Ruleset:Module("scoreRows") = { schema, campaign, rows =
--     { [identity] = { b = body, t = epoch heard } } }, read back like remote
--     input. Display cache only; losing it loses no player data.

local SR = { revision = 0, sent = 0, received = 0, rejected = 0, linkSent = {} }
WF.ScoreRows = SR

local K = {
  REFRESH = 900, CHANGE_GAP = 60, FIRST_MIN = 30, FIRST_MAX = 90, MAX_ROWS = 300,
  MAX_VALUE = 999999999, TICK = 5, SCHEMA = 1,
}
SR.K = K

-- Wire order of the counters: the scoreboard's STAT_KEYS without conf (only
-- the Worker can witness a capture).
local FIELDS = {
  "capO", "capS", "capC", "capW", "defO", "defS", "defC", "defW", "kills", "assists", "deaths",
  "gold", "wood", "atkF", "atkR", "atkM", "atkS", "garF", "garR", "garM",
}
SR.FIELDS = FIELDS
local FACTION = { A = "Alliance", H = "Horde" }
local FACTION_CODE = { Alliance = "A", Horde = "H" }

local nextTickAt, firstSendAt = 0, nil
local held, heldKey = nil, nil -- parsed rows of the stored campaign, and its saved table

local function Now()
  return WF.Now and WF.Now() or (GetTime and GetTime()) or 0
end

local function Wall()
  local value = WF.Epoch and WF.Epoch() or nil
  return type(value) == "number" and value > 0 and value or 0
end

local function Me()
  return WF.Capture and WF.Capture:Me() or nil
end

local function CampaignKey()
  local scoreboard = WF.Scoreboard
  return scoreboard and scoreboard.CampaignKey and scoreboard.CampaignKey() or nil
end

-- Wire ------------------------------------------------------------------------------

local function B36(value)
  if value <= 0 then return "0" end
  local digits, out = "0123456789abcdefghijklmnopqrstuvwxyz", ""
  while value > 0 do
    local d = value % 36
    out = string.sub(digits, d + 1, d + 1) .. out
    value = math.floor(value / 36)
  end
  return out
end

local function Count(value)
  if type(value) ~= "number" or value < 0 or value ~= math.floor(value) then return 0 end
  return value > K.MAX_VALUE and K.MAX_VALUE or value
end

-- "R,<A|H>,<class>,<race>,<20 base-36 counters>", or nil when the row is empty.
function SR.Body(stats, faction, classFile, raceFile)
  local code = FACTION_CODE[faction]
  if not code or type(stats) ~= "table" then return nil end
  if type(classFile) ~= "string" or not string.find(classFile, "^%u+$") or #classFile > 12 then classFile = "" end
  if type(raceFile) ~= "string" or not string.find(raceFile, "^%a+$") or #raceFile > 12 then raceFile = "" end
  local parts, total = { "R", code, classFile, raceFile }, 0
  for index = 1, #FIELDS do
    local value = Count(stats[FIELDS[index]])
    total = total + value
    parts[#parts + 1] = B36(value)
  end
  if total == 0 then return nil end
  return table.concat(parts, ",")
end

-- Strict parse: exact field count, known codes, bounded counters.
function SR.Parse(body)
  if type(body) ~= "string" or #body > 200 then return nil end
  local code, classFile, raceFile, rest = string.match(body, "^R,([AH]),(%u*),(%a*),([0-9a-z,]+)$")
  if not code or #classFile > 12 or #raceFile > 12 then return nil end
  local row, index, total = { faction = FACTION[code] }, 0, 0
  for text in string.gmatch(rest .. ",", "([^,]*),") do
    index = index + 1
    if index > #FIELDS or text == "" or #text > 6 then return nil end
    local value = tonumber(text, 36)
    if not value or value > K.MAX_VALUE then return nil end
    row[FIELDS[index]] = value
    total = total + value
  end
  if index ~= #FIELDS or total == 0 then return nil end
  row.class = classFile ~= "" and classFile or nil
  row.race = raceFile ~= "" and raceFile or nil
  row.total, row.body = total, body
  return row
end

-- Store ------------------------------------------------------------------------------

local function Root()
  local ruleset = WF.Ruleset
  local root = ruleset and ruleset.Module and ruleset:Module("scoreRows")
  if not root then return nil end
  if type(root.schema) == "number" and root.schema > K.SCHEMA then return nil end
  local key = CampaignKey()
  if not key then return nil end
  root.schema = K.SCHEMA
  -- A new campaign starts empty: the rows of the last one are dropped.
  if root.campaign ~= key or type(root.rows) ~= "table" then
    root.campaign, root.rows = key, {}
  end
  return root
end

local function Held()
  local root = Root()
  if not root then return nil end
  if held and heldKey == root.rows then return held, root end
  held, heldKey = {}, root.rows
  local me = Me()
  for identity, saved in pairs(root.rows) do
    local row = type(identity) == "string" and identity ~= me and type(saved) == "table" and SR.Parse(saved.b)
    if row then
      row.char, row.seen = identity, type(saved.t) == "number" and saved.t or 0
      held[identity] = row
    else
      root.rows[identity] = nil
    end
  end
  SR.revision = SR.revision + 1
  return held, root
end

local function Evict(rows, root)
  local count, oldest = 0, nil
  for identity, row in pairs(rows) do
    count = count + 1
    if not oldest or row.seen < rows[oldest].seen or (row.seen == rows[oldest].seen and identity < oldest) then
      oldest = identity
    end
  end
  if count >= K.MAX_ROWS and oldest then
    rows[oldest] = nil
    root.rows[oldest] = nil
  end
end

-- Receive ------------------------------------------------------------------------------

-- One row from its own player (identity = the event sender). True when taken
-- or already held.
function SR:OnLine(body, identity)
  self.received = self.received + 1
  local row = type(identity) == "string" and identity ~= "" and identity ~= Me() and SR.Parse(body)
  local rows, root
  if row then rows, root = Held() end
  if not rows then
    self.rejected = self.rejected + 1
    return false
  end
  local old = rows[identity]
  if old and (row.total < old.total or (row.total == old.total and row.body <= old.body)) then
    if row.body == old.body then
      old.seen = Wall()
      root.rows[identity] = { b = old.body, t = old.seen }
    end
    return true
  end
  if not old then Evict(rows, root) end
  row.char, row.seen = identity, Wall()
  rows[identity] = row
  root.rows[identity] = { b = row.body, t = row.seen }
  self.revision = self.revision + 1
  return true
end

-- Rows for the Players boards of the running campaign: { row... } with char,
-- faction, class, race and the counters, never our own.
function SR:Rows()
  local rows = Held()
  local out = {}
  if not rows then return out end
  for _, row in pairs(rows) do out[#out + 1] = row end
  return out
end

function SR:Count()
  local count = 0
  for _ in pairs(Held() or {}) do count = count + 1 end
  return count
end

-- Send ------------------------------------------------------------------------------

local function OwnBody()
  if not WF.WarRecord then return nil end
  local record, char = WF.WarRecord:Current()
  local scoreboard = WF.Scoreboard
  if not record or type(char) ~= "table" or not scoreboard then return nil end
  return SR.Body(scoreboard.StatsFromRecord(record), char.faction, char.class, char.race)
end

local function SendLinks(transport, body, now)
  local relay = WF.Relay
  if not relay or type(relay.BoardLinks) ~= "function" then return end
  local ok, ids = pcall(relay.BoardLinks, relay, now)
  if not ok or type(ids) ~= "table" then return end
  for i = 1, #ids do
    local id = ids[i]
    local last = SR.linkSent[id]
    if not last or last.body ~= body or now - last.at >= K.REFRESH then
      -- One link a tick, only when the lane is idle.
      if transport:SendBoard("L:" .. tostring(id), "SR", body) then
        SR.linkSent[id] = { body = body, at = now }
        SR.sent = SR.sent + 1
      end
      return
    end
  end
end

function SR:Tick(now)
  if now < nextTickAt then return end
  nextTickAt = now + K.TICK
  if not firstSendAt then
    firstSendAt = now + K.FIRST_MIN + math.random(0, K.FIRST_MAX - K.FIRST_MIN)
  end
  if now < firstSendAt then return end
  local transport = WF.Transport
  if not transport or type(transport.SendScoreRow) ~= "function" then return end
  local body = OwnBody()
  if not body then return end
  local changed = body ~= self.lastBody
  if (changed and now - (self.lastSent or -K.CHANGE_GAP) >= K.CHANGE_GAP) or now >= (self.nextSend or 0) then
    if transport:SendScoreRow(body) then self.sent = self.sent + 1 end
    self.lastBody, self.lastSent, self.nextSend, self.guildBody = body, now, now + K.REFRESH, body
  end
  if self.guildBody and transport:SendScoreRowGuild(self.guildBody) then self.guildBody = nil end
  if self.lastBody then SendLinks(transport, self.lastBody, now) end
end

function SR:Summary()
  return "score rows held=" .. self:Count() .. " sent=" .. self.sent .. " received=" .. self.received
    .. " rejected=" .. self.rejected
end

-- Wiring ------------------------------------------------------------------------------

if CreateFrame then
  local frame = CreateFrame("Frame", "WarfrontScoreRowsFrame", UIParent)
  frame:SetScript("OnUpdate", function()
    local ok, err = pcall(SR.Tick, SR, Now())
    if not ok and WF.RecordError then WF.RecordError("score rows", err) end
  end)
end
