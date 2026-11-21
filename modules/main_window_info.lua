local WF = Warfront
local Window = WF.MainWindow

-- Main window (modules/main_window.lua): the Guide, Scoreboard and Players pages.
-- The base file loads first and shares its constants and helpers through
-- Window.Kit. Keep every main_window file far below the 200-local limit
-- (.claude/forever-compatibility.md, Lua runtime).
local Kit = Window.Kit
local CONTENT_WIDTH = Kit.CONTENT_WIDTH
local CONTENT_HEIGHT = Kit.CONTENT_HEIGHT
local GAP = Kit.GAP
local GetGlobal = Kit.GetGlobal
local Paint = Kit.Paint
local Duration = Kit.Duration
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
local ArmyTab = Kit.ArmyTab

-- Guide -----------------------------------------------------------------------

local Guide = {}
Window.Guide = Guide

-- The game loop for new players, one card per mechanic; the numbers come from
-- the modules that own them.
local function GuideSteps()
  local stock, army, scout, capture = WF.Stock, WF.Army, WF.Scout, WF.Capture
  return {
    { "Gather", "guide.gather", "In a Gold Mine, Forest or Farm, PvP flag on: +" .. stock.GATHER_AMOUNT
      .. " every " .. stock.GATHER_TICK .. "s. Stocks are shared and refill slowly." },
    { "Recruit", "guide.recruit", "Inside your capital, or a Settlement or War Camp your faction holds, spend resources on units. Reserve: "
      .. army.RESERVE_CAPACITY .. " Unit Size." },
    { "Capture", "guide.capture", "Stay in an enemy or neutral Outpost or War Camp, PvP flag on, until the bar is full."
      .. " War Camps your side holds speed its travel and captures on their continent." },
    { "Garrison", "guide.garrison", "Give units to a place of your faction: they defend it. A gift never comes back." },
    { "Scout", "guide.scout", "Send a " .. army:Name("SCOUT") .. " to an enemy place: your faction sees it for "
      .. math.floor(scout.DISCOVERY / 60) .. " minutes." },
    { "Attack", "guide.attack", "Pick a found target, choose units within your Assault Capacity and send them. They never come back." },
    { "Conquer", "guide.conquer", "Only Settlements on your faction's front. Take every Outpost of the zone to open a "
      .. math.floor((WF.Front and WF.Front.WINDOW or 10800) / 3600) .. "-hour siege, scout it, then " .. capture.SIEGE_ATTACKERS
      .. " players stand inside. A garrison slows it, never blocks it." },
    { "A living world", "icon.warning", "The war moves as players play; news can arrive late. Optional: the Warfront Companion keeps your map fresher." },
  }
end
Window.GuideSteps = GuideSteps

-- Two Scoreboard-style sub-tabs: the main Guide (a wiki: categories and pages
-- in a contents list, linked pages in a reader, roadmap item 12) and Basics
-- (the game loop cards). The wiki's pages and its home view (BuildHome,
-- UpdateHome) are in modules/main_window_wiki.lua.
Guide.view = "home"
Guide.VIEWS = { { "home", "Guide" }, { "basics", "Basics" } }
Guide.AUCTION = {
  MENU = "auctionhouse-background-categories",
  PANEL = "auctionhouse-background-index",
  ROW = "auctionhouse-nav-button",
  HOVER = "auctionhouse-nav-button-highlight",
  SUBMENU_ALPHA = 0.72,
}

function Guide:AuctionBackground(frame, atlas)
  local background = frame:CreateTexture(nil, "BORDER", nil, -8)
  if background.SetAtlas then
    background:SetAtlas(atlas, false)
  else
    background:SetTexture("Interface\\Buttons\\WHITE8X8")
    background:SetVertexColor(0.04, 0.04, 0.04, 1)
  end
  background:SetPoint("TOPLEFT", frame, "TOPLEFT", 4, -4)
  background:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -4, 4)
  return background
end

function Guide:Build()
  ArmyTab.Backdrop(self)
  local height = CONTENT_HEIGHT - ArmyTab.SHIFT
  self.home = NewFrame(self.frame, CONTENT_WIDTH, height)
  Place(self.home, self.frame, 0, -ArmyTab.SHIFT)
  self.basics = NewFrame(self.frame, CONTENT_WIDTH, height)
  Place(self.basics, self.frame, 0, -ArmyTab.SHIFT)
  self:BuildHome(height)
  self:BuildBasics(height)
  local level = (self.frame:GetFrameLevel() or 0) + 6
  local x = 12
  self.switch = {}
  for index = 1, #self.VIEWS do
    local key, title = self.VIEWS[index][1], self.VIEWS[index][2]
    local tab = ArmyTab.New(self, level, key, title)
    tab:SetScript("OnClick", function(b) Guide.view = b.key Guide:Update() end)
    Place(tab, self.frame, x, -ArmyTab.TOP)
    x = x + tab:GetWidth() + 2
    self.switch[key] = tab
  end
end

function Guide:BuildBasics(height)
  self.cards = {}
  local width = math.floor((CONTENT_WIDTH - 3 * GAP) / 4)
  height = math.floor((height - GAP) / 2)
  local index = 1
  while index <= 8 do
    local column = ((index - 1) % 4)
    local row = math.floor((index - 1) / 4)
    local card = NewFrame(self.basics, width, height)
    Place(card, self.basics, column * (width + GAP), -row * (height + GAP))
    Skin():Slice9(card, "panel", 0.25, "BACKGROUND")
    card.auctionBackground = self:AuctionBackground(card, self.AUCTION.PANEL)
    if index < 8 then
      local ring = Skin():Icon(card, "icon.ring", 22, 22)
      Place(ring, card, 8, -8)
      local number = NewText(card, "GameFontNormalSmall", 8, -12, 22, "CENTER")
      SetText(number, tostring(index))
    end
    card.title = NewText(card, "GameFontNormal", index < 8 and 34 or 10, -12, width - 40)
    card.picture = Skin():Icon(card, nil, 96, 72)
    card.picture:SetPoint("TOP", card, "TOP", 0, -32)
    card.text = NewText(card, "GameFontHighlightSmall", 10, -108, width - 20)
    card.text:SetHeight(height - 114)
    card.text:SetJustifyV("TOP")
    self.cards[index] = card
    index = index + 1
  end
end

function Guide:Update()
  local home = self.view ~= "basics"
  Show(self.home, home)
  Show(self.basics, not home)
  for key, tab in pairs(self.switch) do
    tab.selected = key == self.view
    ArmyTab.Paint(tab)
  end
  if home then self:UpdateHome() else self:UpdateBasics() end
end

function Guide:UpdateBasics()
  if not WF.Stock or not WF.Army or not WF.Scout or not WF.Capture then return end
  if self.filled then return end
  local steps = GuideSteps()
  for index = 1, #self.cards do
    local card, step = self.cards[index], steps[index]
    SetText(card.title, step[1])
    Skin():Apply(card.picture, step[2])
    local piece = Skin():Piece(step[2])
    if piece then
      local scale = math.min(96 / piece.w, 72 / piece.h)
      card.picture:SetWidth(piece.w * scale)
      card.picture:SetHeight(piece.h * scale)
    end
    SetText(card.text, step[3])
  end
  self.filled = true
end


-- Scoreboard -----------------------------------------------------------------

-- Read-only boards (decisions 0104, 0105, 0109): WF.Scoreboard builds the
-- rows; this page only draws them. Current campaign / History, Players /
-- Guilds, Territory / PvP / War effort; the own row inserted or pinned.
local Ranks = { period = "current", who = "players", board = "territory", sorts = {} }
Window.Ranks = Ranks
-- One filter row (board sub-tabs left, Players/Guilds and Current/History
-- pairs right); sortable column titles are clicked to sort.
-- The page panel starts under the menu tabs like every page; the board panel
-- is nested in it, RANK_INSET_TOP from its top and RANK_INSET from its sides.
-- Board tabs stand on the board panel's top edge, overlapping its rim; the two
-- segmented toggles sit right of them, inside the page panel.
local RANK_INSET_TOP = 27
local RANK_INSET = 5
local RANK_TAB_MIN = 72
local RANK_TAB_HEIGHT = 24
local RANK_TAB_OVERLAP = 3
local RANK_SEGMENT_HEIGHT = 20
local RANK_HEADER_TOP = -10
local RANK_LIST_TOP = -28
local RANK_BOARD_ICONS = { territory = "scoreboard.icon.territory", pvp = "scoreboard.icon.pvp", effort = "scoreboard.icon.effort" }
local RANK_FOOTER = 34
-- 23 px since 2026-11-16 (22 before; user: the tab fills its full height).
local RANK_ROW = 23
local RANK_SLOTS = 12
-- Scoreboard row texts use their template font size (as the Territory POI list), and are this high.
local RANK_FONT_BONUS = 0
local RANK_TEXT_HEIGHT = 18
-- Rows taken by the pinned own row and its note; the list uses them when it is hidden.
local RANK_PINNED_SLOTS = 2
local RANK_NAME_X = 68
local RANK_NAME_WIDTH = 180
local RANK_VALUES_X = 252
local RANK_VALUE_WIDTH = 66

-- A faint white band over a rank row, inside its rounded edges.
local function RankTint(row, layer, alpha)
  local tint = row:CreateTexture(nil, layer)
  tint:SetTexture("Interface\\Buttons\\WHITE8X8")
  tint:SetVertexColor(1, 1, 1, alpha)
  tint:SetPoint("TOPLEFT", row, "TOPLEFT", 2, -1)
  tint:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -2, 1)
  return tint
end

local function RankText(parent, template, x, y, width, justify)
  local text = NewText(parent, template, x, y, width, justify)
  local font, size, flags = text:GetFont()
  if font and size then text:SetFont(font, size + RANK_FONT_BONUS, flags) end
  text:SetHeight(RANK_TEXT_HEIGHT)
  return text
end

local function RankRow(parent, width, height)
  local row = NewFrame(parent, width, height)
  -- Lit while the cursor is over the row (Ranks:WatchHover).
  row.hover = RankTint(row, "BORDER", Skin().HOVER_ALPHA)
  row.hover:Hide()
  -- Texts and icons are vertically centered in the row.
  local y = -math.floor((height - RANK_TEXT_HEIGHT) / 2)
  local iconY = -math.floor((height - 14) / 2)
  row.rank = RankText(row, "GameFontHighlightSmall", 2, y, 30, "RIGHT")
  row.class = Skin():Icon(row, nil, 14, 14)
  Place(row.class, row, 36, iconY)
  row.race = Skin():Icon(row, nil, 14, 14)
  Place(row.race, row, 51, iconY)
  row.name = RankText(row, "GameFontHighlightSmall", RANK_NAME_X, y, RANK_NAME_WIDTH)
  row.values = {}
  for column = 1, 5 do
    row.values[column] = RankText(row, "GameFontHighlightSmall",
      RANK_VALUES_X + (column - 1) * RANK_VALUE_WIDTH, y, RANK_VALUE_WIDTH - 6, "RIGHT")
  end
  return row
end

local function SetIcon(texture, atlas)
  if atlas and texture.SetAtlas then
    texture:SetAtlas(atlas)
    texture:Show()
  else
    texture:Hide()
  end
end

local function FillRankRow(row, item, view, who)
  local board = view.board
  local rank = item.rank and tostring(item.rank) or ""
  SetText(row.rank, item.own and Paint("GOLD", rank) or rank)
  local name = WF.Scoreboard.NameText(item, who)
  if item.own then name = name .. Paint("GOLD", " (you)") end
  if item.share then name = name .. Paint("DIM", " your part: " .. WF.Scoreboard.Format({ v = item.share }, "v")) end
  if item.plus and item.plus > 0 then
    name = name .. Paint("GOOD", " +" .. WF.Scoreboard.Format({ v = item.plus }, "v") .. " this campaign")
  end
  SetText(row.name, name)
  SetIcon(row.class, who == "players" and WF.Scoreboard.ClassAtlas(item.class) or nil)
  SetIcon(row.race, who == "players" and WF.Scoreboard.RaceAtlas(item.race) or nil)
  for column = 1, 5 do
    local spec = board.columns[column]
    local text = ""
    if spec then
      text = item.blank and "-" or WF.Scoreboard.Format(item.columns, spec.key)
      if spec.key == view.rankKey then text = Paint("GOLD", text) end
    end
    SetText(row.values[column], text)
  end
end

-- Board tab look: the selected tab merges into the panel, hover warms the rim.
-- Unselected tab art sits 2 px lower, so its icon and label follow.
local function PaintBoardTab(tab)
  local state = tab.selected and "selected" or (tab.over and "hover" or "normal")
  Skin():SetSlice3(tab.art, "scoreboard.tab." .. state)
  Skin():Color(tab.label, tab.selected and "GOLD" or (tab.over and "WHITE" or "N"))
  local drop = tab.selected and 0 or 2
  Place(tab.icon, tab, 12, -3 - drop)
  tab.label:ClearAllPoints()
  tab.label:SetPoint("LEFT", tab, "LEFT", 33, 1 - drop)
end

local function NewBoardTab(parent, level, key)
  local tab = GetGlobal("CreateFrame")("Button", nil, parent)
  tab:SetHeight(RANK_TAB_HEIGHT)
  tab:SetFrameLevel(level)
  tab.art = Skin():Slice3(tab, "scoreboard.tab.normal", RANK_TAB_HEIGHT, "BACKGROUND")
  tab.icon = Skin():Icon(tab, RANK_BOARD_ICONS[key], 16, 16)
  tab.label = Skin():Text(tab, "GameFontNormal")
  tab.label:SetText(WF.L(WF.Scoreboard.BOARDS[key].title))
  -- Sized to its label: icon and left pad 33, right pad 16.
  tab:SetWidth(math.max(RANK_TAB_MIN, math.floor((tab.label:GetStringWidth() or 0) + 0.5) + 49))
  tab:SetScript("OnClick", function() Ranks:Set("board", key) end)
  tab:SetScript("OnEnter", function(b) b.over = true PaintBoardTab(b) end)
  tab:SetScript("OnLeave", function(b) b.over = false PaintBoardTab(b) end)
  PaintBoardTab(tab)
  return tab
end

-- Segmented toggle half: the raised plate marks the chosen half.
local function PaintSegment(half)
  local selected = Ranks[half.field] == half.value
  for _, part in pairs({ half.plate.L, half.plate.M, half.plate.R }) do Show(part, selected) end
  Skin():Color(half.label, selected and "GOLD" or (half.over and "WHITE" or "N"))
end

-- A two-way toggle of `field`: options = { { value, label }, { value, label } }.
-- Both halves share the width of the longer label plus 24.
local function NewSegments(parent, level, field, options)
  local create = GetGlobal("CreateFrame")
  local control = create("Frame", nil, parent)
  control:SetHeight(RANK_SEGMENT_HEIGHT)
  control:SetFrameLevel(level)
  Skin():Slice3(control, "scoreboard.segment.frame", RANK_SEGMENT_HEIGHT, "BACKGROUND")
  control.halves = {}
  local size = 0
  for index = 1, 2 do
    local option = options[index]
    local half = create("Button", nil, control)
    half:SetHeight(RANK_SEGMENT_HEIGHT)
    -- The plate is drawn on the half itself, under its label.
    half.plate = Skin():Slice3(half, index == 1 and "scoreboard.segment.left" or "scoreboard.segment.right",
      RANK_SEGMENT_HEIGHT, "BACKGROUND")
    half.label = Skin():Text(half, "GameFontNormalSmall", "CENTER")
    half.label:SetPoint("CENTER", half, "CENTER", 0, 0)
    half.label:SetText(WF.L(option[2]))
    size = math.max(size, math.floor((half.label:GetStringWidth() or 0) + 0.5) + 24)
    half.field, half.value = field, option[1]
    half:SetScript("OnClick", function(b) Ranks:Set(b.field, b.value) end)
    half:SetScript("OnEnter", function(b) b.over = true PaintSegment(b) end)
    half:SetScript("OnLeave", function(b) b.over = false PaintSegment(b) end)
    control.halves[index] = half
  end
  control:SetWidth(2 * size)
  for index = 1, 2 do
    control.halves[index]:SetWidth(size)
    Place(control.halves[index], control, (index - 1) * size, 0)
  end
  -- The divider stays above both plates.
  local top = NewFrame(control, 4, RANK_SEGMENT_HEIGHT)
  top:SetFrameLevel(level + 3)
  Place(top, control, size - 2, 0)
  local divider = Skin():Icon(top, "scoreboard.segment.divider", 4, RANK_SEGMENT_HEIGHT)
  divider:SetPoint("TOPLEFT", top, "TOPLEFT", 0, 0)
  return control
end

-- Tabs and toggles belong to the page panel `frame`, placed against the board panel.
function Ranks:BuildFilters(frame, panel)
  local level = panel:GetFrameLevel() + 3
  self.boardTabs = {}
  local order = WF.Scoreboard.BOARD_ORDER
  local x = 12
  for index = 1, #order do
    local tab = NewBoardTab(frame, level, order[index])
    Place(tab, panel, x, RANK_TAB_HEIGHT - RANK_TAB_OVERLAP)
    x = x + tab:GetWidth() + 2
    self.boardTabs[order[index]] = tab
  end
  local segmentY = RANK_SEGMENT_HEIGHT + 2
  self.periodToggle = NewSegments(frame, level, "period", { { "current", "Current" }, { "history", "History" } })
  local right = panel.width - 4 - self.periodToggle:GetWidth()
  Place(self.periodToggle, panel, right, segmentY)
  self.whoToggle = NewSegments(frame, level, "who", { { "players", "Players" }, { "guilds", "Guilds" } })
  Place(self.whoToggle, panel, right - 8 - self.whoToggle:GetWidth(), segmentY)
end

function Ranks:RefreshFilters()
  for key, tab in pairs(self.boardTabs) do
    if tab.selected ~= (key == self.board) then
      tab.selected = key == self.board
      PaintBoardTab(tab)
    end
  end
  for _, control in ipairs({ self.periodToggle, self.whoToggle }) do
    for index = 1, 2 do PaintSegment(control.halves[index]) end
  end
end

function Ranks:Build()
  local frame = self.frame
  local outerHeight = CONTENT_HEIGHT - RANK_FOOTER
  local outer = NewPanel(self, "", 0, 0, CONTENT_WIDTH, outerHeight)
  -- The tabs and toggles say what is shown: no title strips. The list's
  -- "1-14 of 100, scroll" note moves under the list.
  outer.title:GetParent():Hide()
  local height = outerHeight - RANK_INSET_TOP - RANK_INSET
  local panel = Skin():Panel(outer, "", CONTENT_WIDTH - 2 * RANK_INSET, height)
  Place(panel, outer, RANK_INSET, -RANK_INSET_TOP)
  panel.title:GetParent():Hide()
  self.panel = panel
  panel.note = NewText(panel, "GameFontHighlightSmall", panel.width - 212, -(height - 18), 200, "RIGHT")
  self:BuildFilters(outer, panel)
  local width = panel.width - 12
  local header = NewFrame(panel, width, 16)
  Place(header, panel, 6, RANK_HEADER_TOP)
  header.rank = NewText(header, "GameFontNormalSmall", 2, -1, 30, "RIGHT")
  header.name = NewText(header, "GameFontNormalSmall", RANK_NAME_X, -1, RANK_NAME_WIDTH)
  header.values = {}
  header.sorters = {}
  for column = 1, 5 do
    local x = RANK_VALUES_X + (column - 1) * RANK_VALUE_WIDTH
    -- No width: a title is never cut, whatever its length.
    header.values[column] = NewText(header, "GameFontNormalSmall", x, -1, nil, "CENTER")
    -- Shown over a sortable column title while the board has several sorts.
    local sorter = GetGlobal("CreateFrame")("Button", nil, header)
    sorter:SetWidth(RANK_VALUE_WIDTH - 2)
    sorter:SetHeight(16)
    Place(sorter, header, x - 2, 0)
    sorter.column = column
    sorter:SetScript("OnClick", function(b) Ranks:SortBy(b.column) end)
    sorter:SetScript("OnEnter", function(b)
      local spec = Ranks.view and Ranks.view.board.columns[b.column]
      if not spec then return end
      GameTooltip:SetOwner(b, "ANCHOR_TOP")
      GameTooltip:AddLine(spec.key == Ranks.view.sortKey and ("Ranked by " .. spec.label)
        or ("Click to rank by " .. spec.label), 1, 1, 1)
      Window.LocalizeTooltip(GameTooltip)
      GameTooltip:Show()
    end)
    sorter:SetScript("OnLeave", function() GameTooltip:Hide() end)
    sorter:Hide()
    header.sorters[column] = sorter
  end
  SetText(header.rank, "#")
  self.header = header
  -- Measures values in the row font for Ranks:CenterTitles; never seen.
  self.measure = RankText(header, "GameFontHighlightSmall", 0, -1)
  self.measure:SetAlpha(0)
  self.list = NewList(panel, RANK_SLOTS + RANK_PINNED_SLOTS, RANK_ROW, RANK_LIST_TOP, function(row)
    local inner = RankRow(row, width - Scroll.GUTTER, RANK_ROW - 2)
    Place(inner, row, 0, 0)
    -- Every other row is slightly lighter.
    row.stripe = Skin():RowStripe(inner)
    row.inner = inner
    -- Lit by the list's own hover watcher (NewList).
    row.hover = inner.hover
  end)
  local pinnedTop = RANK_LIST_TOP - RANK_SLOTS * RANK_ROW
  self.pinnedNote = NewText(panel, "GameFontHighlightSmall", 12, pinnedTop - 3, width - 12)
  -- As wide as the list rows above it, left of their scrollbar.
  self.pinned = RankRow(panel, width - Scroll.GUTTER, RANK_ROW - 2)
  Place(self.pinned, panel, 6, pinnedTop - RANK_ROW)
  Skin():RowBackground(self.pinned, RANK_ROW - 2)
  -- The list's rows light through NewList; the pinned own row has its own watcher.
  Window.WatchHover(panel, { self.pinned })
  self.empty = NewText(panel, "GameFontHighlight", 12, -90, width - 12, "CENTER")
  self.subtitle = NewText(frame, "GameFontHighlightSmall", 4, -(outerHeight + 4), CONTENT_WIDTH - 8)
  self.updated = NewText(frame, "GameFontHighlightSmall", 4, -(outerHeight + 18), CONTENT_WIDTH - 8)
end

function Ranks:Set(field, value)
  self[field] = value
  if self.list then self.list.offset = 0 end
  Window:Refresh()
end

-- A click on a sortable column title ranks the board by that column.
function Ranks:SortBy(column)
  local board = WF.Scoreboard.BOARDS[self.board]
  local spec = board and board.columns[column]
  if not spec or not board.sorts[spec.key] then return end
  self.sorts[self.board] = spec.key
  if self.list then self.list.offset = 0 end
  Window:Refresh()
end

local function SortCount(board)
  local count = 0
  for _ in pairs(board.sorts) do count = count + 1 end
  return count
end

function Ranks:Update(now)
  local scoreboard = WF.Scoreboard
  if not scoreboard then return end
  local view = scoreboard:View(self.period, self.who, self.board, self.sorts[self.board])
  self.view = view
  local language = WF.Locale and WF.Locale:Get()
  local width = self.list.panel.width
  local hint = scoreboard.CompanionHint and scoreboard.CompanionHint()
  SetText(self.updated, hint and Paint("GOLD", hint) or Paint("DIM", scoreboard.UpdatedText(view.updated) or ""))
  if self.drawnView == view and self.drawnOffset == self.list.offset
    and self.drawnLanguage == language and self.drawnWidth == width then return end
  local board = view.board
  self:RefreshFilters()
  SetText(self.header.name, self.who == "guilds" and "Guild" or "Player")
  -- Several sorts: each sortable title is clickable, the ranked one in white.
  local several = SortCount(board) > 1
  for column = 1, 5 do
    local spec = board.columns[column]
    local sortable = several and spec ~= nil and board.sorts[spec.key] ~= nil
    local label = spec and WF.L(spec.label) or ""
    if sortable and spec.key == view.sortKey then label = Paint("WHITE", label) end
    SetText(self.header.values[column], label)
    Show(self.header.sorters[column], sortable)
  end
  local rows, who = view.rows, self.who
  self.list.slots = view.own and RANK_SLOTS or (RANK_SLOTS + RANK_PINNED_SLOTS)
  FillList(self.list, #rows, function(row, item)
    FillRankRow(row.inner, rows[item], view, who)
    Show(row.stripe, item % 2 == 0)
  end)
  if view.own then
    FillRankRow(self.pinned, view.own, view, who)
    self.pinned:Show()
    local note = ""
    if view.outside then
      note = "Outside the top 100 - " .. scoreboard.Format({ v = view.gap }, "v") .. " more to reach the top 100"
    end
    SetText(self.pinnedNote, Paint("DIM", note))
  else
    self.pinned:Hide()
    SetText(self.pinnedNote, "")
  end
  SetText(self.empty, (#rows == 0 and view.empty) and Paint("DIM", "No ranking received yet.") or "")
  self:CenterTitles(view)
  SetText(self.subtitle, Paint("DIM", board.subtitle))
  -- Decision 0110 § 6: the Companion hint, highlighted, takes the update line.
  self.drawnView, self.drawnOffset = view, self.list.offset
  self.drawnLanguage, self.drawnWidth = language, width
end

-- Each column title is centered over the widest right-aligned value of the
-- whole board (every row and the own row, not only the rows on screen), so
-- scrolling never moves the titles.
function Ranks:CenterTitles(view)
  local format = WF.Scoreboard.Format
  local all = view.rows
  for column = 1, 5 do
    local title = self.header.values[column]
    local spec = view.board.columns[column]
    -- The longest value text is the widest one in the row font.
    local longest = ""
    local function Consider(item)
      local text = item.blank and "-" or format(item.columns, spec.key)
      if string.len(text) > string.len(longest) then longest = text end
    end
    if spec then
      for index = 1, #all do Consider(all[index]) end
      if view.own then Consider(view.own) end
    end
    local widest = 0
    if longest ~= "" then
      SetText(self.measure, longest)
      widest = self.measure:GetStringWidth() or 0
    end
    -- No value: the title stays right-aligned with the column.
    if widest == 0 then widest = title:GetStringWidth() or 0 end
    local right = RANK_VALUES_X + column * RANK_VALUE_WIDTH - 6
    local x = math.floor(right - widest / 2 + 0.5)
    if title.x ~= x then
      title.x = x
      Place(title, self.header, x, -1, "TOP")
    end
  end
end

function Ranks:Summary()
  return ""
end

-- Players ---------------------------------------------------------------------

-- Everyone online with Warfront right now (WF.Players), three names per row.
local Online = {}
Window.Online = Online
local ONLINE_COLUMNS = 3
local ONLINE_FOOTER = 30
-- Where we know a player from, beyond the Warfront channel.
local ONLINE_TAGS = { near = "(near you)", group = "(group)", guild = "(guild)", friend = "(friend)" }
-- A cell: faction emblem (the map's front emblems), name, then region and
-- ruleset at the right edge, dropped when the name needs the room.
Online.CELL = { ICON = 12, NAME_X = 22, PAD = 6, GAP = 4 }
Online.FACTION_ICONS = {
  Alliance = "Interface\\AddOns\\Warfront\\media\\Textures\\UI\\Front\\FactionAlliance",
  Horde = "Interface\\AddOns\\Warfront\\media\\Textures\\UI\\Front\\FactionHorde",
}

-- Width of a text as drawn, on an unbounded string of the cells' font.
function Online:Measure(text)
  local measure = self.measure
  if not measure or text == "" then return 0 end
  measure:SetText(text)
  return measure:GetStringWidth() or 0
end

function Online:Build()
  local height = CONTENT_HEIGHT - ONLINE_FOOTER
  local panel = NewPanel(self, "Players Online", 0, 0, CONTENT_WIDTH, height)
  self.panel = panel
  self.measure = Skin():Text(panel, "GameFontHighlightSmall")
  self.measure:Hide()
  local layout = self.CELL
  local cell = math.floor((panel.width - 12 - Scroll.GUTTER) / ONLINE_COLUMNS)
  self.nameRoom = cell - 4 - layout.NAME_X - layout.PAD
  local slots = math.floor((height - 26) / 22)
  self.list = NewList(panel, slots, (height - 26) / slots, -24, function(row)
    row.cells = {}
    local column = 1
    while column <= ONLINE_COLUMNS do
      local box = NewFrame(row, cell - 4, 20)
      Place(box, row, (column - 1) * cell, 0)
      Skin():RowBackground(box, 20)
      row.boxes = row.boxes or {}
      row.boxes[column] = box
      -- A grid of names, not a list: no alternating bands, and only the
      -- name under the cursor lights up (Window.WatchHover, `cellHover`).
      row.hovers = row.hovers or {}
      row.hovers[column] = Skin():RowStripe(box, Skin().HOVER_ALPHA)
      row.cellHover = true
      row.icons = row.icons or {}
      local icon = box:CreateTexture(nil, "OVERLAY")
      icon:SetWidth(layout.ICON)
      icon:SetHeight(layout.ICON)
      Place(icon, box, layout.PAD, -4)
      icon:Hide()
      row.icons[column] = icon
      row.cells[column] = NewText(box, "GameFontHighlightSmall", layout.NAME_X, -4, self.nameRoom)
      row.realms = row.realms or {}
      row.realms[column] = NewText(box, "GameFontHighlightSmall", cell - 4 - layout.PAD, -4, nil, "RIGHT")
      Place(row.realms[column], box, cell - 4 - layout.PAD, -4, "TOPRIGHT")
      column = column + 1
    end
  end, true)
  self.empty = NewText(panel, "GameFontHighlight", 12, -48, panel.width - 24, "CENTER")
  self.updated = NewText(self.frame, "GameFontHighlightSmall", 6, -(height + 9), CONTENT_WIDTH - 260)
  self.refresh = NewButton(self.frame, "dark", 100, 24, "Refresh", Window.RefreshPlayers)
  Place(self.refresh, self.frame, CONTENT_WIDTH - 100, -(height + 4))
  self.allies = NewButton(self.frame, "dark", 128, 24, "Allies", function()
    if WF.Allies then WF.Allies:Command("") end
  end)
  Place(self.allies, self.frame, CONTENT_WIDTH - 234, -(height + 4))
  -- Same short tooltip as the Synchronization panel button; the skin's own
  -- hover scripts keep running (wrapped).
  local skinEnter, skinLeave = self.allies:GetScript("OnEnter"), self.allies:GetScript("OnLeave")
  self.allies:SetScript("OnEnter", function(frame, ...)
    if skinEnter then skinEnter(frame, ...) end
    GameTooltip:SetOwner(frame, "ANCHOR_TOP")
    GameTooltip:AddLine("Allies", 1, 1, 1)
    GameTooltip:AddLine("Become Battle.net friends with a player of the other faction to help Warfront share data between factions.", 0.8, 0.8, 0.8, 1)
    Window.LocalizeTooltip(GameTooltip)
    GameTooltip:Show()
  end)
  self.allies:SetScript("OnLeave", function(frame, ...)
    if skinLeave then skinLeave(frame, ...) end
    GameTooltip:Hide()
  end)
end

function Online:Update(now)
  local players = WF.Players
  if not players then return end
  players:Tick(now)
  local names, me = players.names, players.me
  local count = players.count
  local room, gap = self.nameRoom or 0, self.CELL.GAP
  FillList(self.list, math.ceil(count / ONLINE_COLUMNS), function(row, item)
    local column = 1
    while column <= ONLINE_COLUMNS do
      local name = names[(item - 1) * ONLINE_COLUMNS + column]
      local tag = name and players.tags and players.tags[name]
      local info = name and players.info and players.info[name] or nil
      local icon = row.icons[column]
      local path = info and info.faction and self.FACTION_ICONS[info.faction] or nil
      if path then
        icon:SetTexture(path)
        icon:SetTexCoord(0, 1, 0, 1)
        icon:Show()
      else
        icon:Hide()
      end
      local realm = ""
      if info and (info.region or info.ruleset) then
        realm = (info.region or "") .. ((info.region and info.ruleset) and " " or "") .. (info.ruleset or "")
      end
      if name == me then name = Paint("GOLD", name .. " (you)")
      elseif tag then name = name .. " " .. Paint("DIM", ONLINE_TAGS[tag] or "") end
      SetText(row.cells[column], name or "")
      -- The name and its tag keep their room: the label only fills what is left.
      local realmWidth = name and self:Measure(realm) or 0
      if realmWidth > 0 and self:Measure(row.cells[column].value or "") + gap + realmWidth > room then
        realm, realmWidth = "", 0
      end
      row.cells[column]:SetWidth(realmWidth > 0 and room - realmWidth - gap or room)
      SetText(row.realms[column], realm ~= "" and Paint("DIM", realm) or "")
      if name then row.boxes[column]:Show() else row.boxes[column]:Hide() end
      column = column + 1
    end
  end)
  SetText(self.panel.title, count > 0 and ("Players Online (" .. count .. ")") or "Players Online")
  local empty = ""
  if count == 0 then
    empty = players.requestedAt and "Looking for players..." or "Not connected yet. Try again in a moment."
  end
  SetText(self.empty, Paint("DIM", empty))
  local updated = ""
  if players.updatedAt then
    updated = "Updated " .. Duration(math.max(0, now - players.updatedAt)) .. " ago"
  end
  SetText(self.updated, Paint("DIM", updated))
end

function Online:Summary()
  local count = WF.Players and WF.Players.count or 0
  if count == 1 then return "1 player online" end
  return count .. " players online"
end

Window:AddTab("ranks", "Scoreboard", Ranks)
Window:AddTab("players", "Players", Online, nil, true)
Window:AddTab("guide", "Guide", Guide, nil, true)
