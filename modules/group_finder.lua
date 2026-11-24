local WF = Warfront

-- Same-faction group finder (decision 0145).
--
-- A solo player or a group leader lists a group (L); every client of the
-- faction that hears it shows it in the Group Finder page until it closes (X)
-- or goes quiet. A player applies by whisper (A); the leader's client invites
-- at once for an auto-join listing that fits, otherwise the leader answers
-- with Invite or Decline (R). Nothing here touches capture, presence, owners
-- or any other shared state: a liar can only show a group nobody answers.
--   * One producer per listing: its leader, the chat sender (R1); revisions
--     only grow, equal or lower ones change nothing (R5, R8).
--   * Every table indexed by remote data is bounded (R9); our own listing and
--     applications are never evicted.
--   * Saved: WarfrontDB.settings.groupFinder (last form, open listing).

local GF = {
  listings = {}, closed = {}, applicants = {}, mine = {}, ignored = {},
  declined = {}, replied = {}, own = nil,
  sent = 0, received = 0, rejected = 0, invited = 0,
}
WF.GroupFinder = GF

local K = {
  REFRESH = 120, CHANGE_GAP = 10, TTL = 330, LIFE = 7200, APP_TTL = 600,
  MAX_LISTINGS = 100, MAX_CLOSED = 100, MAX_IGNORED = 64, MAX_APPLICANTS = 20,
  MAX_MINE = 5, TITLE = 30, NOTE = 60, MAX_LEVEL = 99, REPLY_GAP = 30, TICK = 1,
}
GF.K = K

-- Fixed codes, one per thing a group does with Warfront (2026-11-24, user);
-- their labels are translated by the page.
GF.ACTIVITIES = {
  { code = "A", label = "Active Front objective" }, { code = "C", label = "Capture an Outpost" },
  { code = "W", label = "Capture a War Camp" }, { code = "S", label = "Settlement siege" },
  { code = "K", label = "Capital siege" }, { code = "F", label = "Defend our places" },
  { code = "G", label = "Gathering" }, { code = "E", label = "Gathering on enemy ground" },
  { code = "P", label = "World PvP" }, { code = "O", label = "Other" },
}
GF.LANGUAGES = { "EN", "FR", "DE", "ES", "IT", "PT", "RU", "ZH" }
-- Shown in full, translated by the page (2026-11-24, user).
GF.LANGUAGE_NAMES = { EN = "English", FR = "French", DE = "German", ES = "Spanish", IT = "Italian",
  PT = "Portuguese", RU = "Russian", ZH = "Chinese" }
GF.SIZES = { 5, 10, 20, 40 }
GF.ROLES = { T = "Tank", H = "Healer", D = "Damage" }
local ACTIVITY, LANGUAGE, SIZE = {}, {}, {}
for _, item in ipairs(GF.ACTIVITIES) do ACTIVITY[item.code] = item.label end
for _, code in ipairs(GF.LANGUAGES) do LANGUAGE[code] = true end
for _, size in ipairs(GF.SIZES) do SIZE[size] = true end
-- Reply codes (R): invited, declined, full, closed, level.
local REPLIES = { I = true, N = true, F = true, C = true, V = true }

local nextTickAt, wasLeader = 0, false

-- Helpers ---------------------------------------------------------------------------

local function Now()
  local now = WF.Now and WF.Now() or 0
  return type(now) == "number" and now or 0
end

local function Wall()
  local value = WF.Epoch and WF.Epoch() or nil
  return type(value) == "number" and value > 0 and value or nil
end

local function Global(name)
  if WF.Compat and WF.Compat.Global then return WF.Compat.Global(name) end
  return _G and _G[name] or nil
end

local function IsSecret(value)
  local fn = Global("issecretvalue")
  if type(fn) ~= "function" then return false end
  local ok, secret = pcall(fn, value)
  return ok and secret and true or false
end

local function Call(name, ...)
  local fn = Global(name)
  if type(fn) ~= "function" then return false end
  return pcall(fn, ...)
end

local function Flag(name, unit)
  local ok, value = Call(name, unit)
  if not ok or IsSecret(value) then return nil end
  return value and true or false
end

local function Count(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

local function Settings()
  local storage = WF.Storage
  if not storage or type(storage.GetDB) ~= "function" or storage.readOnly then return nil end
  local db = storage:GetDB()
  return type(db) == "table" and type(db.settings) == "table" and db.settings or nil
end

local function Me()
  local capture = WF.Capture
  return capture and capture.Me and capture:Me() or nil
end

local function Say(text)
  local frame = Global("DEFAULT_CHAT_FRAME")
  if frame and frame.AddMessage then frame:AddMessage("|cfff5ae0aWarfront:|r " .. text) end
end

local function Sound()
  if WF.Preferences and not WF.Preferences:Get("soundEnabled") then return end
  local play, kits = Global("PlaySound"), Global("SOUNDKIT")
  local kit = type(kits) == "table" and kits.IG_PLAYER_INVITE or nil
  if type(play) == "function" and type(kit) == "number" then pcall(play, kit) end
end

local function Hex(digits)
  local out = {}
  for i = 1, digits do
    local v = math.random(0, 15)
    out[i] = string.sub("0123456789abcdef", v + 1, v + 1)
  end
  return table.concat(out)
end

-- Text: URL-safe base64 of UTF-8, no padding, canonical. -------------------------------

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
local DECODE = {}
for i = 1, 64 do DECODE[string.sub(B64, i, i)] = i - 1 end

local function Encode(text)
  local out = {}
  for i = 1, #text, 3 do
    local a, b, c = string.byte(text, i, i + 2)
    local n = a * 65536 + (b or 0) * 256 + (c or 0)
    local chars = 2 + (b and 1 or 0) + (c and 1 or 0)
    for j = 1, chars do
      local v = math.floor(n / 2 ^ (18 - (j - 1) * 6)) % 64
      out[#out + 1] = string.sub(B64, v + 1, v + 1)
    end
  end
  return table.concat(out)
end

local function Decode(text)
  if type(text) ~= "string" or #text % 4 == 1 or string.find(text, "[^%w_%-]") then return nil end
  local out = {}
  for i = 1, #text, 4 do
    local chunk = string.sub(text, i, i + 3)
    local n = 0
    for j = 1, 4 do n = n * 64 + (j <= #chunk and DECODE[string.sub(chunk, j, j)] or 0) end
    local bytes = { math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256 }
    for j = 1, #chunk - 1 do out[#out + 1] = string.char(bytes[j]) end
  end
  local result = table.concat(out)
  if Encode(result) ~= text then return nil end
  return result
end

-- Well-formed UTF-8 with no control byte and no "|" (no escape code).
local function CleanText(text, limit)
  if type(text) ~= "string" or #text > limit or string.find(text, "[%z\1-\31\127|]") then return false end
  local i, n = 1, #text
  while i <= n do
    local c = string.byte(text, i)
    local len = c < 128 and 1 or (c >= 194 and c <= 223) and 2 or (c >= 224 and c <= 239) and 3
      or (c >= 240 and c <= 244) and 4 or nil
    if not len or i + len - 1 > n then return false end
    for k = i + 1, i + len - 1 do
      local d = string.byte(text, k)
      if d < 128 or d > 191 then return false end
    end
    i = i + len
  end
  return true
end
GF.CleanText = CleanText

-- What the player typed: escapes and control bytes dropped, spaces trimmed,
-- cut to `limit` bytes on a character boundary.
function GF.Trim(text, limit)
  text = string.gsub(tostring(text or ""), "[%z\1-\31\127|]", "")
  text = string.gsub(string.gsub(text, "^%s+", ""), "%s+$", "")
  if #text > limit then
    local cut = limit
    while cut > 0 do
      local c = string.byte(text, cut + 1)
      if not c or c < 128 or c > 191 then break end
      cut = cut - 1
    end
    text = string.sub(text, 1, cut)
  end
  if not CleanText(text, limit) then return "" end
  return text
end

GF.Encode, GF.Decode = Encode, Decode

-- Game state ------------------------------------------------------------------------

local function InRaid() return Flag("UnitExists", "raid1") == true end
local function InGroup() return InRaid() or Flag("UnitExists", "party1") == true end

-- Members including us.
local function Members()
  local count = 0
  if InRaid() then
    for i = 1, 40 do if Flag("UnitExists", "raid" .. i) == true then count = count + 1 end end
    return math.max(count, 1)
  end
  for i = 1, 4 do if Flag("UnitExists", "party" .. i) == true then count = count + 1 end end
  return count + 1
end

local function Leading()
  return not InGroup() or Flag("UnitIsGroupLeader", "player") == true
end

local function UnitIdentity(unit)
  local ok, first, surname = Call("UnitNameUnmodified", unit)
  if not ok or IsSecret(first) or IsSecret(surname) or type(first) ~= "string" then return nil end
  local names = WF.Names
  local full = names and names.Full and names.Full(first, surname) or first
  return full and names and names.Identity and names.Identity(full) or nil
end

local function GroupIdentities()
  local out = {}
  local prefix, last = "party", 4
  if InRaid() then prefix, last = "raid", 40 end
  for i = 1, last do
    local identity = UnitIdentity(prefix .. i)
    if identity then out[identity] = true end
  end
  return out
end

function GF.Faction()
  local ok, tag = Call("UnitFactionGroup", "player")
  if not ok or IsSecret(tag) then return nil end
  return tag == "Alliance" and "A" or (tag == "Horde" and "H") or nil
end

-- Our class file name (e.g. "WARRIOR") and level.
function GF.Self()
  local ok, _, classFile = Call("UnitClass", "player")
  local okLevel, level = Call("UnitLevel", "player")
  if not ok or IsSecret(classFile) or type(classFile) ~= "string" or not string.find(classFile, "^%u+$") then classFile = "" end
  if not okLevel or IsSecret(level) or type(level) ~= "number" then level = 0 end
  return string.sub(classFile, 1, 12), math.floor(level)
end

local function GameIgnored(identity)
  local api = Global("C_FriendList")
  if type(api) ~= "table" or type(api.IsIgnored) ~= "function" then return false end
  local ok, ignored = pcall(api.IsIgnored, identity)
  return ok and not IsSecret(ignored) and ignored == true
end

local function Invite(target)
  local api = Global("C_PartyInfo")
  if type(api) ~= "table" or type(api.InviteUnit) ~= "function" then return false end
  return pcall(api.InviteUnit, target) and true or false
end

local function Transport() return WF.Transport end

local function Whisper(target, body)
  local transport = Transport()
  if not transport or type(transport.SendTo) ~= "function" or type(target) ~= "string" then return false end
  local ok = transport:SendTo(target, "GF", body)
  if ok then GF.sent = GF.sent + 1 end
  return ok and true or false
end

-- Wire ------------------------------------------------------------------------------

local function ListingBody(own)
  local classFile = GF.Self()
  return table.concat({ "L", own.lid, own.rev, own.faction, own.activity, own.min, own.max,
    own.tanks, own.healers, own.dps, own.have, own.size, own.lang, own.auto and 1 or 0, classFile,
    Encode(own.title or ""), Encode(own.note or "") }, ",")
end
GF.ListingBody = ListingBody

local function Int(text, low, high)
  local value = tonumber(text)
  if not value or value ~= math.floor(value) or value < low or value > high then return nil end
  return value
end

local function ParseListing(body)
  local lid, rev, faction, activity, low, high, tanks, healers, dps, have, size, lang, auto, classFile, title, note =
    string.match(body, "^L,([0-9a-f]+),(%d+),([AH]),(%u),(%d+),(%d+),(%d),(%d),(%d),(%d+),(%d+),(%u%u),([01]),(%u*),([%w_%-]*),([%w_%-]*)$")
  if not lid or #lid ~= 6 or not ACTIVITY[activity] or not LANGUAGE[lang] or #classFile > 12 then return nil end
  local row = {
    lid = lid, rev = Int(rev, 1, 99999), faction = faction, activity = activity,
    min = Int(low, 0, K.MAX_LEVEL), max = Int(high, 0, K.MAX_LEVEL),
    tanks = Int(tanks, 0, 9), healers = Int(healers, 0, 9), dps = Int(dps, 0, 9),
    have = Int(have, 1, 40), size = Int(size, 5, 40), lang = lang, auto = auto == "1", class = classFile,
    title = Decode(title), note = Decode(note),
  }
  if not row.rev or not row.min or not row.max or not row.tanks or not row.healers or not row.dps
      or not row.have or not row.size or not SIZE[row.size] then return nil end
  if row.min > 0 and row.max > 0 and row.min > row.max then return nil end
  if not row.title or not row.note or not CleanText(row.title, K.TITLE) or not CleanText(row.note, K.NOTE) then return nil end
  return row
end
GF.ParseListing = ParseListing

local function Key(origin, lid) return origin .. "\n" .. lid end

-- Bounded tables --------------------------------------------------------------------

local function Prune(now)
  for key, row in pairs(GF.listings) do
    if now - row.heardAt > K.TTL then GF.listings[key] = nil end
  end
  for key, untilAt in pairs(GF.closed) do
    if now >= untilAt then GF.closed[key] = nil end
  end
  for key, at in pairs(GF.replied) do
    if now - at > K.REPLY_GAP then GF.replied[key] = nil end
  end
  for key, app in pairs(GF.mine) do
    if app.state ~= "sent" and now - (app.doneAt or app.at) > K.APP_TTL then GF.mine[key] = nil
    elseif app.state == "sent" and now - app.at > K.APP_TTL then app.state, app.doneAt = "expired", now end
  end
  for key, app in pairs(GF.applicants) do
    if now - app.at > K.APP_TTL then GF.applicants[key] = nil end
  end
end

local function Oldest(t, field)
  local oldestKey, oldestAt
  for key, row in pairs(t) do
    local at = type(row) == "table" and row[field] or row
    if not oldestAt or at < oldestAt then oldestKey, oldestAt = key, at end
  end
  return oldestKey
end

local function NoteClosed(key, now)
  if not GF.closed[key] and Count(GF.closed) >= K.MAX_CLOSED then
    GF.closed[Oldest(GF.closed)] = nil
  end
  GF.closed[key] = now + K.TTL
end

-- Receiving -------------------------------------------------------------------------

local function OnListing(row, origin, target, now)
  if row.faction ~= GF.Faction() or GameIgnored(origin) or GF.ignored[origin] then return false end
  local key = Key(origin, row.lid)
  if GF.closed[key] then return true end
  local known = GF.listings[key]
  if known then
    known.heardAt = now
    if row.rev <= known.rev then return true end
    row.firstAt = known.firstAt
  else
    if Count(GF.listings) >= K.MAX_LISTINGS then GF.listings[Oldest(GF.listings, "heardAt")] = nil end
    row.firstAt = now
  end
  row.leader, row.target, row.heardAt = origin, target, now
  GF.listings[key] = row
  return true
end

local function OnClose(body, origin, now)
  local lid, rev = string.match(body, "^X,([0-9a-f]+),(%d+)$")
  if not lid or #lid ~= 6 or not Int(rev, 1, 99999) then return false end
  local key = Key(origin, lid)
  GF.listings[key] = nil
  NoteClosed(key, now)
  local app = GF.mine[key]
  if app and app.state == "sent" then app.state, app.doneAt = "closed", now end
  return true
end

local function Reply(identity, target, lid, aid, code, now)
  local key = identity .. "\n" .. code
  if GF.replied[key] then return false end
  GF.replied[key] = now
  return Whisper(target, table.concat({ "R", lid, aid, code }, ","))
end

local function RoleOpen(own, role)
  if own.tanks + own.healers + own.dps == 0 then return true end
  return (role == "T" and own.tanks > 0) or (role == "H" and own.healers > 0) or (role == "D" and own.dps > 0)
end

local function TakeRole(own, role)
  local field = role == "T" and "tanks" or (role == "H" and "healers") or "dps"
  if own[field] > 0 then own[field] = own[field] - 1 end
end

-- Room for one more without the raid conversion prompt.
local function HasRoom(own)
  local have = Members()
  if have >= own.size then return false end
  return InRaid() or have < 5
end

local function LevelFits(own, level)
  return (own.min == 0 or level >= own.min) and (own.max == 0 or level <= own.max)
end

function GF:Changed(now)
  local own = self.own
  if not own then return end
  own.rev = math.min(own.rev + 1, 99999)
  own.nextSend = math.max(now, (own.lastSent or -1000) + K.CHANGE_GAP)
  self:Save()
end

local function OnApplication(body, identity, target, now)
  local lid, aid, classFile, level, role, note =
    string.match(body, "^A,([0-9a-f]+),([0-9a-f]+),(%u*),(%d+),([THD]),([%w_%-]*)$")
  level = level and Int(level, 0, K.MAX_LEVEL)
  note = note and Decode(note)
  if not lid or #lid ~= 6 or #aid ~= 4 or #classFile > 12 or not level or not note or not CleanText(note, K.NOTE) then
    return false
  end
  local own = GF.own
  if not own or own.lid ~= lid or GF.ignored[identity] or GameIgnored(identity) then return true end
  local key = identity .. "\n" .. aid
  if GF.applicants[key] then return true end
  if GF.declined[identity] then return Reply(identity, target, lid, aid, "N", now) end
  if not LevelFits(own, level) then return Reply(identity, target, lid, aid, "V", now) end
  if Members() >= own.size then return Reply(identity, target, lid, aid, "F", now) end
  if own.auto and HasRoom(own) and RoleOpen(own, role) and Invite(target) then
    GF.invited = GF.invited + 1
    TakeRole(own, role)
    GF:Changed(now)
    Whisper(target, table.concat({ "R", lid, aid, "I" }, ","))
    return true
  end
  -- One waiting application per player: a newer one replaces it.
  for other, app in pairs(GF.applicants) do
    if app.identity == identity then GF.applicants[other] = nil end
  end
  if Count(GF.applicants) >= K.MAX_APPLICANTS then return true end
  GF.applicants[key] = { identity = identity, target = target, aid = aid, lid = lid, class = classFile,
    level = level, role = role, note = note, at = now }
  Say(string.format(WF.L("%s wants to join your group. Open the Group Finder to answer (/wf groups)."), identity))
  Sound()
  return true
end

local function OnWithdraw(body, identity)
  local lid, aid = string.match(body, "^W,([0-9a-f]+),([0-9a-f]+)$")
  if not lid or #lid ~= 6 or #aid ~= 4 then return false end
  GF.applicants[identity .. "\n" .. aid] = nil
  return true
end

local REPLY_STATES = { I = "invited", N = "declined", F = "full", C = "closed", V = "level" }

local function OnReply(body, identity, now)
  local lid, aid, code = string.match(body, "^R,([0-9a-f]+),([0-9a-f]+),(%u)$")
  if not lid or #lid ~= 6 or #aid ~= 4 or not REPLIES[code] then return false end
  local app = GF.mine[Key(identity, lid)]
  if not app or app.aid ~= aid or app.state ~= "sent" then return true end
  app.state, app.doneAt = REPLY_STATES[code], now
  if code == "I" then Say(string.format(WF.L("%s invited you: accept the group invitation."), identity)) end
  return true
end

-- Transport entry point. `channel` lines and guild lines carry listings only;
-- whispers carry applications and replies (decision 0145 § 4, § 5).
function GF:OnLine(body, identity, target, chatType, now)
  if type(body) ~= "string" or #body > 200 or type(identity) ~= "string" then return false end
  if identity == Me() then return false end
  now = now or Now()
  Prune(now)
  self.received = self.received + 1
  local kind = string.sub(body, 1, 1)
  local ok
  if chatType == "WHISPER" then
    if kind == "A" then ok = OnApplication(body, identity, target, now)
    elseif kind == "W" then ok = OnWithdraw(body, identity)
    elseif kind == "R" then ok = OnReply(body, identity, now) end
  elseif chatType == "CHANNEL" or chatType == "GUILD" then
    if kind == "L" then
      local row = ParseListing(body)
      ok = row and OnListing(row, identity, target, now) or false
    elseif kind == "X" then
      ok = OnClose(body, identity, now)
    end
  end
  if not ok then self.rejected = self.rejected + 1 end
  return ok and true or false
end

-- Own listing -----------------------------------------------------------------------

local FORM_FIELDS = { "activity", "min", "max", "tanks", "healers", "dps", "size", "lang", "auto", "title", "note" }

-- The default form, then the last one saved.
function GF:Form()
  local form = { activity = "C", min = 0, max = 0, tanks = 0, healers = 0, dps = 0, size = 5, lang = "EN",
    auto = true, title = "", note = "" }
  local settings = Settings()
  local saved = settings and type(settings.groupFinder) == "table" and settings.groupFinder.form or nil
  if type(saved) == "table" then
    if ACTIVITY[saved.activity] then form.activity = saved.activity end
    if LANGUAGE[saved.lang] then form.lang = saved.lang end
    if SIZE[saved.size] then form.size = saved.size end
    for _, field in ipairs({ "min", "max" }) do
      if Int(saved[field], 0, K.MAX_LEVEL) then form[field] = saved[field] end
    end
    for _, field in ipairs({ "tanks", "healers", "dps" }) do
      if Int(saved[field], 0, 9) then form[field] = saved[field] end
    end
    if type(saved.auto) == "boolean" then form.auto = saved.auto end
    if CleanText(saved.title, K.TITLE) then form.title = saved.title end
    if CleanText(saved.note, K.NOTE) then form.note = saved.note end
  end
  if self.own then
    for _, field in ipairs(FORM_FIELDS) do form[field] = self.own[field] end
  end
  return form
end

function GF:Save()
  local settings = Settings()
  if not settings then return end
  local saved = type(settings.groupFinder) == "table" and settings.groupFinder or {}
  settings.groupFinder = saved
  local own = self.own
  if own then
    saved.form = {}
    for _, field in ipairs(FORM_FIELDS) do saved.form[field] = own[field] end
    saved.open = { lid = own.lid, rev = own.rev, wall = own.wall }
  else
    saved.open = nil
  end
end

-- nil when we may list, else why not.
function GF:CannotList()
  if not GF.Faction() then return "Not available right now." end
  if not Leading() then return "Only the group leader can list the group." end
  return nil
end

-- Lists or updates our group with a validated form. True, or false and why.
function GF:Publish(form, now)
  now = now or Now()
  local why = self:CannotList()
  if why then return false, why end
  if type(form) ~= "table" or not ACTIVITY[form.activity] or not LANGUAGE[form.lang] or not SIZE[form.size] then
    return false, "Check the group settings."
  end
  local low, high = Int(form.min, 0, K.MAX_LEVEL), Int(form.max, 0, K.MAX_LEVEL)
  local tanks, healers, dps = Int(form.tanks, 0, 9), Int(form.healers, 0, 9), Int(form.dps, 0, 9)
  if not low or not high or not tanks or not healers or not dps then return false, "Check the group settings." end
  if low > 0 and high > 0 and low > high then return false, "The minimum level is above the maximum." end
  local have = Members()
  if have >= form.size then return false, "Your group is already full." end
  local own = self.own
  if not own then
    own = { lid = Hex(6), rev = 0, created = now, wall = Wall(), lastSent = nil }
    self.own = own
    self.applicants, self.declined = {}, {}
  end
  own.activity, own.lang, own.size, own.auto = form.activity, form.lang, form.size, form.auto == true
  own.min, own.max, own.tanks, own.healers, own.dps = low, high, tanks, healers, dps
  own.title, own.note = GF.Trim(form.title, K.TITLE), GF.Trim(form.note, K.NOTE)
  own.faction, own.have = GF.Faction(), have
  self:Changed(now)
  return true
end

function GF:Close(text, now)
  local own = self.own
  if not own then return false end
  now = now or Now()
  self.own = nil
  self.applicants = {}
  local transport = Transport()
  local body = table.concat({ "X", own.lid, math.min(own.rev + 1, 99999) }, ",")
  if transport and type(transport.SendFinder) == "function" then
    if transport:SendFinder(body, own.lid) then self.sent = self.sent + 1 end
    self.guildClose = { body = body, untilAt = now + K.REFRESH }
  end
  self:Save()
  if text then Say(WF.L(text)) end
  return true
end

-- A listing restored after a /reload, if still young enough.
function GF:Restore(now)
  -- Only once the game knows who and which faction we are.
  if self.restored or not GF.Faction() or not Me() then return end
  self.restored = true
  local settings = Settings()
  local saved = settings and type(settings.groupFinder) == "table" and settings.groupFinder or nil
  local open, wall = saved and saved.open, Wall()
  if type(open) ~= "table" or type(open.lid) ~= "string" or #open.lid ~= 6 or string.find(open.lid, "[^0-9a-f]")
      or not Int(open.rev, 0, 99999) or not wall or type(open.wall) ~= "number" then
    if saved then saved.open = nil end
    return
  end
  local age = wall - open.wall
  if age < 0 or age >= K.LIFE or self:CannotList() then saved.open = nil return end
  local form = self:Form()
  self.own = { lid = open.lid, rev = open.rev, created = now - age, wall = open.wall }
  if not self:Publish(form, now) then self.own = nil saved.open = nil end
end

-- The leader of our group when we do not lead it, or nil.
local function GroupLeader()
  if not InGroup() or Leading() then return nil end
  local prefix, last = "party", 4
  if InRaid() then prefix, last = "raid", 40 end
  for i = 1, last do
    if Flag("UnitIsGroupLeader", prefix .. i) == true then return UnitIdentity(prefix .. i) end
  end
  return nil
end

-- A new leader lists the group the leader it replaced had listed, while that
-- player is still in the group (decision 0145 § 7).
local function Adopt(previous, now)
  if not previous or not GroupIdentities()[previous] then return end
  for _, row in pairs(GF.listings) do
    if row.leader == previous and row.faction == GF.Faction() then
      local form = {}
      for _, field in ipairs(FORM_FIELDS) do form[field] = row[field] end
      GF.listings[Key(row.leader, row.lid)] = nil
      if GF:Publish(form, now) then
        Say(WF.L("You lead the group now: it stays listed in the Group Finder."))
      end
      return
    end
  end
end

local function TickOwn(now)
  local own = GF.own
  local leading = InGroup() and Leading()
  if not InGroup() then GF.previousLeader = nil
  elseif not leading then GF.previousLeader = GroupLeader() or GF.previousLeader end
  if not own then
    if leading and not wasLeader then Adopt(GF.previousLeader, now) end
    if leading then GF.previousLeader = nil end
    wasLeader = leading
    return
  end
  wasLeader = leading
  if not Leading() then return GF:Close("You are no longer the leader: your group left the Group Finder.", now) end
  local have = Members()
  if have >= own.size then return GF:Close("Your group is full and left the Group Finder.", now) end
  if now - own.created >= K.LIFE then return GF:Close("Your group left the Group Finder after 2 hours.", now) end
  if have ~= own.have then
    own.have = have
    GF:Changed(now)
  end
  local transport = Transport()
  if not transport or type(transport.SendFinder) ~= "function" then return end
  if now >= (own.nextSend or 0) then
    local body = ListingBody(own)
    transport:SendFinder(body, own.lid)
    GF.sent = GF.sent + 1
    own.lastSent, own.nextSend, own.guildBody = now, now + K.REFRESH, body
  end
  if own.guildBody and transport:SendFinderGuild(own.guildBody) then own.guildBody = nil end
end

-- Applying --------------------------------------------------------------------------

-- What the join button shows for a listing: nil when we may join, else why not.
function GF:CannotJoin(row)
  if not row then return "Closed" end
  local _, level = GF.Self()
  if self.own then return "Listed" end
  if InGroup() and GroupIdentities()[row.leader] then return "In group" end
  if row.have >= row.size then return "Full" end
  if (row.min > 0 and level < row.min) or (row.max > 0 and level > row.max) then return "Level" end
  return nil
end

function GF:Apply(key, role, note, now)
  now = now or Now()
  local row = self.listings[key]
  if not row or not self.ROLES[role] or self:CannotJoin(row) then return false end
  local app = self.mine[key]
  if app and app.state == "sent" then return false end
  local open = 0
  for _, other in pairs(self.mine) do if other.state == "sent" then open = open + 1 end end
  if open >= K.MAX_MINE then return false, "You already wait for 5 answers." end
  local classFile, level = GF.Self()
  note = GF.Trim(note, K.NOTE)
  local aid = Hex(4)
  local body = table.concat({ "A", row.lid, aid, classFile, level, role, Encode(note) }, ",")
  if not Whisper(row.target, body) then return false, "Could not reach the leader. Try again in a moment." end
  if not self.mine[key] and Count(self.mine) >= 2 * K.MAX_MINE then
    for other, mineApp in pairs(self.mine) do
      if mineApp.state ~= "sent" then self.mine[other] = nil break end
    end
  end
  self.mine[key] = { aid = aid, leader = row.leader, lid = row.lid, target = row.target, role = role,
    note = note, at = now, state = "sent" }
  return true
end

function GF:Withdraw(key)
  local app = self.mine[key]
  if not app or app.state ~= "sent" then return false end
  Whisper(app.target, table.concat({ "W", app.lid, app.aid }, ","))
  self.mine[key] = nil
  return true
end

-- Leader answers ----------------------------------------------------------------------

function GF:Accept(key, now)
  local app, own = self.applicants[key], self.own
  if not app or not own then return false end
  now = now or Now()
  if Members() >= own.size then return false, "Your group is already full." end
  if not Invite(app.target) then return false, "The invitation could not be sent." end
  self.invited = self.invited + 1
  self.applicants[key] = nil
  TakeRole(own, app.role)
  self:Changed(now)
  Whisper(app.target, table.concat({ "R", app.lid, app.aid, "I" }, ","))
  return true
end

function GF:Decline(key, now)
  local app = self.applicants[key]
  if not app then return false end
  self.applicants[key] = nil
  self.declined[app.identity] = true
  Whisper(app.target, table.concat({ "R", app.lid, app.aid, "N" }, ","))
  return true
end

-- Ignored for the session: no application from them, none of their groups.
function GF:Ignore(identity)
  if type(identity) ~= "string" then return false end
  if not self.ignored[identity] and Count(self.ignored) >= K.MAX_IGNORED then
    self.ignored[Oldest(self.ignored)] = nil
  end
  self.ignored[identity] = Now()
  for key, app in pairs(self.applicants) do
    if app.identity == identity then self.applicants[key] = nil end
  end
  for key, row in pairs(self.listings) do
    if row.leader == identity then self.listings[key] = nil end
  end
  return true
end

-- Views -----------------------------------------------------------------------------

-- Listings newest first, each with its key.
function GF:Rows()
  local rows = {}
  for key, row in pairs(self.listings) do
    row.key = key
    rows[#rows + 1] = row
  end
  table.sort(rows, function(a, b)
    if a.firstAt ~= b.firstAt then return a.firstAt > b.firstAt end
    return a.key < b.key
  end)
  return rows
end

function GF:Applicants()
  local rows = {}
  for key, app in pairs(self.applicants) do
    app.key = key
    rows[#rows + 1] = app
  end
  table.sort(rows, function(a, b)
    if a.at ~= b.at then return a.at < b.at end
    return a.key < b.key
  end)
  return rows
end

function GF.ActivityLabel(code) return ACTIVITY[code] or "Other" end

function GF:Summary()
  return "groups listings=" .. Count(self.listings) .. " own=" .. tostring(self.own and self.own.lid)
    .. " applicants=" .. Count(self.applicants) .. " mine=" .. Count(self.mine)
    .. " sent=" .. self.sent .. " received=" .. self.received .. " rejected=" .. self.rejected
    .. " invited=" .. self.invited
end

function GF:Tick(now)
  if now < nextTickAt then return end
  nextTickAt = now + K.TICK
  Prune(now)
  self:Restore(now)
  TickOwn(now)
  local close = self.guildClose
  if close then
    local transport = Transport()
    if now >= close.untilAt or (transport and transport.SendFinderGuild and transport:SendFinderGuild(close.body)) then
      self.guildClose = nil
    end
  end
end

-- Wiring ------------------------------------------------------------------------------

if CreateFrame then
  local frame = CreateFrame("Frame", "WarfrontGroupFinderFrame", UIParent)
  frame:SetScript("OnUpdate", function()
    local ok, err = pcall(GF.Tick, GF, Now())
    if not ok and WF.RecordError then WF.RecordError("group finder", err) end
  end)
end
