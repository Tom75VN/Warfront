local WF = Warfront
local Mesh = { pending = {}, seen = {}, partial = {}, rates = {}, nextSend = 0 }
WF.AlliesMesh = Mesh

-- Decision 0127: bounded, idle-only forwarding. Origins on forwarded lines
-- are vouched for by the immediate peer, never server-authenticated.
local TTL, HOPS, CHUNK, MAX_MESSAGES = 600, 4, 28, 32
local function Count(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end
local function Hex(s) return (s:gsub('.', function(c) return string.format('%02x', string.byte(c)) end)) end
local function Unhex(s)
  if #s % 2 ~= 0 or s:find('[^0-9a-f]') then return nil end
  return (s:gsub('..', function(c) return string.char(tonumber(c, 16)) end))
end
local function Name(s)
  return type(s) == 'string' and #s <= 64 and WF.Names and WF.Names.Identity(s) == s
end
local function Mine() return WF.Capture and WF.Capture:Me() end
local function Context()
  local r = WF.Ruleset
  return r and r:Scope(), r and r:Region()
end
local function Key(origin, kind, id) return origin .. ':' .. kind .. ':' .. id end
local function Prune(t, now)
  for k, v in pairs(t) do if v.untilAt <= now then t[k] = nil end end
end
local function Audiences(exclude)
  local transport = WF.Transport
  local all = transport and transport:BoardAudiences() or {}
  local out, whispers, links = {}, 0, 0
  local keys = {} for k in pairs(all) do keys[#keys + 1] = k end table.sort(keys)
  for _, a in ipairs(keys) do
    local prefix = a:sub(1, 2)
    if a ~= exclude and (a == 'GROUP' or a == 'GUILD' or
      (prefix == 'L:' and links < 2) or (prefix == 'W:' and whispers < 2)) then
      out[#out + 1] = a
      if prefix == 'L:' then links = links + 1 elseif prefix == 'W:' then whispers = whispers + 1 end
    end
  end
  return out
end
local function Valid(kind, id, payload)
  return type(kind) == 'string' and kind:match('^[OACRD]$') and type(id) == 'string'
    and #id == 16 and not id:find('[^0-9a-f]') and type(payload) == 'string'
    and #payload > 0 and #payload <= 240 and not payload:find('[^%w,._%-]')
end

function Mesh:Publish(kind, id, payload, now)
  local me = Mine()
  if not Name(me) or not Valid(kind, id, payload) then return false end
  local key = Key(me, kind, id)
  if self.pending[key] then return self.pending[key].payload == payload end
  Prune(self.seen, now)
  if Count(self.pending) >= MAX_MESSAGES or Count(self.seen) >= 256 then return false end
  self.pending[key] = { origin = me, kind = kind, id = id, payload = payload,
    born = now, untilAt = now + TTL, hop = 0, own = true, round = 0, nextAt = now }
  self.seen[key] = { untilAt = now + TTL }
  return true
end

function Mesh:CancelOwn()
  for key, row in pairs(self.pending) do if row.own then self.pending[key] = nil end end
end

function Mesh:CancelExchange(offerId, replyId)
  for key, row in pairs(self.pending) do
    if row.own and (row.id == offerId or row.id == replyId) then self.pending[key] = nil end
  end
end

function Mesh:OnLine(_, body, sender, audience, now)
  if type(body) ~= 'string' or #body > 200 or not Name(sender) then return false end
  local scope, region, hop, age, originHex, kind, id, part, total, data = body:match(
    '^([A-Z]+),(%d+),(%d),(%d+),([0-9a-f]+),([OACRD]),([0-9a-f]+),(%d),(%d),([%w,._%-]+)$')
  local ours, ourRegion = Context()
  if not scope or scope ~= ours or tonumber(region) ~= ourRegion then return false end
  hop, age, part, total = tonumber(hop), tonumber(age), tonumber(part), tonumber(total)
  if hop > HOPS or age >= TTL or #id ~= 16 or #originHex > 128 or #data > CHUNK
    or total < 1 or total > 9 or part < 1 or part > total or (part < total and #data ~= CHUNK) then return false end
  local origin = Unhex(originHex)
  if not Name(origin) or origin == Mine() or (hop == 0 and origin ~= sender) then return false end
  local ticket = WF.Ticket
  if ticket and (not ticket:Admit(sender, 'AM', now, true) or not ticket:Admit(origin, 'AM', now, true)) then return false end
  Prune(self.seen, now) Prune(self.partial, now) Prune(self.rates, now)
  local key = Key(origin, kind, id)
  if self.seen[key] then return true end
  local rate = self.rates[sender]
  if not rate then
    if Count(self.rates) >= 64 then return false end
    rate = { untilAt = now + 60, n = 0 } self.rates[sender] = rate
  end
  rate.n = rate.n + 1
  if rate.n > 60 then return false end
  local row = self.partial[key]
  if not row then
    if Count(self.partial) >= MAX_MESSAGES then return false end
    row = { untilAt = now + math.min(120, TTL - age), born = now - age,
      parts = {}, total = total, sender = sender, hop = hop, audience = audience }
    self.partial[key] = row
  end
  -- Never combine different forwarders or renew an assembly with duplicates.
  if row.sender ~= sender or row.total ~= total or row.hop ~= hop then return false end
  if row.parts[part] and row.parts[part] ~= data then return false end
  row.parts[part] = data
  for i = 1, total do if not row.parts[i] then return true end end
  local payload = table.concat(row.parts)
  if not Valid(kind, id, payload) then self.partial[key] = nil return false end
  local allies = WF.Allies
  if not allies or not allies.ValidMessage or not allies:ValidMessage(kind, payload) then
    self.partial[key] = nil return false
  end
  if Count(self.seen) >= 256 then return false end
  self.partial[key] = nil
  self.seen[key] = { untilAt = row.born + TTL }
  if hop < HOPS and Count(self.pending) < MAX_MESSAGES - 8 then
    self.pending[key] = { origin = origin, kind = kind, id = id, payload = payload,
      born = row.born, untilAt = row.born + TTL, hop = hop + 1,
      exclude = audience, round = 0, nextAt = now }
  end
  allies:OnMatchMessage(kind, id, payload, origin, now)
  return true
end

function Mesh:Tick(now)
  Prune(self.pending, now) Prune(self.seen, now) Prune(self.partial, now)
  if now < self.nextSend then return end
  if not self.window or now - self.window >= 3600 then self.window, self.sent = now, 0 end
  if self.sent >= 240 then return end
  local scope, region = Context()
  if not scope or not region then return end
  -- Oldest message first; a busy audience never blocks all the others.
  local keys = {} for k in pairs(self.pending) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b)
    local x, y = self.pending[a], self.pending[b]
    return x.nextAt < y.nextAt or (x.nextAt == y.nextAt and a < b)
  end)
  for _, key in ipairs(keys) do
    local row = self.pending[key]
    if now >= row.nextAt then
      if not row.audiences then row.audiences, row.done = Audiences(row.exclude), {} end
      local total, complete = math.ceil(#row.payload / CHUNK), #row.audiences > 0
      for _, audience in ipairs(row.audiences) do
        local part = (row.done[audience] or 0) + 1
        if part <= total then
          complete = false
          local body = table.concat({ scope, region, row.hop, math.floor(now - row.born),
            Hex(row.origin), row.kind, row.id, part, total,
            row.payload:sub((part - 1) * CHUNK + 1, part * CHUNK) }, ',')
          if WF.Transport and WF.Transport:SendBoard(audience, 'AM', body) then
            row.done[audience] = part
            self.sent, self.nextSend = self.sent + 1, now + 4
            return
          end
        end
      end
      if complete then
        row.round = row.round + 1
        if row.round >= 3 then self.pending[key] = nil
        else row.audiences = nil row.nextAt = now + 30 * row.round end
      elseif #row.audiences == 0 then row.audiences = nil row.nextAt = now + 10 end
    end
  end
end
