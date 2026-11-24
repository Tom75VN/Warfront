Warfront = Warfront or {}

local WF = Warfront
local Window = { tabs = {}, order = {}, tabButtons = {}, elapsed = 0 }

WF.MainWindow = Window
Window.JOURNAL_WIDTH = 58

-- Main gameplay window (roadmap WP11, docs/architecture.md), textured with the
-- sprite atlas (modules/ui_skin.lua). Each tab is a page that builds its
-- widgets once and fills them once per second while shown, from the modules
-- that own the data. A local view: it sends nothing itself; a recruitment
-- goes through WF.Army, a confirmed pledge through WF.Garrison, a scout or a
-- confirmed attack through WF.Scout:Launch or WF.Attack:Launch.
local NAME = "WarfrontMainWindow"
local WIDTH = 640
local HEIGHT = 560
local CONTENT_LEFT = 16
local CONTENT_TOP = -98
local CONTENT_WIDTH = WIDTH - 2 * CONTENT_LEFT
-- The pages end 19 px above the frame bottom, over the bottom border's rim and
-- just above the footer texts (2026-11-16, user: full height; 432, then 424
-- before the status strip left).
local CONTENT_HEIGHT = 443
local GAP = 4
-- Footer texts in the dark band of the bottom border, 7 to 17 px above the
-- frame bottom (frame.bottom rows 40-73 of 95 at FRAME_SCALE). The 54 px
-- Synchronization handle holds the middle: each side stops 6 px short of it.
local FOOTER = { bottom = 6, height = 11, edge = 44, left = 27, right = 27, centre = WIDTH / 2 - 33 }
-- The "?" button at the right end of the tab row opens the Guide; the Players
-- button left of it opens the Players page (group atlas and online count).
local HELP_SIZE = 36
local PLAYERS_WIDTH = 58
local PLAYERS_ATLAS = "socialqueuing-icon-group"
local REFRESH_INTERVAL = 1
local CONNECT_WIDTH = 78
local VERSION_WIDTH = 36
local CONNECT_WAIT = 15 -- "Connecting..." gives way to the chat command after this many seconds
local CONNECT_DONE = 6 -- "Connected to Warfront." clears after this many seconds
-- The channel level of Capture:CanTalk (decision 0039).
local LOCK_LEVEL = 5
local FRAME_SCALE = 0.3
local ORNAMENT_SCALE = 0.46
local ALLIANCE_SCALE = 0.475
local HORDE_SCALE = 0.472
local TITLE_SCALE = 0.448
local COLORS = {
  H = "e64033", A = "408cff", N = "b3b3b3",
  GOOD = "4dff4d", BAD = "ff5959", DIM = "999999", GOLD = "ffd100", WHITE = "ffffff", WARN = "ff8014",
}
local RESOURCE_NAMES = { gold = "Gold", wood = "Wood", food = "Food" }
local UNIT_ICON_DIR = "Interface\\AddOns\\Warfront\\media\\Textures\\Icons\\War3Units\\"
local UNIT_ICONS = {
  FOOTMAN = { A = "BTNFootman", H = "BTNGrunt" },
  RIFLEMAN = { A = "BTNRifleman", H = "BTNHeadhunter" },
  MORTAR = { A = "BTNMortarTeam", H = "BTNDemolisher" },
  SCOUT = { A = "BTNKnight", H = "BTNRaider" },
}
-- Columns of MapPOIIconAtlas (Map.GetIcon) for an owner and a half challenger.
local POI_COLUMNS = { H = 2, A = 4 }
local POI_HALF_COLUMNS = { H = 1, A = 3 }

local FrontDrawer = {
  routeId = "KA", position = 1, target = 1, animating = false,
  areaIds = {}, areaSet = {}, presenceSeen = {},
}
Window.FrontDrawer = FrontDrawer

-- Synchronization drawer under the window (2026-11-15): closed at login,
-- slides down from the bottom edge; its widgets live in this table.
local SyncDrawer = { position = 0, target = 0, animating = false, HEIGHT = 88 }
Window.SyncDrawer = SyncDrawer

Window.CONTENT_HEIGHT = CONTENT_HEIGHT
-- The whole window and every tab draw larger (2026-11-15, user: +20 %, then
-- +10 %, +20 %, −15 %, then −5 %, 1.2 × 1.1 × 1.2 × 0.85 × 0.95), shrunk to
-- fit the screen by Window:FitScale (main_window_drawers.lua). The drawers
-- keep their own on-screen scale whatever the window's: Active Front +10 %,
-- Synchronization +20 % (2026-11-15, user), their handles with them.
Window.UI_SCALE = 1.27908
Window.FRONT_SCALE = 1.1
Window.SYNC_SCALE = 1.2
-- Both drawer handles share one on-screen scale (2026-11-16, user): the Active
-- Front handle's 1.1 reduced by 20 %; the Synchronization handle came down to it.
Window.HANDLE_SCALE = 0.88
Window.WIDTH, Window.HEIGHT = WIDTH, HEIGHT

local function GetGlobal(name)
  if WF.Compat and WF.Compat.Global then return WF.Compat.Global(name) end
  if _G then return _G[name] end
  return nil
end

-- Soft bounce, never past 0..1 (an overshoot would open a gap beside the
-- window): an eased approach, then two low rebounds (restitution 0.3, about
-- 9 % then 1 % of the travel) shaped as smooth sine arcs.
local BOUNCE_R = 0.3
local BOUNCE_FALL = 1 / (1 + 2 * BOUNCE_R + 2 * BOUNCE_R * BOUNCE_R)
local function EaseOutSoftBounce(value)
  if value >= 1 then return 1 end
  if value < BOUNCE_FALL then
    local t = value / BOUNCE_FALL
    -- Starts fast and keeps some speed for the first contact.
    return math.sin(t * math.pi / 2) * 0.35 + t * t * 0.65
  end
  local t = (value - BOUNCE_FALL) / BOUNCE_FALL
  local span = 2 * BOUNCE_R
  if t < span then
    return 1 - BOUNCE_R * BOUNCE_R * math.sin(t / span * math.pi)
  end
  t = t - span
  span = 2 * BOUNCE_R * BOUNCE_R
  if t < span then
    return 1 - BOUNCE_R ^ 4 * math.sin(t / span * math.pi)
  end
  return 1
end

local function Now()
  return WF.Now and WF.Now() or 0
end

local function Paint(color, text)
  return "|cff" .. (COLORS[color] or COLORS.N) .. tostring(text) .. "|r"
end

local function FactionName(code)
  local names = WF.Capture and WF.Capture.FACTION_NAMES
  local name = names and names[code] or tostring(code)
  return WF.L and WF.L(name) or name
end

local function FactionText(code)
  return Paint(code, FactionName(code))
end

local function Duration(seconds)
  seconds = math.ceil(seconds)
  if seconds < 60 then return seconds .. "s" end
  if seconds < 3600 then return string.format("%dm %02ds", math.floor(seconds / 60), (seconds % 60)) end
  return string.format("%dh %02dm", math.floor(seconds / 3600), math.floor((seconds % 3600) / 60))
end

local function AreaName(area)
  local name = tostring(area.label or area.id)
  return WF.L and WF.L(name) or name
end

local function AreaZone(area)
  local name = tostring(area.map or "")
  return Paint("DIM", WF.L and WF.L(name) or name)
end

local function MyFaction()
  local faction = WF.Capture and WF.Capture:MyFaction()
  if faction == "H" or faction == "A" then return faction end
  return nil
end

local function OtherFaction(faction)
  if faction == "H" then return "A" end
  return "H"
end

-- Shows the same POI picture as the world map (MapPOIIconAtlas): type, owner
-- (H, A or N) and, while a challenger holds half the bar, the half state of
-- that challenger.
function Window.SetPoiIcon(texture, area, owner, challenger)
  local map = WF.Map
  if not texture or not area or not map or not map.GetIcon then return false end
  local column = POI_HALF_COLUMNS[challenger or ""] or POI_COLUMNS[owner or ""] or 0
  local level = map.SettlementLevel and map.SettlementLevel(area) or 1
  local path, left, right, top, bottom = map.GetIcon(area.type, nil, column, level)
  if not path then return false end
  texture:SetTexture(path)
  texture:SetTexCoord(left, right, top, bottom)
  return true
end

local function UnitIcon(texture, key, faction)
  local names = UNIT_ICONS[key]
  if not names then return end
  texture:SetTexture(UNIT_ICON_DIR .. (names[faction or "A"] or names.A))
  texture:SetTexCoord(0.07, 0.93, 0.07, 0.93)
end

-- Same unit pictures for the map tooltip.
Window.UnitIcon = UnitIcon

local function Skin()
  return WF.Skin
end

-- Small widget helpers -----------------------------------------------------

local function Place(region, parent, x, y, point)
  region:ClearAllPoints()
  region:SetPoint(point or "TOPLEFT", parent, "TOPLEFT", x, y)
end

local function NewText(parent, template, x, y, width, justify)
  local text = Skin():Text(parent, template or "GameFontHighlightSmall", justify)
  Place(text, parent, x, y)
  if width then text:SetWidth(width) end
  if text.SetNonSpaceWrap then text:SetNonSpaceWrap(false) end
  text:SetHeight(14)
  return text
end

local function SetText(text, value)
  value = value or ""
  if WF.L then value = WF.L(value) end
  if text.value ~= value then
    text.value = value
    text:SetText(value)
  end
end

-- Matchmaking buttons (Synchronization panel, Players tab): a green dot while
-- the player volunteers or the Companion manages it, refreshed with their
-- panel; the label moves aside.
local function AlliesState()
  local allies = WF.Allies
  if not allies or not allies.OptedIn then return nil end
  if allies:OptedIn() then return "on" end
  if allies.CloudLocked and allies:CloudLocked() then return "cloud" end
  return nil
end

function Window.MarkAllies(button)
  if not button then return end
  local on = AlliesState() ~= nil
  if button.alliesOn == on then return end
  button.alliesOn = on
  if on and not button.onDot then
    button.onDot = Skin():Icon(button, "dot.green", 10, 10, "OVERLAY")
    button.onDot:SetPoint("LEFT", button, "LEFT", 6, 0)
  end
  if button.onDot then
    if on then button.onDot:Show() else button.onDot:Hide() end
  end
  button.label:ClearAllPoints()
  button.label:SetPoint("CENTER", button, "CENTER", on and 6 or 0, 0)
end

-- The matchmaking tooltip's state line, only while it is on.
function Window.AlliesTooltipState(tooltip)
  local state = AlliesState()
  if state == "on" then
    tooltip:AddLine("Matchmaking is on.", 0.25, 1, 0.25)
  elseif state == "cloud" then
    tooltip:AddLine("Managed in the Companion", 0.25, 1, 0.25)
  end
end

function Window.LocalizeTooltip(tooltip)
  if not tooltip or not WF.L then return end
  local name = tooltip:GetName()
  if not name then return end
  local index = 1
  while index <= tooltip:NumLines() do
    local left = GetGlobal(name .. "TextLeft" .. index)
    local right = GetGlobal(name .. "TextRight" .. index)
    if left and left.GetText and left.SetText then left:SetText(WF.L(left:GetText() or "")) end
    if right and right.GetText and right.SetText then right:SetText(WF.L(right:GetText() or "")) end
    index = index + 1
  end
end

-- Single-line text that shrinks its font to fit `room`; only re-measured when the value changes.
local function FitText(text, value, room)
  value = value or ""
  if text.fitValue == value then return end
  text.fitValue = value
  if not text.fitFont then
    local font, size, flags = text:GetFont()
    text.fitFont = { font, size, flags }
  end
  local base = text.fitFont
  if not base[1] or not base[2] then SetText(text, value) return end
  text:SetFont(base[1], base[2], base[3])
  text:SetWidth(0) -- unbounded, so the measure is the full text, not the width cut to the old room
  SetText(text, value)
  local width = text:GetStringWidth() or 0
  text:SetWidth(room)
  if width > room then text:SetFont(base[1], math.max(8, math.floor(base[2] * room / width)), base[3]) end
end

local function Show(region, shown)
  if shown then region:Show() else region:Hide() end
end

local function NewPanel(page, title, x, y, width, height)
  local panel = Skin():Panel(page.frame, title, width, height)
  Place(panel, page.frame, x, y - (page.shift or 0))
  return panel
end

local function NewFrame(parent, width, height)
  local frame = GetGlobal("CreateFrame")("Frame", nil, parent)
  frame:SetWidth(width)
  frame:SetHeight(height)
  return frame
end

-- Lights the list row under the cursor (2026-11-15, every list; was the
-- scoreboard's alone): its `hover` band, or each of its `hovers` for a row of
-- separate boxes. Polled, so rows never take the mouse (wheel scrolling,
-- buttons and sorters keep working); runs only while the panel is shown. A
-- row marked `isCategory` (a section title) is never lit. `rows` may grow.
Window.HOVER_PERIOD = 0.05

-- A row marked `cellHover` (a grid of boxes, not a list) lights only the box
-- under the cursor: `boxes[n]` is hit-tested, `hovers[n]` is its band.
local function CellUnder(row)
  for box = 1, #row.hovers do
    local frame = row.boxes[box]
    if frame and frame:IsShown() and frame:IsMouseOver() then return row.hovers[box] end
  end
end

local function LightRow(row, on)
  if row.hover then Show(row.hover, on) end
  if row.hovers and not row.cellHover then
    for box = 1, #row.hovers do Show(row.hovers[box], on) end
  end
end

function Window.WatchHover(panel, rows)
  local watcher = GetGlobal("CreateFrame")("Frame", nil, panel)
  local wait, lit, litCell = 0, nil, nil
  watcher:SetScript("OnUpdate", function(_, elapsed)
    wait = wait - (elapsed or 0)
    if wait > 0 then return end
    wait = Window.HOVER_PERIOD
    local over, cell
    if panel:IsMouseOver() then
      for index = 1, #rows do
        local row = rows[index]
        if row:IsShown() and not row.isCategory and (row.hover or row.hovers) and row:IsMouseOver() then
          over = row
          if row.cellHover then cell = CellUnder(row) end
          break
        end
      end
    end
    if over ~= lit then
      if lit then LightRow(lit, false) end
      if over then LightRow(over, true) end
      lit = over
    end
    if cell ~= litCell then
      if litCell then Show(litCell, false) end
      if cell then Show(cell, true) end
      litCell = cell
    end
  end)
  return watcher
end

-- Every list keeps a scrollbar in a gutter right of its rows (2026-11-15):
-- a dark track, and a gold thumb while the list holds more than its rows.
-- Click the track or drag the thumb; the wheel works over the bar too.
local Scroll = { WIDTH = 6, THUMB_MIN = 12 }
Scroll.GUTTER = Scroll.WIDTH + 2

function Scroll.SetOffset(list, offset)
  local most = list.count - list.slots
  if most < 0 then most = 0 end
  if offset > most then offset = most end
  if offset < 0 then offset = 0 end
  if offset ~= list.offset then
    list.offset = offset
    Window:Refresh()
  end
end

function Scroll.Wheel(list, delta)
  if delta and delta > 0 then Scroll.SetOffset(list, list.offset - 1) else Scroll.SetOffset(list, list.offset + 1) end
end

function Scroll.NewBar(list, top)
  local panel = list.panel
  local bar = NewFrame(panel, Scroll.WIDTH, 1)
  Place(bar, panel, panel.width - 6 - Scroll.WIDTH, top)
  local track = bar:CreateTexture(nil, "BACKGROUND")
  track:SetTexture("Interface\\Buttons\\WHITE8X8")
  track:SetVertexColor(0, 0, 0, 0.35)
  track:SetAllPoints(bar)
  bar.thumb = bar:CreateTexture(nil, "ARTWORK")
  bar.thumb:SetTexture("Interface\\Buttons\\WHITE8X8")
  bar.thumb:SetVertexColor(0.85, 0.7, 0.35, 0.85)
  bar.thumb:SetWidth(Scroll.WIDTH)
  bar.thumb:Hide()
  bar.height = 1
  -- Distance from the bar's top to the cursor, in the bar's own units.
  local function CursorDepth()
    local getCursor = GetGlobal("GetCursorPosition")
    local barTop = bar:GetTop()
    if type(getCursor) ~= "function" or not barTop then return nil end
    local _, y = getCursor()
    return barTop - y / bar:GetEffectiveScale()
  end
  local function Drag()
    local depth = CursorDepth()
    local most = list.count - list.slots
    local room = bar.height - (bar.thumbHeight or 0)
    if not depth or not bar.thumbHeight or most <= 0 or room <= 0 then return end
    Scroll.SetOffset(list, math.floor((depth - bar.grab) / room * most + 0.5))
  end
  local function Stop()
    bar:SetScript("OnUpdate", nil)
  end
  bar:EnableMouse(true)
  bar:EnableMouseWheel(true)
  bar:SetScript("OnMouseWheel", function(_, delta) Scroll.Wheel(list, delta) end)
  bar:SetScript("OnMouseDown", function(_, button)
    if button and button ~= "LeftButton" then return end
    local depth = CursorDepth()
    if not depth or not bar.thumbHeight then return end
    -- Held where it was taken; a click on the track centres the thumb there.
    local within = depth - bar.thumbTop
    if within >= 0 and within <= bar.thumbHeight then bar.grab = within else bar.grab = bar.thumbHeight / 2 end
    bar:SetScript("OnUpdate", Drag)
    Drag()
  end)
  bar:SetScript("OnMouseUp", Stop)
  bar:SetScript("OnHide", Stop)
  return bar
end

function Scroll.Update(list)
  local bar = list.bar
  local height = list.slots * list.rowHeight - 2
  if bar.height ~= height then
    bar.height = height
    bar:SetHeight(height)
  end
  local count, slots = list.count, list.slots
  if count <= slots then
    bar.thumbHeight = nil
    bar.thumb:Hide()
    return
  end
  local thumb = math.max(Scroll.THUMB_MIN, math.floor(height * slots / count + 0.5))
  if thumb > height then thumb = height end
  local thumbTop = math.floor((height - thumb) * list.offset / (count - slots) + 0.5)
  bar.thumbTop, bar.thumbHeight = thumbTop, thumb
  bar.thumb:ClearAllPoints()
  bar.thumb:SetPoint("TOPLEFT", bar, "TOPLEFT", 0, -thumbTop)
  bar.thumb:SetHeight(thumb)
  bar.thumb:Show()
end

-- A list of `slots` pooled rows inside a panel, scrolled with the mouse wheel
-- over the panel or with its scrollbar. build(row, index) makes a row once;
-- Fill(count, fill) shows rows offset+1.. and calls fill(row, index). Rows
-- are Scroll.GUTTER narrower than the panel inside, for the scrollbar.
local function NewList(panel, slots, rowHeight, top, build, plain)
  local list = { panel = panel, rows = {}, slots = slots, offset = 0, count = 0, rowHeight = rowHeight }
  local index = 1
  while index <= slots do
    local row = NewFrame(panel, panel.width - 12 - Scroll.GUTTER, rowHeight - 2)
    Place(row, panel, 6, top - (index - 1) * rowHeight)
    if not plain then Skin():RowBackground(row, rowHeight - 2) end
    build(row, index)
    -- Every other row lighter (FillList); a build may bring its own stripe,
    -- or `stripes` for a row of separate boxes.
    if not plain and not row.stripe then row.stripe = Skin():RowStripe(row) end
    if not plain and row.hover == nil then row.hover = Skin():RowStripe(row, Skin().HOVER_ALPHA) end
    list.rows[index] = row
    index = index + 1
  end
  Window.WatchHover(panel, list.rows)
  panel:EnableMouseWheel(true)
  panel:SetScript("OnMouseWheel", function(_, delta) Scroll.Wheel(list, delta) end)
  list.bar = Scroll.NewBar(list, top)
  Scroll.Update(list)
  return list
end

local function FillList(list, count, fill)
  local most = count - list.slots
  if most < 0 then most = 0 end
  if list.offset > most then list.offset = most end
  if list.offset < 0 then list.offset = 0 end
  list.count = count
  local index = 1
  -- Rows built past list.slots (a list that can shrink) stay hidden.
  while index <= #list.rows do
    local row = list.rows[index]
    local item = list.offset + index
    if index <= list.slots and item <= count then
      -- By item, so the bands follow the content while scrolling; fill may override.
      local even = item % 2 == 0
      if row.stripe then Show(row.stripe, even) end
      if row.stripes then
        for box = 1, #row.stripes do Show(row.stripes[box], even) end
      end
      fill(row, item)
      row:Show()
    else
      row:Hide()
    end
    index = index + 1
  end
  Scroll.Update(list)
  if count > list.slots then
    SetText(list.panel.note, Paint("DIM", (list.offset + 1) .. "-" .. (list.offset + list.slots) .. " of " .. count .. ", scroll"))
  else
    SetText(list.panel.note, "")
  end
end

local function NewButton(parent, style, width, height, label, fn)
  local button = Skin():Button(parent, style, width, height, function(b)
    if b.action then b.action(Window, b.a, b.b) end
  end)
  button.action = fn
  Skin():SetButton(button, label, true)
  return button
end

local function SetAction(button, label, fn, a, b, enabled)
  button.action, button.a, button.b = fn, a, b
  Skin():SetButton(button, label, enabled ~= false and fn ~= nil)
end

-- Reused id lists: one per list, refilled on each refresh.
local function Collect(list, test)
  local count = 0
  local map = WF.Map
  local index = 1
  while map and index <= #map.order do
    local id = map.order[index]
    if test(id) then
      count = count + 1
      list[count] = id
    end
    index = index + 1
  end
  local extra = count + 1
  while list[extra] do
    list[extra] = nil
    extra = extra + 1
  end
  return count
end

-- POI locations are percentages within their zone. Forever can project those
-- zones onto their continent map, so lists stay nearest-first across nearby zones.
-- POIs on another continent follow measurable entries, ordered by their IDs.
local function MapIDForKey(mapKey)
  local keys = WF.Compat and WF.Compat.MAP_KEYS
  if type(keys) ~= "table" or type(mapKey) ~= "string" then return nil end
  for mapID, name in pairs(keys) do
    if type(name) == "string" and string.lower(name) == mapKey then return mapID end
  end
  return nil
end

local function ContinentMapID(cmap, mapID)
  local current = mapID
  local safety = 0
  while type(current) == "number" and safety < 8 do
    local key = WF.Compat and WF.Compat.MAP_KEYS and WF.Compat.MAP_KEYS[current]
    if key == "Azeroth" or key == "Kalimdor" then return current end
    local info = cmap.GetMapInfo(current)
    current = info and info.parentMapID
    safety = safety + 1
  end
  return nil
end

local function ContinentPoint(cmap, mapID, continentID, x, y)
  if mapID == continentID then return x, y end
  local minX, maxX, minY, maxY = cmap.GetMapRectOnMap(mapID, continentID)
  if type(minX) ~= "number" or type(maxX) ~= "number"
      or type(minY) ~= "number" or type(maxY) ~= "number" then return nil end
  return minX + (maxX - minX) * x, minY + (maxY - minY) * y
end

local function PlayerDistanceContext()
  local cmap = GetGlobal("C_Map")
  if type(cmap) ~= "table" or type(cmap.GetBestMapForUnit) ~= "function"
      or type(cmap.GetPlayerMapPosition) ~= "function" or type(cmap.GetMapRectOnMap) ~= "function"
      or type(cmap.GetMapInfo) ~= "function" then return nil end
  local mapID = cmap.GetBestMapForUnit("player")
  if type(mapID) ~= "number" then return nil end
  local position = cmap.GetPlayerMapPosition(mapID, "player")
  if not position then return nil end
  local x, y
  if type(position.GetXY) == "function" then
    x, y = position:GetXY()
  else
    x, y = position.x, position.y
  end
  if type(x) ~= "number" or type(y) ~= "number" then return nil end
  local continentID = ContinentMapID(cmap, mapID)
  if not continentID then return nil end
  x, y = ContinentPoint(cmap, mapID, continentID, x, y)
  if not x or not y then return nil end
  return { cmap = cmap, continentID = continentID, x = x, y = y, distances = {} }
end

local function AreaPoint(area)
  if area.shape and area.shape.type == "circle" then return area.shape.x / 100, area.shape.y / 100 end
  local locations = area.locations
  if type(locations) ~= "table" or #locations == 0 then return nil end
  local x, y = 0, 0
  for index = 1, #locations do
    x = x + locations[index].x
    y = y + locations[index].y
  end
  return x / #locations / 100, y / #locations / 100
end

local function DistanceToArea(context, area)
  if not context or not area then return nil end
  local cached = context.distances[area.id]
  if cached ~= nil then return cached or nil end
  local mapID = MapIDForKey(area.mapKey)
  local x, y = AreaPoint(area)
  if not mapID or not x or not y then
    context.distances[area.id] = false
    return nil
  end
  x, y = ContinentPoint(context.cmap, mapID, context.continentID, x, y)
  if not x or not y then
    context.distances[area.id] = false
    return nil
  end
  local dx, dy = x - context.x, y - context.y
  local distance = dx * dx + dy * dy
  context.distances[area.id] = distance
  return distance
end

local function SortByPlayerDistance(list, count, context)
  if not context or count < 2 then return end
  table.sort(list, function(left, right)
    local leftDistance = DistanceToArea(context, WF.Map and WF.Map.areas[left])
    local rightDistance = DistanceToArea(context, WF.Map and WF.Map.areas[right])
    if leftDistance and rightDistance and leftDistance ~= rightDistance then return leftDistance < rightDistance end
    if leftDistance then return not rightDistance end
    if rightDistance then return false end
    return left < right
  end)
end

-- Tabs ------------------------------------------------------------------------

-- page = { Build = function(page) ... end, Update = function(page, now) ... end };
-- Build makes the widgets on page.frame once, Update fills them. enabled(now),
-- when given, greys the tab out while it returns false. A hidden page has no
-- tab button: something else selects it (the "?" or Players button, or the
-- switch of its `group` tab, which stays highlighted while the page is shown).
function Window:AddTab(key, title, page, enabled, hidden, group)
  if type(key) ~= "string" or self.tabs[key] or type(page) ~= "table" or type(page.Update) ~= "function" then
    return false
  end
  if enabled ~= nil and type(enabled) ~= "function" then return false end
  page.key = key
  self.tabs[key] = { key = key, title = title, page = page, enabled = enabled, hidden = hidden and true or nil,
    group = group }
  self.order[#self.order + 1] = key
  if not self.selected then self.selected = key end
  if self.frame then self:BuildTabs() end
  return true
end

-- Disabled buttons do not receive hover events on Forever. A mouse-only
-- sibling preserves the disabled appearance while owning the tooltip; show it
-- only while the button is disabled.
local function DisabledTip(button, title, text)
  local hit = GetGlobal("CreateFrame")("Frame", nil, button:GetParent())
  hit:SetAllPoints(button)
  hit:SetFrameLevel((button:GetFrameLevel() or 0) + 1)
  hit:EnableMouse(true)
  hit:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:AddLine(title, 1, 1, 1)
    GameTooltip:AddLine(text, 0.8, 0.8, 0.8, 1)
    Window.LocalizeTooltip(GameTooltip)
    GameTooltip:Show()
  end)
  hit:SetScript("OnLeave", function() GameTooltip:Hide() end)
  hit:Hide()
  return hit
end

-- Army and Garrison share the Army tab: two Scoreboard-style tabs sit above the
-- first panel (24 px high, 3 px over its top edge), so both pages start
-- ArmyTab.SHIFT lower (NewPanel adds `page.shift`). TOP keeps the tabs off the
-- main tab bar (2026-11-16, user: they sat too close).
local ArmyTab = { TOP = 6, HEIGHT = 24, OVERLAP = 3 }
ArmyTab.SHIFT = ArmyTab.TOP + ArmyTab.HEIGHT - ArmyTab.OVERLAP

function ArmyTab.Paint(tab)
  local state = tab.selected and "selected" or (tab.enabled and tab.over and "hover" or "normal")
  Skin():SetSlice3(tab.art, "scoreboard.tab." .. state)
  Skin():Color(tab.label, tab.selected and "GOLD" or (not tab.enabled and "DIM") or (tab.over and "WHITE" or "N"))
  tab.label:ClearAllPoints()
  tab.label:SetPoint("CENTER", tab, "CENTER", 0, 1 - (tab.selected and 0 or 2))
end

-- The tabs' backing, like the Scoreboard's outer panel: drawn first, so the
-- page's panels cover everything but the strip behind the tabs.
function ArmyTab.Backdrop(page)
  page.shift = ArmyTab.SHIFT
  -- Starts at the main tab bar (2026-11-16, user: no floating strip); only the
  -- tabs sit TOP lower inside it.
  local back = Skin():Panel(page.frame, "", CONTENT_WIDTH, ArmyTab.SHIFT + 12)
  Place(back, page.frame, 0, 0)
  back.title:GetParent():Hide()
end

function ArmyTab.New(page, level, key, title)
  local tab = GetGlobal("CreateFrame")("Button", nil, page.frame)
  tab:SetHeight(ArmyTab.HEIGHT)
  tab:SetFrameLevel(level)
  tab.art = Skin():Slice3(tab, "scoreboard.tab.normal", ArmyTab.HEIGHT, "BACKGROUND")
  tab.label = Skin():Text(tab, "GameFontNormal", "CENTER")
  tab.label:SetText(WF.L(title))
  tab:SetWidth(math.max(86, math.floor((tab.label:GetStringWidth() or 0) + 0.5) + 36))
  tab.key, tab.enabled = key, true
  tab:SetScript("OnClick", function(b) if b.enabled then Window:Select(b.key) end end)
  tab:SetScript("OnEnter", function(b) b.over = true ArmyTab.Paint(b) end)
  tab:SetScript("OnLeave", function(b) b.over = false ArmyTab.Paint(b) end)
  return tab
end

local function ArmySwitch(page, panel)
  local level = (panel:GetFrameLevel() or 0) + 3
  local army = ArmyTab.New(page, level, "army", "Army")
  local garrison = ArmyTab.New(page, level, "garrison", "Garrison")
  Place(army, page.frame, 12, -ArmyTab.TOP)
  Place(garrison, page.frame, 12 + army:GetWidth() + 2, -ArmyTab.TOP)
  garrison.disabledTip = DisabledTip(garrison, "Garrison unavailable",
    "Visit an Outpost or Settlement to manage its garrison.")
  page.switch = { army = army, garrison = garrison }
  ArmyTab.Paint(army)
  ArmyTab.Paint(garrison)
end

local function RefreshArmySwitch(page)
  local switch = page.switch
  if not switch then return end
  local inside = Window.InGarrison()
  switch.army.selected = page.key == "army"
  switch.garrison.selected = page.key == "garrison"
  switch.garrison.enabled = inside and true or false
  ArmyTab.Paint(switch.army)
  ArmyTab.Paint(switch.garrison)
  Show(switch.garrison.disabledTip, not inside)
end

-- Actions ---------------------------------------------------------------------

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

-- Pledge basket (user, 2026-11-20): each +1/+5 adds to what Yes gives, so
-- 2 Footmen and 1 Rifleman go out together. Local only until Yes.
-- Returns the basket as { kind, count } in unit order, then gold and wood.
function Window.PledgeItems(confirm)
  local items, kinds = {}, {}
  local garrison = WF.Garrison
  for _, key in ipairs(garrison and garrison.UNIT_ORDER or {}) do kinds[#kinds + 1] = key end
  kinds[#kinds + 1], kinds[#kinds + 2] = "gold", "wood"
  for _, kind in ipairs(kinds) do
    local count = confirm and confirm.items[kind]
    if count and count > 0 then items[#items + 1] = { kind = kind, count = count } end
  end
  return items
end

-- Unit Size of the basket's units (modules/army.lua sizes).
function Window.PledgeSize(confirm)
  local units, size = WF.Army and WF.Army.UNITS or {}, 0
  for _, item in ipairs(Window.PledgeItems(confirm)) do
    local unit = units[item.kind]
    if unit and unit.size then size = size + item.count * unit.size end
  end
  return size
end

function Window:AskPledge(kind, count)
  local area = WF.Presence and WF.Presence.current
  local garrison = WF.Garrison
  local basket = self.confirm
  if not area or not basket or basket.id ~= area.id then basket = nil end
  local already = basket and basket.items[kind] or 0
  -- War Chest picks stop at the next level's goal (user, 2026-11-20): +500
  -- adds only what is still needed; the next goal shows once it is reached.
  local chest = (kind == "gold" or kind == "wood") and garrison and area and garrison:View(area.id)
  local goal = chest and (kind == "gold" and chest.nextGold or chest.nextWood)
  if goal then count = math.min(count, goal - chest[kind] - already) end
  if count < 1 then
    self:SetStatus("Pledge refused: " .. "the War Chest needs only " .. 0 .. " more " .. kind, "BAD")
    self:Refresh()
    return false
  end
  local total = count + already
  local valid, reason = garrison and garrison:Check(kind, total)
  local view = valid and garrison:View(area.id)
  if valid and view and WF.Army and WF.Army.UNITS and WF.Army.UNITS[kind] then
    -- Check sees one kind only: the whole basket must fit the garrison too.
    local after = { id = area.id, items = {} }
    for key, value in pairs(basket and basket.items or {}) do after.items[key] = value end
    after.items[kind] = total
    local size = Window.PledgeSize(after)
    if view.used + size > view.capacity then
      valid, reason = nil, "garrison full: needs " .. size .. " Unit Size, " .. view.used .. "/" .. view.capacity .. " used"
    end
  end
  if not area or not valid then
    self:SetStatus("Pledge refused: " .. tostring(reason or "you are not inside a garrison"), "BAD")
    self:Refresh()
    return false
  end
  basket = basket or { id = area.id, items = {} }
  basket.items[kind] = total
  self.confirm = basket
  self:SetStatus(nil)
  self:Refresh()
  return true
end

function Window:CancelPledge()
  self.confirm = nil
  self:SetStatus("Pledge cancelled", "DIM")
  self:Refresh()
end

-- Sends the basket one kind at a time: a character has one pledge waiting
-- for the keeper at most (modules/garrison.lua, Garrison:Pledge), so the next
-- kind leaves once the keeper answered the previous one (WatchPledges).
function Window:Pledge()
  local confirm = self.confirm
  self.confirm = nil
  local area = WF.Presence and WF.Presence.current
  local ok = false
  if not confirm or not area or area.id ~= confirm.id then
    self:SetStatus("Pledge refused: " .. "you are no longer in the same place", "BAD")
  else
    self.pledgeQueue = { id = confirm.id, items = Window.PledgeItems(confirm) }
    ok = self:NextPledge()
  end
  self:Refresh()
  return ok
end

-- Pledges the queue's next kinds with the reserve's current pledge number, so
-- one confirmation pledges each kind once. Stops at the first refusal.
function Window:NextPledge()
  local queue = self.pledgeQueue
  local garrison = WF.Garrison
  while queue and queue.items[1] do
    local item = table.remove(queue.items, 1)
    local area = WF.Presence and WF.Presence.current
    local reserve = WF.Army and WF.Army:Reserve()
    local ok, result = false, "no saved data or identity yet"
    if not area or area.id ~= queue.id then
      result = "you are no longer in the same place"
    elseif garrison and reserve then
      ok, result = garrison:Pledge(item.kind, item.count, reserve.gop)
    end
    if not ok then
      self.pledgeQueue = nil
      self:SetStatus("Pledge refused: " .. tostring(result), "BAD")
      return false
    end
    if result == "sent" then
      self:SetStatus("Pledge sent: waiting for the garrison keeper", "GOOD")
      queue.before = garrison.last
      if queue.items[1] then self:WatchPledges() else self.pledgeQueue = nil end
      return true
    end
    self:SetStatus("Pledged " .. item.count .. " " .. garrison:Name(item.kind, garrison:View(queue.id).owner), "GOOD")
  end
  self.pledgeQueue = nil
  return true
end

-- Runs only while a basket waits for a keeper's answer, even with the window
-- closed; a refused or returned pledge drops the rest of the basket.
function Window:WatchPledges()
  local watcher = self.pledgeWatcher
  if not watcher then
    watcher = GetGlobal("CreateFrame")("Frame")
    self.pledgeWatcher = watcher
  end
  local wait = 0
  watcher:SetScript("OnUpdate", function(_, elapsed)
    wait = wait - (elapsed or 0)
    if wait > 0 then return end
    wait = 0.25
    local queue, garrison = Window.pledgeQueue, WF.Garrison
    if queue and garrison and garrison:Pending() then return end
    watcher:SetScript("OnUpdate", nil)
    if not queue or not garrison then return end
    local last = garrison.last
    if last and last ~= queue.before and not last.ok then
      Window.pledgeQueue = nil
      Window:SetStatus(last.text, "BAD")
    else
      Window:NextPledge()
    end
    if Window.frame and Window.frame:IsShown() then Window:Refresh() end
  end)
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

function Window:BuildTabs()
  local frame = self.frame
  local index = 1
  while index <= #self.order do
    local tab = self.tabs[self.order[index]]
    if not tab.hidden and not tab.button then
      local number = #self.tabButtons + 1
      local button = Skin():Button(frame, "tab", 100, 26, function(b) Window:Select(b.tabKey) end, NAME .. "Tab" .. number)
      button.tabKey = tab.key
      Skin():SetButton(button, tab.title, true)
      tab.button = button
      self.tabButtons[#self.tabButtons + 1] = button
    end
    index = index + 1
  end
  -- Reserve the longest translated title, left of the Players and "?" buttons.
  local count = #self.tabButtons
  if count == 0 then return end
  Skin():SizeTranslatedTabs(frame, self.tabButtons, self.tabs, CONTENT_WIDTH - HELP_SIZE - 4 - PLAYERS_WIDTH - self.JOURNAL_WIDTH)
  local left = CONTENT_LEFT
  index = 1
  while index <= count do
    local button = self.tabButtons[index]
    Place(button, frame, left, CONTENT_TOP + 26)
    left = left + button:GetWidth()
    index = index + 1
  end
end

function Window:BuildPage(tab)
  local page = tab.page
  if page.frame then return true end
  local frame = GetGlobal("CreateFrame")("Frame", nil, self.frame)
  frame:SetWidth(CONTENT_WIDTH)
  frame:SetHeight(CONTENT_HEIGHT)
  Place(frame, self.frame, CONTENT_LEFT, CONTENT_TOP)
  page.frame = frame
  page.error = Skin():Text(frame, "GameFontHighlight", "LEFT")
  Place(page.error, frame, 8, -8)
  page.error:SetWidth(CONTENT_WIDTH - 16)
  if page.Build then
    local ok, err = pcall(page.Build, page)
    if not ok then
      if WF.RecordError then WF.RecordError("main window " .. tab.key, err) end
      page.broken = tostring(err)
    end
  end
  frame:Hide()
  return true
end

local function Ornament(frame, name, scale, point, x, y, level)
  local piece = Skin():Piece(name)
  if not piece then return nil end
  local image = Skin():Image(frame, name, piece.w * scale, piece.h * scale, "ARTWORK")
  image:SetPoint(point, frame, point, x, y)
  image:SetFrameLevel((frame:GetFrameLevel() or 0) + (level or 4))
  return image
end

-- True below level 5 (decision 0039) or while nobody can hear us (decision
-- 0141): the player takes no part in the conquest and the maps show nothing.
function Window.Locked()
  return WF.Capture and WF.Capture.CanTalk and not WF.Capture:CanTalk() and true or false
end

-- True when the lock is the isolation one (decision 0141), not the level.
function Window.Connecting()
  local capture = WF.Capture
  return capture and type(capture.LockKind) == "function" and capture:LockKind() == "isolated" or false
end

function Window.LockTitle()
  if Window.Connecting() then return "Connecting to Warfront" end
  return "Reach level " .. LOCK_LEVEL .. " to join the conquest"
end

function Window.LockSummary()
  if Window.Connecting() then return "Connecting..." end
  return "Level " .. LOCK_LEVEL .. " required"
end

function Window.LockText()
  if Window.Connecting() then
    return "Until you are connected you cannot capture, gather, send scouts or attack, and the"
      .. " world map and minimap show no conquest places.\n\n"
      .. "Click anywhere in the game or press Connect at the bottom. If it takes long, update"
      .. " Warfront, then restart the game."
  end
  local ok, level = pcall(GetGlobal("UnitLevel") or function() return nil end, "player")
  local yours = ok and type(level) == "number" and level > 0 and (" You are level " .. level .. ".") or ""
  return "Warfront opens at level " .. LOCK_LEVEL .. "; before that, what it would show"
    .. " could be wrong." .. yours .. "\n\n"
    .. "Until then you cannot capture, gather, send scouts or attack, and the world map and"
    .. " minimap show no conquest places.\n\n"
    .. "At level " .. LOCK_LEVEL .. " you join automatically, no /reload needed. Meanwhile the"
    .. " Guide tab explains how the conquest works."
end

function Window:ShowLock()
  if not self.lock then
    local frame = GetGlobal("CreateFrame")("Frame", nil, self.frame)
    frame:SetWidth(CONTENT_WIDTH)
    frame:SetHeight(CONTENT_HEIGHT)
    Place(frame, self.frame, CONTENT_LEFT, CONTENT_TOP)
    Skin():Slice9(frame, "panel", 0.25, "BACKGROUND")
    frame.title = NewText(frame, "GameFontNormalLarge", 24, -120, CONTENT_WIDTH - 48, "CENTER")
    frame.title:SetHeight(24)
    frame.text = NewText(frame, "GameFontHighlight", 48, -160, CONTENT_WIDTH - 96, "CENTER")
    frame.text:SetHeight(200)
    frame.text:SetJustifyV("TOP")
    -- Turning arrow above the title while connecting (decision 0141).
    local spinner = GetGlobal("CreateFrame")("Frame", nil, frame)
    spinner:SetWidth(32)
    spinner:SetHeight(32)
    Place(spinner, frame, math.floor((CONTENT_WIDTH - 32) / 2), -76)
    local arrow = spinner:CreateTexture(nil, "ARTWORK")
    arrow:SetAllPoints(spinner)
    arrow:SetTexture("Interface\\AddOns\\Warfront\\media\\Textures\\UI\\LoadingArrow")
    local angle = 0
    spinner:SetScript("OnUpdate", function(_, elapsed)
      if type(arrow.SetRotation) ~= "function" then return end
      angle = (angle - (elapsed or 0) * 4) % (2 * math.pi)
      arrow:SetRotation(angle)
    end)
    spinner:Hide()
    frame.spinner = spinner
    self.lock = frame
  end
  SetText(self.lock.title, Paint("GOLD", Window.LockTitle()))
  SetText(self.lock.text, Window.LockText())
  Show(self.lock.spinner, Window.Connecting())
  if not self.lock:IsShown() then self.lock:Show() end
end

function Window:Build()
  if self.frame then return self.frame end
  local create = GetGlobal("CreateFrame")
  if type(create) ~= "function" or not WF.Skin or not WF.UIAtlas then return nil end
  local ok, frame = pcall(create, "Frame", NAME, UIParent)
  if not ok or not frame then return nil end
  self.frame = frame
  frame:SetWidth(WIDTH)
  frame:SetHeight(HEIGHT)
  frame:SetPoint("CENTER", UIParent, "CENTER", 0, 20 / Window.UI_SCALE)
  frame:SetFrameStrata("HIGH")
  frame:SetToplevel(true)
  frame:EnableMouse(true)
  frame:SetMovable(true)
  frame:SetClampedToScreen(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
  frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
  frame:SetScript("OnShow", function()
    Window:FitScale()
    if Window.PickPlayerFrontRoute then Window:PickPlayerFrontRoute() end
    Window:Refresh()
  end)
  -- A new UI scale or resolution refits the window (Window:FitScale).
  frame:RegisterEvent("UI_SCALE_CHANGED")
  frame:RegisterEvent("DISPLAY_SIZE_CHANGED")
  frame:SetScript("OnEvent", function() Window:FitScale() end)
  frame:SetScript("OnUpdate", function(_, elapsed) Window:OnUpdate(elapsed) end)

  -- One shared frame: dark stone, the Alliance lion and drape on the left
  -- corner, the Horde cloth, crest and chain on the right corner, their rails on
  -- the top border, the Warfront medallion and title between.
  local border = Skin():Border(frame, { top = "frame.top", bottom = "frame.bottom", left = "frame.left",
    right = "frame.right", centre = "frame.centre", sideCap = 14, overlap = 10 }, FRAME_SCALE)
  -- The bottom bar's middle drops its thin top rim (frame.bottom rows 0-12),
  -- a stray line under the page footer texts (2026-11-16, user).
  local bottomSlice = border and border.parts.bottomSlice
  local bottomPiece = Skin():Piece("frame.bottom")
  if bottomSlice and bottomPiece then
    local rim = 13
    Skin():Apply(bottomSlice.M, "frame.bottom", bottomPiece.insets[1], bottomPiece.w - bottomPiece.insets[2],
      rim, bottomPiece.h)
    bottomSlice.M:ClearAllPoints()
    bottomSlice.M:SetPoint("TOPLEFT", bottomSlice.L, "TOPRIGHT", 0, -rim * FRAME_SCALE)
    bottomSlice.M:SetPoint("BOTTOMRIGHT", bottomSlice.R, "BOTTOMLEFT", 0, 0)
  end
  -- The footer has no strip of its own (2026-11-16, user): its texts sit in
  -- the dark band of the frame's bottom border (FOOTER).
  local status = create("Frame", nil, frame)
  status:SetHeight(FOOTER.height)
  status:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, FOOTER.bottom)
  status:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, FOOTER.bottom)
  status:SetFrameLevel((frame:GetFrameLevel() or 0) + 5)
  self.statusBar = status
  self.ornaments = {
    alliance = Ornament(frame, "frame.alliance", ALLIANCE_SCALE, "TOPLEFT", -8, 28),
    horde = Ornament(frame, "frame.horde", HORDE_SCALE, "TOPRIGHT", 8, 36),
    medallion = Ornament(frame, "frame.medallion", ORNAMENT_SCALE, "TOP", 0, 38, 6),
    title = Ornament(frame, "frame.title", TITLE_SCALE, "TOP", 0, -25, 7),
  }
  local close = Skin():CloseButton(frame, 26, function() Window.frame:Hide() end)
  close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 7, 36)
  close:SetFrameLevel((frame:GetFrameLevel() or 0) + 9)
  self.close = close

  self.status = Skin():Text(status, "GameFontHighlightSmall", "LEFT")
  -- The addon version sits first on the left of the footer; the status text
  -- and the Connect button follow it. Each text stays one line on its side of
  -- the Synchronization handle, its font shrunk to fit (FitText).
  self.versionLabel = Skin():Text(status, "GameFontDisableSmall", "LEFT")
  self.versionLabel:SetPoint("LEFT", status, "LEFT", FOOTER.left, 0)
  self.versionLabel:SetWidth(VERSION_WIDTH)
  self.versionLabel:SetText("v" .. tostring(WF.version))
  self.statusLeft = FOOTER.left + VERSION_WIDTH + 6
  self.statusRoom = FOOTER.centre - self.statusLeft
  self.status:SetPoint("LEFT", status, "LEFT", self.statusLeft, 0)
  self.status:SetHeight(FOOTER.height + 2)
  self.status:SetWidth(self.statusRoom)
  -- Shown while the player is not connected (decision 0118).
  -- Red face and white label so it stands out on the dark border (2026-11-16, user).
  local connect = Skin():Button(status, "red", CONNECT_WIDTH, 20, function() Window:Connect() end, NAME .. "Connect")
  connect.textColor = "WHITE"
  Skin():SetButton(connect, "Connect", true)
  connect:SetPoint("LEFT", status, "LEFT", self.statusLeft, 0)
  local connectEnter, connectLeave = connect:GetScript("OnEnter"), connect:GetScript("OnLeave")
  connect:SetScript("OnEnter", function(button)
    if connectEnter then connectEnter(button) end
    GameTooltip:SetOwner(button, "ANCHOR_TOP")
    GameTooltip:AddLine("Connect", 1, 1, 1)
    GameTooltip:AddLine("You are not connected to Warfront. Click to connect and see the war live with the other players.", 0.8, 0.8, 0.8, 1)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Still not connecting? Update Warfront, then restart the game.", 1, 0.82, 0, 1)
    Window.LocalizeTooltip(GameTooltip)
    GameTooltip:Show()
  end)
  connect:SetScript("OnLeave", function(button)
    if connectLeave then connectLeave(button) end
    GameTooltip:Hide()
  end)
  connect:Hide()
  self.connect = connect
  self.summary = Skin():Text(status, "GameFontHighlightSmall", "RIGHT")
  self.summary:SetPoint("RIGHT", status, "RIGHT", -FOOTER.right, 0)
  self.summary:SetHeight(FOOTER.height + 2)
  -- The handle is centred, so the right side has the same room as the left.
  self.summaryRoom = FOOTER.centre - FOOTER.right
  self.summary:SetWidth(self.summaryRoom)
  -- Footer texts draw 2 px smaller than their templates (2026-11-16, user);
  -- FitText takes this reduced size as its base.
  for _, text in ipairs({ self.versionLabel, self.status, self.summary }) do
    local font, size, flags = text:GetFont()
    if font and size then text:SetFont(font, size - 2, flags) end
  end
  -- The version also sits beside the Warfront title (2026-11-16, user).
  local titleArt = self.ornaments.title
  if titleArt then
    local holder = create("Frame", nil, frame)
    holder:SetAllPoints(frame)
    holder:SetFrameLevel((frame:GetFrameLevel() or 0) + 8)
    self.titleVersion = Skin():Text(holder, "GameFontDisableSmall", "LEFT")
    -- frame.title ends its letters 71 px before its right edge (transparent).
    self.titleVersion:SetPoint("BOTTOMLEFT", titleArt, "BOTTOMRIGHT", 3 - 71 * TITLE_SCALE, 6)
    self.titleVersion:SetText("v" .. tostring(WF.version))
  end
  -- Both version texts open What's new (main_window_changelog.lua).
  self:BindVersion(self.versionLabel)
  self:BindVersion(self.titleVersion)
  self:BuildTabs()
  local help = Skin():Button(frame, "tab", HELP_SIZE, 26, function() Window:ToggleGuide() end, NAME .. "Help")
  Skin():SetButton(help, "?", true)
  -- The "?" spans the whole button, centred by its justification.
  help.label:ClearAllPoints()
  help.label:SetPoint("LEFT", help, "LEFT", 0, -1)
  help.label:SetPoint("RIGHT", help, "RIGHT", 0, -1)
  Place(help, frame, CONTENT_LEFT + CONTENT_WIDTH - HELP_SIZE, CONTENT_TOP + 26)
  -- The skin's own hover glow first, then the tooltip (same for Players).
  local helpEnter, helpLeave = help:GetScript("OnEnter"), help:GetScript("OnLeave")
  help:SetScript("OnEnter", function(self)
    if helpEnter then helpEnter(self) end
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
    GameTooltip:AddLine("Guide", 1, 1, 1)
    GameTooltip:AddLine("How to play Warfront.", 0.8, 0.8, 0.8, 1)
    Window.LocalizeTooltip(GameTooltip)
    GameTooltip:Show()
  end)
  help:SetScript("OnLeave", function(self)
    if helpLeave then helpLeave(self) end
    GameTooltip:Hide()
  end)
  self.help = help
  self:BuildJournalButton(frame, CONTENT_LEFT + CONTENT_WIDTH - HELP_SIZE - 4 - self.JOURNAL_WIDTH, CONTENT_TOP + 26)
  local players = Skin():Button(frame, "tab", PLAYERS_WIDTH, 26, function() Window:ToggleHidden("players") end,
    NAME .. "Players")
  Skin():SetButton(players, "", true)
  Place(players, frame, CONTENT_LEFT + CONTENT_WIDTH - HELP_SIZE - 4 - PLAYERS_WIDTH - self.JOURNAL_WIDTH, CONTENT_TOP + 26)
  -- The group atlas only when the client knows it; otherwise the label reads "Online".
  local textureApi = GetGlobal("C_Texture")
  local known, info = false, nil
  if type(textureApi) == "table" and type(textureApi.GetAtlasInfo) == "function" then
    known, info = pcall(textureApi.GetAtlasInfo, PLAYERS_ATLAS)
  end
  players.icon = Skin():Icon(players, nil, 19, 17, "ARTWORK")
  if known and type(info) == "table" and players.icon.SetAtlas
      and pcall(players.icon.SetAtlas, players.icon, PLAYERS_ATLAS) then
    players.hasIcon = true
  else
    players.icon:Hide()
  end
  local playersEnter, playersLeave = players:GetScript("OnEnter"), players:GetScript("OnLeave")
  players:SetScript("OnEnter", function(self)
    if playersEnter then playersEnter(self) end
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
    GameTooltip:AddLine("Players", 1, 1, 1)
    GameTooltip:AddLine("Everyone online with Warfront right now.", 0.8, 0.8, 0.8, 1)
    Window.LocalizeTooltip(GameTooltip)
    GameTooltip:Show()
  end)
  players:SetScript("OnLeave", function(self)
    if playersLeave then playersLeave(self) end
    GameTooltip:Hide()
  end)
  self.players = players
  self:RefreshPlayersButton()
  self:BuildFrontDrawer()
  self:BuildSyncDrawer()
  self:FitScale()

  -- Escape closes the frames listed in UISpecialFrames (FrameXML UIParent.lua).
  local special = GetGlobal("UISpecialFrames")
  if type(special) == "table" then special[#special + 1] = NAME end
  frame:Hide()
  return frame
end

function Window:Refresh()
  if not self.frame then return end
  local now = Now()
  local tab = self.tabs[self.selected]
  if tab and not self:TabEnabled(tab, now) then
    -- The place that opened this tab was left: back to its group tab (Army),
    -- or the first tab.
    self.selected, self.confirm = tab.group or self.order[1], nil
    tab = self.tabs[self.selected]
  end
  if not tab then return end
  local offline = self:RefreshConnect(now)
  -- Below level 5 every tab but the Guide, Journal, Scoreboard and Players
  -- shows the level notice instead; the last two only read (decision 0039).
  local levelLocked = Window.Locked()
  local locked = levelLocked and tab.key ~= "guide" and tab.key ~= "journal"
    and not ((tab.key == "ranks" or tab.key == "players") and not Window.Connecting())
  if self.frontToggle then
    Show(self.frontToggle, not levelLocked and WF.Front and WF.Front:HasRoutes())
    -- Hidden while locked or without routes; reopens once available again.
    local available = not levelLocked and WF.Front and WF.Front:HasRoutes()
    if not available and FrontDrawer.target > 0 then
      self:SnapFrontDrawer(0)
      FrontDrawer.reopen = true
    elseif available and FrontDrawer.reopen then
      FrontDrawer.reopen = nil
      self:SnapFrontDrawer(1)
    end
  end
  -- Every tab, the level lock included: it tells why the player cannot take part.
  self:RefreshSyncDrawer(now)
  for index = 1, #self.order do
    local other = self.tabs[self.order[index]]
    if (locked or other ~= tab) and other.page.frame and other.page.frame:IsShown() then other.page.frame:Hide() end
  end
  if locked then
    self:ShowLock()
    FitText(self.summary, Paint("BAD", Window.LockSummary()), self.summaryRoom)
    self:RefreshTabs(now)
    return
  end
  if self.lock and self.lock:IsShown() then self.lock:Hide() end
  self:BuildPage(tab)
  local page = tab.page
  if not page.frame:IsShown() then page.frame:Show() end
  local ok, err = true, page.broken
  if not err then ok, err = pcall(page.Update, page, now) end
  if not ok or page.broken then
    if not ok and WF.RecordError then WF.RecordError("main window " .. tab.key, err) end
    SetText(page.error, Paint("BAD", "This tab failed: " .. tostring(err)))
  else
    SetText(page.error, "")
  end
  local summary = ""
  if ok and page.Summary then
    local fine, text = pcall(page.Summary, page)
    if fine and type(text) == "string" then summary = text end
  end
  -- A newer Warfront stays visible on every tab (decision 0108).
  local notice = WF.Version and WF.Version:Notice()
  if notice then summary = Paint("BAD", notice)
  elseif offline then summary = Paint("BAD", "Not connected to Warfront.") end
  FitText(self.summary, summary, self.summaryRoom)
  self:PaintVersion()
  self:RefreshTabs(now)
  self:RefreshFrontDrawer(now)
end

function Window:RefreshTabs(now)
  for index = 1, #self.tabButtons do
    local button = self.tabButtons[index]
    button.tabEnabled = self:TabEnabled(self.tabs[button.tabKey], now)
    -- A grouped page (Garrison) keeps its group's tab (Army) highlighted.
    local shown = self.tabs[self.selected]
    local selected = button.tabKey == self.selected or (shown and shown.group == button.tabKey)
    Skin():SetButton(button, self.tabs[button.tabKey].title, button.tabEnabled, selected)
  end
  if self.help then Skin():SetButton(self.help, "?", true, self.selected == "guide") end
  self:RefreshJournalButton()
  self:RefreshPlayersButton()
end

-- The Players button: the group atlas and, once the list was read, the count.
function Window:RefreshPlayersButton()
  local button = self.players
  if not button then return end
  local players = WF.Players
  local count = players and players.updatedAt and players.count or nil
  local label = count and tostring(count) or ""
  if not button.hasIcon then label = "Online" end
  Skin():SetButton(button, label, true, self.selected == "players")
  if button.hasIcon then
    button.icon:ClearAllPoints()
    if label == "" then
      button.icon:SetPoint("CENTER", button, "CENTER", 0, -1)
    else
      button.icon:SetPoint("RIGHT", button, "CENTER", 3, -1)
      button.label:ClearAllPoints()
      button.label:SetPoint("LEFT", button, "CENTER", 5, -1)
    end
  end
end

-- The "?" and Players buttons: open their page, or go back to the tab shown
-- before (never to the other button's page).
function Window:ToggleHidden(key)
  if self.selected ~= key then
    local current = self.tabs[self.selected]
    if current and (not current.hidden or current.group) then self.beforeHidden = self.selected end
    return self:Select(key)
  end
  local back = self.beforeHidden
  self.beforeHidden = nil
  return back and self:Select(back) or self:Select(self.order[1])
end

function Window:ToggleGuide()
  return self:ToggleHidden("guide")
end

function Window:RefreshPlayers()
  local players = WF.Players
  if not players then return end
  if players:Request() then
    self:SetStatus("Looking for players...", "DIM")
  elseif not players:Joined() then
    self:SetStatus("Not connected yet. Try again in a moment.", "BAD")
  else
    self:SetStatus("Please wait a few seconds.", "DIM")
  end
end

function Window:TabEnabled(tab, now)
  if not tab.enabled then return true end
  local ok, enabled = pcall(tab.enabled, now)
  return ok and enabled and true or false
end

function Window:OnUpdate(elapsed)
  self:AnimateFrontDrawer(elapsed)
  self:AnimateSyncDrawer(elapsed)
  self.elapsed = self.elapsed + (elapsed or 0)
  if self.elapsed < REFRESH_INTERVAL then return end
  self.elapsed = 0
  self:Refresh()
end

function Window:SetStatus(text, color)
  self.connectingAt, self.connectedAt = nil, nil
  if self.status then FitText(self.status, text and Paint(color, text) or "", self.statusRoom) end
end

-- The Connect button and its status, while the player is not connected
-- (decision 0118). Returns true while not connected.
function Window:RefreshConnect(now)
  local button = self.connect
  local p2p = WF.P2PTest
  if not button or not p2p or type(p2p.ChannelJoined) ~= "function" then return false end
  local ok, joined = pcall(p2p.ChannelJoined)
  local offline = ok and not joined
  if offline ~= button:IsShown() then
    Show(button, offline)
    self.status:ClearAllPoints()
    if offline then
      self.status:SetPoint("LEFT", button, "RIGHT", 6, 0)
    else
      self.status:SetPoint("LEFT", self.statusBar, "LEFT", self.statusLeft, 0)
    end
    -- The Connect button takes its width from the status room; refit the text.
    self.statusRoom = FOOTER.centre - self.statusLeft - (offline and CONNECT_WIDTH + 6 or 0)
    local value = self.status.fitValue or ""
    self.status.fitValue = nil
    FitText(self.status, value, self.statusRoom)
  end
  -- After a click: confirm the connection, or point to the chat command when
  -- it has not landed in time; the confirmation clears after CONNECT_DONE.
  if self.connectingAt then
    if not offline then
      self:SetStatus("Connected to Warfront.", "GOOD")
      self.connectedAt = now
    elseif now - self.connectingAt > CONNECT_WAIT then
      self:SetStatus("Type /join Warfront in chat to connect.", "WARN")
    end
  elseif self.connectedAt and now - self.connectedAt > CONNECT_DONE then
    self:SetStatus(nil)
  end
  return offline
end

function Window:Connect()
  local p2p = WF.P2PTest
  if not p2p or type(p2p.JoinChannelFromUI) ~= "function" then return end
  local ok, result = pcall(p2p.JoinChannelFromUI)
  if not ok and WF.RecordError then WF.RecordError("connect", result) end
  if ok and result == "joining" then
    self:SetStatus("Connecting...", "GOOD")
    self.connectingAt = Now()
  elseif ok and result == "chat" then
    self:SetStatus("Press Enter in chat to connect.", "GOOD")
  elseif not (ok and result == "joined") then
    self:SetStatus("Type /join Warfront in chat to connect.", "WARN")
  end
  self:Refresh()
end

function Window:Select(key)
  if not self.tabs[key] or not self:TabEnabled(self.tabs[key], Now()) then return false end
  self.selected = key
  self:SetStatus(nil)
  self:Refresh()
  return true
end

-- /wf and /wf ui
function Window:Toggle()
  local frame = self:Build()
  if not frame then
    WF.Print("The Warfront window is unavailable.")
    return false
  end
  if frame:IsShown() then frame:Hide() else frame:Show() end
  return true
end

-- Shared with the page and drawer files (modules/main_window_*.lua), which
-- load after this one and alias what they use.
Window.Kit = {
  NAME = NAME,
  CONTENT_WIDTH = CONTENT_WIDTH,
  CONTENT_HEIGHT = CONTENT_HEIGHT,
  GAP = GAP,
  RESOURCE_NAMES = RESOURCE_NAMES,
  FrontDrawer = FrontDrawer,
  SyncDrawer = SyncDrawer,
  GetGlobal = GetGlobal,
  EaseOutSoftBounce = EaseOutSoftBounce,
  Now = Now,
  Paint = Paint,
  FactionName = FactionName,
  FactionText = FactionText,
  Duration = Duration,
  AreaName = AreaName,
  AreaZone = AreaZone,
  MyFaction = MyFaction,
  OtherFaction = OtherFaction,
  UnitIcon = UnitIcon,
  Skin = Skin,
  Place = Place,
  NewText = NewText,
  SetText = SetText,
  FitText = FitText,
  Show = Show,
  NewPanel = NewPanel,
  NewFrame = NewFrame,
  Scroll = Scroll,
  NewList = NewList,
  FillList = FillList,
  NewButton = NewButton,
  SetAction = SetAction,
  Collect = Collect,
  MapIDForKey = MapIDForKey,
  PlayerDistanceContext = PlayerDistanceContext,
  SortByPlayerDistance = SortByPlayerDistance,
  ArmyTab = ArmyTab,
  ArmySwitch = ArmySwitch,
  RefreshArmySwitch = RefreshArmySwitch,
}
