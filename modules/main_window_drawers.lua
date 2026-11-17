local WF = Warfront
local Window = WF.MainWindow

-- Main window (modules/main_window.lua): the Active Front and Synchronization drawers.
-- The base file loads first and shares its constants and helpers through
-- Window.Kit. Keep every main_window file far below the 200-local limit
-- (.claude/forever-compatibility.md, Lua runtime).
local Kit = Window.Kit
local NAME = Kit.NAME
local CONTENT_WIDTH = Kit.CONTENT_WIDTH
local FrontDrawer = Kit.FrontDrawer
local SyncDrawer = Kit.SyncDrawer
local GetGlobal = Kit.GetGlobal
local EaseOutSoftBounce = Kit.EaseOutSoftBounce
local Now = Kit.Now
local Paint = Kit.Paint
local FactionName = Kit.FactionName
local FactionText = Kit.FactionText
local AreaName = Kit.AreaName
local MyFaction = Kit.MyFaction
local OtherFaction = Kit.OtherFaction
local Skin = Kit.Skin
local Place = Kit.Place
local NewText = Kit.NewText
local SetText = Kit.SetText
local FitText = Kit.FitText
local Show = Kit.Show
local NewFrame = Kit.NewFrame
local MapIDForKey = Kit.MapIDForKey

local DRAWER_WIDTH = 342
local DRAWER_HEIGHT = 450
local DRAWER_DURATION = 0.6 -- matches the 0.6 s drawer sounds
local FRONT_TOGGLE_ICON_TEXTURE = "Interface\\AddOns\\Warfront\\media\\Textures\\UI\\Front\\FrontDrawerArrows"
local FRONT_DRAWER_OPEN_SOUND = "Interface\\AddOns\\Warfront\\media\\Sounds\\LeftGlueScreenPopUpShort.wav"
local FRONT_DRAWER_CLOSE_SOUND = "Interface\\AddOns\\Warfront\\media\\Sounds\\LeftGlueScreenPopDownShort.wav"
-- Active Front panoramas by Forever uiMapID (WF.Compat.MAP_KEYS); each file
-- name ends with that ID.
local FRONT_ZONE_TEXTURES = {}
do
  local dir = "Interface\\AddOns\\Warfront\\media\\Textures\\UI\\Front\\Zones\\Front"
  local names = {
    [1411] = "Durotar", [1412] = "Mulgore", [1413] = "TheBarrens",
    [1416] = "AlteracMountains", [1417] = "ArathiHighlands", [1418] = "Badlands",
    [1419] = "BlastedLands", [1420] = "TirisfalGlades", [1421] = "SilverpineForest",
    [1422] = "WesternPlaguelands", [1423] = "EasternPlaguelands",
    [1424] = "HillsbradFoothills", [1425] = "TheHinterlands", [1426] = "DunMorogh",
    [1427] = "SearingGorge", [1428] = "BurningSteppes", [1429] = "Elwynn",
    [1430] = "DeadwindPass", [1431] = "Duskwood", [1432] = "LochModan",
    [1433] = "RedridgeMountains", [1434] = "StranglethornVale",
    [1435] = "SwampOfSorrows", [1436] = "Westfall", [1437] = "Wetlands",
    [1438] = "Teldrassil", [1439] = "Darkshore", [1440] = "Ashenvale",
    [1441] = "ThousandNeedles", [1442] = "StonetalonMountains", [1443] = "Desolace",
    [1444] = "Feralas", [1445] = "Dustwallow", [1446] = "Tanaris", [1447] = "Azshara",
    [1448] = "Felwood", [1449] = "UnGoro", [1450] = "Moonglade", [1451] = "Silithus",
    [1452] = "Winterspring", [1453] = "Stormwind", [1454] = "Orgrimmar",
    [1455] = "Ironforge", [1456] = "ThunderBluff", [1457] = "Darnassus",
    [1458] = "Undercity", [2482] = "Hyjal", [2521] = "ZephrasIsle",
    [2548] = "Riverglades", [2652] = "Shendralas",
  }
  for mapID, name in pairs(names) do
    FRONT_ZONE_TEXTURES[mapID] = dir .. name .. "_" .. mapID
  end
end
local FRONT_ZONE_TEXTURE_WIDTH, FRONT_ZONE_TEXTURE_HEIGHT = 430, 143
local FRONT_ZONE_BACKDROP_HEIGHT = math.floor((DRAWER_WIDTH - 20) * FRONT_ZONE_TEXTURE_HEIGHT
  / FRONT_ZONE_TEXTURE_WIDTH + 0.5)
-- Front card banner of your faction: texture, width, height (tools/build_flags.py).
local FRONT_FLAGS = {
  A = { "Interface\\AddOns\\Warfront\\media\\Textures\\UI\\Flag\\WFFlagAlliance", 400, 60 },
  H = { "Interface\\AddOns\\Warfront\\media\\Textures\\UI\\Flag\\WFFlagHorde", 400, 61 },
}
local FRONT_FLAG_WIDTH = 280
local FRONT_TITLE_SIZE = 20 -- gold zone name cap height
local FRONT_HEADER_TITLE_SIZE = 10 -- gold "Active Front" header title cap height (fits the 20 px header)
local GOAL_FRAME_TEXTURE = "Interface\\AddOns\\Warfront\\media\\Textures\\UI\\Front\\FrontObjectiveFrame"
local GOAL_DIVIDER_TEXTURE = "Interface\\AddOns\\Warfront\\media\\Textures\\UI\\Front\\FrontObjectiveDivider"
local GOAL_STRIP_HEIGHT = 46 -- victory goal + allied players, one strip under the objective panel
local GOAL_DIVIDER_X = 214 -- centre of the goal/players divider, in the 322 px strip
local GOAL_DIVIDER_W = 3 -- divider texture (8 × 64 tga, tools/build_front_objective_frame.py), UI units
local GOAL_DIVIDER_H = 29
local GOAL_TEXT_WIDTH = 160 -- goal text column, left of the divider
local GOAL_PLAYERS_WIDTH = 44 -- allied count over "allies", right of the divider, clear of the end cap
local FRONT_CARD_DROP = 8 -- card, panorama and banner sit this far below the header so the title is clear
local FRONT_SIEGE_TOP = 28 + FRONT_CARD_DROP + FRONT_ZONE_BACKDROP_HEIGHT + 8 -- "Your objective" panel top in the body
local FRONT_GARRISON_H = 44 -- Garrison bar and detail rows under the victory goal strip
local FRONT_BODY_PAD = 10 -- body margin under its last row
-- Siege countdown ring around the target (map node layout, 64 texels): padded
-- from the panel's top and left edges, clear of the Outpost row below it.
local SIEGE_RING_SIZE, SIEGE_RING_X, SIEGE_RING_Y, SIEGE_RING_ICON = 42, 8, -25, 24
local SIEGE_TEXT_X = 56 -- target name and owner beside the ring (48 beside the icon)
-- Gold-letter countdown, right-aligned at x 310 on the ring's centre line,
-- shrunk to fit SIEGE_CLOCK_ROOM (a capital's 24-hour clock is wider).
local SIEGE_CLOCK_SIZE, SIEGE_CLOCK_RIGHT, SIEGE_CLOCK_ROOM = 16, 310, 90
local SIEGE_CLOCK_WARN = 60 -- the countdown keeps the letters' own gold, red only for its last minute
local DIVIDER_LINE = "Interface\\AddOns\\Warfront\\media\\Textures\\UI\\Divider\\WFDivider2"
local DIVIDER_DIAMOND = "Interface\\AddOns\\Warfront\\media\\Textures\\UI\\Divider\\WFDivider1"
-- Outpost medallions of the objective's zone (tools/build_front_outpost_textures.py):
-- x, y, width, height on the 256 x 128 page.
local OUTPOST_TEXTURE = "Interface\\AddOns\\Warfront\\media\\Textures\\UI\\Front\\FrontOutposts"
local OUTPOST_ART = {
  ["tower.neutral"] = { 0, 0, 64, 81 },
  ["tower.horde"] = { 66, 0, 64, 81 },
  ["tower.alliance"] = { 132, 0, 64, 81 },
  ["rail"] = { 0, 83, 256, 24 },
  ["divider"] = { 0, 109, 128, 6 },
}
local OUTPOST_TOWERS = { N = "tower.neutral", H = "tower.horde", A = "tower.alliance" }
local OUTPOST_FACTIONS = { H = true, A = true }
local OUTPOST_SLOTS = 3
local OUTPOST_W, OUTPOST_H = 48, 61
-- Row inside "Your objective": centred title between two gold dividers, then
-- the towers centred on their rail, OUTPOST_GAP apart.
local OUTPOST_ROW_W, OUTPOST_TOWER_Y, OUTPOST_GAP = 306, -18, 100
-- Row top inside the panel (4 px below the objective line) and its bottom.
local OUTPOST_ROW_TOP = -66
local OUTPOST_ROW_BOTTOM = -OUTPOST_ROW_TOP + OUTPOST_H - OUTPOST_TOWER_Y
local OUTPOST_RAIL_H = 10
-- Keep the original 14 px outer margins, but let the title borrow room from
-- both dividers. Each divider keeps enough width to remain recognisable.
local OUTPOST_DIVIDER_INSET, OUTPOST_DIVIDER_MIN = 14, 24
local DRAWER_ROUTES = {
  { id = "KA", label = "Kalimdor" },
  { id = "EK", label = "Eastern Kingdoms" },
}
local function AddFrontArea(drawer, id)
  if id and not drawer.areaSet[id] then
    drawer.areaSet[id] = true
    drawer.areaIds[#drawer.areaIds + 1] = id
  end
end

local function SetFrontAreas(drawer, capture, rear, forward)
  if drawer.lastRear == rear and drawer.lastForward == forward then return end
  drawer.lastRear, drawer.lastForward = rear, forward
  for id in pairs(drawer.areaSet) do drawer.areaSet[id] = nil end
  for index = 1, #drawer.areaIds do drawer.areaIds[index] = nil end
  local pair = { rear, forward }
  for index = 1, 2 do
    local id = pair[index]
    AddFrontArea(drawer, id)
    if id then
      local links = capture:LinkedObjectives(id)
      for link = 1, #links do AddFrontArea(drawer, links[link]) end
    end
  end
end

local function FrontZoneName(id)
  local map = WF.Map
  local area = id and map and map.areas[id]
  if not area then return nil end
  return tostring(map.FrontZoneName and map.FrontZoneName(area) or area.map or area.label or area.id)
end

-- Decision 0111: the card names your own target (your faction's banner and
-- objective line, the zone in gold letters, its owner below); "Defend" names
-- your Settlement the other faction targets once the lines meet (grey while
-- only targeted, orange once an Outpost is lost) on the card's bottom row.
-- Returns the threat level, that Settlement and your target.
local function SetFrontLines(drawer, front, capture, route, faction, now)
  local forward, rear = front:Targets(route, now)
  local side = faction or route.advancing
  local mine = side == route.advancing
  local index = mine and forward or rear
  local node = route.nodes[index]
  local attackId = node and node.id or (mine and index > #route.nodes and route.endpoint) or nil
  local zone = FrontZoneName(attackId)
  local status
  if not attackId then
    status = Paint("DIM", "Front endpoint")
  else
    status = FactionText((capture:SiegeOwner(attackId, now)) or "N")
    if faction and front:Paused(route, faction, now) then
      status = status .. Paint("DIM", " - Paused")
    elseif forward == rear then
      status = status .. Paint("GOLD", " - Contested")
    end
  end
  local flag = FRONT_FLAGS[side]
  if flag and drawer.flagPath ~= flag[1] then
    drawer.flagPath = flag[1]
    drawer.flag:SetTexture(flag[1])
    drawer.flag:SetHeight(FRONT_FLAG_WIDTH * flag[3] / flag[2])
  end
  Show(drawer.flag, flag ~= nil)
  SetText(drawer.objective, side == "A" and "ALLIANCE OBJECTIVE" or side == "H" and "HORDE OBJECTIVE" or "Objective")
  if drawer.zoneText ~= zone then
    drawer.zoneText = zone
    local width = Skin():SetGoldTitle(drawer.zoneTitle, zone or "", FRONT_TITLE_SIZE)
    local room = drawer.frontCard:GetWidth() - 24
    if width > room then Skin():SetGoldTitle(drawer.zoneTitle, nil, FRONT_TITLE_SIZE * room / width) end
  end
  Show(drawer.zoneTitle, zone ~= nil)
  SetText(drawer.owner, status)

  local level, threatId, lost, links = 0, nil, 0, 0
  if faction then level, threatId, lost, links = front:Threat(route, faction, now) end
  if level >= 1 and threatId then
    local status
    if level == 3 then
      local rec = front:Window(route.id)
      status = Paint("BAD", "Siege " .. front.Clock(rec and front:Remaining(rec, now) or 0))
    elseif level == 2 then
      status = Paint("WARN", lost .. "/" .. links .. " Outposts lost")
    else
      status = Paint("DIM", "Targeted")
    end
    SetText(drawer.defend.name, "Defend: " .. (FrontZoneName(threatId) or "?"))
    SetText(drawer.defend.status, status)
  end
  local defending = level >= 1 and threatId ~= nil
  for _, region in pairs(drawer.defend) do Show(region, defending) end
  return level, threatId, attackId
end

local function SetFrontBackdrop(drawer, mapKey)
  if drawer.frontBackdropKey == mapKey and drawer.frontBackdropKeySet then return end
  drawer.frontBackdropKey, drawer.frontBackdropKeySet = mapKey, true
  local mapID = mapKey and MapIDForKey(mapKey)
  local path = mapID and FRONT_ZONE_TEXTURES[mapID]
  if drawer.frontBackdropPath == path then return end
  drawer.frontBackdropPath = path
  if path then
    drawer.frontBackdrop:SetTexture(path)
    drawer.frontBackdrop:SetTexCoord(0, 1, 0, 1)
  end
  Show(drawer.frontBackdrop, path ~= nil)
  for _, part in pairs(drawer.frontCardSkin) do Show(part, path == nil) end
end

-- Garrison of the Settlement you defend and of its linked Outposts you hold
-- (an Outpost can hold a garrison too). Your attack target's is unknown.
local function DefenceGarrison(capture, id, faction, now)
  local used, capacity = capture:GarrisonOccupancy(id)
  local outpostUsed, outpostCapacity, outposts = 0, 0, 0
  local links = capture:LinkedObjectives(id)
  for index = 1, #links do
    if (capture:SiegeOwner(links[index], now)) == faction then
      local u, c = capture:GarrisonOccupancy(links[index])
      outpostUsed, outpostCapacity, outposts = outpostUsed + u, outpostCapacity + c, outposts + 1
    end
  end
  return used, capacity, outpostUsed, outpostCapacity, outposts
end

-- Crops `fraction` (bottom part) of an Outpost art piece into a texture;
-- `mirror` flips it horizontally.
local function SetOutpostArt(texture, name, fraction, mirror)
  local rect = OUTPOST_ART[name]
  fraction = fraction or 1
  if texture.art ~= name then
    texture.art = name
    texture:SetTexture(OUTPOST_TEXTURE)
  end
  local left, right = rect[1] / 256, (rect[1] + rect[3]) / 256
  if mirror then left, right = right, left end
  texture:SetTexCoord(left, right, (rect[2] + rect[4] * (1 - fraction)) / 128, (rect[2] + rect[4]) / 128)
end

local function OutpostTooltip(self)
  local capture, id = WF.Capture, self.outpostId
  local area = id and WF.Map and WF.Map.areas[id]
  if not capture or not area then return end
  local now = Now()
  local owner, confirmed = capture:SiegeOwner(id, now)
  GameTooltip:SetOwner(self, "ANCHOR_CURSOR", 10, 10)
  GameTooltip:AddLine(AreaName(area), 1, 1, 1)
  GameTooltip:AddLine(FactionText(owner or "N"))
  if not confirmed then GameTooltip:AddLine(Paint("DIM", "Reported, not confirmed")) end
  local view = capture:GetView(id, now)
  if view and OUTPOST_FACTIONS[view.challenger] and view.challenger ~= owner and view.progress > 0 then
    GameTooltip:AddLine("Being captured by " .. FactionText(view.challenger) .. ": "
      .. math.floor(view.progress / 10 + 0.5) .. "%")
  end
  Window.LocalizeTooltip(GameTooltip)
  GameTooltip:Show()
end

-- One medallion per Outpost of the objective's zone, coloured by its owner and
-- filled from the bottom by a challenger's capture progress. Returns whether
-- the row is shown.
-- The countdown ring: the attacker's capture band, clockwise from the top,
-- over the share of the siege window still left. Returns whether it shows.
local function SetSiegeRing(drawer, rec, left)
  local ring, map = drawer.ring, WF.Map
  local layout, textures = map and map.LayoutRingArc, map and map.RING_TEXTURES
  local path = rec and textures and textures[rec.side]
  if not path or not layout or not WF.Front or not WF.Front.Length then
    ring:Hide()
    return false
  end
  if ring.trackPath ~= textures.track then
    ring.trackPath = textures.track
    ring.track:SetTexture(textures.track, "CLAMP", "CLAMP", "TRILINEAR")
  end
  local length = WF.Front.Length(rec)
  local share = length > 0 and math.max(0, math.min(1, left / length)) or 0
  -- Redrawn only when the arc moves by a thousandth (about 11 s of a 3-hour window).
  local key = rec.side .. math.floor(share * 1000)
  if ring.key ~= key then
    ring.key = key
    local half = SIEGE_RING_SIZE / 2
    local used = layout(ring.arcs, 0, ring, path, half, half, SIEGE_RING_SIZE, 0, 2 * math.pi * share)
    for index = used + 1, #ring.arcs do ring.arcs[index]:Hide() end
  end
  ring:Show()
  return true
end

-- Gold-letter countdown beside the ring, tinted red near its end; redrawn
-- only when its text or tint changes.
local function SetGoldClock(drawer, seconds)
  local clock = drawer.goldClock
  local text = WF.Front.Clock(seconds)
  local warn = seconds <= SIEGE_CLOCK_WARN
  if clock.clockText == text and clock.clockWarn == warn then return end
  clock.clockText, clock.clockWarn = text, warn
  local width = Skin():SetGoldTitle(clock, text, SIEGE_CLOCK_SIZE)
  if width > SIEGE_CLOCK_ROOM then
    Skin():SetGoldTitle(clock, nil, SIEGE_CLOCK_SIZE * SIEGE_CLOCK_ROOM / width)
  end
  for index = 1, #clock.goldLetters do
    if warn then
      clock.goldLetters[index]:SetVertexColor(1, 0.35, 0.3)
    else
      clock.goldLetters[index]:SetVertexColor(1, 1, 1)
    end
  end
end

-- Gold countdown beside the ring while a siege runs; the small hourglass line
-- otherwise. Moves the target's name and owner beside whichever shows.
local function SetSiegeLayout(drawer, ringed)
  Show(drawer.goldClock, ringed)
  Show(drawer.clock, not ringed)
  if drawer.ringed == ringed then return end
  drawer.ringed = ringed
  local x = ringed and SIEGE_TEXT_X or 48
  Place(drawer.targetName, drawer.siege, x, -27)
  Place(drawer.targetOwner, drawer.siege, x, -45)
  drawer.targetName:SetWidth(216 - x)
  drawer.targetOwner:SetWidth(216 - x)
end

local function SetOutpostRow(drawer, capture, target, side, now)
  local row = drawer.outposts
  local links = target and capture:LinkedObjectives(target) or nil
  local count = links and math.min(#links, OUTPOST_SLOTS) or 0
  Show(row, count > 0)
  if count == 0 then return false end
  local held = 0
  for index = 1, OUTPOST_SLOTS do
    local tower = row.towers[index]
    local id = index <= count and links[index] or nil
    tower.outpostId = id
    Show(tower, id ~= nil)
    if id then
      if row.count ~= count then
        local centre = OUTPOST_ROW_W / 2 + (index - (count + 1) / 2) * OUTPOST_GAP
        Place(tower, row, math.floor(centre - OUTPOST_W / 2 + 0.5), OUTPOST_TOWER_Y)
      end
      local owner = (capture:SiegeOwner(id, now)) or "N"
      if owner == side then held = held + 1 end
      SetOutpostArt(tower.base, OUTPOST_TOWERS[owner] or OUTPOST_TOWERS.N)
      local view = capture:GetView(id, now)
      local challenger = view and view.challenger
      local fraction = (OUTPOST_FACTIONS[challenger] and challenger ~= owner) and (view.progress or 0) / 1000 or 0
      if fraction > 0 then
        fraction = math.min(1, fraction)
        SetOutpostArt(tower.fill, OUTPOST_TOWERS[challenger], fraction)
        tower.fill:SetHeight(math.max(1, OUTPOST_H * fraction))
      end
      Show(tower.fill, fraction > 0)
    end
  end
  if row.count ~= count then
    -- The rail joins the first and last tower centres; the towers cover it.
    local span = (count - 1) * OUTPOST_GAP
    row.rail:SetWidth(math.max(1, span))
    Place(row.rail, row, math.floor((OUTPOST_ROW_W - span) / 2 + 0.5),
      OUTPOST_TOWER_Y - math.floor((OUTPOST_H - OUTPOST_RAIL_H) / 2))
    Show(row.rail, count > 1)
  end
  row.count = count
  local title = held .. " / " .. #links .. " Outposts captured"
  local previous = row.label.value
  SetText(row.label, title)
  if row.label.value ~= previous or not row.labelWidth then
    local room = OUTPOST_ROW_W - 2 * (OUTPOST_DIVIDER_INSET + OUTPOST_DIVIDER_MIN)
    row.label.fitValue = nil
    FitText(row.label, title, room)
    row.label:SetWidth(0)
    local titleWidth = math.min(room, math.ceil((row.label:GetStringWidth() or 0) + 6))
    local dividerWidth = math.max(OUTPOST_DIVIDER_MIN,
      math.floor((OUTPOST_ROW_W - 2 * OUTPOST_DIVIDER_INSET - titleWidth) / 2))
    row.label:SetWidth(titleWidth)
    Place(row.label, row, math.floor((OUTPOST_ROW_W - titleWidth) / 2 + 0.5), 0)
    for side = 1, 2 do
      local line = row.dividers[side]
      line:SetWidth(dividerWidth)
      Place(line, row, side == 1 and OUTPOST_DIVIDER_INSET
        or OUTPOST_ROW_W - OUTPOST_DIVIDER_INSET - dividerWidth, -5)
    end
    row.labelWidth = titleWidth
  end
  return true
end

local function Outcome(front, route, id, side, now)
  if front.byCapital and front.byCapital[id] then return "The campaign is won" end
  local node = front.bySettlement and front.bySettlement[id]
  if not node then return "" end
  local forwardIndex, rearIndex = front:Targets(route, now)
  if side == route.advancing and node.index == forwardIndex then
    local nextNode = route.nodes[node.index + 1]
    return "Advance toward " ..(nextNode and FrontZoneName(nextNode.id) or route.capital or "the capital")
  end
  if side == OtherFaction(route.advancing) and node.index == rearIndex then
    local previous = route.nodes[node.index - 1]
    return "Push toward " ..(previous and FrontZoneName(previous.id) or "the route start")
  end
  return "Moves the Active Front"
end

-- Victory goal line (2026-11-15): always the base font size; a line too long for
-- its column is cut by the font string and shows whole in a tooltip on hover.
local function SetGoalText(text, hover, value)
  if text.goalValue == value then return end
  text.goalValue = value
  text:SetWidth(0) -- unbounded, so the measure is the full text
  SetText(text, value)
  local width = text:GetStringWidth() or 0
  text:SetWidth(GOAL_TEXT_WIDTH)
  hover.fullText = width > GOAL_TEXT_WIDTH and value or nil
end

local function GoalTextTooltip(self)
  if not self.fullText then return end
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  GameTooltip:AddLine(self.fullText, 1, 1, 1)
  Window.LocalizeTooltip(GameTooltip)
  GameTooltip:Show()
end

-- Drawer handles (2026-11-15): one dark button, 54 × 24 under the window, the
-- same face turned a quarter (24 × 54) beside it. The chevron is cropped to
-- the right arrow of the double-arrow texture (columns 16-28, rows 6-25 of 32)
-- so it sits centred in every direction.
Window.CHEVRON = { 16 / 32, 29 / 32, 6 / 32, 26 / 32 }

function Window.ShowHandleTip(handle)
  GameTooltip:SetOwner(handle, handle.tipAnchor)
  GameTooltip:AddLine(handle.tipText(), 1, 1, 1)
  Window.LocalizeTooltip(GameTooltip)
  GameTooltip:Show()
end

function Window.NewHandle(parent, turned, onClick, name, anchor, tipText)
  local width, height = 54, 24
  if turned then width, height = 24, 54 end
  local handle = Skin():Button(parent, "dark", width, height, onClick, name, turned)
  handle:SetFrameLevel((parent:GetFrameLevel() or 0) + 12)
  Skin():SetButton(handle, "", true)
  -- 13 × 20 texels: upright beside the window, lying under it.
  if turned then
    handle.icon = Skin():Icon(handle, nil, 9, 14, "ARTWORK")
  else
    handle.icon = Skin():Icon(handle, nil, 14, 9, "ARTWORK")
  end
  handle.icon:SetTexture(FRONT_TOGGLE_ICON_TEXTURE)
  handle.icon:SetPoint("CENTER", handle, "CENTER", 0, 0)
  handle.tipAnchor, handle.tipText = anchor, tipText
  -- The skin's own hover glow first, then the tooltip.
  local skinEnter, skinLeave = handle:GetScript("OnEnter"), handle:GetScript("OnLeave")
  handle:SetScript("OnEnter", function(self)
    if skinEnter then skinEnter(self) end
    Window.ShowHandleTip(self)
  end)
  handle:SetScript("OnLeave", function(self)
    if skinLeave then skinLeave(self) end
    GameTooltip:Hide()
  end)
  return handle
end

-- After a click, while the pointer is still on the handle (`over`, set by the
-- skin's hover script): the tooltip names the next action.
function Window.RefreshHandleTip(handle)
  if handle and handle.over then Window.ShowHandleTip(handle) end
end

function Window:BuildFrontDrawer()
  if FrontDrawer.frame then return FrontDrawer.frame end
  local create = GetGlobal("CreateFrame")
  local clip = create("ScrollFrame", NAME .. "FrontDrawerClip", self.frame)
  clip:SetWidth(DRAWER_WIDTH)
  clip:SetHeight(DRAWER_HEIGHT)
  -- Scale and anchor: Window:FitScale.
  clip:SetFrameLevel((self.frame:GetFrameLevel() or 0) + 2)

  local scroll = create("Frame", NAME .. "FrontDrawerScroll", clip)
  scroll:SetWidth(DRAWER_WIDTH * 2)
  scroll:SetHeight(DRAWER_HEIGHT)
  clip:SetScrollChild(scroll)

  local drawer = create("Frame", NAME .. "FrontDrawer", scroll)
  drawer:SetWidth(DRAWER_WIDTH)
  drawer:SetHeight(DRAWER_HEIGHT)
  drawer:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, 0)
  FrontDrawer.frame, FrontDrawer.clip, FrontDrawer.scroll = drawer, clip, scroll

  local tabWidth = math.floor(DRAWER_WIDTH / 2)
  FrontDrawer.tabs = {}
  for index = 1, #DRAWER_ROUTES do
    local spec = DRAWER_ROUTES[index]
    local button = Skin():Button(drawer, "tab", tabWidth, 28, function(b) Window:SelectFrontRoute(b.routeId) end,
      NAME .. "FrontTab" .. index)
    button.routeId = spec.id
    Place(button, drawer, (index - 1) * tabWidth, 0)
    Skin():SetButton(button, spec.label, true, spec.id == FrontDrawer.routeId)
    FrontDrawer.tabs[index] = button
  end

  local body = Skin():Panel(drawer, "Active Front", DRAWER_WIDTH, DRAWER_HEIGHT - 28)
  Place(body, drawer, 0, -28)
  FrontDrawer.body = body

  -- Header title: centred gold letters, smaller than the zone name, in place of the left-aligned text.
  local headerStrip = body.title:GetParent()
  body.title:SetText("")
  FrontDrawer.headerTitle = Skin():GoldTitle(headerStrip, "Active Front", FRONT_HEADER_TITLE_SIZE, "OVERLAY")
  FrontDrawer.headerTitle:SetPoint("CENTER", headerStrip, "CENTER", 0, 0)

  -- ARTWORK: on BACKGROUND it shares the panel's own layer, where the draw order is undefined.
  FrontDrawer.frontBackdrop = Skin():Icon(body, nil, DRAWER_WIDTH - 20, FRONT_ZONE_BACKDROP_HEIGHT, "ARTWORK")
  Place(FrontDrawer.frontBackdrop, body, 10, -(28 + FRONT_CARD_DROP))
  FrontDrawer.frontBackdrop:Hide()

  -- Front card at the panorama's full height (dark panel for a zone without one):
  -- your banner over its top edge, "<FACTION> OBJECTIVE" between thin dividers,
  -- the zone in gold letters, its owner between diamond dividers, then Defend.
  local frontCard = NewFrame(body, DRAWER_WIDTH - 20, FRONT_ZONE_BACKDROP_HEIGHT)
  Place(frontCard, body, 10, -(28 + FRONT_CARD_DROP))
  FrontDrawer.frontCardSkin = Skin():Slice9(frontCard, "panel", 0.18, "BACKGROUND")
  FrontDrawer.frontCard = frontCard
  -- A child frame draws above the panel's header strip, which the banner overlaps.
  local banner = NewFrame(frontCard, FRONT_FLAG_WIDTH, 60)
  banner:SetPoint("TOP", frontCard, "TOP", 0, 12)
  FrontDrawer.flag = banner:CreateTexture(nil, "ARTWORK")
  FrontDrawer.flag:SetWidth(FRONT_FLAG_WIDTH)
  FrontDrawer.flag:SetPoint("TOP", banner, "TOP", 0, 0)
  FrontDrawer.flag:Hide()

  local function Divider(path, width, height, anchor, side, gap, mirror)
    local texture = frontCard:CreateTexture(nil, "ARTWORK")
    texture:SetTexture(path)
    if mirror then texture:SetTexCoord(1, 0, 0, 1) end
    texture:SetWidth(width)
    texture:SetHeight(height)
    if side == "LEFT" then
      texture:SetPoint("RIGHT", anchor, "LEFT", -gap, 0)
    else
      texture:SetPoint("LEFT", anchor, "RIGHT", gap, 0)
    end
    return texture
  end
  -- No width: the line sizes to its text, so the dividers follow it.
  FrontDrawer.objective = Skin():Text(frontCard, "GameFontHighlight", "CENTER")
  FrontDrawer.objective:SetPoint("TOP", frontCard, "TOP", 0, -32)
  Divider(DIVIDER_LINE, 32, 2, FrontDrawer.objective, "LEFT", 6, true)
  Divider(DIVIDER_LINE, 32, 2, FrontDrawer.objective, "RIGHT", 6, false)
  FrontDrawer.zoneTitle = Skin():GoldTitle(frontCard, "", FRONT_TITLE_SIZE, "OVERLAY")
  FrontDrawer.zoneTitle:SetPoint("TOP", frontCard, "TOP", 0, -50)
  FrontDrawer.owner = Skin():Text(frontCard, "GameFontNormal", "CENTER")
  FrontDrawer.owner:SetPoint("TOP", frontCard, "TOP", 0, -75)
  -- Both kinds of divider: thick end (diamond) beside the text, tip outward.
  Divider(DIVIDER_DIAMOND, 30, 6, FrontDrawer.owner, "LEFT", 8, true)
  Divider(DIVIDER_DIAMOND, 30, 6, FrontDrawer.owner, "RIGHT", 8, false)
  FrontDrawer.defend = {}
  FrontDrawer.defend.icon = Skin():Icon(frontCard, "icon.shield", 16, 16)
  Place(FrontDrawer.defend.icon, frontCard, 12, -88)
  FrontDrawer.defend.name = NewText(frontCard, "GameFontNormalSmall", 32, -89, 170)
  FrontDrawer.defend.status = NewText(frontCard, "GameFontHighlightSmall", 202, -89, frontCard:GetWidth() - 214, "RIGHT")

  local stripTop = -FRONT_SIEGE_TOP
  -- One strip: victory goal on the left, allied players present on the right.
  local outcome = NewFrame(body, DRAWER_WIDTH - 20, GOAL_STRIP_HEIGHT)
  -- FrontObjectiveFrame.tga (512 × 73, tools/build_front_objective_frame.py): cropped to the frame, so it
  -- fills the strip; the divider is a separate texture placed here at GOAL_DIVIDER_X.
  local frame = outcome:CreateTexture(nil, "BORDER")
  frame:SetTexture(GOAL_FRAME_TEXTURE)
  frame:SetAllPoints(outcome)
  local divider = outcome:CreateTexture(nil, "ARTWORK")
  divider:SetTexture(GOAL_DIVIDER_TEXTURE)
  divider:SetWidth(GOAL_DIVIDER_W)
  divider:SetHeight(GOAL_DIVIDER_H)
  divider:SetPoint("CENTER", outcome, "LEFT", GOAL_DIVIDER_X, 0)
  FrontDrawer.outcomeFrame = outcome
  FrontDrawer.outcomeIcon = Skin():Icon(outcome, "icon.swords", 28, 28)
  Place(FrontDrawer.outcomeIcon, outcome, 10, -9)
  FrontDrawer.outcomeLabel = NewText(outcome, "GameFontNormalSmall", 46, -10, GOAL_TEXT_WIDTH)
  SetText(FrontDrawer.outcomeLabel, "VICTORY GOAL")
  FrontDrawer.outcome = NewText(outcome, "GameFontHighlight", 46, -22, GOAL_TEXT_WIDTH)
  FrontDrawer.outcomeHover = NewFrame(outcome, GOAL_TEXT_WIDTH, 14)
  Place(FrontDrawer.outcomeHover, outcome, 46, -22)
  FrontDrawer.outcomeHover:EnableMouse(true)
  FrontDrawer.outcomeHover:SetScript("OnEnter", GoalTextTooltip)
  FrontDrawer.outcomeHover:SetScript("OnLeave", function() GameTooltip:Hide() end)
  FrontDrawer.playerIcon = Skin():Icon(outcome, "icon.unitsize", 24, 19)
  Place(FrontDrawer.playerIcon, outcome, GOAL_DIVIDER_X + 17, -14)
  FrontDrawer.playersCount = NewText(outcome, "GameFontHighlightLarge", GOAL_DIVIDER_X + 47, -10, GOAL_PLAYERS_WIDTH, "CENTER")
  FrontDrawer.playersLabel = NewText(outcome, "GameFontHighlight", GOAL_DIVIDER_X + 47, -25, GOAL_PLAYERS_WIDTH, "CENTER")

  -- Its height follows its content (RefreshFrontDrawer); the victory goal strip and the bars below follow it.
  local siege = Skin():Panel(body, "Your objective", DRAWER_WIDTH - 20, 172)
  Place(siege, body, 10, stripTop)
  FrontDrawer.siege = siege
  outcome:ClearAllPoints()
  outcome:SetPoint("TOPLEFT", siege, "BOTTOMLEFT", 0, -8)
  siege.title:SetText("")
  FrontDrawer.siegeTitle = Skin():GoldTitle(siege.title:GetParent(), "Your objective", FRONT_HEADER_TITLE_SIZE, "OVERLAY")
  FrontDrawer.siegeTitle:SetPoint("CENTER", siege.title:GetParent(), "CENTER", 0, 0)
  FrontDrawer.targetIcon = Skin():Icon(siege, nil, 34, 34)
  Place(FrontDrawer.targetIcon, siege, 8, -27)
  FrontDrawer.targetName = NewText(siege, "GameFontNormal", 48, -27, 168)
  FrontDrawer.targetOwner = NewText(siege, "GameFontHighlightSmall", 48, -45, 168)
  FrontDrawer.clockIcon = Skin():Icon(siege, "icon.hourglass", 20, 24)
  Place(FrontDrawer.clockIcon, siege, 226, -30)
  -- Leave room for the inactive "Not started" status; active countdowns remain right-aligned beside the hourglass.
  FrontDrawer.clock = NewText(siege, "GameFontNormal", 212, -34, 98, "RIGHT")
  -- While a siege runs, the target sits in a ring of the map's capture-band
  -- art that empties with the time left, in the attacker's colour.
  local ring = NewFrame(siege, SIEGE_RING_SIZE, SIEGE_RING_SIZE)
  Place(ring, siege, SIEGE_RING_X, SIEGE_RING_Y)
  ring.track = ring:CreateTexture(nil, "ARTWORK", nil, 0)
  ring.track:SetAllPoints(ring)
  ring.arcs = {}
  ring.icon = Skin():Icon(ring, nil, SIEGE_RING_ICON, SIEGE_RING_ICON, "OVERLAY")
  ring.icon:SetPoint("CENTER", ring, "CENTER", 0, 0)
  ring:Hide()
  FrontDrawer.ring = ring
  FrontDrawer.goldClock = Skin():GoldTitle(siege, "", SIEGE_CLOCK_SIZE, "OVERLAY")
  FrontDrawer.goldClock:SetPoint("RIGHT", siege, "TOPLEFT", SIEGE_CLOCK_RIGHT, SIEGE_RING_Y - SIEGE_RING_SIZE / 2)
  FrontDrawer.goldClock:Hide()
  FrontDrawer.checks = {}
  for index = 1, 3 do
    local row = NewFrame(siege, siege.width - 16, 20)
    Place(row, siege, 8, -68 - (index - 1) * 23)
    Skin():RowBackground(row, 20)
    Show(Skin():RowStripe(row), index % 2 == 0)
    row.hover = Skin():RowStripe(row, Skin().HOVER_ALPHA)
    row.text = NewText(row, "GameFontHighlightSmall", 0, -3, row:GetWidth(), "CENTER")
    FrontDrawer.checks[index] = row
  end
  Window.WatchHover(siege, FrontDrawer.checks)

  -- Outpost medallions on their rail, between the objective and its checklist.
  local outposts = NewFrame(siege, OUTPOST_ROW_W, OUTPOST_H - OUTPOST_TOWER_Y)
  Place(outposts, siege, 8, OUTPOST_ROW_TOP)
  local titleRoom = OUTPOST_ROW_W - 2 * (OUTPOST_DIVIDER_INSET + OUTPOST_DIVIDER_MIN)
  local titleLeft = (OUTPOST_ROW_W - titleRoom) / 2
  outposts.label = NewText(outposts, "GameFontHighlight", titleLeft, 0, titleRoom, "CENTER")
  outposts.dividers = {}
  for side = 1, 2 do
    local line = Skin():Icon(outposts, nil, OUTPOST_DIVIDER_MIN, 3, "BORDER")
    SetOutpostArt(line, "divider", nil, side == 2)
    Place(line, outposts, side == 1 and OUTPOST_DIVIDER_INSET
      or OUTPOST_ROW_W - OUTPOST_DIVIDER_INSET - OUTPOST_DIVIDER_MIN, -5)
    outposts.dividers[side] = line
  end
  outposts.rail = Skin():Icon(outposts, nil, 1, OUTPOST_RAIL_H, "BORDER")
  SetOutpostArt(outposts.rail, "rail")
  outposts.towers = {}
  for index = 1, OUTPOST_SLOTS do
    local tower = NewFrame(outposts, OUTPOST_W, OUTPOST_H)
    tower:EnableMouse(true)
    tower.base = Skin():Icon(tower, nil, OUTPOST_W, OUTPOST_H, "ARTWORK")
    tower.base:SetPoint("TOPLEFT", tower, "TOPLEFT", 0, 0)
    tower.fill = Skin():Icon(tower, nil, OUTPOST_W, OUTPOST_H, "OVERLAY")
    tower.fill:SetPoint("BOTTOMLEFT", tower, "BOTTOMLEFT", 0, 0)
    tower.fill:Hide()
    tower:SetScript("OnEnter", OutpostTooltip)
    tower:SetScript("OnLeave", function() GameTooltip:Hide() end)
    outposts.towers[index] = tower
  end
  FrontDrawer.outposts = outposts

  -- The Garrison row hangs under the objective panel (the Outpost towers already show capture progress).
  local function Below(region, x, y)
    region:ClearAllPoints()
    region:SetPoint("TOPLEFT", siege, "BOTTOMLEFT", x, y - GOAL_STRIP_HEIGHT - 8)
  end
  FrontDrawer.garrisonLabel = NewText(body, "GameFontHighlightSmall", 0, 0, 70)
  Below(FrontDrawer.garrisonLabel, 2, -12)
  FrontDrawer.garrisonBar = Skin():Bar(body, 190, 16, "gold")
  Below(FrontDrawer.garrisonBar, 70, -11)
  FrontDrawer.garrisonValue = NewText(body, "GameFontHighlightSmall", 0, 0, 55, "RIGHT")
  Below(FrontDrawer.garrisonValue, 265, -12)
  FrontDrawer.garrisonDetail = NewText(body, "GameFontHighlightSmall", 0, 0, 250)
  Below(FrontDrawer.garrisonDetail, 70, -30)

  -- The Synchronization handle stood on end (same dark face, turned).
  local toggle = Window.NewHandle(self.frame, true, function() Window:ToggleFrontDrawer() end,
    NAME .. "FrontDrawerToggle", "ANCHOR_LEFT",
    function() return FrontDrawer.target > 0 and "Close Active Front" or "Open Active Front" end)
  -- 7 units at the old 1.1 handle scale, kept at the same place on screen.
  toggle:SetPoint("RIGHT", self.frame, "RIGHT", 7 * Window.FRONT_SCALE / Window.HANDLE_SCALE, 0)
  self.frontToggle = toggle

  clip:UpdateScrollChildRect()
  self:SnapFrontDrawer(FrontDrawer.position)
  return drawer
end

function Window:SelectFrontRoute(routeId)
  local front = WF.Front
  if not front or not front:HasRoutes() or not front.byId[routeId] then return false end
  FrontDrawer.routeId = routeId
  FrontDrawer.lastRear, FrontDrawer.lastForward = nil, nil
  self:RefreshFrontDrawer(Now())
  return true
end

-- Each time the window opens, the drawer starts on the continent the player
-- stands on (2026-11-16, user); elsewhere it keeps its last tab.
function Window:PickPlayerFrontRoute()
  local front, network = WF.Front, WF.FrontNetwork
  local continent = network and network:PlayerContinent()
  if not continent or not front or not front:HasRoutes() or not front.byId[continent] then return false end
  if FrontDrawer.routeId ~= continent then
    FrontDrawer.routeId = continent
    FrontDrawer.lastRear, FrontDrawer.lastForward = nil, nil
  end
  return true
end

function Window:ToggleFrontDrawer()
  if not FrontDrawer.clip then return false end
  FrontDrawer.target = FrontDrawer.target > 0 and 0 or 1
  FrontDrawer.animFrom = FrontDrawer.position
  FrontDrawer.animElapsed = 0
  FrontDrawer.animDuration = math.max(0.08, DRAWER_DURATION * math.abs(FrontDrawer.target - FrontDrawer.position))
  FrontDrawer.animating = true
  self:UpdateFrontToggleIcon()
  Window.RefreshHandleTip(self.frontToggle)
  -- Played only for a player click; automatic closes and reopens use SnapFrontDrawer or set the state directly.
  if type(PlaySoundFile) == "function" then
    pcall(PlaySoundFile, FrontDrawer.target > 0 and FRONT_DRAWER_OPEN_SOUND or FRONT_DRAWER_CLOSE_SOUND)
  end
  if FrontDrawer.target > 0 then FrontDrawer.clip:EnableMouse(true) end
  if FrontDrawer.target > 0 then self:RefreshFrontDrawer(Now()) end
  return true
end

-- The handle's arrow points where a click moves the drawer: left to close, right to open.
function Window:UpdateFrontToggleIcon()
  local icon = self.frontToggle and self.frontToggle.icon
  if not icon then return end
  local c = Window.CHEVRON
  if FrontDrawer.target > 0 then icon:SetTexCoord(c[2], c[1], c[3], c[4]) else icon:SetTexCoord(c[1], c[2], c[3], c[4]) end
end

-- Places the drawer at once (0 closed, 1 open), stopping any animation.
function Window:SnapFrontDrawer(position)
  if not FrontDrawer.clip then return end
  FrontDrawer.position, FrontDrawer.target, FrontDrawer.animating = position, position, false
  FrontDrawer.clip:SetHorizontalScroll(DRAWER_WIDTH * (1 - position))
  FrontDrawer.clip:EnableMouse(position > 0)
  self:UpdateFrontToggleIcon()
end

-- WarfrontDev only (/wfd siege): siege windows by route id, shaped like
-- WF.Front's, that the drawer's objective panel shows instead of the real one.
-- Display only: never read by WF.Front, saved or sent; nil clears them.
function Window:SetSimulatedSiege(windows)
if windows then FrontDrawer.preview = nil end
FrontDrawer.simulated = windows
if WF.Map and type(WF.Map.SetSimulatedSiege) == "function" then WF.Map:SetSimulatedSiege(windows) end
if FrontDrawer.frame then self:RefreshFrontDrawer(Now()) end
end

-- WarfrontDev only (/wfd drawer): complete display data for the Active Front
-- drawer. The preview supplies Front/Capture-shaped read-only adapters and
-- never changes the real modules, SavedVariables, maps or network state.
function Window:SetSimulatedFrontDrawer(preview)
FrontDrawer.preview = type(preview) == "table" and preview or nil
if FrontDrawer.preview then
FrontDrawer.simulated = nil
if WF.Map and type(WF.Map.SetSimulatedSiege) == "function" then WF.Map:SetSimulatedSiege(nil) end
end
if FrontDrawer.frame then self:RefreshFrontDrawer(Now()) end
end

function Window:AnimateFrontDrawer(elapsed)
  if not FrontDrawer.clip or not FrontDrawer.animating then return end
  local duration = FrontDrawer.animDuration or DRAWER_DURATION
  FrontDrawer.animElapsed = math.min(duration, (FrontDrawer.animElapsed or 0) + (elapsed or 0))
  local progress = duration > 0 and FrontDrawer.animElapsed / duration or 1
  local eased = EaseOutSoftBounce(progress)
  FrontDrawer.position = FrontDrawer.animFrom + (FrontDrawer.target - FrontDrawer.animFrom) * eased
  if progress >= 1 then
    FrontDrawer.position = FrontDrawer.target
    FrontDrawer.animating = false
  end
  FrontDrawer.clip:SetHorizontalScroll(DRAWER_WIDTH * (1 - FrontDrawer.position))
  if not FrontDrawer.animating and FrontDrawer.position == 0 then FrontDrawer.clip:EnableMouse(false) end
end

-- Synchronization drawer: the same clip as the Active Front drawer, turned
-- downward. The scroll child is twice the drawer's height with the panel on
-- top; a vertical scroll of HEIGHT shows the empty half (closed), 0 the panel.
function Window:BuildSyncDrawer()
  if SyncDrawer.clip then return SyncDrawer.clip end
  local create = GetGlobal("CreateFrame")
  local height = SyncDrawer.HEIGHT
  local clip = create("ScrollFrame", NAME .. "SyncDrawerClip", self.frame)
  clip:SetWidth(CONTENT_WIDTH)
  clip:SetHeight(height)
  -- Scale and anchor: Window:FitScale.
  clip:SetFrameLevel((self.frame:GetFrameLevel() or 0) + 2)
  local scroll = create("Frame", NAME .. "SyncDrawerScroll", clip)
  scroll:SetWidth(CONTENT_WIDTH)
  scroll:SetHeight(height * 2)
  clip:SetScrollChild(scroll)
  SyncDrawer.clip, SyncDrawer.scroll = clip, scroll
  SyncDrawer:BuildPanel(scroll)

  local toggle = Window.NewHandle(self.frame, false, function() Window:ToggleSyncDrawer() end,
    NAME .. "SyncDrawerToggle", "ANCHOR_TOP",
    function() return SyncDrawer.target > 0 and "Close Synchronization" or "Open Synchronization" end)
  -- 11 units at the old 1.2 handle scale, kept at the same place on screen, then 8 up (2026-11-16, user).
  toggle:SetPoint("BOTTOM", self.frame, "BOTTOM", 0, -11 * Window.SYNC_SCALE / Window.HANDLE_SCALE + 8)
  self.syncToggle = toggle

  clip:UpdateScrollChildRect()
  self:SnapSyncDrawer(SyncDrawer.position)
  return clip
end

function Window:ToggleSyncDrawer()
  if not SyncDrawer.clip then return false end
  SyncDrawer.target = SyncDrawer.target > 0 and 0 or 1
  SyncDrawer.animFrom = SyncDrawer.position
  SyncDrawer.animElapsed = 0
  SyncDrawer.animDuration = math.max(0.08, DRAWER_DURATION * math.abs(SyncDrawer.target - SyncDrawer.position))
  SyncDrawer.animating = true
  self:UpdateSyncToggleIcon()
  Window.RefreshHandleTip(self.syncToggle)
  if type(PlaySoundFile) == "function" then
    pcall(PlaySoundFile, SyncDrawer.target > 0 and FRONT_DRAWER_OPEN_SOUND or FRONT_DRAWER_CLOSE_SOUND)
  end
  if SyncDrawer.target > 0 then
    SyncDrawer.clip:EnableMouse(true)
    SyncDrawer:Update(Now())
  end
  return true
end

-- The chevron points where a click moves the drawer: down to open, up to close.
function Window:UpdateSyncToggleIcon()
  local icon = self.syncToggle and self.syncToggle.icon
  if not icon then return end
  -- The right arrow turned: counter-clockwise points up, clockwise down.
  local u0, u1, v0, v1 = Window.CHEVRON[1], Window.CHEVRON[2], Window.CHEVRON[3], Window.CHEVRON[4]
  if SyncDrawer.target > 0 then
    icon:SetTexCoord(u1, v0, u0, v0, u1, v1, u0, v1)
  else
    icon:SetTexCoord(u0, v1, u1, v1, u0, v0, u1, v0)
  end
end

function Window:SnapSyncDrawer(position)
  if not SyncDrawer.clip then return end
  SyncDrawer.position, SyncDrawer.target, SyncDrawer.animating = position, position, false
  SyncDrawer.clip:SetVerticalScroll(SyncDrawer.HEIGHT * (1 - position))
  SyncDrawer.clip:EnableMouse(position > 0)
  self:UpdateSyncToggleIcon()
end

function Window:AnimateSyncDrawer(elapsed)
  if not SyncDrawer.clip or not SyncDrawer.animating then return end
  local duration = SyncDrawer.animDuration or DRAWER_DURATION
  SyncDrawer.animElapsed = math.min(duration, (SyncDrawer.animElapsed or 0) + (elapsed or 0))
  local progress = duration > 0 and SyncDrawer.animElapsed / duration or 1
  SyncDrawer.position = SyncDrawer.animFrom + (SyncDrawer.target - SyncDrawer.animFrom) * EaseOutSoftBounce(progress)
  if progress >= 1 then
    SyncDrawer.position = SyncDrawer.target
    SyncDrawer.animating = false
  end
  SyncDrawer.clip:SetVerticalScroll(SyncDrawer.HEIGHT * (1 - SyncDrawer.position))
  if not SyncDrawer.animating and SyncDrawer.position == 0 then SyncDrawer.clip:EnableMouse(false) end
end

-- The window draws at Window.UI_SCALE, shrunk until it fits UIParent with its
-- top ornaments, the Alliance drape and both drawers open (2026-11-15, user).
-- Each drawer and its handle take their own scale over the window's, so they
-- keep Window.FRONT_SCALE / SYNC_SCALE on screen; their offsets follow the
-- frame's art: the Active Front drawer centres on the window's right edge, and the bottom border's 10
-- transparent rows (× 0.3 = 3 frame units).
Window.FIT = { top = 38, left = 8, margin = 8, minimum = 0.5 }

function Window:FitScale()
  local frame = self.frame
  if not frame then return end
  local factor = WF.Preferences and WF.Preferences:ScaleFactor() or 1
  local scale, fit = Window.UI_SCALE * factor, Window.FIT
  local frontScale, syncScale = Window.FRONT_SCALE * factor, Window.SYNC_SCALE * factor
  local parent = frame:GetParent()
  local width = parent and parent:GetWidth() or 0
  local height = parent and parent:GetHeight() or 0
  if width > 0 and height > 0 then
    local byHeight = (height - SyncDrawer.HEIGHT * syncScale - 2 * fit.margin) / (Window.HEIGHT + fit.top)
    local byWidth = (width - DRAWER_WIDTH * frontScale - 2 * fit.margin) / (Window.WIDTH + fit.left)
    scale = math.max(fit.minimum, math.min(scale, byHeight, byWidth))
  end
  if scale == self.scale and factor == self.userScaleFactor then return end
  self.scale, self.userScaleFactor = scale, factor
  frame:SetScale(scale)
  local front, sync = FrontDrawer.clip, SyncDrawer.clip
  if front then
    front:SetScale(frontScale / scale)
    front:ClearAllPoints()
    -- Centred on the window's right edge, like its handle, at every scale.
    front:SetPoint("LEFT", frame, "RIGHT", 0, 0)
  end
  if sync then
    sync:SetScale(syncScale / scale)
    sync:ClearAllPoints()
    sync:SetPoint("TOP", frame, "BOTTOM", 0, 3 * scale / syncScale)
  end
  if self.frontToggle then self.frontToggle:SetScale(Window.HANDLE_SCALE * factor / scale) end
  if self.syncToggle then self.syncToggle:SetScale(Window.HANDLE_SCALE * factor / scale) end
end

-- Only while open or opening: a closed drawer costs nothing.
function Window:RefreshSyncDrawer(now)
  if SyncDrawer.target > 0 or SyncDrawer.position > 0 then SyncDrawer:Update(now) end
end

function Window:RefreshFrontDrawer(now)
  if not FrontDrawer.frame or (FrontDrawer.position == 0 and FrontDrawer.target == 0) then return end
  local preview = FrontDrawer.preview
  local front = preview and preview.front or WF.Front
  local capture = preview and preview.capture or WF.Capture
  if not front or not capture or not front:HasRoutes() then return end
  local route = front.byId[FrontDrawer.routeId] or front.routes[1]
  if not route then return end
  FrontDrawer.routeId = route.id
  for index = 1, #FrontDrawer.tabs do
    local button = FrontDrawer.tabs[index]
    Skin():SetButton(button, DRAWER_ROUTES[index].label, front.byId[button.routeId] ~= nil, button.routeId == route.id)
  end

  local rear, forward = front:Pair(route, now)
  SetFrontAreas(FrontDrawer, capture, rear, forward)
  local faction = preview and preview.faction or MyFaction()
  local players = preview and preview.players
  if players == nil then
    players = faction and capture:CountFront(FrontDrawer.areaIds, faction, now, FrontDrawer.presenceSeen) or 0
  end
  FitText(FrontDrawer.playersCount, tostring(players), GOAL_PLAYERS_WIDTH)
  FitText(FrontDrawer.playersLabel, players == 1 and "ally" or "allies", GOAL_PLAYERS_WIDTH)

  local rec = (not preview and FrontDrawer.simulated and FrontDrawer.simulated[route.id]) or front:Window(route.id)
  local active = rec and rec.seen and front:Remaining(rec, now) > 0
  local target
  if active then
    target = rec.node
  elseif forward and front:CanBesiege(forward, faction, now) then
    target = forward
  elseif rear and front:CanBesiege(rear, faction, now) then
    target = rear
  end
  local side = active and rec.side or faction
  local area = target and WF.Map and WF.Map.areas[target]
  local owner = target and (capture:SiegeOwner(target, now)) or "N"
  local level, threatId, attackId = SetFrontLines(FrontDrawer, front, capture, route, faction, now)
  local attackArea = attackId and WF.Map and WF.Map.areas[attackId]
  SetFrontBackdrop(FrontDrawer, attackArea and attackArea.mapKey)
  local siegeTitle = active and "Siege in progress" or "Your objective"
  if FrontDrawer.siegeTitleText ~= siegeTitle then
    FrontDrawer.siegeTitleText = siegeTitle
    Skin():SetGoldTitle(FrontDrawer.siegeTitle, siegeTitle)
  end
  local left = active and front:Remaining(rec, now) or 0
  local ringed = SetSiegeRing(FrontDrawer, active and area and rec, left)
  SetSiegeLayout(FrontDrawer, ringed)
  if area then
    Window.SetPoiIcon(ringed and FrontDrawer.ring.icon or FrontDrawer.targetIcon, area, owner)
    SetText(FrontDrawer.targetName, AreaName(area))
    SetText(FrontDrawer.targetOwner, active and (FactionText(side) .. " attacking") or FactionText(owner))
  else
    SetText(FrontDrawer.targetName, "No available Settlement")
    SetText(FrontDrawer.targetOwner, Paint("DIM", "Front endpoint"))
  end
  Show(FrontDrawer.targetIcon, area ~= nil and not ringed)
  Show(FrontDrawer.clockIcon, active and not ringed)
  if ringed then SetGoldClock(FrontDrawer, left) end
  SetText(FrontDrawer.clock, active and front.Clock(left) or Paint("DIM", "Not started"))

  -- The medallions replace the "every Outpost held" check; the siege line
  -- repeats the countdown above, so both leave the checklist with them.
  local medallions = SetOutpostRow(FrontDrawer, capture, target, side, now)
  local checkTop, checkSlots = medallions and -(OUTPOST_ROW_BOTTOM + 5) or -68, medallions and 1 or 3
  if FrontDrawer.checkTop ~= checkTop then
    FrontDrawer.checkTop = checkTop
    for index = 1, 3 do
      Place(FrontDrawer.checks[index], FrontDrawer.siege, 8, checkTop - (index - 1) * 23)
    end
  end
  local checklist = target and side and capture:SiegeChecklist(target, side, now) or nil
  local shown = 0
  if checklist then
    for index = 1, #checklist do
      local check = checklist[index]
      if check.text ~= "On the active front" and not (medallions and (check.key == "outposts" or check.key == "siege"))
          and shown < checkSlots then
        shown = shown + 1
        local row = FrontDrawer.checks[shown]
        SetText(row.text, check.ok and check.text or Paint("BAD", check.text))
        row:Show()
      end
    end
  end
  for index = shown + 1, 3 do FrontDrawer.checks[index]:Hide() end
  -- Fit the panel: last check row, else the towers, else the objective line.
  local bottom = shown > 0 and (-checkTop + (shown - 1) * 23 + 20)
    or (medallions and OUTPOST_ROW_BOTTOM) or 61
  if FrontDrawer.siegeHeight ~= bottom + 7 then
    FrontDrawer.siegeHeight = bottom + 7
    FrontDrawer.siege:SetHeight(bottom + 7)
  end

  -- Garrison only for your defence: the enemy's is unknown (decision 0111).
  local defended = faction and level and level >= 1 and threatId
  local defendedArea = defended and WF.Map and WF.Map.areas[threatId]
  Show(FrontDrawer.garrisonLabel, defended)
  Show(FrontDrawer.garrisonBar, defended)
  Show(FrontDrawer.garrisonValue, defended)
  Show(FrontDrawer.garrisonDetail, defended)
  if defended then
    local used, capacity, outpostUsed, outpostCapacity, outposts = DefenceGarrison(capture, threatId, faction, now)
    Skin():SetBar(FrontDrawer.garrisonBar, capacity > 0 and used / capacity or 0, faction == "A" and "blue" or "red")
    SetText(FrontDrawer.garrisonLabel, "Garrison")
    SetText(FrontDrawer.garrisonValue, used .. " / " .. capacity)
    SetText(FrontDrawer.garrisonDetail, (defendedArea and AreaName(defendedArea) or "")
      .. Paint("DIM", "  -  Outposts " .. outpostUsed .. " / " .. outpostCapacity
        .. " (" .. outposts .. " held)"))
  end
  -- Fit the drawer: objective panel, victory goal strip, then the Garrison rows when shown.
  local bodyHeight = FRONT_SIEGE_TOP + FrontDrawer.siegeHeight + 8 + GOAL_STRIP_HEIGHT
    + (defended and FRONT_GARRISON_H or 0) + FRONT_BODY_PAD
  if FrontDrawer.bodyHeight ~= bodyHeight then
    FrontDrawer.bodyHeight = bodyHeight
    FrontDrawer.body:SetHeight(bodyHeight)
    FrontDrawer.frame:SetHeight(bodyHeight + 28)
    FrontDrawer.scroll:SetHeight(bodyHeight + 28)
    FrontDrawer.clip:SetHeight(bodyHeight + 28)
  end
  SetGoalText(FrontDrawer.outcome, FrontDrawer.outcomeHover,
    (preview and preview.goal)
      or (target and Outcome(front, route, target, side, now) or "The route has reached its endpoint"))
end

