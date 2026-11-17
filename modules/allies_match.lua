local WF = Warfront
local A, X = WF.Allies, WF.X25519
local matches, offer = {}, nil
local cloud = {}
local function Now() return WF.Now() end
local function Me() return WF.Capture and WF.Capture:Me() end
local function Faction()
  local f = WF.Capture and WF.Capture:MyFaction()
  return f == "A" and "ALLIANCE" or f == "H" and "HORDE" or nil
end
local function Hex(s, n) return type(s) == 'string' and #s == n and not s:find('[^0-9a-f]') end
local function Tag(s)
  return type(s) == 'string' and #s <= 32 and s:match('^[^%s#|]+#%d+$') ~= nil
end
local function Parts(s)
  local out = {} for p in (s .. ','):gmatch('(.-),') do out[#out + 1] = p end return out
end
local function SealText(s) return type(s) == 'string' and #s >= 18 and #s <= 80 and #s % 2 == 0 and not s:find('[^0-9a-f]') end
local function Send(kind, id, payload) return WF.AlliesMesh:Publish(kind, id, payload, Now()) end
local function Context(m, direction)
  return table.concat({ m.offerId, m.replyId, m.offering, m.responding, m.offerKey, m.replyKey, direction }, ':')
end
local function FreshKey()
  local secret = X.NewSecret(Me())
  return secret, X.Public(secret)
end

function A:ValidMessage(kind, payload)
  local p = Parts(payload)
  if kind == 'O' then
    return #p == 4 and (p[1] == 'ALLIANCE' or p[1] == 'HORDE')
      and p[2]:match('^%d+$') ~= nil and tonumber(p[2]) <= 99999
      and p[3]:match('^[0-5]$') ~= nil and Hex(p[4], 64)
  elseif kind == 'A' then return #p == 4 and Hex(p[1], 16) and Hex(p[4], 64)
    and (p[2] == 'ALLIANCE' or p[2] == 'HORDE') and p[3]:match('^%d+$') ~= nil and tonumber(p[3]) <= 99999
  elseif kind == 'C' or kind == 'R' then return #p == 2 and Hex(p[1], 16) and SealText(p[2])
  elseif kind == 'D' then return #p == 1 and Hex(p[1], 16) end
  return false
end

function A:ResetMatches()
  matches, offer = {}, nil
  if WF.AlliesMesh then WF.AlliesMesh:CancelOwn() end
  if self.partnerPopup then self.partnerPopup:Hide() end
end

function A:MatchRows()
  local out = {}
  for name, m in pairs(matches) do
    out[#out + 1] = { name = name, status = m.status, tag = m.tag, faction = m.faction }
  end
  for name, row in pairs(cloud) do
    if row.untilAt > Now() and not self:IsBlocked(name) then
      out[#out + 1] = { name = name, status = 'ready', tag = row.tag, faction = row.faction }
    end
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

function A:DeclineMatch(name)
  cloud[name] = nil
  local m = matches[name]
  if m then
    WF.AlliesMesh:CancelExchange(m.offerId, m.replyId)
    if m.replyId then Send('D', m.replyId, m.offerId) end
    matches[name] = nil
  end
  self:Block(name)
  if offer and offer.partner == name then offer = nil end
  return true
end

function A:ConfirmMatch(name)
  local m = matches[name]
  if not m or not self:OptedIn() or m.untilAt <= Now() or self:IsBlocked(name) then return false end
  if m.status == 'offer' then
    if not self:TakePartner(name) then return false end
    m.secret, m.replyKey = FreshKey()
    m.replyId = m.replyKey:sub(1, 16)
    m.responding, m.offering = Me(), name
    if not Send('A', m.replyId, table.concat({ m.offerId, Faction(), WF.Ruleset.record, m.replyKey }, ',')) then
      self:State().partners[name] = nil m.secret, m.replyKey, m.replyId = nil, nil, nil return false
    end
    m.status = 'waiting' return true
  elseif m.status == 'accept' then
    if not self:CanTakePartner(name) or self:RecentReveals() >= self.MAX_REVEALS then return false end
    local tag = self:OwnBattleTag()
    if not tag then return false end
    local sealed = X.Seal(m.secret, m.replyKey, Context(m, 'C'), tag)
    if not sealed or not Send('C', m.offerId, m.replyId .. ',' .. sealed) then return false end
    self:TakePartner(name) self:NoteReveal(name)
    m.status = 'waiting' return true
  end
  return false
end

function A:OnMatchMessage(kind, id, payload, origin, now)
  if not self:OptedIn() or self:IsBlocked(origin) or not self:ValidMessage(kind, payload) then return false end
  local p, m = Parts(payload), matches[origin]
  if kind == 'O' then
    if m or not self:CanTakePartner(origin) or self:RecentReveals() >= self.MAX_REVEALS then return false end
    if p[1] == Faction() or not WF.Ruleset or tonumber(p[2]) ~= WF.Ruleset.record then return false end
    -- Simultaneous offers settle on one initiator, independent of arrival order.
    if offer and not offer.partner then
      if Me() < origin then return false end
      WF.AlliesMesh:CancelExchange(offer.id)
      offer = nil
    end
    local count = 0 for _ in pairs(matches) do count = count + 1 end
    if count >= self.MAX_PARTNERS then return false end
    matches[origin] = { status = 'offer', offerId = id, offerKey = p[4], faction = p[1], untilAt = now + 600 }
  elseif kind == 'A' then
    if m or not offer or offer.id ~= p[1] or offer.untilAt <= now or offer.partner
      or not self:CanTakePartner(origin) or self:RecentReveals() >= self.MAX_REVEALS then return false end
    if p[2] == Faction() or tonumber(p[3]) ~= WF.Ruleset.record then return false end
    local count = 0 for _ in pairs(matches) do count = count + 1 end
    if count >= self.MAX_PARTNERS then return false end
    offer.partner = origin
    matches[origin] = { status = 'accept', offerId = offer.id, replyId = id,
      secret = offer.secret, offerKey = offer.public, replyKey = p[4],
      offering = Me(), responding = origin, faction = p[2], untilAt = offer.untilAt }
    offer.secret = nil
  elseif kind == 'C' then
    if not m or m.status ~= 'waiting' or m.offering ~= origin or m.offerId ~= id or m.replyId ~= p[1] or not m.secret then return false end
    local tag = X.Open(m.secret, m.offerKey, Context(m, 'C'), p[2])
    if not Tag(tag) then return false end
    local own = self:OwnBattleTag()
    local sealed = own and X.Seal(m.secret, m.offerKey, Context(m, 'R'), own)
    if not sealed or not self:CanReveal(origin) then return false end
    m.returnSeal, m.returnTag = sealed, tag
  elseif kind == 'R' then
    if not m or m.status ~= 'waiting' or m.responding ~= origin or m.replyId ~= id or m.offerId ~= p[1] or not m.secret then return false end
    local tag = X.Open(m.secret, m.replyKey, Context(m, 'R'), p[2])
    if not Tag(tag) then return false end
    m.tag, m.status, m.secret, m.untilAt = tag, 'ready', nil, now + self.EXPIRY
    offer = nil
  elseif kind == 'D' then
    if not m or m.replyId ~= id or m.offerId ~= p[1] then return false end
    self:Block(origin) matches[origin] = nil
    if offer and offer.partner == origin then offer = nil end
  end
  return true
end

function A:MatchTick(now)
  if self.nextMatchTick and now < self.nextMatchTick then return end
  self.nextMatchTick = now + 1
  WF.AlliesMesh:Tick(now)
  if self.ShowNextMatch then self:ShowNextMatch() end
  if not self:OptedIn() or not self:BattleNetReady() then return end
  for name, m in pairs(matches) do
    if m.returnSeal and m.untilAt > now and not self:IsBlocked(name) and self:CanReveal(name)
      and Send('R', m.replyId, m.offerId .. ',' .. m.returnSeal) then
      self:NoteReveal(name)
      m.tag, m.status, m.secret, m.untilAt = m.returnTag, 'ready', nil, now + self.EXPIRY
      m.returnSeal, m.returnTag = nil, nil
    end
    if m.untilAt <= now or self:IsBlocked(name) then
      if m.status ~= 'offer' then self:Block(name) end
      matches[name] = nil
    end
  end
  if offer and offer.untilAt <= now then offer = nil end
  local db = self:State()
  local epoch = WF.Epoch()
  if not db or not X.Available() or not Me() or not Faction() or not WF.Ruleset.record then return end
  if not offer and self:OpenPartners() < self.MAX_PARTNERS and self:RecentReveals() < self.MAX_REVEALS
    and (not tonumber(db.lastOffer) or epoch - db.lastOffer >= 1800) then
    local secret, public = FreshKey()
    offer = { id = public:sub(1, 16), secret = secret, public = public, untilAt = now + 600 }
    local payload = table.concat({ Faction(), WF.Ruleset.record, math.floor(epoch % 86400 / 14400), public }, ',')
    if Send('O', offer.id, payload) then db.lastOffer = epoch else offer = nil end
  end
  if self.ShowNextMatch then self:ShowNextMatch() end
end

-- Private companion data: never passed to the mesh or gameplay state.
function A:LoadCompanion(data)
  cloud = {}
  local db = self:State()
  if not db or type(data) ~= 'table' then return end
  if not db.cloudCheckedAt or data.checkedAt >= db.cloudCheckedAt then
    db.cloudUntil, db.cloudCheckedAt = data.lockedUntil, data.checkedAt
  end
  if self:CloudLocked() then self:ResetMatches() end
  if not data.active or WF.Epoch() - data.checkedAt > 7 * 86400 then return end
  for _, row in pairs(data.matches) do
    local life = row.expiresAt == 0 and 7 * 86400 or row.expiresAt - WF.Epoch()
    life = math.min(life, data.checkedAt + 7 * 86400 - WF.Epoch())
    if life > 0 and Tag(row.tag) then cloud[row.name] = {
      tag = row.tag, faction = row.faction == 'H' and 'HORDE' or 'ALLIANCE', untilAt = Now() + life,
    } end
  end
end

function A:OpenMatchFriend(name)
  for _, row in ipairs(self:MatchRows()) do
    if row.name == name and row.status == 'ready' then return self:ShowAddFriend(row.tag) end
  end
  return false
end
