Warfront = Warfront or {}

local WF = Warfront
local Scoreboard = {}
WF.Scoreboard = Scoreboard

-- Read-only scoreboard model (decisions 0088, 0104, 0105, 0109). It turns the
-- companion import (ranks, schema 8; the PvP boards of schema 7) and this
-- character's own war record into the rows both windows draw. Local values are
-- shown to this player only: never sent, never part of shared state (R16).
--
-- The weight table below is the one the Worker uses too (0104 § 3, 0109 § 4).
-- Weights of decision 0126 § 1: a War Camp is half an Outpost, a Settlement
-- five Outposts, a capital four Settlements; a defense is half its conquest.
-- War Camps keep their own raw counters capW and defW (decision 0123 § 9).
local CAPTURE_POINTS = { OUTPOST = 4, SETTLEMENT = 20, CAPITAL = 80, WAR_CAMP = 2 }
local DEFENSE_POINTS = { OUTPOST = 2, SETTLEMENT = 10, CAPITAL = 40, WAR_CAMP = 1 }
local TOP = 100
local PERMANENT = "permanent"
-- atkS: scouts sent, worth their full cost in the Attack column (0126 § 5).
local STAT_KEYS = {
  "capO", "capS", "capC", "defO", "defS", "defC", "conf", "kills", "assists", "deaths",
  "gold", "wood", "atkF", "atkR", "atkM", "garF", "garR", "garM", "capW", "defW", "atkS",
}
local TYPE_SUFFIX = { OUTPOST = "O", SETTLEMENT = "S", CAPITAL = "C", WAR_CAMP = "W" }
local UNIT_SUFFIX = { FOOTMAN = "F", RIFLEMAN = "R", MORTAR = "M" }
local UNIT_ORDER = { "FOOTMAN", "RIFLEMAN", "MORTAR" }

Scoreboard.CAPTURE_POINTS = CAPTURE_POINTS
Scoreboard.DEFENSE_POINTS = DEFENSE_POINTS
Scoreboard.STAT_KEYS = STAT_KEYS
Scoreboard.TOP = TOP

-- Board definitions: the import list each ranking reads, the ranked column
-- and the columns shown. Player-facing names and subtitles come from 0105.
local BOARDS = {
  territory = {
    title = "Territory",
    subtitle = "Conquests: 2 per War Camp, 4 per Outpost, 20 per Settlement, 80 per capital - Defenses: half",
    columns = {
      { key = "points", label = "Points" },
      { key = "conquests", label = "Conquests" },
      { key = "defenses", label = "Defenses" },
      { key = "confirmed", label = "Confirmed" },
    },
    sorts = { confirmed = "confirmed", points = "points" },
    default = "confirmed",
  },
  pvp = {
    title = "PvP",
    subtitle = "Fights against the other faction in the open world - Kills = killing blows + assists",
    columns = {
      { key = "kills", label = "Kills" },
      { key = "blows", label = "Killing blows" },
      { key = "assists", label = "Assists" },
      { key = "deaths", label = "Deaths" },
      { key = "kd", label = "K/D" },
    },
    sorts = { kills = "pvp" },
    default = "kills",
  },
  effort = {
    title = "War effort",
    subtitle = "War Chests: gold and wood deposited to upgrade Settlements - Troops: cost of units and scouts sent out or placed in a garrison",
    columns = {
      { key = "effort", label = "Points" },
      { key = "chests", label = "War Chests" },
      { key = "attack", label = "Attack" },
      { key = "garrison", label = "Garrison" },
      { key = "troops", label = "Troops" },
    },
    sorts = { effort = "effort" },
    default = "effort",
  },
}
Scoreboard.BOARDS = BOARDS
Scoreboard.BOARD_ORDER = { "territory", "pvp", "effort" }

-- Full cost of one unit (gold + wood + food), from the army's own table.
function Scoreboard.UnitCost(kind)
  local units = WF.Army and WF.Army.UNITS
  local unit = units and units[kind]
  if type(unit) ~= "table" then return 0 end
  return (unit.gold or 0) + (unit.wood or 0) + (unit.food or 0)
end

local function Num(value)
  if type(value) == "number" and value >= 0 and value == math.floor(value) then return value end
  return 0
end

-- Flat stats from a war record (or one of its guild buckets).
function Scoreboard.StatsFromRecord(record)
  local stats = {}
  if type(record) ~= "table" then return stats end
  local function Read(category, key)
    local counters = record[category]
    return type(counters) == "table" and Num(counters[key]) or 0
  end
  for kind, suffix in pairs(TYPE_SUFFIX) do
    stats["cap" .. suffix] = Read("capture", kind)
    stats["def" .. suffix] = Read("defense", kind)
  end
  for kind, suffix in pairs(UNIT_SUFFIX) do
    stats["atk" .. suffix] = Read("attack", kind)
    stats["gar" .. suffix] = Read("garrison", kind)
  end
  stats.atkS = Read("attack", "SCOUT")
  stats.gold, stats.wood = Read("chest", "gold"), Read("chest", "wood")
  stats.kills, stats.assists, stats.deaths = Read("pvp", "kills"), Read("pvp", "assists"), Read("pvp", "deaths")
  return stats
end

-- Every displayed column from flat stats. confirmed stays nil when unknown.
function Scoreboard.Columns(stats)
  stats = stats or {}
  local c = {}
  c.conquests = Num(stats.capO) * CAPTURE_POINTS.OUTPOST + Num(stats.capS) * CAPTURE_POINTS.SETTLEMENT
    + Num(stats.capC) * CAPTURE_POINTS.CAPITAL + Num(stats.capW) * CAPTURE_POINTS.WAR_CAMP
  c.defenses = Num(stats.defO) * DEFENSE_POINTS.OUTPOST + Num(stats.defS) * DEFENSE_POINTS.SETTLEMENT
    + Num(stats.defC) * DEFENSE_POINTS.CAPITAL + Num(stats.defW) * DEFENSE_POINTS.WAR_CAMP
  c.points = c.conquests + c.defenses
  if stats.conf ~= nil then c.confirmed = Num(stats.conf) end
  c.blows, c.assists, c.deaths = Num(stats.kills), Num(stats.assists), Num(stats.deaths)
  c.kills = c.blows + c.assists
  -- K/D = Kills / max(1, Deaths) (decision 0109 § 2): displayed, never ranked.
  c.kd = c.kills / math.max(1, c.deaths)
  c.chests = Num(stats.gold) + Num(stats.wood)
  c.attack, c.garrison = 0, 0
  for index = 1, #UNIT_ORDER do
    local kind = UNIT_ORDER[index]
    local cost = Scoreboard.UnitCost(kind)
    c.attack = c.attack + Num(stats["atk" .. UNIT_SUFFIX[kind]]) * cost
    c.garrison = c.garrison + Num(stats["gar" .. UNIT_SUFFIX[kind]]) * cost
  end
  -- Scouts are sent out like armies, never garrisoned (decision 0126 § 5).
  c.attack = c.attack + Num(stats.atkS) * Scoreboard.UnitCost("SCOUT")
  c.troops = c.attack + c.garrison
  c.effort = c.chests + c.troops
  return c
end

-- Import ------------------------------------------------------------------------

-- Developer-only (WarfrontDev /wfd boards): ranks in the import's shape shown
-- in place of the import and relayed copies; nil clears them. Display only:
-- held by this table in memory, never saved, never handed to WF.Boards (which
-- relays Worker-signed copies only) nor sent; /reload clears them.
function Scoreboard:SetSimulatedRanks(ranks)
  self.simulated = type(ranks) == "table" and ranks or nil
end

-- The ranks of the import, schema 8 or 9 as is (9 adds capW and defW), schema 7's PvP boards of the
-- permanent campaign mapped to the same shape; nil without an import.
function Scoreboard:Ranks()
  if self.simulated then return self.simulated end
  local import = WF.Import
  local data = import and import.status == "OK" and import.data
  -- Decision 0110: the newest verified Worker-signed copy, from the import or
  -- from a guild or group member; display only.
  local boards = WF.Boards
  local relayed = boards and boards.Ranks and boards:Ranks() or nil
  if type(data) ~= "table" then return relayed end
  if type(data.ranks) == "table" then
    local stamp = type(data.generatedAt) == "number" and data.generatedAt or 0
    -- A newer relayed copy takes the boards of its period; own and guild rows stay the import's.
    local function Pick(mine, theirs, version, sameCampaign)
      if not theirs or not version or (mine and (version <= stamp or not sameCampaign)) then return mine end
      local merged = {}
      for key, value in pairs(theirs) do merged[key] = value end
      if mine then merged.own, merged.mine = mine.own, mine.mine end
      return merged
    end
    local current = type(data.ranks.current) == "table" and data.ranks.current or nil
    local history = type(data.ranks.history) == "table" and data.ranks.history or nil
    if not relayed then return data.ranks end
    return {
      current = Pick(current, relayed.current, relayed.version,
        not current or not relayed.current or current.campaign == relayed.current.campaign),
      history = Pick(history, relayed.history, relayed.historyVersion, true),
    }
  end
  if relayed then return relayed end
  local pvp = data.pvp
  if type(pvp) ~= "table" then return nil end
  if self.mappedFrom == pvp then return self.mapped end
  local board = type(pvp.boards) == "table" and pvp.boards[PERMANENT] or {}
  local own = type(pvp.own) == "table" and pvp.own[PERMANENT] or nil
  local mine = type(pvp.guilds) == "table" and pvp.guilds[PERMANENT] or nil
  self.mappedFrom = pvp
  self.mapped = {
    current = {
      campaign = PERMANENT,
      players = { pvp = board.players or {} },
      guilds = { pvp = board.guilds or {} },
      own = own,
      mine = mine,
    },
  }
  return self.mapped
end

-- The running campaign's key, as the war record names it.
function Scoreboard.CampaignKey()
  local n = WF.Campaign and WF.Campaign:Current()
  if type(n) == "number" and n >= 1 then return string.format("%.0f", n) end
  return PERMANENT
end

-- The imported boards of a period, or nil. The current boards count only for
-- the running campaign, or the Worker's single campaign before numbered ones.
function Scoreboard:Period(period)
  local ranks = self:Ranks()
  if not ranks then return nil end
  if period == "history" then return type(ranks.history) == "table" and ranks.history or nil end
  local current = ranks.current
  if type(current) ~= "table" then return nil end
  if current.campaign ~= PERMANENT and current.campaign ~= Scoreboard.CampaignKey() then return nil end
  -- A relayed copy names its campaign start: another fork of N is not shown.
  local campaign = WF.Campaign
  if current.start and campaign and type(campaign.s) == "number" and current.start ~= campaign.s then return nil end
  return current
end

-- View --------------------------------------------------------------------------

local function Me()
  return WF.Capture and WF.Capture:Me() or nil
end

local function Region()
  return WF.Ruleset and WF.Ruleset.Region and WF.Ruleset:Region() or nil
end

local function RowFrom(source, who)
  local row = { stats = source, region = source.region }
  if who == "guilds" then
    row.key, row.name, row.faction = source.guild, source.name or source.guild, source.faction
  else
    row.key, row.name = source.char, source.char
    row.class, row.race, row.faction = source.class, source.race, source.faction
  end
  row.columns = Scoreboard.Columns(source)
  return row
end

local function Value(row, rankKey)
  return row.columns[rankKey] or 0
end

local SOURCE_FIELDS = { "char", "guild", "name", "region", "class", "race", "faction" }
local function SameSource(a, b)
  if not a or not b then return a == b end
  for index = 1, #STAT_KEYS do
    local key = STAT_KEYS[index]
    if a[key] ~= b[key] then return false end
  end
  for index = 1, #SOURCE_FIELDS do
    local key = SOURCE_FIELDS[index]
    if a[key] ~= b[key] then return false end
  end
  return true
end

local function SameOwn(a, b)
  if not a or not b then return a == b end
  return a.key == b.key and a.name == b.name and a.class == b.class and a.race == b.race
    and a.faction == b.faction and a.region == b.region and a.blank == b.blank
    and a.plus == b.plus and a.share == b.share and SameSource(a.stats, b.stats)
end

-- The rows of one board with the own row placed (0104 § 3, 0109 § 6):
-- view = { board, rankKey, rows = { row... }, own = row|nil, outside, gap,
--          plus, empty, updated }. row = { rank, name, region, class, race,
--          faction, columns, own }.
function Scoreboard:View(period, who, boardKey, sortKey)
  local board = BOARDS[boardKey] or BOARDS.territory
  sortKey = board.sorts[sortKey] and sortKey or board.default
  local listKey = board.sorts[sortKey]
  local rankKey = sortKey
  local data = self:Period(period)
  local view = { board = board, boardKey = boardKey, sortKey = sortKey, rankKey = rankKey, rows = {} }
  view.empty = data == nil
  view.updated = WF.Import and WF.Import.Age and WF.Import:Age() or nil

  local side = data and data[who]
  local list = type(side) == "table" and side[listKey] or nil
  local region = Region()
  local ownKey
  if who == "guilds" then
    ownKey = WF.WarRecord and WF.WarRecord:GuildKey() or nil
  else
    ownKey = Me()
  end

  -- The local record of the running campaign: own value now, "+X this campaign".
  local record = WF.WarRecord and WF.WarRecord:Current()
  local localStats
  if record then
    if who == "guilds" then
      local bucket = ownKey and type(record.guilds) == "table" and record.guilds[ownKey]
      if bucket then localStats = Scoreboard.StatsFromRecord(bucket) end
    else
      localStats = Scoreboard.StatsFromRecord(record)
    end
  end

  -- The own row's source: imported own/guild row, or the local record.
  local imported
  if data then
    if who == "guilds" then
      imported = ownKey and type(data.mine) == "table" and data.mine[ownKey] or nil
    else
      imported = type(data.own) == "table" and data.own or nil
    end
  end
  local own
  if period ~= "history" and who == "players" and localStats then
    -- Current campaign: local values, the imported Confirmed value.
    localStats.conf = imported and imported.conf or nil
    own = RowFrom(localStats, who)
    own.name, own.key, own.region = ownKey, ownKey, region
    local _, char = WF.WarRecord:Current()
    if type(char) == "table" then own.class, own.race, own.faction = char.class, char.race, char.faction end
  elseif imported then
    local copy = {}
    for key, value in pairs(imported) do copy[key] = value end
    copy.region = region
    if who == "guilds" then copy.guild = ownKey else copy.char = ownKey end
    own = RowFrom(copy, who)
  elseif ownKey and (who == "players" or localStats) then
    -- No imported value: the neutral empty row (and, for a guild, our share).
    own = RowFrom({}, who)
    own.key, own.name, own.region, own.blank = ownKey, ownKey, region, true
    if who == "players" and WF.WarRecord then
      local _, char = WF.WarRecord:Current()
      if type(char) == "table" then own.class, own.race, own.faction = char.class, char.race, char.faction end
    end
  end
  if own and who == "guilds" then
    local bucket = record and ownKey and type(record.guilds) == "table" and record.guilds[ownKey]
    if type(bucket) == "table" then
      if own.name == ownKey and bucket.name then own.name = bucket.name end
      own.faction = own.faction or bucket.faction
    end
    if localStats and own.blank and period ~= "history" then
      own.share = Value(RowFrom(localStats, who), rankKey)
    end
  end
  if own and period == "history" and localStats then
    own.plus = Value(RowFrom(localStats, who), rankKey)
  end
  if own then own.own = true end

  -- One bounded view. Scalar snapshots also detect in-place changes to local,
  -- imported or simulated rows; no pointer-only freshness assumption.
  local cached = self.viewCache
  local count = type(list) == "table" and #list or 0
  local same = cached and cached.period == period and cached.who == who
    and cached.boardKey == boardKey and cached.sortKey == sortKey and cached.empty == view.empty
    and cached.region == region and cached.ownKey == ownKey and #cached.sources == count
    and SameOwn(cached.own, own)
  if same then
    for index = 1, count do
      if not SameSource(cached.sources[index], list[index]) then same = false break end
    end
  end
  if same then
    cached.view.updated = view.updated -- Age keeps ticking without rebuilding rows.
    return cached.view
  end
  cached = { period = period, who = who, boardKey = boardKey, sortKey = sortKey,
    empty = view.empty, region = region, ownKey = ownKey, own = own, sources = {}, view = view }
  for index = 1, count do
    local copy = {}
    for key, value in pairs(list[index]) do copy[key] = value end
    cached.sources[index] = copy
  end

  -- Imported rows, without the own row (it is placed below).
  local rows = view.rows
  if type(list) == "table" then
    for index = 1, #list do
      local source = list[index]
      local key = who == "guilds" and source.guild or source.char
      if not (own and key == own.key and source.region == region) then
        rows[#rows + 1] = RowFrom(source, who)
      end
    end
  end
  if own then
    local mine = own.blank and 0 or Value(own, rankKey)
    local last = rows[TOP]
    if not own.blank and (#rows < TOP or mine >= Value(last, rankKey)) then
      local at = #rows + 1
      for index = 1, #rows do
        if mine > Value(rows[index], rankKey) then
          at = index
          break
        end
      end
      table.insert(rows, at, own)
      -- Past the bound, the last other row leaves; the own row always stays.
      while #rows > TOP do
        if rows[#rows].own then table.remove(rows, #rows - 1) else table.remove(rows) end
      end
    else
      view.outside = #rows >= TOP and not own.blank
      if view.outside then view.gap = Value(last, rankKey) - mine + 1 end
      view.own = own
    end
  end
  for index = 1, #rows do rows[index].rank = index end
  self.viewCache = cached
  return view
end

-- Display helpers -----------------------------------------------------------------

-- "1,234" for whole numbers, one decimal for K/D, "-" for an unknown value.
function Scoreboard.Format(columns, key)
  local value = columns and columns[key]
  if value == nil then return "-" end
  if key == "kd" then return string.format("%.1f", value) end
  local text = string.format("%.0f", value)
  local formatted = text
  while true do
    local before
    formatted, before = string.gsub(formatted, "^(%d+)(%d%d%d)", "%1,%2")
    if before == 0 then break end
  end
  return formatted
end

local RACE_ATLAS = { Scourge = "undead", NightElf = "nightelf", BloodElf = "bloodelf" }

local function Atlas(name)
  if not name or type(C_Texture) ~= "table" or type(C_Texture.GetAtlasInfo) ~= "function" then return nil end
  local ok, info = pcall(C_Texture.GetAtlasInfo, name)
  if ok and info then return name end
  return nil
end

-- Atlas names of a row's class and race icons, nil when unknown or missing.
function Scoreboard.ClassAtlas(class)
  if type(class) ~= "string" then return nil end
  return Atlas("classicon-" .. string.lower(class))
end

function Scoreboard.RaceAtlas(race)
  if type(race) ~= "string" then return nil end
  return Atlas("raceicon-" .. (RACE_ATLAS[race] or string.lower(race)) .. "-male")
end

-- The hex color (RRGGBB) of a class, a faction, or nil.
function Scoreboard.ClassColor(class)
  local colors = type(class) == "string" and RAID_CLASS_COLORS
  local color = type(colors) == "table" and colors[class]
  if type(color) == "table" and type(color.colorStr) == "string" and #color.colorStr == 8 then
    return string.sub(color.colorStr, 3)
  end
  return nil
end

local FACTION_COLORS = { Alliance = "408cff", Horde = "e64033" }
function Scoreboard.FactionColor(faction)
  return FACTION_COLORS[faction]
end

-- The name as drawn: class color for a player, faction color for a guild.
function Scoreboard.NameText(row, who)
  local color
  if who == "guilds" then color = Scoreboard.FactionColor(row.faction) else color = Scoreboard.ClassColor(row.class) end
  local name = tostring(row.name or "?")
  if color then return "|cff" .. color .. name .. "|r" end
  return name
end

-- "Updated 5m ago" or nil.
-- Decision 0110 § 6: while the companion does not help this player (no live
-- companion, no import younger than its stale age), the tab recommends it.
-- Independent of the map hint's on/off setting; never says how rankings travel.
Scoreboard.COMPANION_HINT = "Install the Warfront Companion for complete, up-to-date rankings."
function Scoreboard.CompanionHint()
  local companion = WF.Companion
  if companion and companion.Helping and companion:Helping() then return nil end
  return Scoreboard.COMPANION_HINT
end

function Scoreboard.UpdatedText(age)
  if type(age) ~= "number" then return nil end
  local span = WF.Campaign and WF.Campaign.Span
  if age < 60 then return "Updated just now" end
  if span then return "Updated " .. span(age) .. " ago" end
  return "Updated " .. math.floor(age / 60) .. " minutes ago"
end
