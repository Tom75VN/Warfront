Warfront = Warfront or {}

local WF = Warfront
local Window = { tabs = {}, order = {}, rows = {}, tabButtons = {}, offset = 0, elapsed = 0 }

WF.ClassicWindow = Window

-- Classic text-row window, kept as a backup of the textured window
-- (modules/main_window.lua) and opened by /wf classic. A tab only returns
-- rows; the window draws them in a fixed pool, once per second while shown.
-- A later work package adds its own tab with Window:AddTab. A local view: it
-- sends nothing itself; a confirmed pledge goes through WF.Garrison, a
-- scout or a confirmed attack through WF.Scout:Launch or WF.Attack:Launch.
local NAME = "WarfrontClassicWindow"
local WIDTH = 600
local ROWS = 20
local ROW_HEIGHT = 16
local LIST_TOP = -68
local LEFT_WITH_RIGHT = 270
local BUTTON_WIDTH = 44
local BUTTONS_PER_ROW = 2
local TAB_LEFT = 18
local REFRESH_INTERVAL = 1
local COLORS = {
  H = "e64033", A = "408cff", N = "b3b3b3",
  GOOD = "4dff4d", BAD = "ff5959", DIM = "999999", GOLD = "ffd100",
}
local RESOURCE_NAMES = { gold = "Gold", wood = "Wood", food = "Food" }

function Window:ApplyScale()
  if self.frame and type(self.frame.SetScale) == "function" then
    local factor = WF.Preferences and WF.Preferences:ScaleFactor() or 1
    self.frame:SetScale(factor)
  end
end
local SOURCE_LABELS = {
  LOCAL = "confirmed",
  PEER = "reported",
  STATIC = "not captured yet",
}
-- The held counts are strategic territory only; War Camps are listed but feed
-- the Front Network line instead (decision 0123 § 8).
local BALANCE_TYPES = { OUTPOST = true, SETTLEMENT = true }
local TERRITORY_TYPES = { OUTPOST = true, SETTLEMENT = true, WAR_CAMP = true }

Window.ROWS = ROWS

local function GetGlobal(name)
  if WF.Compat and WF.Compat.Global then return WF.Compat.Global(name) end
  if _G then return _G[name] end
  return nil
end

local function Now()
  return WF.Now and WF.Now() or 0
end

local function Paint(color, text)
  return "|cff" .. (COLORS[color] or COLORS.N) .. tostring(text) .. "|r"
end

local function FactionText(code)
  local names = WF.Capture and WF.Capture.FACTION_NAMES
  return Paint(code, names and names[code] or tostring(code))
end

local function Duration(seconds)
  seconds = math.ceil(seconds)
  if seconds < 60 then return seconds .. "s" end
  return string.format("%dm %02ds", math.floor(seconds / 60), (seconds % 60))
end

local function AreaTitle(area)
  local names = WF.Map and WF.Map.TYPE_NAMES
  local typeName = names and names[area.type] or tostring(area.type)
  return tostring(area.label or area.id) .. " " .. Paint("DIM", "(" .. typeName .. ", " .. tostring(area.map) .. ")")
end

local function Row(rows, left, right, buttons)
  rows[#rows + 1] = { left = left, right = right, buttons = buttons }
end

local function Header(rows, text)
  Row(rows, Paint("GOLD", text))
end

-- Tabs ------------------------------------------------------------------------

-- rows(now) returns a list of { left, right, buttons }, each button
-- { label, fn, a, b } calling fn(Window, a, b) on click. enabled(now), when
-- given, greys the tab out while it returns false.
function Window:AddTab(key, title, rows, enabled)
  if type(key) ~= "string" or self.tabs[key] or type(rows) ~= "function" then return false end
  if enabled ~= nil and type(enabled) ~= "function" then return false end
  self.tabs[key] = { key = key, title = title, rows = rows, enabled = enabled }
  self.order[#self.order + 1] = key
  if not self.selected then self.selected = key end
  if self.frame then self:BuildTabs() end
  return true
end

function Window.ResourceRows(now)
  local rows = {}
  local economy = WF.Economy
  local wallet = economy and economy:Wallet()
  Header(rows, "Your resources")
  if not wallet then
    Row(rows, "  " .. Paint("BAD", "Unavailable: no saved data or identity yet"))
  else
    for index = 1, #economy.RESOURCES do
      local resource = economy.RESOURCES[index]
      local cap = economy.CAPS[resource]
      local full = wallet[resource] >= cap and Paint("BAD", " full") or ""
      Row(rows, "  " .. RESOURCE_NAMES[resource], wallet[resource] .. " / " .. cap .. full)
    end
  end
  local stock = WF.Stock
  local hud = stock and stock:GetHud(now)
  Header(rows, "Gathering")
  if hud then
    Row(rows, "  " .. AreaTitle(hud.area), hud.resource.level .. " / " .. hud.resource.capacity)
    if hud.status == "IN" then
      Row(rows, "  " .. Paint("GOOD", "Gathering " .. stock.GATHER_AMOUNT .. " " .. hud.resource.resource
        .. " every " .. stock.GATHER_TICK .. "s" .. (hud.plunder and " (+30% enemy land)" or "")))
    else
      Row(rows, "  " .. Paint("BAD", "Not gathering: " .. tostring(hud.reason or "checking")))
    end
    Row(rows, "  " .. hud.resource.status)
  else
    Row(rows, "  " .. Paint("DIM", "Stand in a Gold Mine, Farm or Forest to gather, PvP flag on"))
  end
  local map = WF.Map
  if not stock or not map then return rows end
  Header(rows, "Resource stocks")
  for index = 1, #map.order do
    local id = map.order[index]
    local area = stock:Resource(id)
    local view = area and stock:View(id, now)
    if view then
      Row(rows, "  " .. AreaTitle(area), view.level .. " / " .. view.capacity
        .. (view.known and "" or Paint("DIM", " not observed")))
    end
  end
  return rows
end

function Window.ArmyRows(now)
  local rows = {}
  local army = WF.Army
  local reserve = army and army:Reserve()
  local wallet = WF.Economy and WF.Economy:Wallet()
  Header(rows, "Reserve")
  if not reserve or not wallet then
    Row(rows, "  " .. Paint("BAD", "Unavailable: no saved data or identity yet"))
    return rows
  end
  local used = army:Used(reserve)
  Row(rows, "  Unit Size used", used .. " / " .. army.RESERVE_CAPACITY
    .. (used >= army.RESERVE_CAPACITY and Paint("BAD", " full") or ""))
  local area, where = army:Place()
  if area then
    Row(rows, "  " .. Paint("GOOD", "Recruitment open: ") .. AreaTitle(area))
  else
    Row(rows, "  " .. Paint("BAD", "Recruitment closed: ") .. where)
  end
  Row(rows, "  " .. Paint("DIM", "You have " .. wallet.gold .. " gold, " .. wallet.wood .. " wood, "
    .. wallet.food .. " food. Costs are paid at recruitment."))
  Header(rows, "Units")
  for index = 1, #army.ORDER do
    local key = army.ORDER[index]
    local unit = army.UNITS[key]
    local stats = unit.scout and "scout, never fights"
      or ("ATK " .. unit.atk .. " DEF " .. unit.def .. ", " .. (army:CounterText(key) or ""))
    Row(rows, "  " .. army:Name(key) .. " x" .. reserve[key],
      unit.gold .. " gold " .. unit.wood .. " wood " .. unit.food .. " food",
      { { label = "+1", fn = Window.Recruit, a = key, b = 1 }, { label = "+5", fn = Window.Recruit, a = key, b = 5 } })
    Row(rows, "    " .. Paint("DIM", "Unit Size " .. unit.size .. ", " .. stats .. ", up to "
      .. army:MostAffordable(key, reserve, wallet) .. " now"))
  end
  return rows
end

function Window.TerritoryRows(now)
  local rows = {}
  local map, capture = WF.Map, WF.Capture
  Header(rows, "Territory held")
  if not map or not capture then
    Row(rows, "  " .. Paint("BAD", "Unavailable: map or capture not loaded"))
    return rows
  end
  local counts = { H = 0, A = 0, N = 0 }
  local here, others = {}, {}
  local zone = map.PlayerZoneKey and map:PlayerZoneKey() or nil
  local index = 1
  for index = 1, #map.order do
    local id = map.order[index]
    local area = map.areas[id]
    if area and area.enabled and TERRITORY_TYPES[area.type] then
      local list = area.mapKey == zone and here or others
      local owner, _, source = capture:GetOwner(id)
      local info = capture:TooltipInfo(id, now)
      local label = "not capturable yet"
      if capture:Capturable(id) then
        if BALANCE_TYPES[area.type] then counts[owner] = (counts[owner] or 0) + 1 end
        label = SOURCE_LABELS[source] or tostring(source)
      end
      Row(list, "  " .. AreaTitle(area), FactionText(owner) .. " " .. Paint("DIM", label))
      if info and info.hint then
        Row(list, "    " .. Paint("DIM", "Unconfirmed: ") .. FactionText(info.hint.owner) .. Paint("DIM", ", "
          .. info.hint.count .. " player(s), " .. Duration(info.hint.age) .. " ago"))
      end
      if info and info.cloud then
        local cloudLabel, code, detail = capture.CloudLine(info.cloud)
        Row(list, "    " .. Paint("DIM", cloudLabel .. ": ") .. (code and FactionText(code) or "")
          .. Paint("DIM", (code and detail and ", " or "") .. (detail or "")))
      end
      if info and info.challenger then
        local text = "    Capture by " .. FactionText(info.challenger) .. " " .. info.percent .. "%"
        if info.status then
          text = text .. ", " .. info.status .. (info.remaining and (" (" .. Duration(info.remaining) .. ")") or "")
        end
        Row(list, text)
      end
    end
  end
  Row(rows, "  " .. FactionText("H") .. " " .. counts.H .. "    " .. FactionText("A") .. " " .. counts.A
    .. "    " .. FactionText("N") .. " " .. counts.N)
  -- Front Network of the player's faction (decision 0123 § 8, amended
  -- 2026-11-15): one compact line per continent, from the accepted owners only.
  local network = WF.FrontNetwork
  local mine = WF.Capture and WF.Capture:MyFaction()
  if network and (mine == "H" or mine == "A") then
    for _, continent in ipairs(network.CONTINENTS) do
      local total = network:Total(continent)
      local text
      if total == 0 then
        text = Paint("DIM", "No War Camps")
      else
        local _, held, travel, capture = network:Get(continent, mine)
        text = FactionText(mine) .. " " .. held .. "/" .. total
          .. Paint("DIM", " (-" .. travel .. "% travel, -" .. capture .. "% capture)")
      end
      Row(rows, "  Front Network - " .. network.CONTINENT_NAMES[continent], text)
    end
  end
  Row(rows, "  " .. Paint("DIM", "Confirmed: you saw it. Other news may arrive late."))
  if #here > 0 then
    Header(rows, "Current zone")
    for index = 1, #here do
      rows[#rows + 1] = here[index]
    end
  end
  Header(rows, "Other zones")
  for index = 1, #others do
    rows[#rows + 1] = others[index]
  end
  Window.SyncRows(rows, now)
  return rows
end

-- Synchronization health and what the data labels mean: read from the
-- channel modules, nothing is sent.
function Window.SyncRows(rows, now)
  Header(rows, "Synchronization")
  local catchup = WF.Catchup
  local state, age = "waiting", nil
  if catchup and catchup.NewsState then state, age = catchup:NewsState(now) end
  if state == "live" then
    Row(rows, "  War news", Paint("GOOD", "live, last news " .. Duration(age) .. " ago"))
  elseif state == "quiet" then
    Row(rows, "  War news", Paint("GOLD", age and ("connected, last news " .. Duration(age) .. " ago")
      or "connected, no news yet"))
  else
    Row(rows, "  War news", Paint("BAD", "Waiting for other players to sync"))
  end
  if WF.Capture and not WF.Capture:CanTalk() then
    Row(rows, "  " .. Paint("BAD", "You cannot take part: " .. tostring(WF.Capture.LockReason and WF.Capture:LockReason()
      or WF.Capture.LEVEL_REASON)))
  end
  local pending = 0
  for code in pairs(catchup and catchup.pending or {}) do pending = pending + 1 end
  Row(rows, "  Map news", pending > 0 and Paint("GOLD", "updating") or "up to date")
  -- Activity meter (modules/traffic.lua): averages over its last minute.
  local traffic = WF.Traffic
  if traffic then
    Window.trafficIn, Window.trafficOut = Window.trafficIn or {}, Window.trafficOut or {}
    local totalIn, totalOut = traffic:Fill(Window.trafficIn, Window.trafficOut, now)
    Row(rows, "  Active players", traffic:ActivePlayers(now) .. Paint("DIM", ", received "
      .. traffic.Rate(totalIn / traffic.WINDOW) .. ", sent " .. traffic.Rate(totalOut / traffic.WINDOW)))
  end
  local queue = WF.SendQueue
  if queue then
    local dropped = queue.dropped or 0
    if dropped > 0 then
      Row(rows, "  " .. Paint("BAD", "Some recent actions may not have reached others."))
    elseif queue:Pending() > 0 then
      Row(rows, "  " .. Paint("DIM", "Your latest actions are on their way."))
    end
  end
  local version = WF.Version and WF.Version:Text()
  if version then
    Row(rows, "  " .. Paint("BAD", version))
  else
    Row(rows, "  Addon version", tostring(WF.version) .. Paint("DIM", ", no newer version seen"))
  end
  -- Optional companion (decision 0046): a tip only when it would help.
  local companion = WF.Companion
  if companion and companion.Helping then
    local reason = not companion:Helping() and companion:ShownHint(now)
    if companion:Helping() then
      Row(rows, "  Companion", Paint("GOOD", "in use"))
    elseif reason then
      Row(rows, "  Companion", Paint("GOLD", "recommended") .. Paint("DIM", " (optional)"))
      Row(rows, "  " .. Paint("DIM", companion.HINT_TEXTS[reason]))
      Row(rows, "  " .. Paint("DIM", companion.HINT_PITCH))
    else
      Row(rows, "  Companion", Paint("DIM", "optional, not in use"))
    end
  end
  Header(rows, "What the labels mean")
  Row(rows, "  " .. Paint("DIM", "confirmed: your own client watched it happen"))
  Row(rows, "  " .. Paint("DIM", "reported: captured while you were away"))
  Row(rows, "  " .. Paint("DIM", "unconfirmed: some players claim another owner"))
  Row(rows, "  " .. Paint("DIM", "not captured yet: no capture seen since login"))
end

-- The Garrison tab only opens while the player stands in an Outpost or a
-- Settlement.
function Window.InGarrison()
  local area = WF.Presence and WF.Presence.current
  return area ~= nil and WF.Garrison ~= nil and WF.Garrison:Area(area.id) ~= nil
end

local function PledgeButtons(kind, small, large)
  return { { label = "+" .. small, fn = Window.AskPledge, a = kind, b = small },
    { label = "+" .. large, fn = Window.AskPledge, a = kind, b = large } }
end

-- Garrison, level and War Chest of the place the player stands in
-- (modules/garrison.lua). A pledge asks for confirmation first: it is
-- irreversible.
function Window.GarrisonRows(now)
  local rows = {}
  local garrison = WF.Garrison
  local area = WF.Presence and WF.Presence.current
  local view = garrison and area and garrison:View(area.id, now)
  if not view then
    Header(rows, "Garrison")
    Row(rows, "  " .. Paint("DIM", "Stand in an Outpost or a Settlement to see its garrison"))
    return rows
  end
  Header(rows, AreaTitle(view.area))
  local confirm = Window.confirm
  if confirm and confirm.id == view.id then
    local preview = garrison:CapturePreview(confirm.kind, confirm.count, confirm.id)
    local timing = preview and (" Capture time +" .. Duration(preview.added) .. " ("
      .. Duration(preview.before) .. " to " .. Duration(preview.after) .. ").") or ""
    Row(rows, "  " .. Paint("GOLD", "Give " .. confirm.count .. " " .. garrison:Name(confirm.kind, view.owner)
      .. "?" .. timing .. " Irreversible."), nil,
      { { label = "Yes", fn = Window.Pledge }, { label = "No", fn = Window.CancelPledge } })
  end
  local pending = garrison:Pending()
  if pending and pending.id == view.id then
    Row(rows, "  " .. Paint("DIM", "Waiting for the garrison keeper to accept " .. pending.count .. " "
      .. garrison:Name(pending.kind, pending.owner)))
  end
  Row(rows, "  Held by", FactionText(view.owner))
  if view.settlement then Row(rows, "  Level", view.level .. " / 3") end
  Row(rows, "  Garrison", view.used .. " / " .. view.capacity .. " Unit Size"
    .. (view.used >= view.capacity and Paint("BAD", " full") or ""))
  Row(rows, "  Capture time", view.captureDuration and Duration(view.captureDuration) or Paint("DIM", "unknown"))
  Row(rows, "  Defense", tostring(view.defense))
  -- Armies on their way and the post-combat lock (modules/attack.lua).
  local attack = WF.Attack
  local threat = attack and attack:TooltipInfo(view.id, now)
  if threat and threat.enemy then
    Row(rows, "  " .. Paint("BAD", "Enemy army on its way"), "arrives in " .. Duration(threat.enemy))
  end
  if threat and threat.allied then
    Row(rows, "  Allied army on its way", "arrives in " .. Duration(threat.allied.left))
  end
  if threat and threat.pending then Row(rows, "  " .. Paint("BAD", "A battle here is waiting to be resolved")) end
  local frozen = attack and attack:Freeze(view.id, now)
  -- Attackers inside a Settlement under siege block units too (decision 0082).
  if not frozen and WF.Garrison and WF.Garrison.SiegePressure and view.owner then
    frozen = WF.Garrison:SiegePressure(view.id, view.owner, now)
  end
  Row(rows, "  Reinforcements", frozen and Paint("BAD", "blocked") or Paint("GOOD", "open"))
  if frozen then Row(rows, "    " .. Paint("BAD", frozen)) end
  local closed = garrison:Closed(view.area, now)
  local reserve = WF.Army and WF.Army:Reserve()
  local wallet = WF.Economy and WF.Economy:Wallet()
  Header(rows, "Garrison units")
  for index = 1, #garrison.UNIT_ORDER do
    local key = garrison.UNIT_ORDER[index]
    Row(rows, "  " .. garrison:Name(key, view.owner),
      "x" .. view[key] .. (reserve and Paint("DIM", "  you have " .. reserve[key]) or ""),
      not closed and not frozen and PledgeButtons(key, 1, 5) or nil)
  end
  if view.settlement then
    Header(rows, "War Chest")
    Row(rows, "  Gold", view.gold .. (view.nextGold and (" / " .. view.nextGold) or "")
      .. (wallet and Paint("DIM", "  you have " .. wallet.gold) or ""), not closed and PledgeButtons("gold", 100, 500) or nil)
    Row(rows, "  Wood", view.wood .. (view.nextWood and (" / " .. view.nextWood) or "")
      .. (wallet and Paint("DIM", "  you have " .. wallet.wood) or ""), not closed and PledgeButtons("wood", 50, 100) or nil)
    if view.nextGold then
      Row(rows, "  " .. Paint("DIM", "Level " .. (view.level + 1) .. " once both are reached: garrison capacity "
        .. view.nextCapacity))
    else
      Row(rows, "  " .. Paint("GOOD", "Maximum level reached"))
    end
  end
  Header(rows, "War Effort")
  if closed then
    Row(rows, "  " .. Paint("BAD", "Closed: ") .. closed)
  else
    Row(rows, "  " .. Paint("GOOD", "Open: ") .. "what you give can never be taken back")
  end
  local last = garrison.last
  if last then Row(rows, "  " .. Paint(last.ok and "GOOD" or "BAD", last.text)) end
  Row(rows, "  " .. Paint("DIM", "Garrison data: " .. view.source .. "."))
  return rows
end

-- War -------------------------------------------------------------------------

-- The attack being built (target POI and unit counts f, r, m): local until
-- the player confirms Send, then WF.Attack:Launch takes it as /wf attack does.
Window.army = { f = 0, r = 0, m = 0 }

local function Arrives(r, now)
  local left = r.depart + r.dur - now
  if left > 0 then return "arrives in " .. Duration(left) end
  return "battle pending"
end

local function OtherFaction(faction)
  if faction == "H" then return "A" end
  return "H"
end

local function OrderRows(rows, now, faction)
  Header(rows, "Your orders")
  local scout = WF.Scout:Mine(now)
  if scout then
    Row(rows, "  " .. WF.Army:Name("SCOUT", faction) .. " to " .. WF.Scout:Label(scout.target), Arrives(scout, now))
  else
    Row(rows, "  " .. Paint("DIM", "No scout travelling"))
  end
  local mine = WF.Attack:Mine(now)
  if mine then
    Row(rows, "  Army to " .. WF.Attack:Label(mine.target), Arrives(mine, now))
    Row(rows, "    " .. Paint("DIM", WF.Attack.Composition(mine, faction) .. ", gone from your reserve"))
  else
    Row(rows, "  " .. Paint("DIM", "No army marching"))
  end
end

local function BuilderRows(rows, now, faction, reserve)
  local attack, army = WF.Attack, Window.army
  local capacity = attack:AssaultCapacity(faction)
  Header(rows, "Attack builder")
  Row(rows, "  Assault Capacity", capacity .. " Unit Size")
  Row(rows, "    " .. Paint("DIM", "From " .. attack.ASSAULT.min .. " to " .. attack.ASSAULT.max
    .. ", it grows with the Settlements your faction holds"))
  local origin, why = WF.Army:DeparturePlace()
  Row(rows, "  Leave from: " .. (origin and AreaTitle(origin) or Paint("BAD", why)))
  local target = Window.target and attack:Target(Window.target)
  Row(rows, "  Target: " .. (target and AreaTitle(target) or Paint("DIM", "pick a discovered target below")))
  for index = 1, #attack.UNIT_ORDER do
    local key = attack.UNIT_ORDER[index]
    Row(rows, "  " .. WF.Army:Name(key, faction) .. " x" .. army[attack.FIELDS[key]],
      Paint("DIM", "you have " .. reserve[key]),
      { { label = "-1", fn = Window.ChangeArmy, a = key, b = -1 },
        { label = "+1", fn = Window.ChangeArmy, a = key, b = 1 } })
  end
  local size = attack.Size(army)
  Row(rows, "  Army size", size .. " / " .. capacity .. " Unit Size" .. (size > capacity and Paint("BAD", " too large") or ""))
  local duration = origin and target and (WF.Scout:DepartureTravel(origin, target, faction))
  if duration then Row(rows, "  Travel time", Duration(duration)) end
  if Window.launch then
    Row(rows, "  " .. Paint("GOLD", "Send " .. attack.Composition(army, faction) .. "? The units never come back."), nil,
      { { label = "Yes", fn = Window.Launch }, { label = "No", fn = Window.CancelLaunch } })
    return
  end
  if not target then
    Row(rows, "  " .. Paint("BAD", "Cannot send: ") .. "pick a target first")
    return
  end
  local ok, reason = attack:Check(target.id, army, now)
  if ok then
    Row(rows, "  " .. Paint("GOOD", "Ready to send"), nil, { { label = "Send", fn = Window.AskLaunch } })
  else
    Row(rows, "  " .. Paint("BAD", "Cannot send: ") .. tostring(reason))
  end
end

local function TargetRows(rows, now, faction)
  local map, capture, scout, attack = WF.Map, WF.Capture, WF.Scout, WF.Attack
  Header(rows, "Enemy targets")
  local count = 0
  for index = 1, #map.order do
    local id = map.order[index]
    local area = scout:Target(id)
    local owner = area and capture:TargetOwner(id, now)
    if owner == OtherFaction(faction) then
      count = count + 1
      local _, finish = scout:Discovery(id, faction, now)
      local travelling = scout:Travelling(id, faction, now)
      if finish and Window.target == id then
        Row(rows, "  " .. AreaTitle(area), Paint("GOLD", "your target") .. Paint("GOOD", ", " .. Duration(finish - now) .. " left"))
      elseif finish then
        Row(rows, "  " .. AreaTitle(area), Paint("GOOD", "discovered, " .. Duration(finish - now) .. " left"),
          { { label = "Pick", fn = Window.Pick, a = id } })
      elseif travelling then
        Row(rows, "  " .. AreaTitle(area), Paint("DIM", "scout " .. Arrives(travelling, now)))
      else
        Row(rows, "  " .. AreaTitle(area), Paint("DIM", "not scouted"), { { label = "Scout", fn = Window.SendScout, a = id } })
      end
      local info = attack:TooltipInfo(id, now)
      if info and info.allied then Row(rows, "    Allied army arrives in " .. Duration(info.allied.left)) end
      if info and info.pending then Row(rows, "    " .. Paint("GOLD", "A battle is waiting to be resolved")) end
      if info and info.locked then Row(rows, "    " .. Paint("DIM", "Reinforcements locked " .. Duration(info.locked))) end
    end
  end
  if count == 0 then Row(rows, "  " .. Paint("DIM", "No Outpost or Settlement known to be held by the enemy")) end
end

local function ThreatRows(rows, now, faction)
  local map, capture, scout, attack = WF.Map, WF.Capture, WF.Scout, WF.Attack
  Header(rows, "Threats to your faction")
  local count = 0
  for index = 1, #map.order do
    local id = map.order[index]
    local area = scout:Target(id)
    if area and capture:GetOwner(id) == faction then
      local info = attack:TooltipInfo(id, now)
      if info and info.enemy then
        Row(rows, "  " .. AreaTitle(area), Paint("BAD", "enemy army in " .. Duration(info.enemy)))
        count = count + 1
      elseif info and info.pending then
        Row(rows, "  " .. AreaTitle(area), Paint("GOLD", "battle pending"))
        count = count + 1
      end
      local spy = scout:Travelling(id, OtherFaction(faction), now)
      if spy then
        Row(rows, "  " .. AreaTitle(area), Paint("BAD", "enemy scout " .. Arrives(spy, now)))
        count = count + 1
      end
    end
  end
  if count == 0 then Row(rows, "  " .. Paint("DIM", "No enemy army or scout known on its way")) end
end

local function SiegeRows(rows, now, faction)
  local map, capture = WF.Map, WF.Capture
  -- The Active Fronts (decision 0098): where each continent stands.
  local front = WF.Front and WF.Front:HasRoutes() and WF.Front or nil
  if front then
    Header(rows, "Fronts")
    local lines = front:Lines(now)
    for index = 1, #lines do Row(rows, "  " .. lines[index]) end
  end
  Header(rows, "Settlement sieges")
  local count = 0
  for index = 1, #map.order do
    local id = map.order[index]
    local area = map.areas[id]
    local owner = capture:GetOwner(id)
    local open = area and area.enabled and area.type == "SETTLEMENT"
    if open and front then
      open = front:CanBesiege(id, faction, now)
    elseif open then
      open = owner ~= faction
    end
    if open then
      count = count + 1
      Row(rows, "  " .. AreaTitle(area), FactionText(owner))
      local list = capture:SiegeChecklist(id, faction, now)
      for item = 1, #list do
        local check = list[item]
        Row(rows, "    " .. (check.ok and Paint("GOOD", "[x] ") or Paint("BAD", "[  ] ")) .. check.text)
      end
      Row(rows, "    " .. Paint("DIM", "Then " .. capture.SIEGE_ATTACKERS
        .. " players of your faction standing inside start the siege"))
    end
  end
  if count == 0 then
    Row(rows, "  " .. Paint("DIM", front and "No Settlement is open to your faction on the fronts"
      or "Your faction holds every Settlement"))
  end
end

-- Orders, attack builder, scouting, threats and Settlement prerequisites
-- (modules/scout.lua, modules/attack.lua, Capture:SiegeChecklist).
function Window.WarRows(now)
  local rows = {}
  local faction = WF.Capture and WF.Capture:MyFaction()
  local reserve = WF.Army and WF.Army:Reserve()
  if not WF.Scout or not WF.Attack or not WF.Map or not reserve or (faction ~= "H" and faction ~= "A") then
    Header(rows, "War")
    Row(rows, "  " .. Paint("BAD", "Unavailable: no saved data, identity or faction yet"))
    return rows
  end
  OrderRows(rows, now, faction)
  BuilderRows(rows, now, faction, reserve)
  TargetRows(rows, now, faction)
  ThreatRows(rows, now, faction)
  SiegeRows(rows, now, faction)
  return rows
end

-- Scoreboard (decisions 0104, 0105, 0109): the rows of WF.Scoreboard as text.
Window.rank = { period = "current", who = "players", board = 1, sorts = {} }

function Window:SetRank(field, value)
  local rank = self.rank
  if field == "board" then
    local count = #WF.Scoreboard.BOARD_ORDER
    rank.board = (rank.board + value - 1) % count + 1
  elseif field == "sort" then
    local key = WF.Scoreboard.BOARD_ORDER[rank.board]
    rank.sorts[key] = value
  else
    rank[field] = value
  end
  self.offset = 0
  self:Refresh()
end

local function RankLine(item, view, who)
  local scoreboard = WF.Scoreboard
  local name = scoreboard.NameText(item, who)
  if item.own then name = name .. Paint("GOLD", " (you)") end
  if item.share then name = name .. Paint("DIM", " your part: " .. scoreboard.Format({ v = item.share }, "v")) end
  if item.plus and item.plus > 0 then
    name = name .. Paint("GOOD", " +" .. scoreboard.Format({ v = item.plus }, "v") .. " this campaign")
  end
  local values = {}
  for index = 1, #view.board.columns do
    local key = view.board.columns[index].key
    local text = item.blank and "-" or scoreboard.Format(item.columns, key)
    if key == view.rankKey then text = Paint("GOLD", text) end
    values[#values + 1] = text
  end
  local rank = item.rank and (tostring(item.rank) .. ". ") or "    "
  return "  " .. (item.own and Paint("GOLD", rank) or rank) .. name, table.concat(values, "   ")
end

function Window.RankRows(now)
  local rows = {}
  local scoreboard = WF.Scoreboard
  if not scoreboard then return rows end
  local rank = Window.rank
  local boardKey = scoreboard.BOARD_ORDER[rank.board]
  local view = scoreboard:View(rank.period, rank.who, boardKey, rank.sorts[boardKey])
  local board = view.board
  Row(rows, Paint("GOLD", rank.period == "history" and "History" or "Current campaign"), nil,
    { { label = "Now", fn = Window.SetRank, a = "period", b = "current" },
      { label = "All", fn = Window.SetRank, a = "period", b = "history" } })
  Row(rows, rank.who == "guilds" and "Guilds" or "Players", nil,
    { { label = "Plyr", fn = Window.SetRank, a = "who", b = "players" },
      { label = "Guild", fn = Window.SetRank, a = "who", b = "guilds" } })
  Row(rows, board.title, nil,
    { { label = "<", fn = Window.SetRank, a = "board", b = -1 }, { label = ">", fn = Window.SetRank, a = "board", b = 1 } })
  if board.sorts.points then
    local other = view.sortKey == "points" and "confirmed" or "points"
    Row(rows, "  Sorted by " .. (view.sortKey == "points" and "Points" or "Confirmed"), nil,
      { { label = "Sort", fn = Window.SetRank, a = "sort", b = other } })
  end
  local labels = {}
  for index = 1, #board.columns do labels[#labels + 1] = board.columns[index].label end
  Row(rows, Paint("GOLD", "  # " .. (rank.who == "guilds" and "Guild" or "Player")), Paint("GOLD", table.concat(labels, " / ")))
  if #view.rows == 0 and view.empty then Row(rows, "  " .. Paint("DIM", "No ranking received yet.")) end
  for index = 1, #view.rows do
    local left, right = RankLine(view.rows[index], view, rank.who)
    Row(rows, left, right)
  end
  if view.own then
    if view.outside then
      Row(rows, "  " .. Paint("DIM", "Outside the top 100 - " .. scoreboard.Format({ v = view.gap }, "v")
        .. " more to reach the top 100"))
    end
    local left, right = RankLine(view.own, view, rank.who)
    Row(rows, left, right)
  end
  Row(rows, "  " .. Paint("DIM", board.subtitle))
  local updated = scoreboard.UpdatedText(view.updated)
  if updated then Row(rows, "  " .. Paint("DIM", updated)) end
  -- Decision 0110 § 6: the Companion hint, highlighted.
  local hint = scoreboard.CompanionHint and scoreboard.CompanionHint()
  if hint then Row(rows, "  " .. Paint("GOLD", hint)) end
  return rows
end

function Window:ChangeArmy(key, delta)
  local reserve = WF.Army and WF.Army:Reserve()
  local field = WF.Attack and WF.Attack.FIELDS[key]
  if not reserve or not field then return end
  local n = self.army[field] + delta
  if n > reserve[key] then n = reserve[key] end
  if n < 0 then n = 0 end
  self.army[field] = n
  self.launch = nil
  self:SetStatus(nil)
  self:Refresh()
end

function Window:Pick(id)
  self.target = id
  self.launch = nil
  self:SetStatus("Target: " .. WF.Attack:Label(id), "GOOD")
  self:Refresh()
end

function Window:AskLaunch()
  local ok, reason = WF.Attack:Check(self.target or "", self.army, Now())
  if ok then
    self.launch = true
    self:SetStatus(nil)
  else
    self:SetStatus("Attack refused: " .. tostring(reason), "BAD")
  end
  self:Refresh()
end

function Window:CancelLaunch()
  self.launch = nil
  self:SetStatus("Attack cancelled", "DIM")
  self:Refresh()
end

-- Sends the army with the reserve's current attack number, so one
-- confirmation sends once (Attack:Launch, as /wf attack).
function Window:Launch()
  local confirmed = self.launch
  self.launch = nil
  local reserve = WF.Army and WF.Army:Reserve()
  local ok, result = false, "no saved data or identity yet"
  if not confirmed then
    result = "confirm the attack first"
  elseif reserve then
    ok, result = WF.Attack:Launch(self.target or "", { f = self.army.f, r = self.army.r, m = self.army.m }, reserve.aop)
  end
  if ok then
    self:SetStatus("Army sent to " .. WF.Attack:Label(result.target) .. ", arrives in " .. Duration(result.dur), "GOOD")
    self.army = { f = 0, r = 0, m = 0 }
    self.target = nil
  else
    self:SetStatus("Attack refused: " .. tostring(result), "BAD")
  end
  self:Refresh()
  return ok
end

-- Sends one scout with the reserve's current scouting number, so one click
-- sends once (Scout:Launch, as /wf scout).
function Window:SendScout(id)
  local reserve = WF.Army and WF.Army:Reserve()
  local ok, result = false, "no saved data or identity yet"
  if reserve then ok, result = WF.Scout:Launch(id, reserve.sop) end
  if ok then
    self:SetStatus(WF.Army:Name("SCOUT") .. " sent to " .. WF.Scout:Label(id) .. ", arrives in "
      .. Duration(result.dur), "GOOD")
  else
    self:SetStatus("Scout refused: " .. tostring(result), "BAD")
  end
  self:Refresh()
  return ok
end

-- Below level 5 ---------------------------------------------------------------

-- Shown on every tab but the Guide while Capture:CanTalk is false.
function Window.LockRows()
  local rows = {}
  local ok, level = pcall(GetGlobal("UnitLevel") or function() return nil end, "player")
  Header(rows, "Reach level 5 to join the conquest")
  if ok and type(level) == "number" and level > 0 then Row(rows, " You are level " .. level .. ".") end
  Row(rows, " Warfront opens at level 5; before that, what it would show")
  Row(rows, " could be wrong.")
  Row(rows, " You cannot capture, gather, send scouts or attack, and the world map")
  Row(rows, " and minimap show no conquest places.")
  Row(rows, " At level 5 you join automatically, no /reload needed.")
  Row(rows, " " .. Paint("DIM", "The Guide tab explains how the conquest works."))
  return rows
end

-- Guide -----------------------------------------------------------------------

-- The game loop for new players, one section per mechanic; the numbers come
-- from the modules that own them.
function Window.GuideRows(now)
  local rows = {}
  local stock, army, scout, capture = WF.Stock, WF.Army, WF.Scout, WF.Capture
  Header(rows, "1. Gather")
  Row(rows, "  In a Gold Mine, Forest or Farm, PvP flag on, you gain " .. stock.GATHER_AMOUNT
    .. " of its resource every " .. stock.GATHER_TICK .. "s.")
  Row(rows, "  " .. Paint("DIM", "Each place has one stock shared by everyone; it empties and slowly refills."))
  Header(rows, "2. Recruit")
  Row(rows, "  Inside your capital, or a Settlement or War Camp your faction holds, spend resources on units (Army tab).")
  Row(rows, "  " .. Paint("DIM", "Your reserve holds " .. army.RESERVE_CAPACITY
    .. " Unit Size; every cost, food included, is paid once at recruitment."))
  Header(rows, "3. Capture")
  Row(rows, "  Stay inside an enemy or neutral Outpost or War Camp with your PvP flag on until the bar is full.")
  Row(rows, "  " .. Paint("DIM", "A strong garrison slows the capture. A War Camp always takes 3 minutes."))
  Row(rows, "  " .. Paint("DIM", "War Camps your faction holds on a continent speed its scouts, armies and"
    .. " Outpost and Settlement captures there (Front Network, Territory tab)."))
  Header(rows, "4. Garrison")
  Row(rows, "  Give units to an Outpost or Settlement of your faction (Garrison tab): they defend it.")
  Row(rows, "  " .. Paint("DIM", "A gift never comes back. Settlements also take gold and wood to reach levels 2 and 3."))
  Header(rows, "5. Scout")
  Row(rows, "  From an allied place, send a scout to an enemy Outpost or Settlement (War tab).")
  Row(rows, "  " .. Paint("DIM", "On arrival your whole faction sees it for " .. math.floor(scout.DISCOVERY / 60)
    .. " minutes: attacks need it."))
  Header(rows, "6. Attack")
  Row(rows, "  Pick a discovered target, choose units within your Assault Capacity and send them.")
  Row(rows, "  " .. Paint("DIM", "They travel, fight once on arrival and never come back."))
  Row(rows, "  " .. Paint("DIM", "Killing defenders locks the reinforcements of that place for a while."))
  Header(rows, "7. Conquer a Settlement")
  Row(rows, "  Hold every Outpost of its zone and scout it; its garrison never blocks the attempt.")
  Row(rows, "  " .. Paint("DIM", "Then " .. capture.SIEGE_ATTACKERS
    .. " players stand inside. The garrison changes the capture time; the War tab shows what is missing."))
  Header(rows, "A living world")
  Row(rows, "  The war moves as players play: captures, armies and stocks change all the time.")
  Row(rows, "  " .. Paint("DIM", "Some news can arrive late. The Territory tab shows how fresh it is."))
  Header(rows, "Better sync with the Companion (optional)")
  Row(rows, "  The Warfront Companion keeps your map up to date between sessions.")
  Row(rows, "  " .. Paint("DIM", "On WoW: Forever it updates Warfront while the game is closed. Warfront works fully without it."))
  return rows
end

function Window:AskPledge(kind, count)
  local area = WF.Presence and WF.Presence.current
  local garrison = WF.Garrison
  local valid, reason = garrison and garrison:Check(kind, count)
  if not area or not valid then
    self.confirm = nil
    self:SetStatus("Pledge refused: " .. tostring(reason or "you are not inside a garrison"), "BAD")
    self:Refresh()
    return false
  end
  self.confirm = area and { id = area.id, kind = kind, count = count } or nil
  self:SetStatus(nil)
  self:Refresh()
  return true
end

function Window:CancelPledge()
  self.confirm = nil
  self:SetStatus("Pledge cancelled", "DIM")
  self:Refresh()
end

-- Pledges with the reserve's current pledge number, so one confirmation
-- pledges once (modules/garrison.lua, Garrison:Pledge).
function Window:Pledge()
  local confirm = self.confirm
  self.confirm = nil
  local garrison = WF.Garrison
  local area = WF.Presence and WF.Presence.current
  local reserve = WF.Army and WF.Army:Reserve()
  local ok, result = false, "no saved data or identity yet"
  if not confirm or not area or area.id ~= confirm.id then
    result = "you are no longer in the same place"
  elseif garrison and reserve then
    ok, result = garrison:Pledge(confirm.kind, confirm.count, reserve.gop)
  end
  if ok and result == "sent" then
    self:SetStatus("Pledge sent: waiting for the garrison keeper", "GOOD")
  elseif ok then
    self:SetStatus("Pledged " .. confirm.count .. " " .. garrison:Name(confirm.kind, garrison:View(confirm.id).owner), "GOOD")
  else
    self:SetStatus("Pledge refused: " .. tostring(result), "BAD")
  end
  self:Refresh()
  return ok
end

-- Recruits through WF.Army with the reserve's current operation number, so one
-- click recruits once (modules/army.lua, Army:Recruit).
function Window:Recruit(key, count)
  local army = WF.Army
  local reserve = army and army:Reserve()
  local ok, reason = false, "no saved data or identity yet"
  if reserve then ok, reason = army:Recruit(key, count, reserve.op) end
  if ok then
    self:SetStatus("Recruited " .. count .. " " .. army:Name(key) .. ", reserve " .. army:Used(reserve)
      .. " / " .. army.RESERVE_CAPACITY, "GOOD")
  else
    self:SetStatus("Recruitment refused: " .. tostring(reason), "BAD")
  end
  self:Refresh()
  return ok
end

-- Frame -----------------------------------------------------------------------

local function NewText(frame, template)
  local text = frame:CreateFontString(nil, "OVERLAY", template)
  text:SetJustifyH("LEFT")
  return text
end

function Window:BuildTabs()
  local frame = self.frame
  local create = GetGlobal("CreateFrame")
  local index = #self.tabButtons + 1
  while index <= #self.order do
    local button = create("Button", NAME .. "Tab" .. index, frame, "UIPanelButtonTemplate")
    button:SetHeight(22)
    button:SetText(WF.L(self.tabs[self.order[index]].title))
    button.tabKey = self.order[index]
    button:SetScript("OnClick", function(self) Window:Select(self.tabKey) end)
    if button.tabKey == "garrison" then
      local hit = create("Frame", nil, frame)
      hit:SetAllPoints(button)
      hit:SetFrameLevel((button:GetFrameLevel() or 0) + 1)
      hit:EnableMouse(true)
      hit:SetScript("OnEnter", function(self)
        local tooltip = GetGlobal("GameTooltip")
        if not tooltip then return end
        tooltip:SetOwner(self, "ANCHOR_BOTTOM")
  tooltip:AddLine(WF.L("Garrison unavailable"), 1, 1, 1)
  tooltip:AddLine(WF.L("Visit an Outpost or Settlement to manage its garrison."), 0.8, 0.8, 0.8, 1)
        tooltip:Show()
      end)
      hit:SetScript("OnLeave", function()
        local tooltip = GetGlobal("GameTooltip")
        if tooltip then tooltip:Hide() end
      end)
      hit:Hide()
      button.disabledTip = hit
    end
    self.tabButtons[#self.tabButtons + 1] = button
    index = index + 1
  end
  WF.Skin:SizeTranslatedTabs(frame, self.tabButtons, self.tabs, WIDTH - 2 * TAB_LEFT, 4)
  local left = TAB_LEFT
  for index = 1, #self.tabButtons do
    local button = self.tabButtons[index]
    button:ClearAllPoints()
    button:SetPoint("TOPLEFT", frame, "TOPLEFT", left, -36)
    left = left + button:GetWidth() + 4
  end
end

function Window:BuildRow(index)
  local frame = self.frame
  local create = GetGlobal("CreateFrame")
  local y = LIST_TOP - (index - 1) * ROW_HEIGHT
  local slot = { left = NewText(frame, "GameFontHighlightSmall"), right = NewText(frame, "GameFontHighlightSmall"),
    buttons = {}, y = y }
  slot.left:SetPoint("TOPLEFT", frame, "TOPLEFT", 20, y)
  slot.right:SetJustifyH("RIGHT")
  local column = 1
  while column <= BUTTONS_PER_ROW do
    local button = create("Button", NAME .. "Row" .. index .. "Button" .. column, frame, "UIPanelButtonTemplate")
    button:SetWidth(BUTTON_WIDTH)
    button:SetHeight(16)
    button:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -20 - (BUTTONS_PER_ROW - column) * (BUTTON_WIDTH + 2), y + 2)
    button:SetScript("OnClick", function(self) Window:Click(self) end)
    button:Hide()
    slot.buttons[column] = button
    column = column + 1
  end
  self.rows[index] = slot
end

function Window:Build()
  if self.frame then return self.frame end
  local create = GetGlobal("CreateFrame")
  if type(create) ~= "function" then return nil end
  local ok, frame = pcall(create, "Frame", NAME, UIParent, "BackdropTemplate")
  if not ok or not frame then return nil end
  self.frame = frame
  self:ApplyScale()
  frame:SetWidth(WIDTH)
  frame:SetHeight(-LIST_TOP + ROWS * ROW_HEIGHT + 40)
  frame:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
  frame:SetFrameStrata("HIGH")
  frame:SetToplevel(true)
  frame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
  })
  frame:EnableMouse(true)
  frame:SetMovable(true)
  frame:SetClampedToScreen(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
  frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
  frame:EnableMouseWheel(true)
  frame:SetScript("OnMouseWheel", function(_, delta) Window:Scroll(delta) end)
  frame:SetScript("OnShow", function() Window:Refresh() end)
  frame:SetScript("OnUpdate", function(_, elapsed) Window:OnUpdate(elapsed) end)

  local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOP", frame, "TOP", 0, -16)
  title:SetText("|cfff5ae0aWarfront|r |cff999999" .. WF.L("(classic)") .. "|r")
  local close = create("Button", NAME .. "Close", frame, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -6, -6)

  local index = 1
  while index <= ROWS do
    self:BuildRow(index)
    index = index + 1
  end
  self.status = NewText(frame, "GameFontHighlightSmall")
  self.status:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 20, 18)
  self.status:SetWidth(WIDTH - 140)
  self.page = NewText(frame, "GameFontDisableSmall")
  self.page:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -20, 18)
  self.page:SetJustifyH("RIGHT")
  self:BuildTabs()

  -- Escape closes the frames listed in UISpecialFrames (FrameXML UIParent.lua).
  local special = GetGlobal("UISpecialFrames")
  if type(special) == "table" then special[#special + 1] = NAME end
  frame:Hide()
  return frame
end

function Window:Render(rows)
  local total = #rows
  local most = total - ROWS
  if most < 0 then most = 0 end
  if self.offset > most then self.offset = most end
  if self.offset < 0 then self.offset = 0 end
  local index = 1
  while index <= ROWS do
    local slot = self.rows[index]
    local row = rows[self.offset + index] or {}
    local buttons = row.buttons and #row.buttons or 0
    local right = row.right or ""
    slot.left:SetText(WF.L and WF.L(row.left or "") or row.left or "")
    slot.left:SetWidth(right ~= "" and LEFT_WITH_RIGHT or WIDTH - 40)
    slot.right:SetText(WF.L and WF.L(right) or right)
    slot.right:ClearAllPoints()
    slot.right:SetPoint("TOPRIGHT", self.frame, "TOPRIGHT", -20 - buttons * (BUTTON_WIDTH + 2), slot.y)
    slot.right:SetWidth(WIDTH - 44 - LEFT_WITH_RIGHT - buttons * (BUTTON_WIDTH + 2))
    local column = 1
    while column <= BUTTONS_PER_ROW do
      local button = slot.buttons[column]
      -- Buttons are right-aligned: the last action takes the last column.
      local action = row.buttons and row.buttons[column - (BUTTONS_PER_ROW - buttons)]
      button.action = action
      if action then
        button:SetText(WF.L and WF.L(action.label) or action.label)
        button:Show()
      else
        button:Hide()
      end
      column = column + 1
    end
    index = index + 1
  end
  if total > ROWS then
    local last = self.offset + ROWS
    local page = (self.offset + 1) .. "-" .. last .. " of " .. total .. ", scroll for more"
    self.page:SetText(WF.L and WF.L(page) or page)
  else
    self.page:SetText("")
  end
end

function Window:Refresh()
  if not self.frame then return end
  local now = Now()
  local tab = self.tabs[self.selected]
  if tab and not self:TabEnabled(tab, now) then
    -- The place that opened this tab was left: back to the first tab.
    self.selected, self.offset, self.confirm = self.order[1], 0, nil
    tab = self.tabs[self.selected]
  end
  if not tab then return end
  local build = tab.rows
  -- Below level 5 every tab but the Guide shows the level notice (decision 0039).
  if tab.key ~= "guide" and WF.Capture and WF.Capture.CanTalk and not WF.Capture:CanTalk() then
    build = Window.LockRows
  end
  local ok, rows = pcall(build, now)
  if not ok or type(rows) ~= "table" then
    if WF.RecordError then WF.RecordError("classic window " .. tab.key, rows) end
    rows = { { left = Paint("BAD", "This tab failed: " .. tostring(rows)) } }
  end
  self:Render(rows)
  for index = 1, #self.tabButtons do
    local button = self.tabButtons[index]
    if button.tabKey == self.selected then button:LockHighlight() else button:UnlockHighlight() end
    button.tabEnabled = self:TabEnabled(self.tabs[button.tabKey], now)
    if button.tabEnabled then button:Enable() else button:Disable() end
    if button.disabledTip then
      if button.tabEnabled then button.disabledTip:Hide() else button.disabledTip:Show() end
    end
  end
end

function Window:TabEnabled(tab, now)
  if not tab.enabled then return true end
  local ok, enabled = pcall(tab.enabled, now)
  return ok and enabled and true or false
end

function Window:OnUpdate(elapsed)
  self.elapsed = self.elapsed + (elapsed or 0)
  if self.elapsed < REFRESH_INTERVAL then return end
  self.elapsed = 0
  self:Refresh()
end

function Window:Scroll(delta)
  if type(delta) ~= "number" then return end
  if delta > 0 then self.offset = self.offset - 1 else self.offset = self.offset + 1 end
  self:Refresh()
end

function Window:Click(button)
  local action = button and button.action
  if action and type(action.fn) == "function" then action.fn(self, action.a, action.b) end
end

function Window:SetStatus(text, color)
  if self.status then self.status:SetText(text and Paint(color, text) or "") end
end

function Window:Select(key)
  if not self.tabs[key] or not self:TabEnabled(self.tabs[key], Now()) then return false end
  self.selected = key
  self.offset = 0
  self:SetStatus(nil)
  self:Refresh()
  return true
end

-- /wf classic
function Window:Toggle()
  local frame = self:Build()
  if not frame then
    WF.Print(WF.L("The classic Warfront window is unavailable."))
    return false
  end
  if frame:IsShown() then frame:Hide() else frame:Show() end
  return true
end

Window:AddTab("map", "Territory", Window.TerritoryRows)
Window:AddTab("res", "Resources", Window.ResourceRows)
Window:AddTab("army", "Army", Window.ArmyRows)
Window:AddTab("garrison", "Garrison", Window.GarrisonRows, Window.InGarrison)
Window:AddTab("war", "War", Window.WarRows)
Window:AddTab("ranks", "Ranks", Window.RankRows)
Window:AddTab("guide", "Guide", Window.GuideRows)
