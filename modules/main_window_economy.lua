local WF = Warfront
local Window = WF.MainWindow

-- Main window (modules/main_window.lua): the Resources and Army pages.
-- The base file loads first and shares its constants and helpers through
-- Window.Kit. Keep every main_window file far below the 200-local limit
-- (.claude/forever-compatibility.md, Lua runtime).
local Kit = Window.Kit
local CONTENT_WIDTH = Kit.CONTENT_WIDTH
local CONTENT_HEIGHT = Kit.CONTENT_HEIGHT
local RESOURCE_NAMES = Kit.RESOURCE_NAMES
local Paint = Kit.Paint
local AreaName = Kit.AreaName
local AreaZone = Kit.AreaZone
local MyFaction = Kit.MyFaction
local UnitIcon = Kit.UnitIcon
local Skin = Kit.Skin
local Place = Kit.Place
local NewText = Kit.NewText
local SetText = Kit.SetText
local Show = Kit.Show
local NewPanel = Kit.NewPanel
local NewFrame = Kit.NewFrame
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

local RESOURCE_ORDER = { "gold", "wood", "food" }
local RESOURCE_FILLS = { gold = "gold", wood = "brown", food = "red" }
-- Resources -------------------------------------------------------------------

local Resources = {}
Window.Resources = Resources

function Resources:Build()
  local cellWidth = math.floor((CONTENT_WIDTH - 12) / 3)
  local panel = NewPanel(self, "Your Resources", 0, 0, CONTENT_WIDTH, 66)
  self.cells = {}
  local index = 1
  while index <= 3 do
    local cell = NewFrame(panel, cellWidth, 40)
    Place(cell, panel, 6 + (index - 1) * cellWidth, -23)
    cell.icon = Skin():Icon(cell, nil, 30, 30)
    Place(cell.icon, cell, 4, -4)
    cell.name = NewText(cell, "GameFontHighlight", 40, -3)
    cell.value = NewText(cell, "GameFontHighlight", 40, -3, cellWidth - 50, "RIGHT")
    cell.bar = Skin():Bar(cell, cellWidth - 50, 12, "gold")
    Place(cell.bar, cell, 40, -22)
    if index > 1 then
      local divider = Skin():Icon(cell, "divider.v", 3, 36, "BORDER")
      Place(divider, cell, -3, -2)
    end
    self.cells[index] = cell
    index = index + 1
  end
  self.cellsPanel = panel

  panel = NewPanel(self, "Gathering", 0, -70, CONTENT_WIDTH, 70)
  self.gatherIcon = Skin():Icon(panel, nil, 40, 40)
  Place(self.gatherIcon, panel, 10, -24)
  self.gatherName = NewText(panel, "GameFontHighlight", 14, -26, 290)
  self.gatherStock = NewText(panel, "GameFontHighlight", 310, -26, 120)
  self.gatherState = NewText(panel, "GameFontHighlightSmall", 430, -27, 166, "RIGHT")
  self.gatherHint = NewText(panel, "GameFontHighlightSmall", 58, -46, CONTENT_WIDTH - 70)
  self.gatherPanel = panel

  -- Nine rows as tall as the panel allows (29 px since 2026-11-16, user: the
  -- tab fills the space the status strip left).
  panel = NewPanel(self, "Resource Stocks", 0, -144, CONTENT_WIDTH, CONTENT_HEIGHT - 144)
  self.stocks = NewList(panel, 9, (CONTENT_HEIGHT - 144 - 26) / 9, -24, function(row)
    row.icon = Skin():Icon(row, nil, 24, 24)
    Place(row.icon, row, 4, -1)
    -- Same small font as the Territory list (2026-11-16, user). Columns fit
    -- the 588 px row (panel minus the scrollbar gutter) so "not observed"
    -- shows whole.
    row.name = NewText(row, "GameFontHighlightSmall", 34, -7, 214)
    row.value = NewText(row, "GameFontHighlightSmall", 252, -7, 70, "RIGHT")
    row.bar = Skin():Bar(row, 150, 12, "gold")
    Place(row.bar, row, 332, -7)
    row.state = NewText(row, "GameFontHighlightSmall", 490, -7, 94)
  end)
  self.stockIds = {}
end

function Resources:Update(now)
  local economy = WF.Economy
  local wallet = economy and economy:Wallet()
  local index = 1
  while index <= 3 do
    local cell = self.cells[index]
    local resource = economy and economy.RESOURCES[index]
    if wallet and resource then
      local cap = economy.CAPS[resource]
      Skin():Apply(cell.icon, "icon." .. resource)
      SetText(cell.name, RESOURCE_NAMES[resource])
      SetText(cell.value, wallet[resource] .. " / " .. cap .. (wallet[resource] >= cap and Paint("BAD", " full") or ""))
      Skin():SetBar(cell.bar, wallet[resource] / cap, RESOURCE_FILLS[resource])
      cell:Show()
    else
      cell:Hide()
    end
    index = index + 1
  end
  SetText(self.cellsPanel.note, wallet and "" or Paint("BAD", "Unavailable: no saved data or identity yet"))

  local stock = WF.Stock
  local hud = stock and stock:GetHud(now)
  Show(self.gatherIcon, hud ~= nil)
  Place(self.gatherName, self.gatherPanel, hud and 58 or 14, -26)
  Place(self.gatherHint, self.gatherPanel, hud and 58 or 14, -46)
  if hud then
    Window.SetPoiIcon(self.gatherIcon, hud.area)
    SetText(self.gatherName, AreaName(hud.area) .. " " .. AreaZone(hud.area))
    SetText(self.gatherStock, "Stock: " .. hud.resource.level .. " / " .. hud.resource.capacity)
    if hud.status == "IN" then
      SetText(self.gatherState, Paint("GOOD", "Gathering " .. stock.GATHER_AMOUNT .. " " .. hud.resource.resource
        .. " every " .. stock.GATHER_TICK .. "s" .. (hud.plunder and " (+30% enemy land)" or "")))
    else
      SetText(self.gatherState, Paint("BAD", "Not gathering: " .. tostring(hud.reason or "checking")))
    end
    SetText(self.gatherHint, Paint("DIM", hud.resource.status))
  else
    SetText(self.gatherName, Paint("DIM", "Not in a resource place"))
    SetText(self.gatherStock, "")
    SetText(self.gatherState, "")
    SetText(self.gatherHint, Paint("DIM", "Stand in a Gold Mine, Farm or Forest to gather, PvP flag on."))
  end

  local map = WF.Map
  local count = 0
  if stock and map then
    count = Collect(self.stockIds, function(id) return stock:Resource(id) ~= nil and stock:View(id, now) ~= nil end)
    SortByPlayerDistance(self.stockIds, count, PlayerDistanceContext())
  end
  FillList(self.stocks, count, function(row, item)
    local id = self.stockIds[item]
    local area = stock:Resource(id)
    local view = stock:View(id, now)
    Window.SetPoiIcon(row.icon, area)
    SetText(row.name, AreaName(area) .. " " .. AreaZone(area))
    SetText(row.value, view.level .. " / " .. view.capacity)
    Skin():SetBar(row.bar, view.capacity > 0 and view.level / view.capacity or 0, RESOURCE_FILLS[view.resource] or "gold")
    if not view.known then
      SetText(row.state, Paint("DIM", "not observed"))
    elseif view.level >= view.capacity then
      SetText(row.state, Paint("GOOD", "Full"))
    else
      SetText(row.state, "")
    end
  end)
end

-- No footer summary on this tab (2026-11-16, user): the page shows the wallet.
-- Army ------------------------------------------------------------------------

local Army = {
  WALLET_X = 428, -- reserve panel: left edge of the gold/wood/food values
  WALLET_GAP = 12, -- fixed gap between one resource value and the next icon
}
Window.Army = Army

local function ArmyStat(parent, atlas, title, x)
  local stat = NewFrame(parent, 48, 18)
  Place(stat, parent, x, -20)
  local icon = Skin():Icon(stat, atlas, 18, 18)
  Place(icon, stat, 0, 0)
  stat.value = NewText(stat, "GameFontHighlightSmall", 21, -3, 27)
  stat:EnableMouse(true)
  stat:SetScript("OnEnter", function(frame)
    GameTooltip:SetOwner(frame, "ANCHOR_RIGHT")
    GameTooltip:AddLine(title, 1, 1, 1)
    Window.LocalizeTooltip(GameTooltip)
    GameTooltip:Show()
  end)
  stat:SetScript("OnLeave", function() GameTooltip:Hide() end)
  return stat
end

function Army:Build()
  ArmyTab.Backdrop(self)
  local panel = NewPanel(self, "Reserve", 0, 0, CONTENT_WIDTH, 70)
  local icon = Skin():Icon(panel, "icon.unitsize", 30, 24)
  Place(icon, panel, 10, -33)
  self.size = NewText(panel, "GameFontHighlight", 48, -29, 170)
  self.sizeBar = Skin():Bar(panel, 170, 12, "gold")
  Place(self.sizeBar, panel, 48, -48)
  self.placeIcon = Skin():Icon(panel, nil, 34, 34)
  Place(self.placeIcon, panel, 226, -28)
  -- One wrapping text, up to three lines centred beside the icon: never cut
  -- (2026-11-16, user: a truncated reason cannot be read).
  self.place = NewText(panel, "GameFontHighlightSmall", 238, -24, 208)
  self.place:SetHeight(40)
  self.place:SetJustifyV("MIDDLE")
  self.wallet = {}
  local index = 1
  while index <= 3 do
    local coin = Skin():Icon(panel, nil, 20, 20)
    if index == 1 then
      Place(coin, panel, self.WALLET_X, -35)
    else
      -- Chained to the previous value's right edge: the gap is the same whatever the number's length.
      coin:ClearAllPoints()
      coin:SetPoint("TOPLEFT", self.wallet[index - 1].text, "TOPRIGHT", self.WALLET_GAP, 3)
    end
    -- No fixed width: the text takes its natural size so the next icon follows it.
    local text = NewText(panel, "GameFontHighlightSmall", 0, 0)
    text:ClearAllPoints()
    text:SetPoint("TOPLEFT", coin, "TOPLEFT", 23, -3)
    if text.SetWordWrap then text:SetWordWrap(false) end
    self.wallet[index] = { icon = coin, text = text }
    index = index + 1
  end
  self.reservePanel = panel
  ArmySwitch(self, panel)

  panel = NewPanel(self, "Units", 0, -74, CONTENT_WIDTH, CONTENT_HEIGHT - 74 - ArmyTab.SHIFT)
  self.units = {}
  index = 1
  -- Rows 70 px high, 74 apart (2026-11-16, user: a shorter Units panel leaves
  -- room above the sub-tabs; 72 by 76, 64 by 68, then 62 by 66 before); their
  -- contents keep a 64 px box centred in the row.
  while index <= 4 do
    local row = NewFrame(panel, CONTENT_WIDTH - 12, 74)
    Place(row, panel, 6, -24 - (index - 1) * 78)
    Skin():RowBackground(row, 74)
    Show(Skin():RowStripe(row), index % 2 == 0)
    row.hover = Skin():RowStripe(row, Skin().HOVER_ALPHA)
    local box = NewFrame(row, CONTENT_WIDTH - 12, 64)
    Place(box, row, 0, -5)
    row.portrait = Skin():Icon(box, nil, 40, 40, "ARTWORK")
    Place(row.portrait, box, 10, -11)
    local frame = Skin():Icon(box, "portrait", 48, 48, "OVERLAY")
    Place(frame, box, 6, -7)
    -- Reserve count on the portrait's bottom-right corner (2026-11-20, user);
    -- a child frame keeps it above the OVERLAY border.
    local badge = NewFrame(box, 40, 40)
    Place(badge, box, 10, -11)
    row.count = badge:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    row.count:SetPoint("BOTTOMRIGHT", badge, "BOTTOMRIGHT", -1, 2)
    row.name = NewText(box, "GameFontHighlight", 64, -12, 150)
    row.size = NewText(box, "GameFontHighlightSmall", 64, -32, 150)
    row.counter = NewText(box, "GameFontHighlightSmall", 64, -46, 320)
    row.costs = {}
    local c = 1
    while c <= 3 do
      local x = 212 + (c - 1) * 58
      local coin = Skin():Icon(box, "icon." .. RESOURCE_ORDER[c], 18, 18)
      Place(coin, box, x, -22)
      row.costs[c] = NewText(box, "GameFontHighlightSmall", x + 20, -25, 36)
      c = c + 1
    end
    row.info = NewText(box, "GameFontHighlightSmall", 392, -14, 120)
    row.attack = ArmyStat(box, "scoreboard.icon.pvp", "Attack", 392)
    row.defense = ArmyStat(box, "scoreboard.icon.shield", "Defense", 452)
    row.info2 = NewText(box, "GameFontHighlightSmall", 392, -43, 120)
    row.one = NewButton(box, "dark", 34, 26, "+1")
    Place(row.one, box, 512, -18)
    row.five = NewButton(box, "dark", 34, 26, "+5")
    Place(row.five, box, 550, -18)
    self.units[index] = row
    index = index + 1
  end
  Window.WatchHover(panel, self.units)
end

function Army:Update(now)
  RefreshArmySwitch(self)
  local army = WF.Army
  local reserve = army and army:Reserve()
  local wallet = WF.Economy and WF.Economy:Wallet()
  local faction = MyFaction()
  if not reserve or not wallet then
    SetText(self.reservePanel.note, Paint("BAD", "Unavailable: no saved data or identity yet"))
    SetText(self.size, "")
    return
  end
  SetText(self.reservePanel.note, "")
  local used = army:Used(reserve)
  SetText(self.size, "Unit Size: " .. used .. " / " .. army.RESERVE_CAPACITY
    .. (used >= army.RESERVE_CAPACITY and Paint("BAD", " full") or ""))
  Skin():SetBar(self.sizeBar, used / army.RESERVE_CAPACITY, used >= army.RESERVE_CAPACITY and "red" or "gold")
  local area, where = army:Place()
  Show(self.placeIcon, area ~= nil)
  local textX = area and 264 or 226
  Place(self.place, self.reservePanel, textX, -24)
  self.place:SetWidth(self.WALLET_X - 4 - textX)
  if area then
    Window.SetPoiIcon(self.placeIcon, area, faction)
    SetText(self.place, Paint("GOOD", "Recruitment open: " .. AreaName(area)))
  elseif string.find(tostring(where), "^go inside") then
    SetText(self.place, Paint("BAD", "Recruitment unavailable: enter a friendly Settlement"))
  else
    SetText(self.place, Paint("BAD", "Recruitment closed: " .. tostring(where)))
  end
  local index = 1
  while index <= 3 do
    local resource = RESOURCE_ORDER[index]
    Skin():Apply(self.wallet[index].icon, "icon." .. resource)
    SetText(self.wallet[index].text, tostring(wallet[resource]))
    index = index + 1
  end
  index = 1
  for index = 1, #self.units do
    local row = self.units[index]
    local key = army.ORDER[index]
    local unit = key and army.UNITS[key]
    if unit then
      UnitIcon(row.portrait, key, faction)
      SetText(row.count, tostring(reserve[key] or 0))
      SetText(row.name, army:Name(key))
      SetText(row.size, Paint("DIM", "Size: " .. unit.size))
      SetText(row.costs[1], tostring(unit.gold))
      SetText(row.costs[2], tostring(unit.wood))
      SetText(row.costs[3], tostring(unit.food))
      if unit.scout then
        SetText(row.info, Paint("GOOD", "Scout, never fights"))
        SetText(row.counter, "")
        row.attack:Hide()
        row.defense:Hide()
      else
        SetText(row.info, "")
        local strong, weak = army:Counters(key)
        SetText(row.counter, strong and (Paint("GOOD", "Strong vs " .. army:Name(strong))
          .. Paint("DIM", ", ") .. Paint("BAD", "weak vs " .. army:Name(weak))) or "")
        SetText(row.attack.value, Paint("GOOD", tostring(unit.atk)))
        SetText(row.defense.value, Paint("GOOD", tostring(unit.def)))
        row.attack:Show()
        row.defense:Show()
      end
      SetText(row.info2, Paint("DIM", "Up to " .. army:MostAffordable(key, reserve, wallet) .. " now"))
      SetAction(row.one, "+1", Window.Recruit, key, 1)
      SetAction(row.five, "+5", Window.Recruit, key, 5)
      row:Show()
    else
      row:Hide()
    end
  end
end

function Army:Summary()
  local army = WF.Army
  local reserve = army and army:Reserve()
  if not reserve then return "" end
  local area = army:Place()
  return WF.L("Recruitment") .. " " .. (area and Paint("GOOD", WF.L("open")) or Paint("BAD", WF.L("closed")))
end

Window:AddTab("res", "Resources", Resources)
Window:AddTab("army", "Army", Army)
