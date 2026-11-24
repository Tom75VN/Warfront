-- Local presentation history only. Never used to decide gameplay or sent.
local WF = Warfront
local History = { MAX = 200, revision = 0, pending = {} }
WF.AlertHistory = History
History.categories = {
  { "all", "All events" }, { "captures", "Captures" }, { "armies", "Armies" },
  { "battles", "Battles" }, { "scouts", "Scouts" }, { "sieges", "Sieges" },
  { "campaigns", "Campaigns" }, { "orders", "My orders" }, { "updates", "Addon updates" },
}
local known = {}
for _, category in ipairs(History.categories) do known[category[1]] = category[2] end

local function Valid(entry)
  return type(entry) == "table" and known[entry.category] and entry.category ~= "all"
    and type(entry.text) == "string" and #entry.text > 0 and #entry.text <= 2048
    and type(entry.at) == "number" and entry.at == entry.at and entry.at >= 0 and entry.at < 100000000000
    and (entry.k == nil or (type(entry.k) == "string" and #entry.k > 0 and #entry.k <= 64))
end

function History:Initialize()
  self.loaded = true
  if self.store then return end
  local name, complete = WF.Names.Mine()
  local region = WF.Ruleset:Region()
  if not complete or not region then return end
  local key = tostring(region) .. ":" .. name
  local saved = WarfrontJournal
  -- Leave future/unknown data intact; use a session-only view in that case.
  local writable = saved == nil or (type(saved) == "table" and saved.v == 1 and type(saved.characters) == "table")
  if saved == nil then saved = { v = 1, characters = {} } end
  local bucket = writable and saved.characters[key]
  local store = { v = 1, entries = {} }
  if type(bucket) == "table" and type(bucket.entries) == "table" then
    for index = 1, math.min(#bucket.entries, self.MAX) do
      local entry = bucket.entries[index]
      if Valid(entry) then
        store.entries[#store.entries + 1] = {
          category = entry.category, text = entry.text, at = entry.at, read = entry.read == true,
          side = (entry.side == "A" or entry.side == "H") and entry.side or nil, k = entry.k,
          e = entry.e == true or nil,
        }
      end
    end
  end
  self.store = store
  if writable then
    saved.characters[key] = store
    WarfrontJournal = saved
  end
  for _, entry in ipairs(self.pending) do self:Insert(entry) end
  self.pending = {}
  self.revision = self.revision + 1
end

-- Newest first: an entry dated in the past (a cloud capture, decision 0144)
-- takes its place by date; a full list drops its oldest entry.
function History:Insert(entry)
  local entries = self.store.entries
  local index = 1
  while entries[index] and entries[index].at > entry.at do index = index + 1 end
  table.insert(entries, index, entry)
  if #entries > self.MAX then table.remove(entries) end
  self.revision = self.revision + 1
end

-- An event with a key (a capture: "poi:generation", decision 0144) is listed once.
function History:Has(key)
  if not key then return false end
  for _, list in ipairs({ self.store and self.store.entries or {}, self.pending }) do
    for _, entry in ipairs(list) do if entry.k == key then return true end end
  end
  return false
end

-- at: the event's own time when it is not now (a cloud capture); key: see Has;
-- estimated: the date is when this client learned of the event (a missed
-- capture, decision 0149 § 1), until Redate gives the real one.
function History:Add(category, text, side, title, key, at, estimated)
  if self.loaded then self:Initialize() end
  if self:Has(key) then return end
  text = WF.L and WF.L(text) or text
  if title then text = (WF.L and WF.L(title) or title) .. " - " .. text end
  local now = WF.Epoch()
  local entry = { category = category, text = text, at = math.min(type(at) == "number" and at or now, now), read = false, k = key }
  entry.side = (side == "A" or side == "H") and side or nil
  entry.e = key and estimated and true or nil
  if not Valid(entry) then return end
  if not self.store then
    self.pending[#self.pending + 1] = entry
    if #self.pending > self.MAX then table.remove(self.pending, 1) end
    return
  end
  self:Insert(entry)
end

-- The real date of an entry listed with an estimated one (decision 0149 § 3):
-- the entry keeps its text and read state and moves to its place by date.
function History:Redate(key, at)
  if self.loaded then self:Initialize() end
  if not key or type(at) ~= "number" or at ~= at or at < 0 then return false end
  local at2 = math.min(at, WF.Epoch())
  local list = self.store and self.store.entries or self.pending
  for index, entry in ipairs(list) do
    if entry.k == key then
      if not entry.e then return false end
      entry.at, entry.e = at2, nil
      if self.store then
        table.remove(list, index)
        self:Insert(entry)
      else
        self.revision = self.revision + 1
      end
      return true
    end
  end
  return false
end

function History:Entries()
  if self.loaded then self:Initialize() end
  return self.store and self.store.entries or self.pending
end

function History:Unread()
  local count = 0
  for _, entry in ipairs(self:Entries()) do if not entry.read then count = count + 1 end end
  return count
end

function History:Age(at, now)
  local age = math.max(0, (now or WF.Epoch()) - at)
  if age < 60 then return WF.L("Just now") end
  if age < 3600 then return WF.L("%d min ago", math.floor(age / 60)) end
  if age < 86400 then return WF.L("%d h ago", math.floor(age / 3600)) end
  return WF.L("%d d ago", math.floor(age / 86400))
end

function History:Category(key) return WF.L(known[key] or "All events") end

if WF.RegisterEvent then
  WF.RegisterEvent("ADDON_LOADED", function(_, name)
    if string.lower(tostring(name or "")) == string.lower(WF.name) then History:Initialize() end
  end)
end
