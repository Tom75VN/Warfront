local WF = Warfront
local Window = WF.MainWindow

-- Main window (modules/main_window.lua): the Territory page and the Synchronization drawer panel.
-- The base file loads first and shares its constants and helpers through
-- Window.Kit. Keep every main_window file far below the 200-local limit
-- (.claude/forever-compatibility.md, Lua runtime).
local Kit = Window.Kit
local CONTENT_WIDTH = Kit.CONTENT_WIDTH
local CONTENT_HEIGHT = Kit.CONTENT_HEIGHT
local SyncDrawer = Kit.SyncDrawer
local GetGlobal = Kit.GetGlobal
local Now = Kit.Now
local Paint = Kit.Paint
local FactionName = Kit.FactionName
local FactionText = Kit.FactionText
local Duration = Kit.Duration
local AreaName = Kit.AreaName
local AreaZone = Kit.AreaZone
local MyFaction = Kit.MyFaction
local Skin = Kit.Skin
local Place = Kit.Place
local NewText = Kit.NewText
local SetText = Kit.SetText
local FitText = Kit.FitText
local Show = Kit.Show
local NewPanel = Kit.NewPanel
local NewFrame = Kit.NewFrame
local NewList = Kit.NewList
local NewButton = Kit.NewButton
local FillList = Kit.FillList
local Collect = Kit.Collect
local PlayerDistanceContext = Kit.PlayerDistanceContext
local SortByPlayerDistance = Kit.SortByPlayerDistance

-- The tab summary counts strategic territory only; the Points of Interest list
-- also shows War Camps, which feed the Front Network instead (decision 0123 § 8).
local BALANCE_TYPES = { OUTPOST = true, SETTLEMENT = true }
local TERRITORY_TYPES = { OUTPOST = true, SETTLEMENT = true, WAR_CAMP = true }
local NETWORK_FILLS = { A = "fill.blue", H = "fill.red", N = "fill.grey" }
-- War Balance front rows (2026-11-15, user's schema A): one row per continent
-- in its gold frame, the name on the frame's top line, the route rail, then
-- the Front Network strip in its own gold frame (user's mockup, 2026-11-15).
-- Rail x: the advancing faction's lead-in, node 1, the capital (last stop).
-- One table for constants and helpers.
local FRONT = {
  ROW_TOP = -32, ROW_H = 83, RAIL_H = 28, RAIL_Y = -16, PANEL_H = 201,
  -- LEFT 66 (was 40, user 2026-11-15): room for the lead-in chevron left of
  -- stop 1; the stops keep even gaps up to the capital at RIGHT.
  -- LEFT_PASSED (user, 2026-11-20): stop 1 once the attackers are past it,
  -- the lead-in then a short fading tail.
  LEAD = 12, LEFT = 66, LEFT_PASSED = 44, RIGHT = CONTENT_WIDTH - 30,
  -- Front Network strip, y from the row top, x from the panel: label, camp
  -- segments, held/total, divider, then the travel and capture cuts.
  -- NET_CORNER: the strip's frame at half the row frame's thickness (user, 2026-11-15).
  NET_LEFT = 14, NET_TOP = -48, NET_BOTTOM = -74, NET_CORNER = 3,
  -- 2026-11-16 (user): camps wider (136 to 180, gaps 3 to 2), the gaps
  -- around the divider cut 40% and between Travel and Capture 50%; the cuts
  -- end 12 before the frame's right edge. Then (same day) the divider
  -- follows the cuts, DIVIDER_GAP left of the Travel icon; the count ends
  -- COUNT_RIGHT before it and the bar fills the room from BAR_GAP after the
  -- label to COUNT_GAP before the count (Territory:UpdateNetworkBar).
  BAR_GAP = 10, CAMP_H = 14, CAMP_GAP = 2, COUNT_GAP = 8, COUNT_RIGHT = 14,
  DIVIDER_GAP = 13, DIVIDER_W = 3, DIVIDER_H = 20,
  DIVIDER_TEXTURE = "Interface\\AddOns\\Warfront\\media\\Textures\\UI\\Front\\FrontObjectiveDivider",
  -- Cuts right-aligned (user, 2026-11-16): Capture's value ends STAT_RIGHT
  -- before the frame's right edge, Travel ends STAT_GAP before Capture's icon.
  STAT_RIGHT = 12, STAT_GAP = 18, STAT_ICON = 18, CUT_COLOR = { 0.35, 0.78, 1.00 },
  CAMP_TEXTURE = "Interface\\AddOns\\Warfront\\media\\Textures\\UI\\Front\\WarCampSegment",
  CAMP_COLORS = {
    A = { 0.10, 0.42, 1.00 }, H = { 0.90, 0.12, 0.08 }, N = { 0.48, 0.48, 0.48 },
  },
  -- Gold frame (tools/build_section_border.py, 128 x 128, 16 px slices),
  -- drawn with 6 px corners (thinned from 12 in three steps, user 2026-11-15); y from the row top, the top line through the
  -- name's middle, broken under the name.
  BOX_TEXTURE = "Interface\\AddOns\\Warfront\\media\\Textures\\UI\\Border\\WFSectionBorder",
  BOX_SLICE = 16 / 128, BOX_CORNER = 6, BOX_LEFT = 6, BOX_TOP = -5, BOX_BOTTOM = -80, BOX_GAP = 4,
  NAME_SIZE = 9, -- continent name: gold title cap height, as the banner's name
  -- Open stops (user's mockup, 2026-11-15): 128 px HD discs drawn at 58, the
  -- mockup's scale; the number on top in a 22 cell.
  -- Held stops and the capital show their faction emblem, 28% under the
  -- disc's size (user, 2026-11-15).
  -- CAPITAL: the capital crown's atlas cell (ink 68 of 72), 2026-11-20.
  DISC = 58, DIGIT = 22, EMBLEM = 41.76, CAPITAL = 32,
  LINE_H = 6, LINK_H = 3, CHEVRON = 20.125, SIEGE = 18,
  -- Two chevrons on one stretch: each this far from its middle (2026-11-20).
  CHEVRON_PAIR = 9,
  -- Siege flipbook centre from the stop's centre (up is positive), clear of
  -- the frame's top line; 4 x 4 frames at the map's 12 per second.
  SIEGE_DX = 14, SIEGE_DY = 11, SIEGE_FPS = 12, SIEGE_FRAMES = 16,
  -- Grey padlock (icon.lock, 81 x 100) down and right of a locked stop, as on
  -- the map (user, 2026-11-16).
  LOCK_DX = 10, LOCK_DY = -10, LOCK_W = 10, LOCK_H = 12,
  ROUTE_DIR = "Interface\\AddOns\\Warfront\\media\\Textures\\UI\\Route\\",
  EMBLEMS = {
    A = "Interface\\AddOns\\Warfront\\media\\Textures\\UI\\Front\\FactionAlliance",
    H = "Interface\\AddOns\\Warfront\\media\\Textures\\UI\\Front\\FactionHorde",
  },
  SIEGE_TEXTURE = "Interface\\AddOns\\Warfront\\media\\Textures\\UI\\Front\\SiegeCatapultFlipbook",
  -- Open stop styles: beige, gold for the enemy's target, gold with a glow
  -- for the player's own target (both targets while the faction is unknown,
  -- as on the map).
  DISCS = {
    OPEN = "Interface\\AddOns\\Warfront\\media\\Textures\\UI\\Route\\RouteNodePlain",
    ENEMY = "Interface\\AddOns\\Warfront\\media\\Textures\\UI\\Route\\RouteNodeGold",
    MINE = "Interface\\AddOns\\Warfront\\media\\Textures\\UI\\Route\\RouteNodeGoldGlow",
  },
  -- Campaign banner (tools/build_campaign_banner.py, 512 x 73) drawn at half
  -- size, centred over the header strip: the name on the red ribbon, the time
  -- left on the stone plate; text y and room from the banner's top centre.
  BANNER_TEXTURE = "Interface\\AddOns\\Warfront\\media\\Textures\\UI\\Front\\CampaignBanner",
  BANNER_W = 256, BANNER_H = 36.5, BANNER_Y = 1,
  -- The name in the drawer's gold title letters, 9 cap height (Skin:GoldTitle).
  BANNER_NAME_Y = -11.5, BANNER_NAME_W = 150, BANNER_NAME_SIZE = 9, BANNER_LEFT_Y = -27.5, BANNER_LEFT_W = 146,
}
local SOURCE_DOTS = { LOCAL = "dot.green", PEER = "dot.yellow" }
local SOURCE_TIPS = {
  LOCAL = { "Confirmed", "You saw this owner yourself." },
  PEER = { "Reported", "Captured while you were not there. You did not see it yourself." },
  UNCONFIRMED = { "Unconfirmed", "Some players claim this owner, but nobody has confirmed it." },
  STATIC = { "Not captured yet", "Nobody has captured this place since you logged in." },
}
local SOURCE_LABELS = {
  LOCAL = "Confirmed",
  PEER = "Reported",
  STATIC = "Not captured yet",
}
-- Territory -------------------------------------------------------------------

local Territory = {}
Window.Territory = Territory

function FRONT.NetworkTooltip(frame)
  local network = WF.FrontNetwork
  local continent = frame.continent
  if not network or not network.CONTINENT_NAMES[continent or ""] then return end
  GameTooltip:SetOwner(frame, "ANCHOR_CURSOR", 10, 10)
  GameTooltip:AddLine("Front Network - " .. network.CONTINENT_NAMES[continent], 1, 1, 1)
  -- Kept short (user, 2026-11-15): the strip already shows the counts and cuts.
  if network:Total(continent) == 0 then
    GameTooltip:AddLine("No War Camps here.", 0.8, 0.8, 0.8)
  else
    GameTooltip:AddLine("Held camps speed travel here", 0.8, 0.8, 0.8)
    GameTooltip:AddLine("and Outpost/Settlement captures.", 0.8, 0.8, 0.8)
  end
  Window.LocalizeTooltip(GameTooltip)
  GameTooltip:Show()
end

-- Activity row of the Synchronization panel (modules/traffic.lua): players
-- heard recently, then one bar per second of the last minute, received (blue)
-- under sent (gold), scaled to the busiest second; rates in the tooltip.
-- Fields, not file-level locals: this chunk holds many locals already.
SyncDrawer.ACTIVITY = {
  x = 172, y = -68, barW = 2, h = 14, floor = 512,
  inColor = { 0.25, 0.55, 1, 0.9 }, outColor = { 1, 0.82, 0, 0.9 },
}

function SyncDrawer:ActivityTooltip(frame)
  local traffic = WF.Traffic
  GameTooltip:SetOwner(frame, "ANCHOR_CURSOR", 10, 10)
  GameTooltip:AddLine("Network activity", 1, 1, 1)
  if traffic then
    local totalIn, totalOut, peak = traffic:Fill(self.activityRecv, self.activitySent, Now())
    local window = traffic.WINDOW
    GameTooltip:AddLine("Received: " .. traffic.Rate(totalIn / window), 0.4, 0.65, 1)
    GameTooltip:AddLine("Sent: " .. traffic.Rate(totalOut / window), 1, 0.82, 0)
    GameTooltip:AddLine("Busiest second: " .. traffic.Rate(peak), 0.8, 0.8, 0.8)
    GameTooltip:AddLine(WF.L("Active players: Warfront players you received data from in the last %d minutes.",
      math.floor(traffic.ACTIVE / 60)), 0.8, 0.8, 0.8, 1)
  end
  local queue = WF.SendQueue
  if queue and (queue.dropped or 0) > 0 then
    GameTooltip:AddLine("Some recent actions may not have reached others.", 1, 0.35, 0.35, 1)
  elseif queue and queue:Pending() > 0 then
    GameTooltip:AddLine("Your latest actions are on their way.", 0.6, 0.6, 0.6, 1)
  end
  Window.LocalizeTooltip(GameTooltip)
  GameTooltip:Show()
end

function SyncDrawer:BuildActivity(panel)
  local spec = SyncDrawer.ACTIVITY
  local bars = WF.Traffic and WF.Traffic.WINDOW or 60
  local create = GetGlobal("CreateFrame")
  self.activity = NewText(panel, "GameFontHighlightSmall", 28, -68, spec.x - 32)
  local graph = create("Frame", nil, panel)
  graph:SetWidth(bars * spec.barW)
  graph:SetHeight(spec.h)
  graph:SetPoint("TOPLEFT", panel, "TOPLEFT", spec.x, spec.y)
  local back = graph:CreateTexture(nil, "BACKGROUND")
  back:SetTexture("Interface\\Buttons\\WHITE8X8")
  back:SetVertexColor(1, 1, 1, 0.06)
  back:SetPoint("TOPLEFT", graph, "TOPLEFT", 0, 0)
  back:SetPoint("BOTTOMRIGHT", graph, "BOTTOMRIGHT", 0, 0)
  self.activityGraph = graph
  self.activityIn, self.activityOut = {}, {}
  self.activityRecv, self.activitySent = {}, {}
  local function Bar(color)
    local bar = graph:CreateTexture(nil, "ARTWORK")
    bar:SetTexture("Interface\\Buttons\\WHITE8X8")
    bar:SetVertexColor(color[1], color[2], color[3], color[4])
    bar:SetWidth(spec.barW)
    bar:Hide()
    bar.shown = 0
    return bar
  end
  for k = 1, bars do
    self.activityIn[k] = Bar(spec.inColor)
    self.activityOut[k] = Bar(spec.outColor)
  end
  local hit = create("Frame", nil, panel)
  hit:SetWidth(spec.x + bars * spec.barW - 28)
  hit:SetHeight(16)
  hit:SetPoint("TOPLEFT", panel, "TOPLEFT", 28, spec.y + 2)
  hit:EnableMouse(true)
  hit:SetScript("OnEnter", function(frame) SyncDrawer:ActivityTooltip(frame) end)
  hit:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

-- One bar: `height` pixels from `bottom`; repainted only when it changes.
function SyncDrawer.SetActivityBar(bar, graph, bottom, height, x)
  if bar.shown == height and bar.bottom == bottom then return end
  bar.shown, bar.bottom = height, bottom
  if height <= 0 then
    bar:Hide()
    return
  end
  bar:ClearAllPoints()
  bar:SetPoint("BOTTOMLEFT", graph, "BOTTOMLEFT", x, bottom)
  bar:SetHeight(height)
  bar:Show()
end

-- War news dot: the green sphere as is when live; desaturated and tinted
-- orange (reachable, nothing recent) or red (nobody heard). The atlas has no
-- plain orange or red dot (dot.yellow and dot.grey carry a question mark).
SyncDrawer.NEWS_TINTS = { quiet = { 1, 0.6, 0.1 }, waiting = { 1, 0.18, 0.15 } }

function SyncDrawer.SetNewsDot(dot, state)
  if dot.newsState == state then return end
  dot.newsState = state
  Skin():Apply(dot, "dot.green")
  local tint = SyncDrawer.NEWS_TINTS[state]
  if dot.SetDesaturated then dot:SetDesaturated(tint and true or false) end
  if tint then dot:SetVertexColor(tint[1], tint[2], tint[3]) else dot:SetVertexColor(1, 1, 1) end
end

function SyncDrawer:NewsTooltip(frame)
  GameTooltip:SetOwner(frame, "ANCHOR_CURSOR", 10, 10)
  GameTooltip:AddLine("War news", 1, 1, 1)
  GameTooltip:AddLine("Green: recent news.", 0.3, 1, 0.3, 1)
  GameTooltip:AddLine("Orange: connected, no recent news.", 1, 0.6, 0.1, 1)
  GameTooltip:AddLine("Red: no one reached you; the map may lag.", 1, 0.35, 0.35, 1)
  if self.newsAge then
    GameTooltip:AddLine("Last news: " .. Duration(self.newsAge) .. " ago.", 0.6, 0.6, 0.6, 1)
  else
    GameTooltip:AddLine("No news since you logged in.", 0.6, 0.6, 0.6, 1)
  end
  Window.LocalizeTooltip(GameTooltip)
  GameTooltip:Show()
end

function SyncDrawer:UpdateActivity(now)
  local traffic = WF.Traffic
  if not traffic or not self.activityIn then
    SetText(self.activity, "")
    return
  end
  local active = traffic:ActivePlayers(now)
  SetText(self.activity, "Active players: " .. (active > 0 and Paint("GOOD", active) or Paint("DIM", "0")))
  local recv, sent = self.activityRecv, self.activitySent
  local _, _, peak = traffic:Fill(recv, sent, now)
  local spec = SyncDrawer.ACTIVITY
  local scale = math.max(peak, spec.floor)
  for k = 1, #self.activityIn do
    local hIn = math.floor(recv[k] / scale * spec.h + 0.5)
    local hOut = math.floor(sent[k] / scale * spec.h + 0.5)
    if recv[k] > 0 and hIn < 1 then hIn = 1 end
    if sent[k] > 0 and hOut < 1 then hOut = 1 end
    if hIn > spec.h then hIn = spec.h end
    if hIn + hOut > spec.h then hOut = spec.h - hIn end
    local x = (k - 1) * spec.barW
    SyncDrawer.SetActivityBar(self.activityIn[k], self.activityGraph, 0, hIn, x)
    SyncDrawer.SetActivityBar(self.activityOut[k], self.activityGraph, hIn, hOut, x)
  end
end

-- One cut of the strip: its scoreboard icon, its name, then the value, laid
-- out right to left from the value's right end at (relative, point, x, y), so
-- both cuts sit against the frame's right edge (user, 2026-11-16).
function FRONT.Stat(panel, icon, name, relative, point, x, y)
  local value = Skin():Text(panel, "GameFontHighlightSmall", "RIGHT")
  value:SetPoint("RIGHT", relative, point, x, y)
  local color = FRONT.CUT_COLOR
  value:SetTextColor(color[1], color[2], color[3])
  local label = Skin():Text(panel, "GameFontHighlightSmall", "RIGHT")
  label:SetPoint("RIGHT", value, "LEFT", -5, 0)
  label:SetText(WF.L(name))
  local texture = Skin():Icon(panel, icon, FRONT.STAT_ICON, FRONT.STAT_ICON)
  texture:SetPoint("RIGHT", label, "LEFT", -3, 0.5)
  value.icon, value.label = texture, label
  return value
end

-- A cut's width from its icon's left edge to its value's right end.
function FRONT.BlockWidth(value)
  return FRONT.STAT_ICON + 3 + (value.label:GetStringWidth() or 0) + 5 + (value:GetStringWidth() or 0)
end

-- Hovering a cut explains it (user, 2026-11-16).
function FRONT.StatTooltip(frame)
  local network = WF.FrontNetwork
  local name = network and network.CONTINENT_NAMES[frame.continent or ""]
  if not name then return end
  local mine = MyFaction()
  local percent = 0
  if mine then
    local _, _, travel, capture = network:Get(frame.continent, mine)
    percent = frame.kind == "travel" and travel or capture
  end
  local cut = mine and (" " .. FRONT.Cut(mine, percent)) or ""
  GameTooltip:SetOwner(frame, "ANCHOR_CURSOR", 10, 10)
  if frame.kind == "travel" then
    GameTooltip:AddLine("Travel" .. cut, 1, 1, 1)
    GameTooltip:AddLine("Movement time of your scouts and armies heading to " .. name .. ".", 0.8, 0.8, 0.8, 1)
  else
    GameTooltip:AddLine("Capture" .. cut, 1, 1, 1)
    GameTooltip:AddLine("Capture time of Outposts and Settlements in " .. name
      .. " while your side outnumbers the enemy there.", 0.8, 0.8, 0.8, 1)
  end
  Window.LocalizeTooltip(GameTooltip)
  GameTooltip:Show()
end

-- Non-overlapping hover boxes (2026-11-16), placed by the caller: the
-- network's left of the divider, Travel from the divider to the Capture icon,
-- Capture from its icon to the frame's right edge.
function FRONT.Hit(panel, height, continent, kind, tooltip)
  local hit = NewFrame(panel, 1, height)
  hit.continent, hit.kind = continent, kind
  hit:EnableMouse(true)
  hit:SetScript("OnEnter", tooltip)
  hit:SetScript("OnLeave", function() GameTooltip:Hide() end)
  return hit
end

-- One continent's Front Network strip under its route rail, in its own gold
-- frame. One neutral source texture per War Camp segment is tinted grey,
-- Horde red or Alliance blue in Lua; segments are pooled and only grow when a
-- continent has more War Camps (decision 0123 section 8).
function FRONT.NetworkStrip(panel, continent, top)
  local x0, x3 = FRONT.NET_LEFT, CONTENT_WIDTH - FRONT.NET_LEFT
  local y0, y3 = top + FRONT.NET_TOP, top + FRONT.NET_BOTTOM
  FRONT.Box(panel, x0, y0, x3, y3, nil, FRONT.NET_CORNER)
  local mid = (y0 + y3) / 2
  local label = Skin():Text(panel, "GameFontNormalSmall", "LEFT")
  label:SetPoint("LEFT", panel, "TOPLEFT", x0 + 12, mid - 0.5)
  label:SetText(WF.L("Front Network"))
  local view = { segments = {}, segmentCount = 0, width = 0, right = x3 - FRONT.STAT_RIGHT }
  view.barLeft = math.floor(x0 + 12 + (label:GetStringWidth() or 0) + FRONT.BAR_GAP + 0.5)
  view.bar = NewFrame(panel, 1, FRONT.CAMP_H)
  view.bar:SetPoint("LEFT", panel, "TOPLEFT", view.barLeft, mid)
  view.empty = Skin():Text(view.bar, "GameFontDisableSmall", "LEFT")
  view.empty:SetPoint("LEFT", view.bar, "LEFT", 0, -0.5)
  view.text = Skin():Text(panel, "GameFontHighlightSmall", "LEFT")
  view.capture = FRONT.Stat(panel, "scoreboard.icon.pvp", "Capture", panel, "TOPLEFT", x3 - FRONT.STAT_RIGHT, mid - 0.5)
  view.travel = FRONT.Stat(panel, "scoreboard.icon.movement", "Travel", view.capture.icon, "LEFT", -FRONT.STAT_GAP, -0.5)
  -- The divider follows the right-aligned cuts (user, 2026-11-16).
  local divider = FRONT.Texture(panel, "ARTWORK", 0, FRONT.DIVIDER_TEXTURE)
  divider:SetWidth(FRONT.DIVIDER_W)
  divider:SetHeight(FRONT.DIVIDER_H)
  divider:SetPoint("CENTER", view.travel.icon, "LEFT", -FRONT.DIVIDER_GAP, 0)
  -- The count follows the bar, whose camps share one width on both
  -- continents, so both counts line up (user, 2026-11-21).
  view.text:SetPoint("LEFT", view.bar, "RIGHT", FRONT.COUNT_GAP, -0.5)
  local height, lift = y0 - y3, y0 - mid
  local hit = FRONT.Hit(panel, height, continent, nil, FRONT.NetworkTooltip)
  hit:SetPoint("TOPLEFT", panel, "TOPLEFT", x0, y0)
  hit:SetPoint("TOPRIGHT", divider, "CENTER", -4, lift)
  hit = FRONT.Hit(panel, height, continent, "travel", FRONT.StatTooltip)
  hit:SetPoint("TOPLEFT", divider, "CENTER", 4, lift)
  hit:SetPoint("TOPRIGHT", view.capture.icon, "LEFT", -FRONT.STAT_GAP / 2, lift)
  hit = FRONT.Hit(panel, height, continent, "capture", FRONT.StatTooltip)
  hit:SetPoint("TOPLEFT", view.capture.icon, "LEFT", -FRONT.STAT_GAP / 2, lift)
  hit:SetPoint("TOPRIGHT", panel, "TOPLEFT", x3, y0)
  return view
end

-- A gold nine-slice frame (no centre: the texture is clear inside) from
-- (x0, y0) to (x3, y3); a given `topFrom` starts its top edge there, right of
-- a continent's name; `corner` overrides FRONT.BOX_CORNER (line thickness).
function FRONT.Box(panel, x0, y0, x3, y3, topFrom, corner)
  local c, u = corner or FRONT.BOX_CORNER, FRONT.BOX_SLICE
  local xs, ys, uv = { x0, x0 + c, x3 - c, x3 }, { y0, y0 - c, y3 + c, y3 }, { 0, u, 1 - u, 1 }
  for row = 1, 3 do
    for column = 1, 3 do
      if row ~= 2 or column ~= 2 then
        local left = xs[column]
        if row == 1 and column == 2 and topFrom then left = math.max(left, topFrom) end
        local piece = FRONT.Texture(panel, "BORDER", 0, FRONT.BOX_TEXTURE)
        piece:SetTexCoord(uv[column], uv[column + 1], uv[row], uv[row + 1])
        piece:SetPoint("TOPLEFT", panel, "TOPLEFT", left, ys[row])
        piece:SetPoint("BOTTOMRIGHT", panel, "TOPLEFT", xs[column + 1], ys[row + 1])
      end
    end
  end
end

-- The campaign banner over the War Balance header; above the panel's strip
-- and the first row's frame, whose top line runs behind the plate.
function FRONT.Banner(panel)
  local banner = NewFrame(panel, FRONT.BANNER_W, FRONT.BANNER_H)
  banner:SetPoint("TOP", panel, "TOP", 0, FRONT.BANNER_Y)
  if banner.SetFrameLevel and panel.GetFrameLevel then banner:SetFrameLevel(panel:GetFrameLevel() + 4) end
  FRONT.Texture(banner, "ARTWORK", 0, FRONT.BANNER_TEXTURE):SetAllPoints(banner)
  banner.name = Skin():GoldTitle(banner, "", FRONT.BANNER_NAME_SIZE, "OVERLAY")
  banner.name:SetPoint("CENTER", banner, "TOP", 0, FRONT.BANNER_NAME_Y)
  banner.left = Skin():Text(banner, "GameFontHighlightSmall", "CENTER")
  banner.left:SetPoint("CENTER", banner, "TOP", 0, FRONT.BANNER_LEFT_Y)
  -- 20 % greyer and 2 smaller than the template (user, 2026-11-15); set
  -- before FitText reads its base font.
  banner.left:SetTextColor(0.8, 0.8, 0.8)
  local font, size, flags = banner.left:GetFont()
  if font and size then banner.left:SetFont(font, size - 2, flags) end
  banner.note = Skin():Text(banner, "GameFontDisableSmall", "LEFT")
  -- Centre the whole two-line block in the header, rather than keeping the
  -- first line on the former one-line baseline and letting the second sink.
  local noteY = FRONT.BANNER_LEFT_Y + 4
  banner.note:SetPoint("LEFT", banner, "TOPRIGHT", 8, noteY)
  banner.note:SetPoint("RIGHT", panel, "TOPRIGHT", -12, noteY)
  banner.note:SetHeight(28)
  banner.note:SetJustifyV("MIDDLE")
  if banner.note.SetWordWrap then banner.note:SetWordWrap(true) end
  SetText(banner.note, "End sooner if a capital falls")
  return banner
end

function Territory:Build()
  -- War Balance (2026-11-15, user's schema A): one row per continent, the
  -- Active Front route drawn like the continent map's (Settlements in route
  -- order, the capital last) at the top, its Front Network strip below.
  -- 8 between continent frames (user, 2026-11-15); 201 high since the strip
  -- moved under the route (user's mockup, 2026-11-15).
  -- No header title or strip (user, 2026-11-16); the note stays for errors.
  local panel = NewPanel(self, "", 0, 0, CONTENT_WIDTH, FRONT.PANEL_H)
  panel.header.L:Hide()
  panel.header.M:Hide()
  panel.header.R:Hide()
  self.balancePanel = panel
  self.banner = FRONT.Banner(panel)
  -- Companion download (decision 0046), left of the banner while it would help.
  self.companionGet = NewButton(panel, "red", 150, 22, "Get the Companion", function()
    if WF.CompanionDownload then WF.CompanionDownload:Toggle() end
  end)
  Place(self.companionGet, panel, 10, -5)
  self.companionGet:Hide()
  self.siegeDriver = NewFrame(panel, 1, 1)
  self.siegeDriver.textures = {}
  self.siegeDriver:SetScript("OnUpdate", FRONT.AnimateSieges)
  self.siegeDriver:Hide()
  self.fronts, self.networks = {}, {}
  local network = WF.FrontNetwork
  local continents = network and network.CONTINENTS or {}
  for index = 1, #continents do
    local continent = continents[index]
    local top = FRONT.ROW_TOP - (index - 1) * FRONT.ROW_H
    local row = { continent = continent, nodes = {}, links = {}, owners = {} }
    local nameX = FRONT.BOX_LEFT + FRONT.BOX_CORNER + 2
    -- The name in the gold title letters (user, 2026-11-16), centred on the
    -- frame's top line.
    row.name = Skin():GoldTitle(panel, network.CONTINENT_NAMES[continent], FRONT.NAME_SIZE, "OVERLAY")
    Place(row.name, panel, nameX, top + FRONT.BOX_TOP + FRONT.NAME_SIZE / 2)
    FRONT.Box(panel, FRONT.BOX_LEFT, top + FRONT.BOX_TOP, CONTENT_WIDTH - FRONT.BOX_LEFT, top + FRONT.BOX_BOTTOM,
      nameX + (row.name:GetWidth() or 0) + FRONT.BOX_GAP)
    row.rail = NewFrame(panel, CONTENT_WIDTH, FRONT.RAIL_H)
    Place(row.rail, panel, 0, top + FRONT.RAIL_Y)
    self.fronts[continent] = row
    self.networks[continent] = FRONT.NetworkStrip(panel, continent, top)
  end

  -- Eight rows from below the War Balance to the bottom of the tab, as tall
  -- as the panel allows, unrounded so the last one ends on the panel's edge
  -- (2026-11-16, user: full height); the row dots explain their source on
  -- hover (no legend panel since 2026-11-15).
  local poiTop = FRONT.PANEL_H + 4
  local poiRow = (CONTENT_HEIGHT - poiTop - 40) / 8
  panel = NewPanel(self, "Points of Interest", 0, -poiTop, CONTENT_WIDTH, CONTENT_HEIGHT - poiTop)
  local headers = { { "Location", 34 }, { "Owner", 236 }, { "Source / Status", 344 }, { "Details", 486 } }
  for index = 1, #headers do
    SetText(NewText(panel, "GameFontDisableSmall", headers[index][2] + 6, -24, 120), headers[index][1])
  end
  self.pois = NewList(panel, 8, poiRow, -38, function(row)
    -- A section title ("Current zone", "Other zones") is plain gold text at
    -- the row's left edge, without a background (2026-11-16, user).
    row.icon = Skin():Icon(row, nil, 20, 20)
    Place(row.icon, row, 4, 0)
    row.name = NewText(row, "GameFontHighlightSmall", 34, -4, 196)
    row.badge = Skin():Icon(row, nil, 14, 16)
    Place(row.badge, row, 236, -2)
    row.owner = NewText(row, "GameFontHighlightSmall", 254, -4, 86)
    row.dot = Skin():Icon(row, nil, 14, 14)
    Place(row.dot, row, 344, -3)
    row.source = NewText(row, "GameFontHighlightSmall", 362, -4, 120)
    local hit = CreateFrame("Frame", nil, row)
    hit:SetWidth(138)
    hit:SetHeight(18)
    hit:SetPoint("TOPLEFT", row, "TOPLEFT", 342, -2)
    hit:EnableMouse(true)
    hit:SetScript("OnEnter", function(self)
      if not row.sourceTip then return end
      GameTooltip:SetOwner(self, "ANCHOR_CURSOR", 10, 10)
      GameTooltip:AddLine(row.sourceTip[1], 1, 1, 1)
      GameTooltip:AddLine(row.sourceTip[2], 0.8, 0.8, 0.8, 1)
      Window.LocalizeTooltip(GameTooltip)
      GameTooltip:Show()
    end)
    hit:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row.details = NewText(row, "GameFontHighlightSmall", 486, -4, 100)
  end)
  self.poiIds = {}
end

-- The Synchronization panel, moved from the Territory tab into the drawer.
function SyncDrawer:BuildPanel(parent)
  local panel = Skin():Panel(parent, "Synchronization", CONTENT_WIDTH, SyncDrawer.HEIGHT)
  Place(panel, parent, 0, 0)
  self.channelDot = Skin():Icon(panel, nil, 14, 14)
  Place(self.channelDot, panel, 10, -27)
  self.channel = NewText(panel, "GameFontHighlightSmall", 28, -28, 270)
  local newsHit = NewFrame(panel, 288, 18)
  Place(newsHit, panel, 8, -26)
  newsHit:EnableMouse(true)
  newsHit:SetScript("OnEnter", function(frame) SyncDrawer:NewsTooltip(frame) end)
  newsHit:SetScript("OnLeave", function() GameTooltip:Hide() end)
  self.sendDot = Skin():Icon(panel, nil, 14, 14)
  Place(self.sendDot, panel, 10, -47)
  self.send = NewText(panel, "GameFontHighlightSmall", 28, -48, 270)
  self:BuildActivity(panel)
  local divider = Skin():Icon(panel, "divider.v", 3, 62, "BORDER")
  Place(divider, panel, 302, -24)
  local sync = Skin():Icon(panel, "icon.sync", 16, 18)
  Place(sync, panel, 312, -25)
  self.catchup = NewText(panel, "GameFontHighlightSmall", 334, -28, 150)
  self.allies = NewButton(panel, "dark", 112, 22, "Allies", function()
    if WF.Allies then WF.Allies:Command("") end
  end)
  Place(self.allies, panel, CONTENT_WIDTH - 120, -22)
  -- Short tooltip; the skin's own hover scripts keep running (wrapped).
  local skinEnter, skinLeave = self.allies:GetScript("OnEnter"), self.allies:GetScript("OnLeave")
  self.allies:SetScript("OnEnter", function(frame, ...)
    if skinEnter then skinEnter(frame, ...) end
    GameTooltip:SetOwner(frame, "ANCHOR_CURSOR", 10, 10)
    GameTooltip:AddLine("Allies", 1, 1, 1)
    GameTooltip:AddLine("Become Battle.net friends with a player of the other faction to help Warfront share data between factions.", 0.8, 0.8, 0.8, 1)
    Window.AlliesTooltipState(GameTooltip)
    Window.LocalizeTooltip(GameTooltip)
    GameTooltip:Show()
  end)
  self.allies:SetScript("OnLeave", function(frame, ...)
    if skinLeave then skinLeave(frame, ...) end
    GameTooltip:Hide()
  end)
  self.versionIcon = Skin():Icon(panel, "icon.warning", 16, 15)
  Place(self.versionIcon, panel, 312, -46)
  self.version = NewText(panel, "GameFontHighlightSmall", 334, -48, 260)
  -- Optional companion (decision 0046): its state, and a tip when it would help.
  self.companion = NewText(panel, "GameFontHighlightSmall", 334, -68, 260)
  self.companionGet = NewButton(panel, "red", 84, 18, "Download", function()
    if WF.CompanionDownload then WF.CompanionDownload:Toggle() end
  end)
  Place(self.companionGet, panel, CONTENT_WIDTH - 92, -65)
  self.companionGet:Hide()
  local companionHit = GetGlobal("CreateFrame")("Frame", nil, panel)
  companionHit:SetWidth(176)
  companionHit:SetHeight(16)
  companionHit:SetPoint("TOPLEFT", panel, "TOPLEFT", 334, -66)
  companionHit:EnableMouse(true)
  companionHit:SetScript("OnEnter", function(frame)
    local companion = WF.Companion
    if not companion then return end
    local reason = companion:ShownHint()
    GameTooltip:SetOwner(frame, "ANCHOR_CURSOR", 10, 10)
    GameTooltip:AddLine("Warfront Companion (optional)", 1, 1, 1)
    if reason then GameTooltip:AddLine(companion.HINT_TEXTS[reason], 1, 0.82, 0, 1) end
    GameTooltip:AddLine(companion.HINT_LIMIT, 0.8, 0.8, 0.8, 1)
    GameTooltip:AddLine("/wf companion hide stops the tips.", 0.6, 0.6, 0.6, 1)
    Window.LocalizeTooltip(GameTooltip)
    GameTooltip:Show()
  end)
  companionHit:SetScript("OnLeave", function() GameTooltip:Hide() end)
  return panel
end

local function Capturing(info)
  return info and info.challenger and info.challenger ~= "-" and (info.percent or 0) >= 50 and info.challenger or nil
end

-- Same owner as the map: with no confirmed owner, show the unconfirmed one
-- (cloud or players' hint). The counter and the list both use it.
local function ShownOwner(capture, id, now)
  local owner, _, source = capture:GetOwner(id)
  local info = capture:TooltipInfo(id, now)
  local guess
  if owner == "N" and capture:Capturable(id) and info then
    if info.cloud then
      local _, code = capture.CloudLine(info.cloud)
      guess = code
    elseif info.hint then
      guess = info.hint.owner
    end
    if guess ~= "A" and guess ~= "H" then guess = nil end
  end
  return guess or owner, info, source
end

-- A cut as shown on the strip: "-21%", "0%", or "-" while the faction is unknown.
function FRONT.Cut(mine, percent)
  if not mine then return "-" end
  if percent > 0 then return "-" .. percent .. "%" end
  return "0%"
end

-- Sets one strip's texts and returns the widest camp segment its room fits,
-- or nil without War Camps.
function Territory:UpdateNetworkText(network, view, continent, mine)
  local camps = network:Camps(continent)
  local total = #camps
  view.camps = camps
  local held, travel, capture = 0, 0, 0
  if mine then
    local _
    _, held, travel, capture = network:Get(continent, mine)
  end
  SetText(view.travel, FRONT.Cut(mine, travel))
  SetText(view.capture, FRONT.Cut(mine, capture))
  if total == 0 then
    SetText(view.text, "")
    SetText(view.empty, "No War Camps")
    for index = 1, #view.segments do view.segments[index]:Hide() end
    return nil
  end
  SetText(view.empty, "")
  SetText(view.text, (mine and (held .. "/") or "") .. total .. (total == 1 and " Camp" or " Camps"))
  -- The bar fills the room from the label to the count, which ends
  -- COUNT_RIGHT before the divider; the divider sits DIVIDER_GAP left of the
  -- right-aligned cuts, so the room follows the texts' widths (user, 2026-11-16).
  local divider = view.right - FRONT.BlockWidth(view.capture) - FRONT.STAT_GAP
    - FRONT.BlockWidth(view.travel) - FRONT.DIVIDER_GAP
  local room = math.floor(divider - FRONT.COUNT_RIGHT - (view.text:GetStringWidth() or 0) - FRONT.COUNT_GAP
    - view.barLeft)
  room = math.max(total, room)
  return math.max(1, math.floor((room - FRONT.CAMP_GAP * (total - 1)) / total))
end

-- Lays out one strip's segments at `width` (shared by both continents so
-- their camps match, user 2026-11-21) and tints them by owner.
function Territory:UpdateNetworkBar(network, view, width, mine)
  local camps = view.camps
  local total = #camps
  local segments = view.segments
  local gap = FRONT.CAMP_GAP
  local room = width * total + gap * (total - 1)
  if view.segmentCount ~= total or view.width ~= room then
    view.segmentCount, view.width = total, room
    view.bar:SetWidth(room)
    for index = 1, total do
      local segment = segments[index]
      if not segment then
        segment = Skin():Icon(view.bar, nil, width, FRONT.CAMP_H, "ARTWORK")
        segment:SetTexture(FRONT.CAMP_TEXTURE)
        segments[index] = segment
      end
      segment:SetWidth(width)
      Place(segment, view.bar, (index - 1) * (width + gap), 0)
    end
  end
  for index = 1, #segments do
    local segment = segments[index]
    if index <= total then
      local owner = network:Owner(camps[index])
      local colorKey = mine and owner == mine and owner or "N"
      if segment.colorKey ~= colorKey then
        local color = FRONT.CAMP_COLORS[colorKey]
        segment.colorKey = colorKey
        segment:SetVertexColor(color[1], color[2], color[3], 1)
      end
      segment:Show()
    else
      segment:Hide()
    end
  end
end

function Territory:UpdateNetwork()
  local network = WF.FrontNetwork
  if not network then return end
  local mine = MyFaction()
  local width
  for index = 1, #network.CONTINENTS do
    local continent = network.CONTINENTS[index]
    local fit = self:UpdateNetworkText(network, self.networks[continent], continent, mine)
    if fit and (not width or fit < width) then width = fit end
  end
  if not width then return end
  for index = 1, #network.CONTINENTS do
    local view = self.networks[network.CONTINENTS[index]]
    if #view.camps > 0 then self:UpdateNetworkBar(network, view, width, mine) end
  end
end

-- War Balance front rows ------------------------------------------------------

function FRONT.Texture(parent, layer, sublevel, path)
  local texture = parent:CreateTexture(nil, layer, nil, sublevel)
  if texture.SetSnapToPixelGrid then texture:SetSnapToPixelGrid(false) end
  if texture.SetTexelSnappingBias then texture:SetTexelSnappingBias(0) end
  if path then texture:SetTexture(path, "CLAMP", "CLAMP", "TRILINEAR") end
  return texture
end

function FRONT.Place(texture, rail, x, size, dy)
  texture:SetWidth(size)
  texture:SetHeight(size)
  texture:ClearAllPoints()
  texture:SetPoint("CENTER", rail, "TOPLEFT", x, -FRONT.RAIL_H / 2 + (dy or 0))
  texture:Show()
end

-- The status line and stop tooltips name a front's place by its zone, like the
-- map tooltips.
function FRONT.ZoneLabel(id)
  local map = WF.Map
  local area = id and map and map.areas[id]
  if not area then return "?" end
  return tostring(map.FrontZoneName and map.FrontZoneName(area) or AreaName(area))
end

function FRONT.NodeTooltip(hit)
  if not hit.id then return end
  GameTooltip:SetOwner(hit, "ANCHOR_CURSOR", 10, 10)
  GameTooltip:AddLine(FRONT.ZoneLabel(hit.id), 1, 1, 1)
  GameTooltip:AddLine(hit.capital and (FactionText(hit.owner) .. " capital") or FactionText(hit.owner))
  if hit.active then GameTooltip:AddLine("Active Front", 1, 0.82, 0) end
  if hit.locked then
    GameTooltip:AddLine("This front is locked.", 0.72, 0.72, 0.72)
    if hit.first then GameTooltip:AddLine("Capture " .. FRONT.ZoneLabel(hit.first) .. " first.", 1, 1, 1) end
  end
  local siege = WF.Front and WF.Front:SiegeText(hit.id)
  if siege then GameTooltip:AddLine(siege, 1, 0.82, 0, 1) end
  for side, flag in pairs(hit.targetOf) do
    if flag then GameTooltip:AddLine("Next target of the " .. FactionText(side), 1, 1, 1) end
  end
  Window.LocalizeTooltip(GameTooltip)
  GameTooltip:Show()
end

-- One stop of a rail, built once: the node disc and its number, the faction
-- emblem that replaces it on a held stop, the siege catapult and the tooltip
-- hit box.
function FRONT.Node(row, index)
  local node = row.nodes[index]
  if node then return node end
  local rail = row.rail
  node = {
    disc = FRONT.Texture(rail, "ARTWORK", 1),
    digit = FRONT.Texture(rail, "OVERLAY", 1, FRONT.ROUTE_DIR .. "RouteNodeDigits"),
    emblem = FRONT.Texture(rail, "OVERLAY", 2),
    siege = FRONT.Texture(rail, "OVERLAY", 3, FRONT.SIEGE_TEXTURE),
    lock = Skin():GreyLock(rail, FRONT.LOCK_W, FRONT.LOCK_H),
    hit = NewFrame(rail, FRONT.CAPITAL, FRONT.CAPITAL),
  }
  node.siege:SetTexCoord(0, 0.25, 0, 0.25)
  node.hit.targetOf = {}
  node.hit:EnableMouse(true)
  node.hit:SetScript("OnEnter", FRONT.NodeTooltip)
  node.hit:SetScript("OnLeave", function() GameTooltip:Hide() end)
  row.nodes[index] = node
  return node
end

function FRONT.HideNode(node)
  node.disc:Hide()
  node.digit:Hide()
  node.emblem:Hide()
  node.siege:Hide()
  if node.lock then node.lock:Hide() end
  node.hit:Hide()
  node.hit.id = nil
end

-- A held stop shows its faction emblem alone, as on the map; an open one its
-- numbered disc in its FRONT.DISCS style (nil: OPEN).
function FRONT.PaintNode(row, node, x, index, owner, style, capital)
  local emblem = FRONT.EMBLEMS[owner]
  if emblem then
    node.disc:Hide()
    node.digit:Hide()
    -- The capital shows the map's capital crown in its holder's colour
    -- (user, 2026-11-20); other held stops their faction emblem.
    local left, right, top, bottom = 0, 1, 0, 1
    if capital and WF.Map and WF.Map.GetIcon then
      local crown, l, r, t, b = WF.Map.GetIcon("CAPITAL", owner == "H" and "HORDE" or "ALLIANCE")
      if crown then emblem, left, right, top, bottom = crown, l, r, t, b end
    end
    if node.emblem.path ~= emblem then
      node.emblem.path = emblem
      node.emblem:SetTexture(emblem, "CLAMP", "CLAMP", "TRILINEAR")
    end
    node.emblem:SetTexCoord(left, right, top, bottom)
    FRONT.Place(node.emblem, row.rail, x, capital and FRONT.CAPITAL or FRONT.EMBLEM)
  else
    node.emblem:Hide()
    local disc = FRONT.DISCS[style] or FRONT.DISCS.OPEN
    if node.disc.path ~= disc then
      node.disc.path = disc
      node.disc:SetTexture(disc, "CLAMP", "CLAMP", "TRILINEAR")
    end
    FRONT.Place(node.disc, row.rail, x, FRONT.DISC)
    if index <= 9 then
      local column, row4 = index % 4, math.floor(index / 4)
      node.digit:SetTexCoord(column / 4, (column + 1) / 4, row4 / 4, (row4 + 1) / 4)
      node.digit:SetVertexColor(0.10, 0.06, 0.02, 1)
      FRONT.Place(node.digit, row.rail, x, FRONT.DIGIT)
    else
      node.digit:Hide()
    end
  end
  node.hit:ClearAllPoints()
  node.hit:SetPoint("CENTER", row.rail, "TOPLEFT", x, -FRONT.RAIL_H / 2)
  node.hit:Show()
end

-- A coloured stretch of the rail between two stops one faction holds.
function FRONT.PaintLink(row, index, x0, x1, owner)
  local link = row.links[index]
  local fill = NETWORK_FILLS[owner]
  if owner ~= "A" and owner ~= "H" then
    if link then link:Hide() end
    return
  end
  if not link then
    link = Skin():Icon(row.rail, nil, 1, FRONT.LINK_H, "BORDER")
    row.links[index] = link
  end
  if link.fill ~= fill then
    link.fill = fill
    Skin():Apply(link, fill)
  end
  link:SetWidth(math.max(1, x1 - x0))
  link:ClearAllPoints()
  link:SetPoint("LEFT", row.rail, "TOPLEFT", x0, -FRONT.RAIL_H / 2)
  link:Show()
end

-- A faction's chevron on the rail, tinted its colour, pointing at its target.
function FRONT.PaintChevron(row, key, x, side, left)
  local chevron = row[key]
  if not x then
    if chevron then chevron:Hide() end
    return
  end
  if not chevron then
    chevron = FRONT.Texture(row.rail, "OVERLAY", 0, FRONT.ROUTE_DIR .. "RouteChevronTint")
    row[key] = chevron
  end
  local colors = WF.Map and WF.Map.COLORS
  local color = colors and colors[side == "H" and "HORDE" or "ALLIANCE"]
  if color then chevron:SetVertexColor(color[1], color[2], color[3], 1) end
  -- The painted chevron points right; mirrored for the defenders.
  if left then chevron:SetTexCoord(1, 0, 0, 1) else chevron:SetTexCoord(0, 1, 0, 1) end
  FRONT.Place(chevron, row.rail, x, FRONT.CHEVRON)
end

-- x of a rail stop: 0 is the advancing faction's lead-in, total + 1 the capital.
function FRONT.X(index, step, left)
  if index < 1 then return FRONT.LEAD end
  return math.floor((left or FRONT.LEFT) + (index - 1) * step + 0.5)
end

-- Fades a rail piece in from its left end, or shows it whole.
function FRONT.Fade(texture, faded)
  if type(texture.SetGradient) ~= "function" or type(CreateColor) ~= "function" then
    texture:SetAlpha(faded and 0.5 or 1)
    return
  end
  texture:SetGradient("HORIZONTAL", CreateColor(1, 1, 1, faded and 0 or 1), CreateColor(1, 1, 1, 1))
end

-- A rail piece from x0 to x1, centred on the rail's line.
function FRONT.Span(texture, rail, x0, x1, height)
  texture:SetHeight(height)
  texture:SetWidth(math.max(1, x1 - x0))
  texture:ClearAllPoints()
  texture:SetPoint("LEFT", rail, "TOPLEFT", x0, -FRONT.RAIL_H / 2)
  texture:Show()
end

function Territory:UpdateFrontRow(row, route, front, capture, now)
  row.siegeTexture = nil
  if not route then
    row.rail:Hide()
    return
  end
  row.rail:Show()
  local rail, total = row.rail, #route.nodes
  if not row.line then
    row.line = FRONT.Texture(rail, "BACKGROUND", 0, FRONT.ROUTE_DIR .. "RouteLine")
    row.tail = FRONT.Texture(rail, "BACKGROUND", 0, FRONT.ROUTE_DIR .. "RouteLine")
  end
  local advancing = route.advancing
  local defender = advancing == "H" and "A" or "H"
  local forward, rear = front:Targets(route)
  -- Once stop 1 is past, the lead-in holds no chevron: it shrinks to a tail
  -- fading in from the left and every stop slides left (user, 2026-11-20).
  local passed = forward ~= 1
  local left = passed and FRONT.LEFT_PASSED or FRONT.LEFT
  local step = (FRONT.RIGHT - left) / total
  FRONT.Span(row.line, rail, FRONT.X(1, step, left), FRONT.X(total + 1, step, left), FRONT.LINE_H)
  FRONT.Span(row.tail, rail, FRONT.LEAD, FRONT.X(1, step, left), FRONT.LINE_H)
  FRONT.Fade(row.tail, passed)
  -- A real siege window, or the map's WarfrontDev simulation (/wfd siege).
  local map = WF.Map
  local rec = (map and map.simSiege and map.simSiege[route.id]) or front:Window(route.id)
  local siege = rec and rec.seen and front:Remaining(rec) > 0 and rec or nil
  local owners = row.owners
  for index = 1, total do owners[index] = ShownOwner(capture, route.nodes[index].id, now) end
  -- The capital belongs to the defending faction (data/fronts.lua endpoint).
  owners[total + 1] = defender

  -- The advancing faction's lead-in, then every stretch between two stops.
  FRONT.PaintLink(row, 1, FRONT.LEAD, FRONT.X(1, step, left), owners[1] == advancing and advancing or nil)
  for index = 1, total do
    local a, b = owners[index], owners[index + 1]
    FRONT.PaintLink(row, index + 1, FRONT.X(index, step, left), FRONT.X(index + 1, step, left), a == b and a or nil)
  end
  if row.links[1] then FRONT.Fade(row.links[1], passed) end
  for index = total + 2, #row.links do row.links[index]:Hide() end

  local mine = MyFaction()
  for index = 1, total + 1 do
    local node = FRONT.Node(row, index)
    local capital = index > total
    local id = capital and route.endpoint or route.nodes[index].id
    local x = FRONT.X(index, step, left)
    local style
    if index == forward or index == rear then
      local side = index == forward and advancing or defender
      style = (not mine or mine == side) and "MINE" or "ENEMY"
    end
    FRONT.PaintNode(row, node, x, index, owners[index], style, capital)
    -- An open stop that is nobody's target is locked, like the map's grey node.
    local lock = node.lock
    local locked = not style and not FRONT.EMBLEMS[owners[index]]
    -- The map tooltip's "Capture X first": the stop the player's side must take
    -- before this one (the map's own rule, capital included).
    local first
    if locked then
      local target = route.nodes[(mine == advancing and forward or rear) or 0]
      if not (capital and mine and mine ~= advancing) and target and target.id ~= id then first = target.id end
    end
    node.hit.locked, node.hit.first = locked, first
    if lock and locked then
      lock:ClearAllPoints()
      lock:SetPoint("CENTER", rail, "TOPLEFT", x + FRONT.LOCK_DX, -FRONT.RAIL_H / 2 + FRONT.LOCK_DY)
      lock:Show()
    elseif lock then
      lock:Hide()
    end
    node.hit.id, node.hit.owner, node.hit.capital = id, owners[index], capital
    node.hit.active = style == "MINE"
    node.hit.targetOf[advancing] = index == forward
    node.hit.targetOf[defender] = not capital and index == rear
    if siege and siege.node == id then
      -- The map's catapult flipbook at the top right of the besieged stop's
      -- circle (user, 2026-11-16), stepped by FRONT.AnimateSieges.
      FRONT.Place(node.siege, rail, x + FRONT.SIEGE_DX, FRONT.SIEGE, FRONT.SIEGE_DY)
      row.siegeTexture = node.siege
    else
      node.siege:Hide()
    end
  end
  for index = total + 2, #row.nodes do FRONT.HideNode(row.nodes[index]) end

  -- Each faction's chevron sits at the middle of the stretch leading to its
  -- target, between the two stops (user, 2026-11-15).
  -- On the lead-in before stop 1 it sits 30% further left, x 39 to 27
  -- (user, 2026-11-15).
  local ahead
  if forward <= total + 1 then
    local from = FRONT.X(forward - 1, step, left)
    ahead = math.floor(from + (FRONT.X(forward, step, left) - from) * (forward == 1 and 0.28 or 0.5) + 0.5)
  end
  local back
  if rear >= 1 and rear <= total then
    local from = FRONT.X(rear, step, left)
    back = math.floor(from + (FRONT.X(rear + 1, step, left) - from) * 0.5 + 0.5)
  end
  -- Both factions face each other on one stretch: side by side instead of
  -- stacked, the advancing one on the left (user, 2026-11-20).
  if ahead and back and ahead == back then
    ahead, back = ahead - FRONT.CHEVRON_PAIR, back + FRONT.CHEVRON_PAIR
  end
  FRONT.PaintChevron(row, "ahead", ahead, advancing, false)
  FRONT.PaintChevron(row, "back", back, defender, true)
end

-- The campaign's name and time left on the banner, then one row per
-- continent from the same owners as the Points of Interest list.
function Territory:UpdateFronts(now)
  local front, capture = WF.Front, WF.Capture
  local campaign = WF.Campaign
  local left = campaign and type(campaign.LeftText) == "function" and campaign:LeftText()
  -- Under one day the banner counts down H:MM:SS, refreshed every second.
  local seconds = campaign and type(campaign.Left) == "function" and campaign:Left()
  if seconds and seconds < 86400 then
    seconds = math.max(0, math.floor(seconds))
    left = string.format("Campaign ends in %d:%02d:%02d", math.floor(seconds / 3600),
      math.floor(seconds % 3600 / 60), seconds % 60)
  end
  local name = front and front.campaignName
  local banner = self.banner
  Show(banner, name or left)
  if banner.nameText ~= name then
    -- Gold letters shrink to fit the ribbon; redrawn only when the name changes.
    banner.nameText = name
    local width = Skin():SetGoldTitle(banner.name, name or "", FRONT.BANNER_NAME_SIZE)
    if width > FRONT.BANNER_NAME_W then
      Skin():SetGoldTitle(banner.name, nil, FRONT.BANNER_NAME_SIZE * FRONT.BANNER_NAME_W / width)
    end
  end
  FitText(banner.left, left or "", FRONT.BANNER_LEFT_W)
  local routes = front and type(front.HasRoutes) == "function" and front:HasRoutes() and front.routes or {}
  for continent, row in pairs(self.fronts or {}) do
    local route
    for index = 1, #routes do
      if routes[index].id == continent then route = routes[index] end
    end
    self:UpdateFrontRow(row, route, front, capture, now)
  end
  -- The flipbook driver runs only while a catapult is shown (a hidden frame
  -- gets no OnUpdate, nor while the tab is closed).
  local driver = self.siegeDriver
  if not driver then return end
  local list = driver.textures
  for index = #list, 1, -1 do list[index] = nil end
  for _, row in pairs(self.fronts or {}) do
    if row.siegeTexture then list[#list + 1] = row.siegeTexture end
  end
  Show(driver, #list > 0)
end

-- Steps the War Balance siege flipbooks (columns then rows of the 4 x 4
-- sheet) at the map's rate.
function FRONT.AnimateSieges(driver)
  local getTime = GetGlobal("GetTime")
  if type(getTime) ~= "function" then return end
  local step = math.floor(getTime() * FRONT.SIEGE_FPS) % FRONT.SIEGE_FRAMES
  if step == driver.step then return end
  driver.step = step
  local column, row = step % 4, math.floor(step / 4)
  local list = driver.textures
  for index = 1, #list do
    list[index]:SetTexCoord(column / 4, (column + 1) / 4, row / 4, (row + 1) / 4)
  end
end

function Territory:Update(now)
  local map, capture = WF.Map, WF.Capture
  if not map or not capture then
    SetText(self.balancePanel.note, Paint("BAD", "Unavailable: map or capture not loaded"))
    FillList(self.pois, 0, nil)
    return
  end
  local counts = self.counts or {}
  self.counts = counts
  counts.H, counts.A, counts.N = 0, 0, 0
  local count = Collect(self.poiIds, function(id)
    local area = map.areas[id]
    if not area or not area.enabled or not TERRITORY_TYPES[area.type] then return false end
    if BALANCE_TYPES[area.type] and capture:Capturable(id) then
      local shown = ShownOwner(capture, id, now)
      counts[shown] = (counts[shown] or 0) + 1
    end
    return true
  end)
  SortByPlayerDistance(self.poiIds, count, PlayerDistanceContext())
  local download, companion = WF.CompanionDownload, WF.Companion
  Show(self.companionGet, download ~= nil and download.Wanted() and not companion:HintHidden())
  self:UpdateFronts(now)
  self:UpdateNetwork()
  -- Two sections, each still sorted by distance: this zone, then the others.
  local zone = map.PlayerZoneKey and map:PlayerZoneKey() or nil
  local rows = self.poiRows or {}
  self.poiRows = rows
  local inZone = 0
  for index = 1, count do
    if map.areas[self.poiIds[index]].mapKey == zone then inZone = inZone + 1 end
  end
  local filled = 0
  if inZone > 0 then
    filled = filled + 1
    rows[filled] = "#here"
    for index = 1, count do
      if map.areas[self.poiIds[index]].mapKey == zone then
        filled = filled + 1
        rows[filled] = self.poiIds[index]
      end
    end
  end
  -- Without a current-zone section the list needs no title (2026-11-24, user).
  if inZone > 0 and inZone < count then
    filled = filled + 1
    rows[filled] = "#other"
  end
  for index = 1, count do
    if map.areas[self.poiIds[index]].mapKey ~= zone then
      filled = filled + 1
      rows[filled] = self.poiIds[index]
    end
  end
  local extra = filled + 1
  while rows[extra] do
    rows[extra] = nil
    extra = extra + 1
  end
  local labels = {
    ["#here"] = Paint("GOLD", "Current zone"),
    ["#other"] = Paint("GOLD", "Other zones"),
  }
  -- Place number inside its section (1, 2, ...), for the alternating bands.
  local sectionRank = self.poiRanks or {}
  self.poiRanks = sectionRank
  local rank = 0
  for item = 1, filled do
    if labels[rows[item]] then rank = 0 else rank = rank + 1 end
    sectionRank[item] = rank
  end
  FillList(self.pois, filled, function(row, item)
    local id = rows[item]
    local label = labels[id]
    Show(row.icon, not label)
    Show(row.badge, not label)
    Show(row.dot, not label)
    Place(row.name, row, label and 4 or 34, -4)
    row.isCategory = label and true or nil
    if label then Show(row.hover, false) end
    -- Bands restart under each section title: its first place stays plain.
    Show(row.stripe, not label and (sectionRank[item] or 0) % 2 == 0)
    if label then
      SetText(row.name, label)
      SetText(row.owner, "")
      SetText(row.source, "")
      SetText(row.details, "")
      row.sourceTip = nil
      return
    end
    local area = map.areas[id]
    -- The source column says when the shown owner is unconfirmed.
    local shown, info, source = ShownOwner(capture, id, now)
    Window.SetPoiIcon(row.icon, area, shown, Capturing(info))
    SetText(row.name, AreaName(area) .. " " .. AreaZone(area))
    Skin():Apply(row.badge, shown == "A" and "badge.alliance" or shown == "H" and "badge.horde" or "badge.neutral")
    SetText(row.owner, FactionText(shown))
    if not capture:Capturable(id) then
      Skin():Apply(row.dot, "dot.empty")
      SetText(row.source, Paint("DIM", "Not capturable yet"))
      row.sourceTip = { "Not capturable yet", "This place cannot be conquered yet." }
    elseif info and info.cloud then
      Skin():Apply(row.dot, "dot.grey")
      SetText(row.source, "Unconfirmed")
      row.sourceTip = SOURCE_TIPS.UNCONFIRMED
    elseif info and info.hint then
      Skin():Apply(row.dot, "dot.grey")
      SetText(row.source, "Unconfirmed")
      row.sourceTip = SOURCE_TIPS.UNCONFIRMED
    else
      Skin():Apply(row.dot, SOURCE_DOTS[source] or "dot.empty")
      row.sourceTip = SOURCE_TIPS[source or ""] or SOURCE_TIPS.STATIC
      SetText(row.source, source == "LOCAL" and SOURCE_LABELS.LOCAL or source == "PEER" and SOURCE_LABELS.PEER
        or Paint("DIM", SOURCE_LABELS.STATIC))
    end
    if info and info.challenger and info.challenger ~= "-" then
      SetText(row.details, FactionText(info.challenger) .. " " .. info.percent .. "%"
        .. (info.remaining and Paint("DIM", " " .. Duration(info.remaining)) or ""))
    elseif area.type == "SETTLEMENT" and map.LevelText then
      SetText(row.details, map.LevelText(area) or Paint("DIM", "Level 1"))
    elseif info and info.cloud then
      local _, _, detail = capture.CloudLine(info.cloud)
      SetText(row.details, Paint("DIM", detail or "-"))
    elseif info and info.hint then
      SetText(row.details, Paint("DIM", info.hint.count .. " player(s), " .. Duration(info.hint.age) .. " ago"))
    else
      SetText(row.details, Paint("DIM", "-"))
    end
  end)
end

function SyncDrawer:Update(now)
  if not self.channel then return end
  Window.MarkAllies(self.allies)
  local capture = WF.Capture
  local catchup = WF.Catchup
  local state, age = "waiting", nil
  if catchup and catchup.NewsState then state, age = catchup:NewsState(now) end
  self.newsState, self.newsAge = state, age
  SyncDrawer.SetNewsDot(self.channelDot, state)
  if state == "live" then
    SetText(self.channel, "War news: " .. Paint("GOOD", "live, last news " .. Duration(age) .. " ago"))
  elseif state == "quiet" then
    SetText(self.channel, "War news: " .. Paint("WARN", age and ("connected, last news " .. Duration(age) .. " ago")
      or "connected, no news yet"))
  else
    SetText(self.channel, "War news: " .. Paint("BAD", "Waiting for other players to sync"))
  end
  local talk = not capture or not capture.CanTalk or capture:CanTalk()
  Skin():Apply(self.sendDot, talk and "dot.green" or "dot.empty")
  SetText(self.send, "You take part: " .. (talk and Paint("GOOD", "yes")
    or Paint("BAD", tostring(capture.LockReason and capture:LockReason() or capture.LEVEL_REASON))))
  self:UpdateActivity(now)
  local pending = 0
  for code in pairs(catchup and catchup.pending or {}) do pending = pending + 1 end
  FitText(self.catchup, "Map news: " .. (pending > 0 and Paint("GOLD", "updating")
    or Paint("DIM", "up to date")), 168)
  local version = WF.Version and WF.Version:Text()
  Show(self.versionIcon, version ~= nil)
  if version then
    SetText(self.version, Paint("BAD", version))
  else
    SetText(self.version, "Addon version: " .. tostring(WF.version) .. Paint("DIM", ", no newer version seen"))
  end
  local companion = WF.Companion
  local download = WF.CompanionDownload
  local wanted = download ~= nil and download.Wanted()
  Show(self.companionGet, wanted)
  -- Room left of the Download button while it shows.
  local room = wanted and 176 or 260
  if companion and companion.Helping then
    if companion:Helping() then
      FitText(self.companion, "Companion: " .. Paint("GOOD", "in use"), room)
    elseif companion:ShownHint(now) then
      FitText(self.companion, "Companion: " .. Paint("GOLD", "recommended") .. Paint("DIM", " (optional)"), room)
    else
      FitText(self.companion, "Companion: " .. Paint("DIM", "optional, not in use"), room)
    end
  else
    SetText(self.companion, "")
  end
end

function Territory:Summary()
  local counts = self.counts
  if not counts then return "" end
  return FactionText("A") .. " " .. counts.A .. "   " .. FactionText("H") .. " " .. counts.H
end

Window:AddTab("map", "Territory", Territory)
