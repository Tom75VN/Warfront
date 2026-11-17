local WF = Warfront
local Window = WF.MainWindow

-- Main window (modules/main_window.lua): the Garrison and War pages.
-- The base file loads first and shares its constants and helpers through
-- Window.Kit. Keep every main_window file far below the 200-local limit
-- (.claude/forever-compatibility.md, Lua runtime).
local Kit = Window.Kit
local CONTENT_WIDTH = Kit.CONTENT_WIDTH
local CONTENT_HEIGHT = Kit.CONTENT_HEIGHT
local GAP = Kit.GAP
local RESOURCE_NAMES = Kit.RESOURCE_NAMES
local Paint = Kit.Paint
local FactionText = Kit.FactionText
local Duration = Kit.Duration
local AreaName = Kit.AreaName
local AreaZone = Kit.AreaZone
local MyFaction = Kit.MyFaction
local OtherFaction = Kit.OtherFaction
local UnitIcon = Kit.UnitIcon
local Skin = Kit.Skin
local Place = Kit.Place
local NewText = Kit.NewText
local SetText = Kit.SetText
local Show = Kit.Show
local NewPanel = Kit.NewPanel
local NewFrame = Kit.NewFrame
local Scroll = Kit.Scroll
local NewList = Kit.NewList
local FillList = Kit.FillList
local NewButton = Kit.NewButton
local SetAction = Kit.SetAction
local Collect = Kit.Collect
local PlayerDistanceContext = Kit.PlayerDistanceContext
local SortByPlayerDistance = Kit.SortByPlayerDistance
local ArmyTab = Kit.ArmyTab
local ArmySwitch = Kit.ArmySwitch
local RefreshArmySwitch = Kit.RefreshArmySwitch

-- Garrison --------------------------------------------------------------------

local Garrison = {}
Window.Garrison = Garrison

-- The Garrison tab only opens while the player stands in an Outpost or a
-- Settlement.
function Window.InGarrison()
  local area = WF.Presence and WF.Presence.current
  return area ~= nil and WF.Garrison ~= nil and WF.Garrison:Area(area.id) ~= nil
end

function Garrison:Build()
  ArmyTab.Backdrop(self)
  local panel = NewPanel(self, "Garrison", 0, 0, CONTENT_WIDTH, 64)
  self.icon = Skin():Icon(panel, nil, 40, 40)
  Place(self.icon, panel, 8, -22)
  SetText(NewText(panel, "GameFontDisableSmall", 56, -24, 60), "Held by")
  self.badge = Skin():Icon(panel, nil, 14, 16)
  Place(self.badge, panel, 56, -40)
  self.owner = NewText(panel, "GameFontHighlight", 74, -41, 120)
  local columns = { { "Level", 236 }, { "Garrison", 336 }, { "Capture time", 486 } }
  self.columns = {}
  local index = 1
  while index <= 3 do
    SetText(NewText(panel, "GameFontDisableSmall", columns[index][2], -24, 140), columns[index][1])
    self.columns[index] = NewText(panel, "GameFontHighlight", columns[index][2], -41, 140)
    index = index + 1
  end
  self.header = panel
  ArmySwitch(self, panel)

  local notice = NewFrame(self.frame, CONTENT_WIDTH, 26)
  Place(notice, self.frame, 0, -66 - ArmyTab.SHIFT)
  self.noticeBack = Skin():Slice3(notice, "row", 26, "BACKGROUND")
  self.noticeText = NewText(notice, "GameFontHighlightSmall", 24, -7, 430)
  self.yes = NewButton(notice, "red", 56, 22, "Yes", Window.Pledge)
  Place(self.yes, notice, 470, -2)
  self.no = NewButton(notice, "dark", 56, 22, "No", Window.CancelPledge)
  Place(self.no, notice, 530, -2)
  self.notice = notice

  panel = NewPanel(self, "Current Situation", 0, -94, CONTENT_WIDTH, 118)
  self.strips = {}
  local kinds = { { "strip.red", "icon.swords" }, { "strip.blue", "icon.shield" }, { "strip.gold", "icon.hourglass" } }
  index = 1
  while index <= 3 do
    local strip = NewFrame(panel, CONTENT_WIDTH - 12, 22)
    Place(strip, panel, 6, -24 - (index - 1) * 23)
    Skin():Slice3(strip, kinds[index][1], 22, "BACKGROUND")
    strip.icon = Skin():Icon(strip, kinds[index][2], 18, 18)
    Place(strip.icon, strip, 14, -2)
    strip.text = NewText(strip, "GameFontHighlight", 40, -4, 330)
    strip.right = NewText(strip, "GameFontHighlight", 380, -4, 200, "RIGHT")
    self.strips[index] = strip
    index = index + 1
  end
  self.calm = NewText(panel, "GameFontHighlightSmall", 14, -28, CONTENT_WIDTH - 30)
  local lock = Skin():Icon(panel, "icon.lock", 15, 18)
  Place(lock, panel, 12, -95)
  self.reinforce = NewText(panel, "GameFontHighlight", 34, -97, 180)
  self.reinforceWhy = NewText(panel, "GameFontHighlightSmall", 200, -98, 390)

  -- Cells 66 px high (2026-11-16, user: the tab fills its full height; 54,
  -- then 46 before), their contents in a 54 px box centred in the cell.
  panel = NewPanel(self, "Garrison Units", 0, -216, CONTENT_WIDTH, 96)
  self.unitsPanel = panel
  self.units = {}
  index = 1
  local cellWidth = math.floor((CONTENT_WIDTH - 12) / 3) - 4
  while index <= 3 do
    local row = NewFrame(panel, cellWidth, 66)
    Place(row, panel, 6 + (index - 1) * (cellWidth + 6), -24)
    Skin():RowBackground(row, 66)
    row.hover = Skin():RowStripe(row, Skin().HOVER_ALPHA)
    local box = NewFrame(row, cellWidth, 54)
    Place(box, row, 0, -6)
    row.portrait = Skin():Icon(box, nil, 28, 28)
    Place(row.portrait, box, 6, -13)
    row.name = NewText(box, "GameFontHighlight", 40, -11, cellWidth - 90)
    row.count = NewText(box, "GameFontHighlight", cellWidth - 50, -11, 44, "RIGHT")
    row.have = NewText(box, "GameFontHighlightSmall", 40, -32, 70)
    row.one = NewButton(box, "red", 40, 20, "+1")
    Place(row.one, box, cellWidth - 90, -26)
    row.five = NewButton(box, "red", 40, 20, "+5")
    Place(row.five, box, cellWidth - 48, -26)
    self.units[index] = row
    index = index + 1
  end
  Window.WatchHover(panel, self.units)

  -- 12 px lower, its lines spread over the gain (2026-11-16, user: full height).
  panel = NewPanel(self, "War Chest", 0, -316, CONTENT_WIDTH, CONTENT_HEIGHT - ArmyTab.SHIFT - 316)
  self.chestPanel = panel
  self.chest = {}
  local kindsChest = { { "gold", 100, 500 }, { "wood", 50, 100 } }
  local width = math.floor((CONTENT_WIDTH - 12) / 2)
  index = 1
  while index <= 2 do
    local cell = NewFrame(panel, width, 30)
    Place(cell, panel, 6 + (index - 1) * width, -25)
    cell.icon = Skin():Icon(cell, "icon." .. kindsChest[index][1], 24, 24)
    Place(cell.icon, cell, 4, -3)
    cell.value = NewText(cell, "GameFontHighlightSmall", 34, -2, 160)
    cell.bar = Skin():Bar(cell, 150, 10, kindsChest[index][1] == "gold" and "gold" or "brown")
    Place(cell.bar, cell, 34, -17)
    cell.small = NewButton(cell, "red", 52, 20, "+" .. kindsChest[index][2])
    Place(cell.small, cell, 190, -5)
    cell.large = NewButton(cell, "red", 52, 20, "+" .. kindsChest[index][3])
    Place(cell.large, cell, 244, -5)
    cell.kind, cell.smallCount, cell.largeCount = kindsChest[index][1], kindsChest[index][2], kindsChest[index][3]
    self.chest[index] = cell
    index = index + 1
  end
  -- 4 px higher since the sub-tabs moved down (2026-11-16): the panel is 6 px shorter.
  self.nextLevel = NewText(panel, "GameFontHighlightSmall", 12, -60, CONTENT_WIDTH - 24)
  local pouch = Skin():Icon(panel, "icon.pouch", 20, 20)
  Place(pouch, panel, 10, -82)
  self.effort = NewText(panel, "GameFontHighlightSmall", 36, -84, CONTENT_WIDTH - 50)
end

function Garrison:Update(now)
  RefreshArmySwitch(self)
  local garrison = WF.Garrison
  local area = WF.Presence and WF.Presence.current
  local view = garrison and area and garrison:View(area.id, now)
  if not view then
    SetText(self.header.title, "Garrison")
    SetText(self.owner, Paint("DIM", "Stand in an Outpost or a Settlement to see its garrison"))
    return
  end
  local mine = MyFaction()
  SetText(self.header.title, AreaName(view.area) .. "  " .. AreaZone(view.area))
  Window.SetPoiIcon(self.icon, view.area, view.owner)
  Skin():Apply(self.badge, view.owner == "A" and "badge.alliance" or view.owner == "H" and "badge.horde" or "badge.neutral")
  SetText(self.owner, FactionText(view.owner))
  SetText(self.columns[1], view.settlement and (view.level .. " / 3") or Paint("DIM", "-"))
  SetText(self.columns[2], view.used .. " / " .. view.capacity .. Paint("DIM", " Unit Size")
    .. (view.used >= view.capacity and Paint("BAD", " full") or ""))
  SetText(self.columns[3], view.captureDuration and Duration(view.captureDuration) or Paint("DIM", "-"))

  -- Confirmation, pending pledge or nothing.
  local confirm = Window.confirm
  local pending = garrison:Pending()
  if confirm and confirm.id == view.id then
    Skin():SetSlice3(self.noticeBack, "strip.gold")
    local preview = garrison:CapturePreview(confirm.kind, confirm.count, confirm.id)
    local timing = preview and (" Capture +" .. Duration(preview.added) .. " ("
      .. Duration(preview.before) .. " to " .. Duration(preview.after) .. ").") or ""
    SetText(self.noticeText, Paint("GOLD", "Give " .. confirm.count .. " " .. garrison:Name(confirm.kind, view.owner)
      .. "?" .. timing .. " Irreversible."))
    self.yes:Show()
    self.no:Show()
  elseif pending and pending.id == view.id then
    Skin():SetSlice3(self.noticeBack, "strip.gold")
    SetText(self.noticeText, Paint("DIM", "Waiting for the garrison keeper to accept " .. pending.count .. " "
      .. garrison:Name(pending.kind, pending.owner)))
    self.yes:Hide()
    self.no:Hide()
  else
    Skin():SetSlice3(self.noticeBack, "row")
    SetText(self.noticeText, Paint("DIM", "Garrison data: " .. view.source .. "."))
    self.yes:Hide()
    self.no:Hide()
  end

  -- Armies on their way and the post-combat lock (modules/attack.lua).
  local attack = WF.Attack
  local threat = attack and attack:TooltipInfo(view.id, now)
  local shown = 0
  local strip = self.strips[1]
  if threat and threat.enemy then
    shown = shown + 1
    SetText(strip.text, Paint("BAD", "Enemy army on its way"))
    SetText(strip.right, Paint("BAD", "Arrives in " .. Duration(threat.enemy)))
  end
  Show(strip, threat and threat.enemy)
  strip = self.strips[2]
  if threat and threat.allied then
    shown = shown + 1
    SetText(strip.text, Paint("A", "Allied army on its way"))
    SetText(strip.right, Paint("GOOD", "Arrives in " .. Duration(threat.allied.left)))
  end
  Show(strip, threat and threat.allied)
  strip = self.strips[3]
  if threat and threat.pending then
    shown = shown + 1
    SetText(strip.text, Paint("GOLD", "A battle here is waiting to be resolved"))
    SetText(strip.right, "")
  end
  Show(strip, threat and threat.pending)
  SetText(self.calm, shown == 0 and Paint("DIM", "No army on its way and no battle waiting here.") or "")
  local frozen = attack and attack:Freeze(view.id, now)
  -- Attackers inside a Settlement under siege block units too (decision 0082).
  if not frozen and WF.Garrison and WF.Garrison.SiegePressure and view.owner then
    frozen = WF.Garrison:SiegePressure(view.id, view.owner, now)
  end
  SetText(self.reinforce, "Reinforcements: " .. (frozen and Paint("BAD", "blocked") or Paint("GOOD", "open")))
  SetText(self.reinforceWhy, frozen and Paint("BAD", frozen) or "")

  local closed = garrison:Closed(view.area, now)
  local reserve = WF.Army and WF.Army:Reserve()
  local wallet = WF.Economy and WF.Economy:Wallet()
  SetText(self.unitsPanel.note, view.used .. " / " .. view.capacity .. " Unit Size   Defense " .. view.defense)
  local index = 1
  for index = 1, #self.units do
    local row = self.units[index]
    local key = garrison.UNIT_ORDER[index]
    UnitIcon(row.portrait, key, view.owner == "H" and "H" or view.owner == "A" and "A" or mine)
    SetText(row.name, garrison:Name(key, view.owner))
    SetText(row.count, "x" .. view[key])
    SetText(row.have, reserve and Paint("DIM", "you have " .. reserve[key]) or "")
    local open = not closed and not frozen
    Show(row.one, open)
    Show(row.five, open)
    SetAction(row.one, "+1", open and Window.AskPledge or nil, key, 1)
    SetAction(row.five, "+5", open and Window.AskPledge or nil, key, 5)
  end

  SetText(self.chestPanel.title, view.settlement and "War Chest" or "War Effort")
  index = 1
  while index <= 2 do
    local cell = self.chest[index]
    if view.settlement then
      local value, goal = view[cell.kind], cell.kind == "gold" and view.nextGold or view.nextWood
      SetText(cell.value, RESOURCE_NAMES[cell.kind] .. "  " .. value .. (goal and (" / " .. goal) or "")
        .. (wallet and Paint("DIM", "   you have " .. wallet[cell.kind]) or ""))
      Skin():SetBar(cell.bar, goal and goal > 0 and value / goal or 1, cell.kind == "gold" and "gold" or "brown")
      Show(cell.small, not closed)
      Show(cell.large, not closed)
      SetAction(cell.small, "+" .. cell.smallCount, not closed and Window.AskPledge or nil, cell.kind, cell.smallCount)
      SetAction(cell.large, "+" .. cell.largeCount, not closed and Window.AskPledge or nil, cell.kind, cell.largeCount)
      cell:Show()
    else
      cell:Hide()
    end
    index = index + 1
  end
  if not view.settlement then
    SetText(self.nextLevel, Paint("DIM", "Only Settlements take gold and wood, to reach levels 2 and 3."))
  elseif view.nextGold then
    SetText(self.nextLevel, Paint("DIM", "Level " .. (view.level + 1) .. " once both are reached: garrison capacity "
      .. view.nextCapacity))
  else
    SetText(self.nextLevel, Paint("GOOD", "Maximum level reached"))
  end
  if closed then
    SetText(self.effort, Paint("BAD", "Closed: ") .. closed)
  else
    SetText(self.effort, Paint("GOOD", "Open: ") .. "what you give can never be taken back")
  end
end

function Garrison:Summary()
  local last = WF.Garrison and WF.Garrison.last
  if last then return Paint(last.ok and "GOOD" or "BAD", last.text) end
  return ""
end

-- War -------------------------------------------------------------------------

local War = {}
Window.War = War

-- The attack being built (target POI and unit counts f, r, m): local until
-- the player confirms Send, then WF.Attack:Launch takes it as /wf attack does.
Window.army = { f = 0, r = 0, m = 0 }

local function Arrives(r, now)
  local left = r.depart + r.dur - now
  if left > 0 then return "Arrives in " .. Duration(left) end
  return "Battle pending"
end

local function Progress(r, now)
  if not r.dur or r.dur <= 0 then return 1 end
  return (now - r.depart) / r.dur
end

function War:Build()
  local panel = NewPanel(self, "Your Orders", 0, 0, CONTENT_WIDTH, 72)
  self.orders = {}
  local index = 1
  while index <= 2 do
    local row = NewFrame(panel, CONTENT_WIDTH - 12, 22)
    Place(row, panel, 6, -23 - (index - 1) * 23)
    Skin():RowBackground(row, 22)
    Show(Skin():RowStripe(row), index % 2 == 0)
    row.hover = Skin():RowStripe(row, Skin().HOVER_ALPHA)
    row.icon = Skin():Icon(row, nil, 18, 18)
    Place(row.icon, row, 6, -2)
    row.text = NewText(row, "GameFontHighlightSmall", 32, -4, 270)
    row.bar = Skin():Bar(row, 150, 10, "green")
    Place(row.bar, row, 306, -6)
    row.right = NewText(row, "GameFontHighlightSmall", 462, -4, 126, "RIGHT")
    self.orders[index] = row
    index = index + 1
  end
  Window.WatchHover(panel, self.orders)

  panel = NewPanel(self, "Attack Builder", 0, -76, CONTENT_WIDTH, 120)
  local swords = Skin():Icon(panel, "icon.swords", 22, 22)
  Place(swords, panel, 10, -24)
  self.capacity = NewText(panel, "GameFontHighlightSmall", 38, -24, 150)
  self.capacityBar = Skin():Bar(panel, 140, 10, "gold")
  Place(self.capacityBar, panel, 38, -38)
  self.from = NewText(panel, "GameFontHighlightSmall", 196, -24, 360)
  self.target = NewText(panel, "GameFontHighlightSmall", 196, -38, 360)
  self.targetIcon = Skin():Icon(panel, nil, 24, 24)
  Place(self.targetIcon, panel, 566, -22)
  self.cells = {}
  index = 1
  while index <= 3 do
    local cell = NewFrame(panel, 196, 26)
    Place(cell, panel, 6 + (index - 1) * 198, -54)
    Skin():RowBackground(cell, 26)
    cell.portrait = Skin():Icon(cell, nil, 20, 20)
    Place(cell.portrait, cell, 5, -3)
    cell.count = NewText(cell, "GameFontHighlightSmall", 30, -7, 100)
    cell.minus = NewButton(cell, "dark", 26, 20, "-")
    Place(cell.minus, cell, 132, -3)
    cell.plus = NewButton(cell, "dark", 26, 20, "+")
    Place(cell.plus, cell, 162, -3)
    self.cells[index] = cell
    index = index + 1
  end
  self.size = NewText(panel, "GameFontHighlightSmall", 12, -92, 150)
  self.clock = Skin():Icon(panel, "icon.clock", 14, 16)
  Place(self.clock, panel, 160, -90)
  self.travel = NewText(panel, "GameFontHighlightSmall", 178, -92, 130)
  self.warn = Skin():Icon(panel, "icon.warning", 14, 13)
  Place(self.warn, panel, 312, -91)
  self.reason = NewText(panel, "GameFontHighlightSmall", 330, -92, 180)
  self.send = NewButton(panel, "red", 74, 24, "Send", Window.AskLaunch)
  Place(self.send, panel, 520, -86)
  local confirm = NewFrame(panel, CONTENT_WIDTH - 12, 26)
  Place(confirm, panel, 6, -86)
  Skin():Slice3(confirm, "strip.gold", 26, "BACKGROUND")
  confirm:SetFrameLevel((panel:GetFrameLevel() or 0) + 3)
  self.confirmText = NewText(confirm, "GameFontHighlightSmall", 24, -7, 400)
  local yes = NewButton(confirm, "red", 56, 22, "Yes", Window.Launch)
  Place(yes, confirm, 456, -2)
  local no = NewButton(confirm, "dark", 56, 22, "No", Window.CancelLaunch)
  Place(no, confirm, 516, -2)
  self.confirm = confirm
  self.builder = panel

  -- Rows 26 px apart (24 before 2026-11-16, user: the tab fills the space the
  -- status strip left); 29 px since the tab reaches its full height (same
  -- day, user), their contents 3 px lower to stay centred, the Settlement
  -- Sieges panel keeping just its row and note at the bottom.
  local half = math.floor((CONTENT_WIDTH - GAP) / 2)
  local siegesHeight = 96
  local listHeight = CONTENT_HEIGHT - siegesHeight - GAP - 200
  local listRow = math.floor((listHeight - 27) / 4)
  panel = NewPanel(self, "Enemy Targets", 0, -200, half, listHeight)
  self.targets = NewList(panel, 4, listRow, -23, function(row)
    row.icon = Skin():Icon(row, nil, 20, 20)
    Place(row.icon, row, 3, -4)
    row.name = NewText(row, "GameFontHighlightSmall", 26, -8, 120)
    row.state = NewText(row, "GameFontHighlightSmall", 146, -8, 92)
    row.button = NewButton(row, "dark", 44, 20, "Scout")
    Place(row.button, row, half - 58 - Scroll.GUTTER, -4)
  end)
  self.targetIds = {}
  -- "none known" sits centred in the empty list (2026-11-16, user), not in the title bar.
  self.targets.panel.empty = NewText(self.targets.panel, "GameFontHighlightSmall", 0, -math.floor(listHeight / 2) - 6, half, "CENTER")
  panel = NewPanel(self, "Threats to Your Faction", half + GAP, -200, half, listHeight)
  self.threats = NewList(panel, 4, listRow, -23, function(row)
    row.icon = Skin():Icon(row, nil, 18, 18)
    Place(row.icon, row, 4, -5)
    row.name = NewText(row, "GameFontHighlightSmall", 26, -8, 130)
    row.state = NewText(row, "GameFontHighlightSmall", 156, -8, 130 - Scroll.GUTTER, "RIGHT")
  end)
  self.threats.panel.empty = NewText(self.threats.panel, "GameFontHighlightSmall", 0, -math.floor(listHeight / 2) - 6, half, "CENTER")
  self.threatList = {}
  self.threatPool = {}

  panel = NewPanel(self, "Settlement Sieges", 0, siegesHeight - CONTENT_HEIGHT, CONTENT_WIDTH, siegesHeight)
  self.sieges = NewList(panel, 1, 54, -23, function(row)
    row.icon = Skin():Icon(row, nil, 32, 32)
    Place(row.icon, row, 6, -9)
    row.name = NewText(row, "GameFontHighlight", 44, -10, 150)
    row.badge = Skin():Icon(row, nil, 12, 14)
    Place(row.badge, row, 44, -30)
    row.owner = NewText(row, "GameFontHighlightSmall", 60, -31, 120)
    row.checks = {}
    local c = 1
    while c <= 3 do
      local mark = Skin():Icon(row, nil, 12, 12)
      Place(mark, row, 200, -4 - (c - 1) * 16)
      row.checks[c] = { mark = mark, text = NewText(row, "GameFontHighlightSmall", 216, -4 - (c - 1) * 16, 370) }
      c = c + 1
    end
  end)
  self.siegeIds = {}
  self.siegeNote = NewText(panel, "GameFontDisableSmall", 10, -80, CONTENT_WIDTH - 20)
end

local function OrderRow(row, kind, order, now, faction)
  if order then
    UnitIcon(row.icon, kind == "scout" and "SCOUT" or "FOOTMAN", faction)
    row.icon:Show()
    if kind == "scout" then
      SetText(row.text, WF.Army:Name("SCOUT", faction) .. Paint("DIM", "  to  ") .. WF.Scout:Label(order.target))
    else
      SetText(row.text, "Army" .. Paint("DIM", "  to  ") .. WF.Attack:Label(order.target) .. Paint("DIM", "  ("
        .. WF.Attack.Composition(order, faction) .. ")"))
    end
    Skin():SetBar(row.bar, Progress(order, now), kind == "scout" and "green" or (faction == "H" and "red" or "blue"))
    row.bar:Show()
    SetText(row.right, Paint("GOOD", Arrives(order, now)))
  else
    row.icon:Hide()
    row.bar:Hide()
    SetText(row.text, Paint("DIM", kind == "scout" and "No scout travelling" or "No army marching"))
    SetText(row.right, "")
  end
end

local function TargetState(id, faction, now)
  local scout, attack = WF.Scout, WF.Attack
  local _, finish = scout:Discovery(id, faction, now)
  local info = attack:TooltipInfo(id, now)
  if info and info.pending then return Paint("GOLD", "Battle pending"), finish end
  if finish and Window.target == id then return Paint("GOLD", "Your target"), finish end
  if finish then return Paint("A", "Found (" .. Duration(finish - now) .. ")"), finish end
  local travelling = scout:Travelling(id, faction, now)
  if travelling then return Paint("GOOD", "Scout: " .. Duration(math.max(0, travelling.depart + travelling.dur - now))), nil end
  if info and info.locked then return Paint("DIM", "Locked " .. Duration(info.locked)), nil end
  return Paint("BAD", "Not scouted"), nil
end

function War:Update(now)
  local faction = MyFaction()
  local reserve = WF.Army and WF.Army:Reserve()
  if not WF.Scout or not WF.Attack or not WF.Map or not reserve or not faction then
    OrderRow(self.orders[1], "scout", nil, now, "A")
    SetText(self.orders[2].text, Paint("BAD", "Unavailable: no saved data, identity or faction yet"))
    return
  end
  local attack, scout, map, capture = WF.Attack, WF.Scout, WF.Map, WF.Capture
  OrderRow(self.orders[1], "scout", scout:Mine(now), now, faction)
  OrderRow(self.orders[2], "army", attack:Mine(now), now, faction)

  -- Attack builder.
  local army = Window.army
  local capacity = attack:AssaultCapacity(faction)
  local size = attack.Size(army)
  SetText(self.capacity, "Assault Capacity: " .. Paint(size > capacity and "BAD" or "WHITE", size .. " / " .. capacity))
  Skin():SetBar(self.capacityBar, capacity > 0 and size / capacity or 0, size > capacity and "red" or "gold")
  local origin, why = WF.Army:DeparturePlace()
  SetText(self.from, Paint("DIM", "Leave from: ") .. (origin and AreaName(origin) or Paint("BAD", why)))
  local target = Window.target and attack:Target(Window.target)
  SetText(self.target, Paint("DIM", "Target: ") .. (target and AreaName(target) or Paint("DIM", "pick a found target below")))
  Show(self.targetIcon, target ~= nil)
  if target then Window.SetPoiIcon(self.targetIcon, target, OtherFaction(faction)) end
  local index = 1
  for index = 1, #self.cells do
    local cell = self.cells[index]
    local key = attack.UNIT_ORDER[index]
    local count = army[attack.FIELDS[key]]
    UnitIcon(cell.portrait, key, faction)
    SetText(cell.count, WF.Army:Name(key, faction) .. " " .. Paint("GOLD", count) .. Paint("DIM", "/" .. reserve[key]))
    SetAction(cell.minus, "-", Window.ChangeArmy, key, -1, count > 0)
    SetAction(cell.plus, "+", Window.ChangeArmy, key, 1, count < reserve[key])
  end
  SetText(self.size, "Army size: " .. Paint(size > capacity and "BAD" or "GOOD", size .. " / " .. capacity)
    .. (size > capacity and Paint("BAD", " too large") or ""))
  -- The Front Network travel the order would take if it left now (0123 § 5).
  local duration = origin and target and (scout:DepartureTravel(origin, target, faction))
  SetText(self.travel, duration and ("Travel: " .. Duration(duration)) or Paint("DIM", "Travel: -"))
  if Window.launch then
    SetText(self.confirmText, Paint("GOLD", "Send " .. attack.Composition(army, faction) .. "? The units never come back."))
    self.confirm:Show()
  else
    self.confirm:Hide()
  end
  local ready, reason = false, "pick a target first"
  if target then ready, reason = attack:Check(target.id, army, now) end
  if ready then
    SetText(self.reason, Paint("BAD", "The units never come back"))
  else
    SetText(self.reason, Paint("BAD", "Cannot send: " .. tostring(reason)))
  end
  Skin():SetButton(self.send, "Send", ready and true or false)

  -- Enemy targets: places the other faction holds, confirmed or, on a neutral
  -- registry, as the map shows them (decision 0067).
  local enemy = OtherFaction(faction)
  local count = Collect(self.targetIds, function(id)
    return scout:Target(id) ~= nil and capture:TargetOwner(id, now) == enemy
  end)
  local distance = PlayerDistanceContext()
  SortByPlayerDistance(self.targetIds, count, distance)
  FillList(self.targets, count, function(row, item)
    local id = self.targetIds[item]
    local area = scout:Target(id)
    Window.SetPoiIcon(row.icon, area, enemy)
    SetText(row.name, AreaName(area))
    local state, found = TargetState(id, faction, now)
    SetText(row.state, state)
    if found and Window.target ~= id then
      SetAction(row.button, "Pick", Window.Pick, id)
      row.button:Show()
    elseif not found and not scout:Travelling(id, faction, now) then
      SetAction(row.button, "Scout", Window.SendScout, id)
      row.button:Show()
    else
      row.button:Hide()
    end
  end)
  SetText(self.targets.panel.empty, count == 0 and Paint("DIM", "none known") or "")

  -- Threats: enemy armies, battles and enemy scouts heading to our places.
  local threats, pool = self.threatList, self.threatPool
  local n = 0
  index = 1
  for index = 1, #map.order do
    local id = map.order[index]
    local area = scout:Target(id)
    if area and capture:GetOwner(id) == faction then
      local info = attack:TooltipInfo(id, now)
      local spy = scout:Travelling(id, enemy, now)
      local kinds = 0
      if info and info.enemy then kinds = 1 elseif info and info.pending then kinds = 2 end
      if kinds > 0 then
        n = n + 1
        pool[n] = pool[n] or {}
        pool[n].id, pool[n].kind, pool[n].left = id, kinds, info.enemy
        threats[n] = pool[n]
      end
      if spy then
        n = n + 1
        pool[n] = pool[n] or {}
        pool[n].id, pool[n].kind, pool[n].left = id, 3, spy.depart + spy.dur - now
        threats[n] = pool[n]
      end
    end
  end
  local extra = n + 1
  while threats[extra] do
    threats[extra] = nil
    extra = extra + 1
  end
  FillList(self.threats, n, function(row, item)
    local threat = threats[item]
    SetText(row.name, AreaName(map.areas[threat.id]))
    if threat.kind == 1 then
      Skin():Apply(row.icon, "icon.swords")
      SetText(row.state, Paint("BAD", "Army in " .. Duration(threat.left)))
    elseif threat.kind == 2 then
      Skin():Apply(row.icon, "icon.hourglass")
      SetText(row.state, Paint("GOLD", "Battle pending"))
    else
      Skin():Apply(row.icon, "icon.scout")
      SetText(row.state, Paint("BAD", "Scout in " .. Duration(math.max(0, threat.left))))
    end
  end)
  SetText(self.threats.panel.empty, n == 0 and Paint("DIM", "none known") or "")

  -- Settlement sieges: the Settlements the Active Front opens to the faction
  -- (decision 0098), or, without routes, every Settlement it does not hold.
  local front = WF.Front and WF.Front:HasRoutes() and WF.Front or nil
  count = Collect(self.siegeIds, function(id)
    local area = map.areas[id]
    if not area or not area.enabled or area.type ~= "SETTLEMENT" then return false end
    if front then return front:CanBesiege(id, faction, now) end
    return capture:GetOwner(id) ~= faction
  end)
  SortByPlayerDistance(self.siegeIds, count, distance)
  FillList(self.sieges, count, function(row, item)
    local id = self.siegeIds[item]
    local area = map.areas[id]
    local owner = capture:GetOwner(id)
    Window.SetPoiIcon(row.icon, area, owner)
    SetText(row.name, AreaName(area))
    Skin():Apply(row.badge, owner == "A" and "badge.alliance" or owner == "H" and "badge.horde" or "badge.neutral")
    SetText(row.owner, FactionText(owner))
    local all = capture:SiegeChecklist(id, faction, now)
    -- Every listed Settlement is on the front: its own line adds nothing.
    local list = {}
    for index = 1, #all do
      if not (all[index].ok and all[index].text == "On the active front") then list[#list + 1] = all[index] end
    end
    local c = 1
    while c <= 3 do
      local check = list[c]
      if check then
        Skin():Apply(row.checks[c].mark, check.ok and "icon.check" or "icon.cross")
        row.checks[c].mark:Show()
        SetText(row.checks[c].text, check.ok and check.text or Paint("BAD", check.text))
      else
        row.checks[c].mark:Hide()
        SetText(row.checks[c].text, "")
      end
      c = c + 1
    end
  end)
  if front then
    -- One short line per continent: the front's place or its running siege.
    SetText(self.siegeNote, Paint("DIM", table.concat(front:Lines(now), "  |  ")))
  elseif count == 0 then
    SetText(self.siegeNote, Paint("DIM", "Your faction holds every Settlement."))
  else
    SetText(self.siegeNote, "Then " .. capture.SIEGE_ATTACKERS .. " players of your faction standing inside start the siege.")
  end
end

function War:Summary()
  local faction = MyFaction()
  if not faction or not WF.Attack then return "" end
  return "Assault Capacity " .. WF.Attack:AssaultCapacity(faction)
end

Window:AddTab("garrison", "Garrison", Garrison, Window.InGarrison, true, "army")
Window:AddTab("war", "War", War)
