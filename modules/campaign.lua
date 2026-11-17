Warfront = Warfront or {}

local WF = Warfront

-- Campaigns (decisions 0102 and 0103).
--   * Identity: number N and start server time S. The first start ships in
--     data/fronts.lua (firstStart); before it, campaign 0 and no front.
--   * A campaign ends at the first of a confirmed capital fall or 14 days
--     after its start; the next one starts at once (S(N+1) = S(N) + d). A time
--     end needs no message: every client computes it alone.
--   * A capital fall is the end record E = (N, S, d, reason, winner, capital,
--     generation). CE carries it from the clients inside the capital at the
--     capture; it is accepted only from 5 distinct identities (relayed copies
--     per origin through 2 bridges at least, chain copies never), when not
--     contradicted by what this client saw and plausible (0103 § 4b).
--   * CQ asks for the end records after a campaign, CL answers them.
--   * Every line carries <N>.<S>.<set> in its header (modules/p2ptest.lua):
--     a line of another campaign is not applied (Campaign:Admit), except V,
--     CE, CQ and CL, which carry their own campaign.
--   * A campaign change runs the 0102 § 4 reset once per (N, S).
local Campaign = {
  votes = {}, voteCount = 0,
  repeats = {},
  confirmed = {},
  received = 0, rejected = 0, skew = 0, contradicted = 0, implausible = 0, accepted = 0,
  switched = 0, forks = 0, answered = 0, queried = 0,
}
WF.Campaign = Campaign

local LENGTH = 1209600
local CAPITAL_WINDOW = 86400
local CAPITAL_MIN = 1800
local GRACE = 300
local QUORUM = 5
local BRIDGES = 2
local REPEAT_AFTER = 10
local QUERY_GAP = 60
local QUERY_TARGETS = 2
local LOGIN_QUERY_DELAY = 20
local ANSWER_LINES = 8
local ANSWER_MIN, ANSWER_SPREAD = 1, 5
local ANSWER_GAP = 1
local SEEN_EVERY = 60
-- A session's first minutes give no contrary knowledge: the window may not be
-- learned yet.
local ONLINE_SETTLE = 300
-- Seen times closer than this belong to one online interval.
local ONLINE_JOIN = 180
local RETRY_EVERY = 5
local MAX_PAST = 32
local MAX_WINDOWS = 8
local MAX_ONLINE = 8
local MAX_VOTES = 32
local MAX_VOTERS = 64
local MAX_VIAS = 8
local MAX_HISTORY = 4
local MAX_STEPS = 2000
local MAX_NUMBER = 2147483647
local EXEMPT = { V = true, CE = true, CQ = true, CL = true, HI = true, D = true }
local CAMPAIGN_LINES = { CE = true, CQ = true, CL = true }
local WINNERS = { H = true, A = true }
local FACTION_NAMES = { H = "Horde", A = "Alliance" }
local BASE36 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
local NO_TAG = "0.0.-"

Campaign.LENGTH, Campaign.QUORUM, Campaign.NO_TAG = LENGTH, QUORUM, NO_TAG

-- Helpers ----------------------------------------------------------------------

local function Now()
  local now = WF.Now and WF.Now() or 0
  if type(now) ~= "number" then return 0 end
  return now
end

local function ServerTime()
  if type(GetServerTime) ~= "function" then return 0 end
  local ok, value = pcall(GetServerTime)
  if not ok or type(value) ~= "number" then return 0 end
  return math.floor(value)
end

local function Notify(text, sound)
  if WF.Alerts and WF.Alerts.Push then
    WF.Alerts:Push("campaigns", text, { title = "Campaign update", sound = sound })
  elseif WF.Print then
    WF.Print(text)
  end
end

local function Record(kind, fields)
  if WF.Record then WF.Record(kind, fields) end
end

local function Base36(value)
  value = math.floor(tonumber(value) or 0)
  if value <= 0 then return "0" end
  local output = ""
  while value > 0 do
    local digit = value - math.floor(value / 36) * 36
    output = string.sub(BASE36, digit + 1, digit + 1) .. output
    value = math.floor(value / 36)
  end
  return output
end
Campaign.Base36 = Base36

-- Strict base 36: canonical digits only (no leading zero), within maximum.
local function Number36(text, maximum)
  if type(text) ~= "string" or #text < 1 or #text > 7 or not string.find(text, "^[0-9A-Z]+$") then return nil end
  local value = tonumber(text, 36)
  if not value or value > (maximum or MAX_NUMBER) or Base36(value) ~= text then return nil end
  return value
end

local function Whole(value, minimum, maximum)
  return type(value) == "number" and value == math.floor(value) and value >= minimum and value <= maximum
end

local function Label(id)
  local area = WF.Map and WF.Map.areas and WF.Map.areas[id]
  return area and area.label or tostring(id)
end

-- The first campaign's start, shipped in data/fronts.lua, or nil: campaigns
-- are then not numbered at all.
function Campaign:First()
  local data = WF.FrontData
  local first = type(data) == "table" and data.firstStart
  if Whole(first, 1, MAX_NUMBER) then return first end
  return nil
end

-- Time ends only: the campaign running at server time `server` when every
-- campaign from (n, s) on ended after 14 days.
local function TimeChain(n, s, server)
  local steps = 0
  while server >= s + LENGTH and steps < MAX_STEPS do
    n, s, steps = n + 1, s + LENGTH, steps + 1
  end
  return n, s
end

-- Identity ---------------------------------------------------------------------

-- The running campaign: number and start, (0, first start) before it, nil
-- when no first start is shipped. Before the saved state is read, the time
-- ends alone.
function Campaign:Current()
  local first = self:First()
  if not first then return nil end
  if self.n then return self.n, self.s end
  local server = ServerTime()
  if server < first then return 0, first end
  return TimeChain(1, first, server)
end

-- Seconds before the running campaign's 14-day end, or nil.
function Campaign:Left()
  local n, s = self:Current()
  if not n or n < 1 then return nil end
  return s + LENGTH - ServerTime()
end

-- "3 days", "5 hours", "12 minutes": the largest whole unit, at least 1 minute.
local function Span(seconds)
  seconds = math.max(0, math.floor(seconds))
  local days, hours, minutes = math.floor(seconds / 86400), math.floor(seconds / 3600), math.floor(seconds / 60)
  if days >= 2 then return days .. " days" end
  if hours >= 2 then return hours .. " hours" end
  if hours == 1 then return "1 hour" end
  if minutes >= 2 then return minutes .. " minutes" end
  return "1 minute"
end
Campaign.Span = Span

-- The campaign's remaining time for the windows (0103 § 3, 0102 § 8), or nil
-- when campaigns are not numbered. Never mentions numbers or clocks.
function Campaign:LeftText()
  local n, s = self:Current()
  if not n then return nil end
  if n < 1 then return "The first campaign begins in " .. Span(s - ServerTime()) end
  return "Campaign ends in " .. Span(s + LENGTH - ServerTime())
end

local function SetId(n, s)
  if not n or n < 1 or not WF.Front or type(WF.Front.SetOf) ~= "function" then return nil end
  return (WF.Front.SetOf(WF.FrontData, n, s))
end

-- The header field <N>.<S>.<set> (decision 0103 § 4b, 0102 § 5).
function Campaign:Tag()
  local n, s = self:Current()
  if not n then return NO_TAG end
  if self.tagN ~= n or self.tagS ~= s then
    self.tagN, self.tagS = n, s
    self.tag = Base36(n) .. "." .. Base36(n >= 1 and s or 0) .. "." .. (SetId(n, s) or "-")
  end
  return self.tag
end

function Campaign.ParseTag(text)
  if type(text) ~= "string" then return nil end
  local nText, sText, set = string.match(text, "^([0-9A-Z]+)%.([0-9A-Z]+)%.([A-Z0-9%-]+)$")
  local n, s = Number36(nText), Number36(sText)
  if not n or not s or #set > 3 then return nil end
  return n, s, set
end

-- Whether a received line of `id` with header field `tag` may be applied
-- (0102 § 5): a line of another campaign is counted, never applied nor
-- answered, never a reject. CE, CQ and CL carry their own campaign and pass;
-- such a line from another campaign is a reason to ask (CQ).
function Campaign:Admit(id, tag, now)
  if not self:First() then return true end
  local mine = self:Tag()
  if EXEMPT[id] then
    if tag ~= mine and CAMPAIGN_LINES[id] then self:TriggerQuery(now) end
    return true
  end
  if tag == mine then return true end
  self.skew = self.skew + 1
  local n, s = Campaign.ParseTag(tag)
  local myN, myS = self:Current()
  if n and myN and (n > myN or (n == myN and s ~= myS)) then self:TriggerQuery(now) end
  return false
end

-- A line built under another campaign than the running one (send queues are
-- purged of them at a campaign change, 0103 § 4b).
function Campaign:StaleLine(text)
  if type(text) ~= "string" or string.sub(text, 1, 2) ~= "WF" then return false end
  local p2p = WF.P2PTest
  if not p2p or type(p2p.ParseChannel) ~= "function" then return false end
  local parsed = p2p.ParseChannel(text)
  if not parsed or EXEMPT[parsed.id] then return false end
  return parsed.campaign ~= self:Tag()
end

-- Cloud owners and garrisons of an import. Schema 10 names their campaign
-- (decision 0125): read only in that very campaign. Older schemas carry none:
-- read only in the first campaign, and only from an import made after its start.
function Campaign:CloudAllowed(data)
  local n, s = self:Current()
  local tagged = type(data) == "table" and data.campaign
  if type(tagged) == "table" then return n ~= nil and tagged.n == n and tagged.s == s end
  if n == nil then return true end
  if n ~= 1 then return false end
  local generated = type(data) == "table" and data.generatedAt
  return type(generated) ~= "number" or generated >= s
end

-- Storage ----------------------------------------------------------------------

-- In the captures bucket of the scope (Capture:Bucket), outside the level
-- sections: a campaign is the world's, not a wire level's.
local function Store()
  local bucket = WF.Capture and WF.Capture:Bucket()
  if not bucket then return nil, nil end
  if type(bucket.campaign) ~= "table" then bucket.campaign = {} end
  return bucket.campaign, bucket
end

local function ValidEnd(e)
  return type(e) == "table" and Whole(e.n, 1, MAX_NUMBER) and Whole(e.s, 1, MAX_NUMBER)
    and Whole(e.d, 1, LENGTH) and (e.r == "T" or e.r == "C")
    and (e.r == "T" and e.d == LENGTH or e.r == "C" and e.d < LENGTH and WINNERS[e.w] ~= nil
      and type(e.c) == "string" and #e.c <= 16 and Whole(e.g, 1, 999999999))
end

-- Keeps the valid, consecutive ended campaigns, oldest first, bounded.
local function CleanPast(list)
  local clean = {}
  if type(list) ~= "table" then return clean end
  for index = 1, #list do
    local e = list[index]
    if ValidEnd(e) then
      local previous = clean[#clean]
      if not previous or (e.n == previous.n + 1 and e.s == previous.s + previous.d) then
        clean[#clean + 1] = { n = e.n, s = e.s, d = e.d, r = e.r, w = e.w, c = e.c, g = e.g }
      else
        clean = { { n = e.n, s = e.s, d = e.d, r = e.r, w = e.w, c = e.c, g = e.g } }
      end
    end
  end
  while #clean > MAX_PAST do table.remove(clean, 1) end
  return clean
end

local function CleanList(list, maximum, valid)
  local clean = {}
  if type(list) ~= "table" then return clean end
  for index = 1, #list do
    if valid(list[index]) then clean[#clean + 1] = list[index] end
  end
  while #clean > maximum do table.remove(clean, 1) end
  return clean
end

local function ValidWindow(w)
  return type(w) == "table" and Whole(w.n, 1, MAX_NUMBER) and Whole(w.s, 1, MAX_NUMBER)
    and type(w.c) == "string" and WINNERS[w.w] ~= nil and Whole(w.start, 1, MAX_NUMBER)
end

local function ValidOnline(o)
  return type(o) == "table" and Whole(o.a, 1, MAX_NUMBER) and Whole(o.b, o.a, MAX_NUMBER)
end

-- Reads the saved campaign once the scope is known. A save from before
-- campaigns adopts the campaign the time ends give, without a reset.
function Campaign:Load(server, now)
  local store, bucket = Store()
  if not store then return false end
  local first = self:First()
  self.loaded = true
  local n, s = store.n, store.s
  if not (Whole(n, 0, MAX_NUMBER) and Whole(s, 1, MAX_NUMBER) and s >= first and (n >= 1 or s == first)) then
    if server < first then n, s = 0, first else n, s = TimeChain(1, first, server) end
    Record("CAMPAIGN_ADOPTED", { n = n, s = s })
  end
  store.n, store.s = n, s
  store.past = CleanPast(store.past)
  store.windows = CleanList(store.windows, MAX_WINDOWS, ValidWindow)
  store.online = CleanList(store.online, MAX_ONLINE, ValidOnline)
  self.store, self.bucket = store, bucket
  self.n, self.s = n, s
  if n >= 1 then bucket.campaignId = n end
  -- The routes built before the save was read may belong to another set.
  local front = WF.Front
  if front and front.built and front.campaignId ~= SetId(n, s) then front:Rebuild() end
  self.queryAt = now + LOGIN_QUERY_DELAY
  return true
end

local function Save(self)
  if not self.store then return end
  self.store.n, self.store.s = self.n, self.s
end

-- Online intervals, for the contradiction check (0103 § 4b: `seen`).
local function NoteOnline(self, server)
  local online = self.store.online
  local last = online[#online]
  if last and server >= last.b and server - last.b <= ONLINE_JOIN then
    last.b = server
  else
    online[#online + 1] = { a = server, b = server }
    while #online > MAX_ONLINE do table.remove(online, 1) end
  end
  self.store.seen = server
end

-- Capital windows (modules/front.lua) -----------------------------------------

-- A capital siege window this client knows, kept by server start time for the
-- plausibility and contradiction checks after it closed.
function Campaign:NoteCapitalWindow(capital, side, startLocal, now)
  if not self.store or not self.n or self.n < 1 or not WINNERS[side] then return end
  local server = ServerTime()
  if server <= 0 then return end
  local start = math.floor(server - ((now or Now()) - startLocal) + 0.5)
  local windows = self.store.windows
  for index = 1, #windows do
    local w = windows[index]
    if w.n == self.n and w.s == self.s and w.c == capital and w.w == side then
      w.start = start
      return
    end
  end
  windows[#windows + 1] = { n = self.n, s = self.s, c = capital, w = side, start = start }
  while #windows > MAX_WINDOWS do table.remove(windows, 1) end
end

local function KnownWindows(self, rec)
  local list = {}
  for index = 1, #self.store.windows do
    local w = self.store.windows[index]
    if w.n == rec.n and w.s == rec.s and w.c == rec.c and w.w == rec.w then list[#list + 1] = w end
  end
  return list
end

-- Records -----------------------------------------------------------------------

local function Key(rec)
  return rec.n .. "," .. rec.s .. "," .. rec.d .. "," .. rec.r .. "," .. (rec.w or "-") .. ","
    .. (rec.c or "-") .. "," .. (rec.g or 0)
end

-- CE and CL: <N>,<S>,<d>,<reason>,<winner>,<capital>,<generation>, numbers in
-- base 36; a time end (reason T) has winner H, A or - and capital - and 0.
local function Body(rec)
  return Base36(rec.n) .. "," .. Base36(rec.s) .. "," .. Base36(rec.d) .. "," .. rec.r .. ","
    .. (rec.w or "-") .. "," .. (rec.c or "-") .. "," .. Base36(rec.g or 0)
end
Campaign.Body = Body

function Campaign.Parse(parts, kind)
  if #parts ~= 7 then return nil, "bad " .. kind .. " field count" end
  local rec = {
    n = Number36(parts[1]), s = Number36(parts[2]), d = Number36(parts[3], LENGTH), r = parts[4],
    w = parts[5], c = parts[6], g = Number36(parts[7], 999999999),
  }
  if not rec.n or rec.n < 1 or not rec.s or rec.s < 1 or not rec.d or rec.d < 1 or not rec.g then
    return nil, "bad " .. kind .. " number"
  end
  if rec.r == "C" then
    if not WINNERS[rec.w] or rec.d >= LENGTH or rec.g < 1 or not string.find(rec.c, "^[%w_]+$") or #rec.c > 16 then
      return nil, "bad " .. kind .. " capital end"
    end
  elseif rec.r == "T" and kind == "CL" then
    if rec.d ~= LENGTH or rec.c ~= "-" or rec.g ~= 0 or not (WINNERS[rec.w] or rec.w == "-") then
      return nil, "bad CL time end"
    end
  else
    return nil, "bad " .. kind .. " reason"
  end
  return rec
end

-- Confirmations (0103 § 4b) -----------------------------------------------------

-- One vote per identity for an identical record. A relayed copy votes for its
-- origin, per bridge (via); a first-hand line for its chat sender (rule R1).
function Campaign:Vote(rec, voter, via, now)
  local key = Key(rec)
  local vote = self.votes[key]
  if not vote then
    if self.voteCount >= MAX_VOTES then
      local oldest, at
      for k, v in pairs(self.votes) do
        if not at or v.at < at then oldest, at = k, v.at end
      end
      self.votes[oldest] = nil
      self.voteCount = self.voteCount - 1
    end
    vote = { rec = rec, voters = {}, voterCount = 0, origins = {}, originCount = 0, at = now, first = now }
    self.votes[key] = vote
    self.voteCount = self.voteCount + 1
  end
  vote.at = now
  if via then
    local vias = vote.origins[voter]
    if not vias then
      if vote.originCount >= MAX_VOTERS then return vote end
      vias = { count = 0 }
      vote.origins[voter] = vias
      vote.originCount = vote.originCount + 1
    end
    if not vias[via] and vias.count < MAX_VIAS then
      vias[via] = true
      vias.count = vias.count + 1
    end
  elseif not vote.voters[voter] and vote.voterCount < MAX_VOTERS then
    vote.voters[voter] = true
    vote.voterCount = vote.voterCount + 1
  end
  return vote
end

-- Distinct identities: first-hand senders, plus relayed origins that came
-- through at least two distinct bridges (one dishonest bridge never completes
-- a quorum).
function Campaign.Count(vote)
  local count = vote.voterCount
  for origin, vias in pairs(vote.origins) do
    if not vote.voters[origin] and vias.count >= BRIDGES then count = count + 1 end
  end
  return count
end

local function PastEntry(self, n)
  local past = self.store and self.store.past or {}
  for index = #past, 1, -1 do
    if past[index].n == n then return past[index], index end
  end
  return nil
end

-- Contradicted when this client already accepted another capital end for that
-- campaign, or was online at the end time, settled, and knew no running siege
-- window of that capital for that winner then.
function Campaign:Contradicted(rec)
  local done = PastEntry(self, rec.n)
  if done and done.s == rec.s and done.r == "C" and Key(done) ~= Key(rec) then return true end
  local at = rec.s + rec.d
  local windows = KnownWindows(self, rec)
  for index = 1, #self.store.online do
    local o = self.store.online[index]
    if o.a + ONLINE_SETTLE <= at and at <= o.b then
      local known = false
      for w = 1, #windows do
        if windows[w].start <= at and at <= windows[w].start + CAPITAL_WINDOW + GRACE then known = true end
      end
      if not known then return true end
    end
  end
  return false
end

-- Below 14 days, already past, on a capital whose route advances with that
-- winner, and inside a known window at least 30 minutes after its start.
function Campaign:Plausible(rec, server)
  if rec.d < 1 or rec.d >= LENGTH or rec.s + rec.d > server then return false end
  local front = WF.Front
  local node = front and front.byCapital and front.byCapital[rec.c]
  if not node or node.route.advancing ~= rec.w then return false end
  local windows = KnownWindows(self, rec)
  if #windows == 0 then return true end
  local at = rec.s + rec.d
  for index = 1, #windows do
    local w = windows[index]
    if at >= w.start + CAPITAL_MIN and at <= w.start + CAPITAL_WINDOW + GRACE then return true end
  end
  return false
end

-- Accepts a capital end with its quorum: for the running campaign it ends it;
-- for an earlier one it replaces a time end (fork rule); a later one waits.
function Campaign:TryAccept(rec, now)
  local vote = self.votes[Key(rec)]
  if not vote or vote.done or Campaign.Count(vote) < QUORUM then return false end
  local server = ServerTime()
  if rec.n > self.n then return false end
  if self:Contradicted(rec) then
    if not vote.contradicted then self.contradicted = self.contradicted + 1 end
    vote.contradicted = true
    return false
  end
  if not self:Plausible(rec, server) then
    if not vote.implausible then self.implausible = self.implausible + 1 end
    vote.implausible = true
    return false
  end
  if rec.n == self.n then
    if rec.s ~= self.s then return false end
    vote.done = true
    self.accepted = self.accepted + 1
    self:Switch(rec, now, true)
    self:Advance(server, now)
    return true
  end
  -- An earlier campaign: only a time end is replaced (a capital end beats it).
  local entry, index = PastEntry(self, rec.n)
  if not entry or entry.s ~= rec.s or entry.r ~= "T" then return false end
  vote.done = true
  self.forks = self.forks + 1
  local past = self.store.past
  while #past >= index do table.remove(past) end
  self.n, self.s = rec.n, rec.s
  Record("CAMPAIGN_FORK", { n = rec.n, d = rec.d })
  self:Switch(rec, now, true)
  self:Advance(server, now)
  return true
end

-- Quorums reached earlier but not plausible yet (an end time a few seconds
-- ahead of this clock) or waiting for this campaign.
local function RetryVotes(self, now)
  for _, vote in pairs(self.votes) do
    if not vote.done and not vote.contradicted and vote.rec.n <= self.n then
      if self:TryAccept(vote.rec, now) then return end
    end
  end
end

-- Campaign change -------------------------------------------------------------------

local function Held(side)
  local front, capture = WF.Front, WF.Capture
  local count = 0
  if not front or not capture or not front.routes then return count end
  for r = 1, #front.routes do
    local nodes = front.routes[r].nodes
    for n = 1, #nodes do
      if capture:GetOwner(nodes[n].id) == side then count = count + 1 end
    end
  end
  return count
end

-- Purges lines built under the old campaign from the send gate and the guild
-- outbox; CE, CQ and CL stay (they carry their own campaign).
local function Purge(self)
  local stale = function(text) return self:StaleLine(text) end
  if WF.SendQueue and type(WF.SendQueue.Purge) == "function" then WF.SendQueue:Purge(stale) end
  if WF.Transport and type(WF.Transport.Purge) == "function" then WF.Transport:Purge(stale) end
end

-- The 0102 § 4 reset: owners, bars, windows, garrisons, War Chests, scouts and
-- unresolved attacks go; wallets, reserves and stocks stay; pending pledges
-- and armies on the march come back to the reserve.
function Campaign:Reset(now)
  -- Prepare/refund armies before any destructive campaign cleanup. An exception
  -- leaves their orders and the old campaign available for the next retry.
  local back = 0
  if WF.Attack and WF.Attack.ResetCampaign then back = WF.Attack:ResetCampaign() or 0 end
  local capture = WF.Capture
  local _, bucket = Store()
  if bucket then
    bucket.pois, bucket.progress, bucket.front = {}, {}, {}
  end
  if capture then
    -- Generations restart: rule R7 holds within one campaign (0103 § 3).
    capture.owners, capture.captured, capture.hints, capture.alerts = {}, {}, {}, {}
    capture.states, capture.cloud = {}, {}
  end
  if WF.Garrison and WF.Garrison.ResetCampaign then WF.Garrison:ResetCampaign() end
  if WF.Scout and WF.Scout.ResetCampaign then WF.Scout:ResetCampaign() end
  self.repeats, self.confirmed, self.witness, self.answer = {}, {}, nil, nil
  return back
end

local function EndText(rec)
  if rec.r == "C" then
    return Label(rec.c) .. " has fallen: the " .. FACTION_NAMES[rec.w] .. " wins the campaign."
  end
  if WINNERS[rec.w] then return "The campaign is over: the " .. FACTION_NAMES[rec.w] .. " wins." end
  return "The campaign is over: no faction wins."
end

-- Ends the running campaign with rec (its d, reason and winner), records it,
-- resets and starts the next one at S + d. Idempotent per (N, S): the saved
-- number moves with the reset.
function Campaign:Switch(rec, now, announce)
  local endedN, endedS = self.n, self.s
  local heldH, heldA = Held("H"), Held("A")
  local here = WF.Capture and WF.Capture.here
  local back = self:Reset(now)
  if endedN >= 1 then
    local past = self.store.past
    past[#past + 1] = { n = endedN, s = endedS, d = rec.d, r = rec.r, w = rec.w, c = rec.c, g = rec.g }
    while #past > MAX_PAST do table.remove(past, 1) end
    local history = self.bucket.history
    if type(history) ~= "table" then
      history = {}
      self.bucket.history = history
    end
    history[#history + 1] = {
      n = endedN, set = SetId(endedN, endedS), rev = WF.Front and WF.Front.campaignRev, s = endedS,
      e = endedS + rec.d, reason = rec.r == "C" and "capital" or "time", winner = rec.w or "-",
      held = { H = heldH, A = heldA },
    }
    while #history > MAX_HISTORY do table.remove(history, 1) end
  end
  self.n, self.s = endedN + 1, endedS + (endedN >= 1 and rec.d or 0)
  Save(self)
  self.bucket.campaignId = self.n
  self.switched = self.switched + 1
  for key, vote in pairs(self.votes) do
    if vote.rec.n < self.n - 1 then
      self.votes[key] = nil
      self.voteCount = self.voteCount - 1
    end
  end
  if WF.Front then WF.Front:Rebuild() end
  Purge(self)
  Record("CAMPAIGN_SWITCH", { n = self.n, s = self.s, reason = rec.r })
  -- Standing in a POI: enter it again under the new campaign's owners.
  if here and WF.Capture then
    WF.Capture.here = nil
    if WF.Capture:Outpost(here.id) then WF.Capture:Enter(here.id, now) end
  end
  if announce then
    if endedN >= 1 then Notify(EndText(rec), true) end
    local name = WF.Front and WF.Front.campaignName
    Notify("A new campaign begins" .. (name and (": " .. name) or "") .. ".")
    if back > 0 then Notify("Your armies on the march came back to your reserve.") end
    local overflow = WF.Army and WF.Army.Overflow and WF.Army:Overflow()
    if overflow then Notify("Some units wait to join your reserve until there is room for them.") end
  end
end

-- Time ends, and capital ends already confirmed for the campaign reached.
function Campaign:Advance(server, now)
  local steps, last = 0, nil
  while steps < MAX_STEPS do
    steps = steps + 1
    if self.n == 0 then
      if server < self.s then break end
      last = { d = 0, r = "T" }
      self:Switch(last, now, false)
    elseif server >= self.s + LENGTH then
      local h, a = Held("H"), Held("A")
      last = { n = self.n, s = self.s, d = LENGTH, r = "T", w = h > a and "H" or a > h and "A" or "-", c = "-", g = 0 }
      self:Switch(last, now, false)
    else
      break
    end
  end
  if last then
    -- One notice for a client catching up several campaigns at once.
    if last.d > 0 and server < self.s + 60 then Notify(EndText(last), true) end
    local name = WF.Front and WF.Front.campaignName
    Notify("A new campaign begins" .. (name and (": " .. name) or "") .. ".")
    RetryVotes(self, now)
  end
end

-- Capital capture (modules/capture.lua, HandleEvent) ----------------------------

local function SendEnd(rec)
  -- An event: no replacement key, sent with priority (rule R12).
  return WF.Capture and WF.Capture:Send("CE", Body(rec), nil, true)
end

-- Our own confirmation of rec: one vote, two sends 10 s apart (0103 § 4b).
function Campaign:Confirm(rec, now)
  local key = rec.c .. ":" .. rec.g
  if self.confirmed[key] then return end
  self.confirmed[key] = true
  local me = WF.Capture and WF.Capture:Me()
  if me then self:Vote(rec, me, nil, now) end
  SendEnd(rec)
  self.repeats[#self.repeats + 1] = { rec = rec, at = now + REPEAT_AFTER }
  self:TryAccept(rec, now)
end

-- The capture of a route's capital by its advancing faction. Its authority
-- writes the record (d from its server time); every client that was inside
-- confirms the authority's record once heard.
function Campaign:OnCapitalCaptured(capital, side, generation, authority, inside, now)
  if not self.loaded or not self.n or self.n < 1 or type(generation) ~= "number" then return end
  local front = WF.Front
  local node = front and front.byCapital and front.byCapital[capital]
  if not node or node.route.advancing ~= side then return end
  local me = WF.Capture and WF.Capture:Me()
  now = now or Now()
  if authority and authority == me then
    local d = ServerTime() - self.s
    if d < 1 or d >= LENGTH then return end
    self:Confirm({ n = self.n, s = self.s, d = d, r = "C", w = side, c = capital, g = generation }, now)
    return
  end
  if not inside or not authority then return end
  self.witness = { c = capital, g = generation, authority = authority, n = self.n, s = self.s, at = now }
  -- The authority's record may have come first.
  for _, vote in pairs(self.votes) do
    local rec = vote.rec
    if rec.c == capital and rec.g == generation and rec.n == self.n and rec.s == self.s
        and (vote.voters[authority] or vote.origins[authority]) then
      self:Confirm(rec, now)
      return
    end
  end
end

-- Both copies of the authority's record lost: after WITNESS_WAIT s a witness
-- confirms the record of this capture that at least two others confirmed
-- (they copied the authority's d); the most confirmed, then the earliest.
local WITNESS_WAIT, WITNESS_PEERS = 15, 2

local function WitnessFallback(self, now)
  local witness = self.witness
  if not witness or now - witness.at < WITNESS_WAIT then return end
  if self.confirmed[witness.c .. ":" .. witness.g] then
    self.witness = nil
    return
  end
  local best, bestCount
  for _, vote in pairs(self.votes) do
    local rec = vote.rec
    local count = Campaign.Count(vote)
    if rec.c == witness.c and rec.g == witness.g and rec.n == witness.n and rec.s == witness.s
        and count >= WITNESS_PEERS
        and (not best or count > bestCount or (count == bestCount and rec.d < best.d)) then
      best, bestCount = rec, count
    end
  end
  if best then self:Confirm(best, now) end
end

-- A confirmation stuck below its quorum for a while: ask the others, who may
-- have accepted it already (CQ at most once a minute).
local STUCK_AFTER = 30

local function AskIfStuck(self, now)
  for _, vote in pairs(self.votes) do
    if not vote.done and not vote.contradicted and vote.rec.n == self.n and vote.rec.s == self.s
        and now - vote.first >= STUCK_AFTER then
      self:TriggerQuery(now)
      return
    end
  end
end

-- Requests and answers ----------------------------------------------------------

-- At most one request a minute: to the group, and by whisper to two guild
-- peers or contacts.
function Campaign:TriggerQuery(now)
  now = now or Now()
  if self.queryAt or (self.queriedAt and now - self.queriedAt < QUERY_GAP) then return end
  self.queryAt = now
end

-- Asks from the oldest of our recent campaigns that ended by time: a time end
-- computed alone may hide a capital end, and the campaigns after it then
-- started elsewhere for the others, who would not know them.
local function SendQuery(self, now)
  self.queriedAt = now
  local n, s = self.n, self.s
  if not n or n < 1 then return end
  local past = self.store.past
  for index = #past, math.max(1, #past - ANSWER_LINES + 1), -1 do
    if past[index].r == "T" then n, s = past[index].n, past[index].s end
  end
  local body = Base36(n) .. "," .. Base36(s)
  local capture, transport = WF.Capture, WF.Transport
  if not capture then return end
  capture:Send("CQ", body, "CQ")
  if transport and type(transport.PullTargets) == "function" then
    local targets = transport:PullTargets(QUERY_TARGETS, now)
    for index = 1, #targets do capture:SendTo(targets[index], "CQ", body) end
  end
  self.queried = self.queried + 1
end

-- Our accepted ends from campaign n (start s) on, at most ANSWER_LINES; only
-- when this client is later than the asker. A contradicted record is never
-- among them: only accepted ends are kept.
local function AnswerLines(self, n, s)
  local entry, index = PastEntry(self, n)
  if not entry or entry.s ~= s then return nil end
  local lines = {}
  local past = self.store.past
  for i = index, #past do
    if #lines >= ANSWER_LINES then break end
    lines[#lines + 1] = Body(past[i])
  end
  return lines
end

local function OnQuery(self, parts, sender, now)
  if #parts ~= 2 then return false, "bad CQ" end
  local n, s = Number36(parts[1]), Number36(parts[2])
  if not n or n < 1 or not s then return false, "bad CQ" end
  if n >= self.n then return true end
  local lines = AnswerLines(self, n, s)
  if not lines or #lines == 0 then return true end
  local capture = WF.Capture
  local asker = capture and capture.addressedFrom
  if asker then
    local transport = WF.Transport
    if transport and type(transport.MayAnswer) == "function" and transport:MayAnswer("CQ", asker, now) then
      self.addressed = { target = asker, lines = lines, at = now }
    end
    return true
  end
  if not self.answer then
    self.answer = { at = now + ANSWER_MIN + math.random() * ANSWER_SPREAD, lines = lines, first = lines[1],
      matches = {}, matchCount = 0 }
  end
  return true
end

-- Rule R14 as amended for CL: our pending answer stops after 5 matching
-- answers from distinct senders.
local function SeeAnswer(self, body, sender)
  local answer = self.answer
  if not answer or body ~= answer.first or answer.matches[sender] then return end
  answer.matches[sender] = true
  answer.matchCount = answer.matchCount + 1
  if answer.matchCount >= QUORUM then self.answer = nil end
end

-- Messages ----------------------------------------------------------------------

function Campaign:Reject(reason, sender)
  self.rejected = self.rejected + 1
  self.lastReject = reason
  if WF.Capture and WF.Capture.Reject then return WF.Capture:Reject(reason, sender) end
  return false
end

-- Routed by Capture:OnMessage after echo, identity, quota and admission;
-- Capture.relayVia and relayHop say whether a bridge or the chain carried it.
function Campaign:OnMessage(kind, parts, sender, now)
  self.received = self.received + 1
  if not self:First() or not self.loaded or not self.n then return true end
  if kind == "CQ" then
    local ok, reason = OnQuery(self, parts, sender, now)
    if not ok then return self:Reject(reason, sender) end
    return true
  end
  local rec, reason = Campaign.Parse(parts, kind)
  if not rec then return self:Reject(reason, sender) end
  local capture = WF.Capture
  local via = capture and capture.relayVia
  if kind == "CL" then
    if via then return self:Reject("relayed CL", sender) end
    SeeAnswer(self, table.concat(parts, ","), sender)
    if rec.r == "C" then
      self:Vote(rec, sender, nil, now)
      self:TryAccept(rec, now)
    end
    return true
  end
  -- CE: a chain copy only makes us ask; it never votes.
  if via and capture.relayHop == "W" then
    self:TriggerQuery(now)
    return true
  end
  -- The capture's authority may be of the other faction: its record then
  -- comes through a bridge, which is how this client saw the capture too.
  local witness = self.witness
  if witness and rec.c == witness.c and rec.g == witness.g and sender == witness.authority
      and rec.n == self.n and rec.s == self.s then
    self:Confirm(rec, now)
  end
  self:Vote(rec, sender, via, now)
  if rec.n ~= self.n or rec.s ~= self.s then self:TriggerQuery(now) end
  self:TryAccept(rec, now)
  return true
end

-- Driver ------------------------------------------------------------------------

function Campaign:Tick(now)
  if not self:First() then return end
  local server = ServerTime()
  if server <= 0 then return end
  if not self.loaded and not self:Load(server, now) then return end
  if not self.seenAt or now - self.seenAt >= SEEN_EVERY then
    self.seenAt = now
    NoteOnline(self, server)
  end
  self:Advance(server, now)
  if not self.retryAt or now >= self.retryAt then
    self.retryAt = now + RETRY_EVERY
    RetryVotes(self, now)
    WitnessFallback(self, now)
    AskIfStuck(self, now)
  end
  local index = 1
  while index <= #self.repeats do
    local item = self.repeats[index]
    if now >= item.at then
      table.remove(self.repeats, index)
      if item.rec.n == self.n and item.rec.s == self.s or item.rec.n == self.n - 1 then SendEnd(item.rec) end
    else
      index = index + 1
    end
  end
  if self.queryAt and now >= self.queryAt then
    self.queryAt = nil
    SendQuery(self, now)
  end
  local capture = WF.Capture
  if self.answer and now >= self.answer.at and capture then
    local line = table.remove(self.answer.lines, 1)
    if line then
      local parts = {}
      for part in string.gmatch(line, "[^,]+") do parts[#parts + 1] = part end
      capture:Send("CL", line, "CL," .. parts[1])
      self.answered = self.answered + 1
      self.answer.at = now + ANSWER_GAP
    end
    if not line or #self.answer.lines == 0 then self.answer = nil end
  end
  local addressed = self.addressed
  if addressed and now >= addressed.at and capture then
    local line = table.remove(addressed.lines, 1)
    if line then
      local parts = {}
      for part in string.gmatch(line, "[^,]+") do parts[#parts + 1] = part end
      capture:SendTo(addressed.target, "CL", line, "CL:" .. addressed.target .. ":" .. parts[1])
      self.answered = self.answered + 1
      addressed.at = now + ANSWER_GAP
    end
    if not line or #addressed.lines == 0 then self.addressed = nil end
  end
end

-- /wfd front (diagnostics, WarfrontDev addon).
function Campaign:PrintStatus()
  local print = WF.Print or print
  local first = self:First()
  if not first then
    print("campaign: not numbered (no first start)")
    return
  end
  local n, s = self:Current()
  local left = self:Left()
  print("campaign: " .. tostring(n) .. " start " .. tostring(s) .. " tag " .. self:Tag()
    .. (left and (" left " .. left) or "") .. (self.loaded and "" or " (not loaded)"))
  local votes = 0
  for _ in pairs(self.votes) do votes = votes + 1 end
  print("campaign: switched " .. self.switched .. " accepted " .. self.accepted .. " forks " .. self.forks
    .. " contradicted " .. self.contradicted .. " implausible " .. self.implausible .. " votes " .. votes
    .. " skew " .. self.skew .. " queried " .. self.queried .. " answered " .. self.answered
    .. " rejected " .. self.rejected .. (self.lastReject and (" last " .. self.lastReject) or ""))
  local past = self.store and self.store.past or {}
  for index = math.max(1, #past - 2), #past do
    local e = past[index]
    print("campaign " .. e.n .. ": " .. (e.r == "C" and ("capital " .. tostring(e.c) .. " by " .. tostring(e.w)) or "time")
      .. " after " .. e.d .. " s")
  end
end
