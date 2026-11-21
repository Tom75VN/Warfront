local WF = Warfront
local Map = WF.Map

-- World map tooltips, hover detection, hover probes and the map driver tick
-- (modules/map.lua loads first and shares its helpers through Map.Kit; the
-- route helpers come from modules/map_routes.lua). Keep every map file far
-- below Lua 5.1's limit of 200 active locals (.claude/forever-compatibility.md).
local Kit = Map.Kit
local CanonicalMapName = Kit.CanonicalMapName
local Contours = Kit.Contours
local CreatePatch = Kit.CreatePatch
local FOREVER_ZONE_IDS = Kit.FOREVER_ZONE_IDS
local GetCanvas = Kit.GetCanvas
local GetCanvasSize = Kit.GetCanvasSize
local GetGlobal = Kit.GetGlobal
local GetIconPosition = Kit.GetIconPosition
local HOVER_ALPHA = Kit.HOVER_ALPHA
local HOVER_INTERVAL = Kit.HOVER_INTERVAL
local HideHoverPatches = Kit.HideHoverPatches
local HideObject = Kit.HideObject
local ICON_HIT_RATIO = Kit.ICON_HIT_RATIO
local IconSize = Kit.IconSize
local MouseFocusGetter = Kit.MouseFocusGetter
local PROFILE_TEXTURE = Kit.PROFILE_TEXTURE
local PlacePatch = Kit.PlacePatch
local ProjectAreaPoint = Kit.ProjectAreaPoint
local REFRESH_INTERVAL = Kit.REFRESH_INTERVAL
local StitchedZoneVisible = Kit.StitchedZoneVisible
local TransformMapPoint = Kit.TransformMapPoint
local RefreshRouteDots = Kit.RefreshRouteDots
local mathFloor, mathAbs, mathMax = math.floor, math.abs, math.max
local strFormat = string.format

local OWNER_CODES = { HORDE = "H", ALLIANCE = "A" }
local FACTION_LABELS = {
  H = { "Horde", 0.90, 0.25, 0.20 },
  A = { "Alliance", 0.25, 0.55, 1.00 },
  N = { "Neutral", 0.70, 0.70, 0.70 },
}

local function CursorOnCanvas(canvas, width, height)
  local getCursor = GetGlobal("GetCursorPosition")
  if type(getCursor) ~= "function" or type(canvas.GetEffectiveScale) ~= "function"
      or type(canvas.GetLeft) ~= "function" or type(canvas.GetTop) ~= "function" then
    return nil
  end
  local ok, cursorX, cursorY, scale, left, top = pcall(function()
    local x, y = getCursor()
    return x, y, canvas:GetEffectiveScale(), canvas:GetLeft(), canvas:GetTop()
  end)
  if not ok or type(cursorX) ~= "number" or type(cursorY) ~= "number"
      or type(scale) ~= "number" or scale <= 0
      or type(left) ~= "number" or type(top) ~= "number" then
    return nil
  end
  local x = ((cursorX / scale) - left) / width * 100
  local y = (top - (cursorY / scale)) / height * 100
  if x < 0 or x > 100 or y < 0 or y > 100 then return nil end
  return x, y
end

local function ShowHoverPatches(entry, area, width, height, stitchedAPI, hostID)
  if not entry.records then return end
  entry.hoverTextures = entry.hoverTextures or {}
  local total = #entry.records
  local index = 1
  while index <= total do
    if not entry.hoverTextures[index] then entry.hoverTextures[index] = CreatePatch(entry) end
    if not PlacePatch(entry, entry.hoverTextures[index], entry.records[index],
        width, height, area.color, HOVER_ALPHA, area, stitchedAPI, hostID) then
      HideObject(entry.hoverTextures[index])
    end
    index = index + 1
  end
  while index <= #entry.hoverTextures do
    HideObject(entry.hoverTextures[index])
    index = index + 1
  end
end

local function FormatDuration(seconds)
  seconds = math.ceil(seconds)
  if seconds < 60 then return seconds .. "s" end
  return strFormat("%dm %02ds", mathFloor(seconds / 60), (seconds % 60))
end

local function AddFactionLine(tooltip, left, code, suffix)
  local label = FACTION_LABELS[code] or FACTION_LABELS.N
  tooltip:AddDoubleLine(left, label[1] .. (suffix or ""), 0.8, 0.8, 0.8,
    label[2], label[3], label[4])
end

-- Forever's world map is a UIParent window (Blizzard_WorldMap.xml) with no
-- WorldMapTooltip, so GameTooltip stays visible over it.
local function MapTooltip()
  local tooltip = GetGlobal("GameTooltip")
  if tooltip and type(tooltip.SetOwner) == "function" then return tooltip, "GameTooltip" end
  return nil, "none"
end

local function LocalizeTooltip(tooltip)
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

-- Route tooltip: offset from the cursor and font size reduction. Declared before
-- the functions below, which would otherwise read them as nil globals.
local ROUTE_TOOLTIP_OFFSET = 15
local ROUTE_TOOLTIP_FONT_DELTA = 3

-- The route tooltip uses smaller fonts on the shared map tooltip; every other tooltip
-- gets the original fonts back first.
local function HideTooltipIcons(tooltip)
  local pool = tooltip.WarfrontIcons
  if not pool then return end
  local index = 1
  while index <= #pool do
    pool[index].icon:Hide()
    pool[index].count:Hide()
    index = index + 1
  end
end

local function RestoreTooltipFonts(tooltip)
  HideTooltipIcons(tooltip)
  local saved = tooltip.WarfrontFonts
  if not saved then return end
  tooltip.WarfrontFonts = nil
  for index = 1, #saved do
    local entry = saved[index]
    pcall(entry[1].SetFont, entry[1], entry[2], entry[3], entry[4])
  end
end

-- Shrinks every line by ROUTE_TOOLTIP_FONT_DELTA; the caller shows the tooltip
-- afterwards so its size and background are computed with the new fonts.
local function ShrinkTooltipFonts(tooltip)
  local name = tooltip:GetName()
  if not name then return end
  local saved = {}
  local lines = tooltip:NumLines()
  local index = 1
  while index <= lines do
    local side = 1
    while side <= 2 do
      local text = GetGlobal(name .. (side == 1 and "TextLeft" or "TextRight") .. index)
      if text and type(text.GetFont) == "function" then
        local path, size, flags = text:GetFont()
        if path and type(size) == "number" then
          saved[#saved + 1] = { text, path, size, flags }
          text:SetFont(path, size - ROUTE_TOOLTIP_FONT_DELTA, flags)
        end
      end
      side = side + 1
    end
    index = index + 1
  end
  tooltip.WarfrontFonts = saved
end

-- The shared tooltip keeps the changed fonts and icons of an area tooltip until the
-- next map tooltip: put them back when it hides, so no other tooltip inherits them.
local function HookTooltipHide(tooltip)
  if tooltip.WarfrontHideHook or type(tooltip.GetScript) ~= "function" then return end
  tooltip.WarfrontHideHook = true
  local previous = tooltip:GetScript("OnHide")
  tooltip:SetScript("OnHide", function(self, ...)
    RestoreTooltipFonts(self)
    if previous then previous(self, ...) end
  end)
end

-- Area tooltip rows: 1.12 has no inline pictures, so a tall blank line reserves the
-- room of a row of unit icons and DrawTooltipRows lays them over it after Show.
local TOOLTIP_ICON_SIZE = 24
local TOOLTIP_ICON_GAP = 8
local TOOLTIP_HINT_SIZE_DELTA = 2
local TOOLTIP_GAP_FONT_SIZE = 5

-- Changes the font size of one left line; RestoreTooltipFonts puts it back.
local function RestyleLine(tooltip, index, size, shrink)
  local name = tooltip:GetName()
  local text = name and GetGlobal(name .. "TextLeft" .. index)
  if not text or type(text.GetFont) ~= "function" then return end
  local path, current, flags = text:GetFont()
  if not path or type(current) ~= "number" then return end
  tooltip.WarfrontFonts = tooltip.WarfrontFonts or {}
  tooltip.WarfrontFonts[#tooltip.WarfrontFonts + 1] = { text, path, current, flags }
  text:SetFont(path, size or (current - shrink), flags)
end

-- Reserves a line for `units` ({ key, count, faded }) and queues it for drawing.
local function AddUnitRow(tooltip, rows, units, faction)
  if #units == 0 then return end
  tooltip:AddLine(" ")
  local line = tooltip:NumLines()
  RestyleLine(tooltip, line, TOOLTIP_ICON_SIZE)
  rows[#rows + 1] = { line = line, units = units, faction = faction }
end

local function DrawTooltipRows(tooltip, rows)
  local window = WF.MainWindow
  local name = tooltip:GetName()
  if not name or not window or not window.UnitIcon then return end
  tooltip.WarfrontIcons = tooltip.WarfrontIcons or {}
  local pool = tooltip.WarfrontIcons
  local used = 0
  local widest = 0
  for rowIndex = 1, #rows do
    local row = rows[rowIndex]
    local line = GetGlobal(name .. "TextLeft" .. row.line)
    local unitIndex = 1
    while line and unitIndex <= #row.units do
      local unit = row.units[unitIndex]
      used = used + 1
      local slot = pool[used]
      if not slot then
        slot = {
          icon = tooltip:CreateTexture(nil, "ARTWORK"),
          count = tooltip:CreateFontString(nil, "OVERLAY", "NumberFontNormal"),
        }
        slot.icon:SetWidth(TOOLTIP_ICON_SIZE)
        slot.icon:SetHeight(TOOLTIP_ICON_SIZE)
        pool[used] = slot
      end
      local x = (unitIndex - 1) * (TOOLTIP_ICON_SIZE + TOOLTIP_ICON_GAP)
      window.UnitIcon(slot.icon, unit.key, row.faction)
      slot.icon:SetAlpha(unit.faded and 0.4 or 1)
      slot.icon:ClearAllPoints()
      slot.icon:SetPoint("LEFT", line, "LEFT", x, 0)
      slot.icon:Show()
      slot.count:SetText(tostring(unit.count))
      slot.count:ClearAllPoints()
      slot.count:SetPoint("BOTTOMRIGHT", slot.icon, "BOTTOMRIGHT", -1, 1)
      slot.count:Show()
      if x + TOOLTIP_ICON_SIZE > widest then widest = x + TOOLTIP_ICON_SIZE end
      unitIndex = unitIndex + 1
    end
  end
  -- Tooltip text insets are 10 px on each side.
  if widest > 0 and tooltip:GetWidth() < widest + 20 then tooltip:SetWidth(widest + 20) end
end

local function ShowAreaTooltip(canvas, area)
  local tooltip = MapTooltip()
  if not tooltip then return nil end
  RestoreTooltipFonts(tooltip)
  HookTooltipHide(tooltip)
  local typeName = Map.TYPE_NAMES[area.type] or area.type
  local info = WF.Capture and WF.Capture.TooltipInfo and WF.Capture:TooltipInfo(area.id)
  local rows = {}
  local ok = pcall(function()
    tooltip:SetOwner(canvas, "ANCHOR_CURSOR")
    tooltip:ClearLines()
    -- A held Settlement's level owns the title's top-right. A locked siege
    -- moves to the type line when both need to be shown; its reason stays below.
    local _, _, lockReason = string.find((info and info.detail) or "", "^Siege locked: (.*)$")
    local level = Map.SettlementLevel and Map.SettlementLevel(area)
    local levelText = level and (WF.L and WF.L("Level %d", level) or ("Level " .. level))
    if levelText then
      tooltip:AddDoubleLine(area.label or typeName, levelText, 1, 0.82, 0, 1, 0.82, 0)
    elseif lockReason then
      tooltip:AddDoubleLine(area.label or typeName, "Siege locked", 1, 0.82, 0, 1, 0.35, 0.3)
    else
      tooltip:AddLine(area.label or typeName, 1, 0.82, 0)
    end
    if area.label then
      if levelText and lockReason then
        tooltip:AddDoubleLine(typeName, "Siege locked", 1, 1, 1, 1, 0.35, 0.3)
      else
        tooltip:AddLine(typeName, 1, 1, 1)
      end
    elseif levelText and lockReason then
      tooltip:AddLine("Siege locked", 1, 0.35, 0.3)
    end
    -- Capturable areas follow the owner registry; others keep their drawn color.
    if not Map.RESOURCE_TYPES[area.type] then
      AddFactionLine(tooltip, "Confirmed owner", info and info.owner or OWNER_CODES[area.colorKey or ""] or "N")
    end
    if info and info.hint then
      AddFactionLine(tooltip, "Unconfirmed owner", info.hint.owner, " (" .. info.hint.count .. " player(s), "
        .. FormatDuration(info.hint.age) .. " ago)")
      -- Decision 0046: an optional recommendation, never a requirement.
      if not info.cloud and WF.Companion and WF.Companion.ShownHint and WF.Companion:ShownHint() then
        tooltip:AddLine("Optional: the Warfront Companion adds the cloud's last known owner.", 0.6, 0.6, 0.6, 1)
      end
    end
    -- Cloud owner (decision 0060): shown only, never an owner for gameplay.
    if info and info.cloud and WF.Capture then
      local label, code, detail = WF.Capture.CloudLine(info.cloud)
      if code then
        AddFactionLine(tooltip, label, code, detail and (" (" .. detail .. ")") or nil)
      else
        tooltip:AddDoubleLine(label, detail, 0.8, 0.8, 0.8, 0.8, 0.8, 0.8)
      end
    end
    if info and info.challenger then
      AddFactionLine(tooltip, "Capture", info.challenger, " " .. info.percent .. "%")
    end
    if info and info.status then
      local status = info.status
      if info.remaining then status = status .. " (" .. FormatDuration(info.remaining) .. ")" end
      tooltip:AddLine(status, 1, 1, 1)
    end
    -- Outpost capture time or Settlement siege prerequisites (decision 0053).
    if lockReason then
      tooltip:AddLine(lockReason, 0.8, 0.8, 0.8)
    elseif info and info.detail then
      tooltip:AddLine(info.detail, 0.8, 0.8, 0.8)
    end
    if info and (info.nH or 0) + (info.nA or 0) > 0 then
      tooltip:AddDoubleLine("Players inside", "|cffe64033" .. info.nH .. " Horde|r  |cff408cff"
        .. info.nA .. " Alliance|r", 0.8, 0.8, 0.8, 1, 1, 1)
    end
    if info and info.here then tooltip:AddLine("You are here", 0.3, 1, 0.3) end
    -- Resource POIs: their shared stock, never an owner (decision 0048).
    local stock = WF.Stock and WF.Stock.TooltipInfo and WF.Stock:TooltipInfo(area.id)
    if stock then
      tooltip:AddDoubleLine(stock.name .. " stock", stock.level .. " / " .. stock.capacity, 0.8, 0.8, 0.8, 1, 1, 1)
      tooltip:AddLine(stock.status, 1, 1, 1)
      if stock.here then tooltip:AddLine("You are here", 0.3, 1, 0.3) end
    end
    -- Scouting (decision 0050): the enemy sees a scout coming, never its sender.
    local preview = Map.simulatedScoutTooltip
    local scout = preview and preview.id == area.id and preview.info
      or WF.Scout and WF.Scout.TooltipInfo and WF.Scout:TooltipInfo(area.id)
    if scout then
      if scout.discovered then
        tooltip:AddDoubleLine("Discovered", FormatDuration(scout.discovered) .. " left", 0.8, 0.8, 0.8, 0.3, 1, 0.3)
        local view = scout.garrison
        local units = {}
        for index = 1, #WF.Garrison.UNIT_ORDER do
          local key = WF.Garrison.UNIT_ORDER[index]
          units[#units + 1] = { key = key, count = view and view[key] or "?", faded = not view or view[key] == 0 }
        end
        tooltip:AddDoubleLine("Garrison", view and ("seen " .. FormatDuration(scout.seen) .. " ago") or "unknown",
          0.8, 0.8, 0.8, 0.8, 0.8, 0.8)
        local side = view and (view.owner == "H" or view.owner == "A") and view.owner
          or WF.Capture and WF.Capture:MyFaction()
        AddUnitRow(tooltip, rows, units, side)
      end
      if scout.allied then
        tooltip:AddDoubleLine("Allied scout", "arrives in " .. FormatDuration(scout.allied), 0.8, 0.8, 0.8, 1, 1, 1)
      end
      if scout.enemy then
        tooltip:AddDoubleLine("Enemy scout", "arrives in " .. FormatDuration(scout.enemy), 0.8, 0.8, 0.8, 1, 0.4, 0.4)
      end
      if scout.exposed then
        tooltip:AddDoubleLine("Scouted by the enemy", FormatDuration(scout.exposed) .. " left", 0.8, 0.8, 0.8, 1, 0.4, 0.4)
      end
    end
    -- Armies (decision 0052): the exact composition only for one's own faction.
    local attack = WF.Attack and WF.Attack.TooltipInfo and WF.Attack:TooltipInfo(area.id)
    if attack then
      if attack.allied then
        tooltip:AddDoubleLine("Allied army", "arrives in " .. FormatDuration(attack.allied.left), 0.8, 0.8, 0.8, 1, 1, 1)
        local units = {}
        for index = 1, #WF.Attack.UNIT_ORDER do
          local key = WF.Attack.UNIT_ORDER[index]
          local count = attack.allied.counts[key]
          if count > 0 then units[#units + 1] = { key = key, count = count } end
        end
        AddUnitRow(tooltip, rows, units, WF.Capture and WF.Capture:MyFaction())
      end
      if attack.enemy then
        tooltip:AddDoubleLine("Enemy army", "arrives in " .. FormatDuration(attack.enemy), 0.8, 0.8, 0.8, 1, 0.4, 0.4)
      end
      if attack.pending then tooltip:AddLine("Battle waiting to be resolved", 1, 0.8, 0.3) end
      if attack.locked then
        tooltip:AddDoubleLine("Reinforcements locked", FormatDuration(attack.locked) .. " left", 0.8, 0.8, 0.8, 1, 0.8, 0.3)
      end
    end
    local hint = Map.TYPE_HINTS[area.type]
    -- The hint is the quietest line: a gap above it, smaller and dimmer than the rest.
    if hint then
      tooltip:AddLine(" ")
      RestyleLine(tooltip, tooltip:NumLines(), TOOLTIP_GAP_FONT_SIZE)
      tooltip:AddLine(hint, 0.6, 0.6, 0.6, 1)
      RestyleLine(tooltip, tooltip:NumLines(), nil, TOOLTIP_HINT_SIZE_DELTA)
    end
    LocalizeTooltip(tooltip)
    tooltip:Show()
    DrawTooltipRows(tooltip, rows)
  end)
  return ok and tooltip or nil
end

-- Developer-only (WarfrontDev /wfd tooltip troops): replaces one area's
-- scouting tooltip data until cleared or reloaded. Never saved nor sent.
function Map:SetSimulatedScoutTooltip(id, info)
  if type(id) == "string" and type(info) == "table" then
    self.simulatedScoutTooltip = { id = id, info = info }
  else
    self.simulatedScoutTooltip = nil
  end
  if self.ClearHover then self:ClearHover() end
  if self.WakeDriver then self:WakeDriver() end
end

-- Tooltip of a scout or army icon: route and time left for everyone; the sender and
-- the composition only when the order belongs to the player's faction.
local function ShowRouteTooltip(canvas, slot)
  local tooltip = MapTooltip()
  if not tooltip then return nil end
  local module = slot.kind == "army" and WF.Attack or WF.Scout
  local now = WF.Now and WF.Now()
  if not module or type(module.RouteInfo) ~= "function" or type(now) ~= "number" then return nil end
  local info = module:RouteInfo(slot.record, now)
  if not info then return nil end
  RestoreTooltipFonts(tooltip)
  local ok, tooltipError = pcall(function()
    -- ANCHOR_CURSOR ignores offsets on this client: anchor by hand, up and right of the cursor.
    tooltip:SetOwner(canvas, "ANCHOR_NONE")
    local getCursor = GetGlobal("GetCursorPosition")
    local parent = GetGlobal("UIParent")
    local cx, cy = nil, nil
    if type(getCursor) == "function" then cx, cy = getCursor() end
    local scale = tooltip:GetEffectiveScale()
    tooltip:ClearAllPoints()
    if cx and cy and parent and scale and scale > 0 then
      tooltip:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", cx / scale + ROUTE_TOOLTIP_OFFSET, cy / scale + ROUTE_TOOLTIP_OFFSET)
    else
      tooltip:SetPoint("BOTTOMLEFT", canvas, "CENTER", ROUTE_TOOLTIP_OFFSET, ROUTE_TOOLTIP_OFFSET)
    end
    tooltip:ClearLines()
    local name = slot.kind == "army" and "army" or "scout"
    if info.allied then
      tooltip:AddLine("Allied " .. name, 0.3, 1, 0.3)
    else
      tooltip:AddLine("Enemy " .. name, 1, 0.4, 0.4)
    end
    if info.owner then tooltip:AddDoubleLine("Sent by", info.owner, 0.8, 0.8, 0.8, 1, 1, 1) end
    tooltip:AddDoubleLine("From", info.from, 0.8, 0.8, 0.8, 1, 1, 1)
    tooltip:AddDoubleLine("To", info.to, 0.8, 0.8, 0.8, 1, 1, 1)
    tooltip:AddDoubleLine("Arrives in", FormatDuration(mathMax(info.left, 0)), 0.8, 0.8, 0.8, 1, 1, 1)
    if info.army then tooltip:AddLine(info.army, 1, 1, 1) end
    ShrinkTooltipFonts(tooltip)
  LocalizeTooltip(tooltip)
  tooltip:Show()
  end)
  if not ok and WF.RecordError then WF.RecordError("map route tooltip", tooltipError) end
  return ok and tooltip or nil
end

-- Zone names for the campaign tooltips (user, 2026-11-14): a front is named
-- by its zone, not by its Settlement. Keyed by the catalog's map file.
local ZONE_NAMES = {
  Arathi = "Arathi Highlands", Ashenvale = "Ashenvale", Barrens = "The Barrens",
  Durotar = "Durotar", Duskwood = "Duskwood", Dustwallow = "Dustwallow Marsh",
  Elwynn = "Elwynn Forest", Hilsbrad = "Hillsbrad Foothills", Mulgore = "Mulgore",
  Orgrimmar = "Orgrimmar", Redridge = "Redridge Mountains",
  StonetalonMountains = "Stonetalon Mountains", StormwindCity = "Stormwind City",
  Stranglethorn = "Stranglethorn Vale", Tanaris = "Tanaris", Westfall = "Westfall",
}

local function FrontZoneName(area)
  return ZONE_NAMES[area.map] or area.map or area.label or area.id
end
-- Shared with the War Balance banner and the front card (main_window_*).
Map.FrontZoneName = FrontZoneName

function Map:ShowCampaignFrontTooltip(canvas, record)
  local tooltip = MapTooltip()
  if not tooltip or not record or not record.area then return nil end
  RestoreTooltipFonts(tooltip)
  local ok, tooltipError = pcall(function()
    tooltip:SetOwner(canvas, "ANCHOR_NONE")
    local getCursor = GetGlobal("GetCursorPosition")
    local parent = GetGlobal("UIParent")
    local cx, cy = nil, nil
    if type(getCursor) == "function" then cx, cy = getCursor() end
    local scale = tooltip:GetEffectiveScale()
    tooltip:ClearAllPoints()
    if cx and cy and parent and scale and scale > 0 then
      tooltip:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", cx / scale + ROUTE_TOOLTIP_OFFSET,
        cy / scale + ROUTE_TOOLTIP_OFFSET)
    else
      tooltip:SetPoint("BOTTOMLEFT", canvas, "CENTER", ROUTE_TOOLTIP_OFFSET, ROUTE_TOOLTIP_OFFSET)
    end
    tooltip:ClearLines()
    tooltip:AddLine(FrontZoneName(record.area), 1, 0.82, 0)
    if record.state == "active" then
      tooltip:AddLine("Active Front", 1, 0.82, 0)
    elseif record.state == "H" then
      tooltip:AddLine("Controlled by the Horde", 0.90, 0.25, 0.20)
    elseif record.state == "A" then
      tooltip:AddLine("Controlled by the Alliance", 0.25, 0.55, 1.00)
    else
      tooltip:AddLine("This front is locked.", 0.72, 0.72, 0.72)
      local front = WF.Front
      local capture = WF.Capture
      local playerSide = capture and type(capture.MyFaction) == "function" and capture:MyFaction()
      local targetIndex = playerSide == record.route.advancing and record.forward or record.rear
      local targetNode = record.route.nodes[targetIndex or 0]
      local target = targetNode and Map.areas[targetNode.id]
      if record.capital and playerSide and playerSide ~= record.route.advancing then target = nil end
      if target and target.id ~= record.id then
        tooltip:AddLine("Capture " .. FrontZoneName(target) .. " first.", 1, 1, 1)
      end
    end
    -- Decision 0111: contested, paused and threat lines.
    local front, capture = WF.Front, WF.Capture
    local mySide = capture and type(capture.MyFaction) == "function" and capture:MyFaction()
    if record.state == "active" and not record.capital and record.forward == record.index
        and record.rear == record.index then
      tooltip:AddLine("Contested by both factions", 1, 0.82, 0)
    end
    if record.state == "active" and mySide and front and type(front.Paused) == "function"
        and front:Paused(record.route, mySide) then
      tooltip:AddLine("Paused during the enemy siege", 0.72, 0.72, 0.72)
    end
    local enemy = mySide == "A" and "Horde" or "Alliance"
    if record.siege and front then
      -- Any running siege, the player's own attack included.
      local attacker = record.siege.side == "A" and "Alliance" or "Horde"
      local theirs = mySide and record.siege.side ~= mySide
      tooltip:AddLine("Siege in progress: " .. attacker .. " attacking, "
        .. front.Clock(front:Remaining(record.siege)) .. " left",
        theirs and 0.95 or 1, theirs and 0.25 or 0.82, theirs and 0.20 or 0)
    elseif record.threat == 3 then
      local rec = front and front:Window(record.route.id)
      local left = rec and front:Remaining(rec) or 0
      tooltip:AddLine("Under siege by the " .. enemy .. ": " .. front.Clock(left) .. " left", 0.95, 0.25, 0.20)
    elseif record.threat == 2 then
      tooltip:AddLine("Under attack: " .. (record.lost or 0) .. "/" .. (record.links or 0)
        .. " Outposts lost", 1, 0.50, 0.08)
    elseif record.threat == 1 then
      tooltip:AddLine("Targeted by the " .. enemy, 1, 0.82, 0)
    end
    ShrinkTooltipFonts(tooltip)
  LocalizeTooltip(tooltip)
  tooltip:Show()
  end)
  if not ok and WF.RecordError then WF.RecordError("campaign route tooltip", tooltipError) end
  return ok and tooltip or nil
end

-- Chevron hover: which faction advances toward which front.
function Map:ShowCampaignChevronTooltip(canvas, hit)
  local tooltip = MapTooltip()
  if not tooltip or not hit then return nil end
  RestoreTooltipFonts(tooltip)
  local ok, tooltipError = pcall(function()
    tooltip:SetOwner(canvas, "ANCHOR_NONE")
    local getCursor = GetGlobal("GetCursorPosition")
    local parent = GetGlobal("UIParent")
    local cx, cy = nil, nil
    if type(getCursor) == "function" then cx, cy = getCursor() end
    local scale = tooltip:GetEffectiveScale()
    tooltip:ClearAllPoints()
    if cx and cy and parent and scale and scale > 0 then
      tooltip:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", cx / scale + ROUTE_TOOLTIP_OFFSET,
        cy / scale + ROUTE_TOOLTIP_OFFSET)
    else
      tooltip:SetPoint("BOTTOMLEFT", canvas, "CENTER", ROUTE_TOOLTIP_OFFSET, ROUTE_TOOLTIP_OFFSET)
    end
    tooltip:ClearLines()
    local target = hit.target
    if target then tooltip:AddLine(FrontZoneName(target), 1, 0.82, 0) end
    local side = hit.side == "H" and "The Horde" or "The Alliance"
    tooltip:AddLine(side .. " advances toward this front.", 1, 1, 1)
    ShrinkTooltipFonts(tooltip)
  LocalizeTooltip(tooltip)
  tooltip:Show()
  end)
  if not ok and WF.RecordError then WF.RecordError("campaign chevron tooltip", tooltipError) end
  return ok and tooltip or nil
end

-- The route slot whose icon is under the cursor (x, y in percent of the canvas).
-- Half-size, in canvas pixels, of the hover square of a scout or army icon: wider
-- than the 20 px icon because it moves. The icon already hovered keeps its tooltip
-- a little further out, so the tooltip does not flicker at the edge.
local ROUTE_HIT_HALF = 15
local ROUTE_KEEP_HALF = 22

function Map:FindRouteAt(x, y, width, height)
  local routes = self.routes
  local best, bestDistance = nil, nil
  local index = 1
  while index <= routes.count do
    local slot = routes.slots[index]
    if slot and slot.iconShown and slot.record and slot.iconX then
      local dx = mathAbs(x / 100 - slot.iconX) * width
      local dy = mathAbs(y / 100 - slot.iconY) * height
      local held = slot.record == self.hoverRoute
      if held and dx <= ROUTE_KEEP_HALF and dy <= ROUTE_KEEP_HALF then return slot end
      if dx <= ROUTE_HIT_HALF and dy <= ROUTE_HIT_HALF then
        -- Overlapping icons: the one nearest the cursor wins.
        local distance = dx * dx + dy * dy
        if not bestDistance or distance < bestDistance then best, bestDistance = slot, distance end
      end
    end
    index = index + 1
  end
  return best
end

function Map:FindCampaignFrontAt(x, y, width, height)
  local routes = self.campaignRoutes
  local best, bestDistance = nil, nil
  for index = 1, routes.nodeCount do
    local record = routes.records[index]
    if record then
      local dx = mathAbs(x / 100 - record.x) * width
      local dy = mathAbs(y / 100 - record.y) * height
      local held = record == self.hoverCampaignFront
      if held and dx <= 24 and dy <= 24 then return record end
      if dx <= 20 and dy <= 20 then
        local distance = dx * dx + dy * dy
        if not bestDistance or distance < bestDistance then best, bestDistance = record, distance end
      end
    end
  end
  return best
end

-- Campaign chevron under the cursor (x, y in canvas percent); the held one keeps
-- a slightly larger reach so the tooltip does not flicker on its edge.
function Map:FindCampaignChevronAt(x, y, width, height)
  local hits = self.campaignRoutes.chevronHits
  local held = self.hoverCampaignChevron
  local best, bestDistance = nil, nil
  for index = 1, #hits do
    local hit = hits[index]
    local dx = mathAbs(x / 100 * width - hit.x)
    local dy = mathAbs(y / 100 * height - hit.y)
    if held and hit.key == held.key and dx <= 11 and dy <= 11 then return hit end
    if dx <= 9 and dy <= 9 then
      local distance = dx * dx + dy * dy
      if not bestDistance or distance < bestDistance then best, bestDistance = hit, distance end
    end
  end
  return best
end

-- War Camp icon under the cursor on a continent or world map (x, y in canvas
-- percent); the held one keeps a slightly larger reach.
function Map:FindWarCampAt(x, y, width, height)
  local camps = self.warCamps
  local best, bestDistance = nil, nil
  for index = 1, camps.count do
    local record = camps.records[index]
    if record then
      local dx = mathAbs(x / 100 - record.x) * width
      local dy = mathAbs(y / 100 - record.y) * height
      local reach = record.id == self.hoverCamp and 10 or 7
      if dx <= reach and dy <= reach then
        local distance = dx * dx + dy * dy
        if not bestDistance or distance < bestDistance then best, bestDistance = record, distance end
      end
    end
  end
  return best
end

function Map:ClearHover()
  self.hoverCamp = nil
  self.hoverCampaignChevron = nil
  local id = self.hoverId
  self.hoverId = nil
  local hadRoute = self.hoverRoute
  self.hoverRoute = nil
  self.routeSecond = nil
  if hadRoute then RefreshRouteDots() end
  local hadCampaignFront = self.hoverCampaignFront
  self.hoverCampaignFront = nil
  if hadCampaignFront then self:RefreshCampaignNodes() end
  self.cursorX = nil
  self.cursorY = nil
  local entry = id and self.groups[id]
  if entry then
    HideHoverPatches(entry)
    self:ApplyLabelVisibility(entry)
  end
  local tooltip = self.tooltipShown
  if tooltip then
    self.tooltipShown = nil
    if type(tooltip.Hide) == "function" then pcall(tooltip.Hide, tooltip) end
    RestoreTooltipFonts(tooltip)
  end
end

local function AreaMatchesView(self, area, mapKey)
  if self.stitchedAPI then return StitchedZoneVisible(self.stitchedMask, area.mapKey) end
  return area.mapKey == mapKey
end

local function AreaContainsCanvasPoint(self, area, x, y)
  if not self.stitchedAPI then return Contours.AreaContainsPoint(area, x, y) end
  local sourceID = FOREVER_ZONE_IDS[area.mapKey]
  local sourceX, sourceY = TransformMapPoint(
    self.stitchedAPI, self.stitchedHostID, sourceID, x / 100, y / 100)
  if not sourceX or not sourceY then return false end
  return Contours.AreaContainsPoint(area, sourceX * 100, sourceY * 100)
end

function Map:FindAreaAt(x, y, width, height)
  local mapKey = CanonicalMapName(self.currentMap)
  local index
  -- Icons draw above every area and may overhang their own zone (the bounding-box
  -- middle can fall outside a concave one), so the cursor on an icon picks it first.
  if width and height then
    index = #self.order
    while index >= 1 do
      local id = self.order[index]
      local area = self.areas[id]
      local entry = self.groups[id]
      if area and entry and entry.active and entry.iconShown
          and AreaMatchesView(self, area, mapKey) then
        local reach = IconSize(area.type) * self.iconZoom * ICON_HIT_RATIO
        local reachX = reach / width * 100
        local reachY = reach / height * 100
        local iconX, iconY = GetIconPosition(area)
        iconX, iconY = ProjectAreaPoint(
          self.stitchedAPI, self.stitchedHostID, area, iconX, iconY)
        if iconX and mathAbs(x - iconX * 100) <= reachX
            and mathAbs(y - iconY * 100) <= reachY then
          return id
        end
      end
      index = index - 1
    end
  end
  index = #self.order
  -- Later areas draw above earlier ones, so test them first.
  while index >= 1 do
    local id = self.order[index]
    local area = self.areas[id]
    local entry = self.groups[id]
    if area and entry and entry.active and entry.records
        and AreaMatchesView(self, area, mapKey)
        and AreaContainsCanvasPoint(self, area, x, y) then
      return id
    end
    index = index - 1
  end
  return nil
end

-- True when the mouse is over the map itself: the canvas, or a frame that holds it
-- (WorldMapDetailFrame, WorldMapFrame). WorldFrame (the 3D world, reported over
-- parts of the open map) and Blizzard's landmark buttons (WorldMapFramePOI<n>,
-- 32x32, they only rename the area label) count as the map: measured on OctoWoW,
-- they swallowed most of the hover over EFST01, EFGM04 and EFFA09. Unit dots
-- (WorldMapPlayer, party, raid) share WorldMapTooltip and still block the hover,
-- as do unrelated frames above the map.
local function MapHasFocus(canvas, focus)
  if focus == canvas then return true end
  if not focus then return false end
  if focus == GetGlobal("WorldFrame") then return true end
  if type(focus.GetName) == "function" then
    local nameOk, name = pcall(focus.GetName, focus)
    if nameOk and type(name) == "string" and string.find(name, "^WorldMapFramePOI%d+$") then
      return true
    end
  end
  local node = canvas
  local depth = 0
  while node and depth < 10 do
    if type(node.GetParent) ~= "function" then return false end
    local ok, parent = pcall(node.GetParent, node)
    if not ok then return false end
    if parent == focus then return true end
    node = parent
    depth = depth + 1
  end
  return false
end

-- Our tooltip may briefly become the top mouse focus. It still belongs to the
-- current map hover; rejecting it would hide the tooltip, shrink the node and
-- immediately hover the node again in an endless pulse.
local function TooltipHasFocus(tooltip, focus)
  if not tooltip or not focus then return false end
  local node = focus
  local depth = 0
  while node and depth < 10 do
    if node == tooltip then return true end
    if type(node.GetParent) ~= "function" then return false end
    local ok, parent = pcall(node.GetParent, node)
    if not ok then return false end
    node = parent
    depth = depth + 1
  end
  return false
end

local function FrameLabel(frame)
  if not frame then return "none" end
  if type(frame.GetName) == "function" then
    local ok, name = pcall(frame.GetName, frame)
    if ok and name then return tostring(name) end
  end
  return "unnamed"
end

-- Taken when a tooltip opens, for /wfd map hover (chat cannot be typed with the map open).
local function TooltipProbe(tooltip)
  local _, name = MapTooltip()
  if not tooltip then return "tooltip=" .. name .. " not shown" end
  local function Ask(frame, method)
    if not frame or type(frame[method]) ~= "function" then return "n/a" end
    local ok, value = pcall(frame[method], frame)
    return ok and tostring(value) or "error"
  end
  local parent = nil
  if type(tooltip.GetParent) == "function" then
    local ok, frame = pcall(tooltip.GetParent, tooltip)
    if ok then parent = frame end
  end
  return "tooltip=" .. name .. " parent=" .. FrameLabel(parent)
    .. " visible=" .. Ask(tooltip, "IsVisible") .. " lines=" .. Ask(tooltip, "NumLines")
    .. " strata=" .. Ask(tooltip, "GetFrameStrata")
    .. " UIParent.visible=" .. Ask(GetGlobal("UIParent"), "IsVisible")
end

function Map:UpdateHover()
  local canvas = GetCanvas()
  local width, height = GetCanvasSize(canvas)
  local canvasShown = true
  if canvas and type(canvas.IsVisible) == "function" then
    local shownOk, shown = pcall(canvas.IsVisible, canvas)
    canvasShown = not shownOk or shown and true or false
  end
  if not width or not canvasShown then
    if self.hoverId or self.hoverRoute or self.hoverCampaignFront or self.hoverCampaignChevron
        or self.hoverCamp then
      self:ClearHover()
    end
    return
  end

  local getFocus = MouseFocusGetter()
  local focus = nil
  local focusOk = false
  if type(getFocus) == "function" then focusOk, focus = pcall(getFocus) end
  local x, y = CursorOnCanvas(canvas, width, height)
  -- This client can report no focused frame over the open map, so only a frame that
  -- is reported and unrelated to the map (a button, a window) blocks the hover.
  local overMap = not focus or MapHasFocus(canvas, focus) or TooltipHasFocus(self.tooltipShown, focus)
  -- Keep the raw sample; Map:HoverDebug builds the text only when asked.
  local sample = self.hoverSample
  if not sample then
    sample = {}
    self.hoverSample = sample
  end
  sample.focus, sample.getFocus, sample.focusOk, sample.overMap = focus, type(getFocus), focusOk, overMap
  sample.x, sample.y, sample.visible, sample.map, sample.hover =
    x, y, self.visibleCount, self.currentMap, self.hoverId

  -- A scout or army icon under the cursor takes the hover before any area.
  local slot = self.enabled and overMap and x and height and self:FindRouteAt(x, y, width, height)
  if slot then
    local second = mathFloor(WF.Now and WF.Now() or 0)
    if self.hoverRoute ~= slot.record then self:ClearHover() end
    if self.hoverRoute ~= slot.record or self.routeSecond ~= second then
      self.hoverRoute, self.routeSecond = slot.record, second
      RefreshRouteDots()
      self.tooltipShown = ShowRouteTooltip(canvas, slot)
    end
    return
  end
  if self.hoverRoute then self:ClearHover() end

  local campaignFront = self.enabled and overMap and x and y
    and self:FindCampaignFrontAt(x, y, width, height)
  if campaignFront then
    if self.hoverCampaignFront ~= campaignFront then
      self:ClearHover()
      self.hoverCampaignFront = campaignFront
      self:RefreshCampaignNodes()
      self.tooltipShown = self:ShowCampaignFrontTooltip(canvas, campaignFront)
      self.tooltipDebug = campaignFront.id .. " campaign-front " .. TooltipProbe(self.tooltipShown)
    end
    return
  end
  if self.hoverCampaignFront then self:ClearHover() end

  local chevron = self.enabled and overMap and x and y
    and self:FindCampaignChevronAt(x, y, width, height)
  if chevron then
    local held = self.hoverCampaignChevron
    if not held or held.key ~= chevron.key then
      self:ClearHover()
      self.tooltipShown = self:ShowCampaignChevronTooltip(canvas, chevron)
      self.tooltipDebug = chevron.key .. " campaign-chevron " .. TooltipProbe(self.tooltipShown)
    end
    self.hoverCampaignChevron = chevron
    return
  end
  if self.hoverCampaignChevron then self:ClearHover() end

  local camp = self.enabled and overMap and x and y and self:FindWarCampAt(x, y, width, height)
  if camp then
    if self.hoverCamp ~= camp.id then
      self:ClearHover()
      self.hoverCamp = camp.id
      self.tooltipShown = ShowAreaTooltip(canvas, self.areas[camp.id])
      self.tooltipDebug = camp.id .. " war-camp " .. TooltipProbe(self.tooltipShown)
    end
    return
  end
  if self.hoverCamp then self:ClearHover() end

  if not self.enabled or not Contours or not overMap or not x
      or self.visibleCount == 0 or not self.currentMap then
    if self.hoverId then self:ClearHover() end
    return
  end
  if self.cursorX == x and self.cursorY == y then return end

  local id = self:FindAreaAt(x, y, width, height)
  if id == self.hoverId then
    self.cursorX, self.cursorY = x, y
    return
  end

  self:ClearHover()
  self.cursorX, self.cursorY = x, y
  if not id then return end

  local area = self.areas[id]
  local entry = self.groups[id]
  self.hoverId = id
  self:ApplyLabelVisibility(entry)
  ShowHoverPatches(entry, area, width, height, self.stitchedAPI, self.stitchedHostID)
  self.tooltipShown = ShowAreaTooltip(canvas, area)
  self.tooltipDebug = id .. " " .. TooltipProbe(self.tooltipShown)
end

-- The last hover sample as text, for the debug command; nil before any sample.
function Map:HoverDebug()
  local sample = self.hoverSample
  if not sample then return nil end
  return "focus=" .. FrameLabel(sample.focus) .. " getFocus=" .. sample.getFocus
    .. " focusOk=" .. tostring(sample.focusOk) .. " overMap=" .. tostring(sample.overMap)
    .. " cursor=" .. (sample.x and string.format("%.1f,%.1f", sample.x, sample.y) or "off-canvas")
    .. " visible=" .. tostring(sample.visible) .. " map=" .. tostring(sample.map)
    .. " hover=" .. tostring(sample.hover)
end

-- Hover probe (/wfd map hover probe | report | probe off). While on, each hover
-- sample with the cursor inside a drawn shape is counted for that area, and a
-- sample whose hover differs from the shape under the cursor keeps its reason.
-- Bounded, and saved in WarfrontDB.hoverProbe so /reload makes it readable.
local HOVER_PROBE_SAMPLES = 150

local function ShapeAreaAt(self, x, y)
  local mapKey = CanonicalMapName(self.currentMap)
  local index = #self.order
  while index >= 1 do
    local id = self.order[index]
    local area = self.areas[id]
    if area and area.enabled and AreaMatchesView(self, area, mapKey)
        and AreaContainsCanvasPoint(self, area, x, y) then
      return id
    end
    index = index - 1
  end
  return nil
end

local function ProbeFocusLabel(focus)
  local label = FrameLabel(focus)
  if focus and label == "unnamed" and type(focus.GetParent) == "function" then
    local ok, parent = pcall(focus.GetParent, focus)
    if ok and parent then label = "unnamed<" .. FrameLabel(parent) end
  end
  return label
end

local function Round2(value)
  return mathFloor(value * 100 + 0.5) / 100
end

function Map:SetHoverProbe(enabled)
  if not enabled then
    self.hoverProbe = nil
    return
  end
  local probe = { areas = {}, samples = {}, dropped = 0 }
  self.hoverProbe = probe
  local db = WF.Storage and WF.Storage.GetDB and WF.Storage:GetDB()
  if type(db) == "table" then db.hoverProbe = probe end
end

local function HoverMissReason(self, canvas, focus, shapeId, x, y, width, height)
  local hoverId = self.hoverId
  if focus and not MapHasFocus(canvas, focus) then return "focus:" .. ProbeFocusLabel(focus) end
  if not shapeId then return "outsideShape:" .. tostring(hoverId) end
  local entry = self.groups[shapeId]
  if not entry then return "noEntry" end
  if not entry.active then return "inactive" end
  if not entry.records then return entry.pending and "building" or "noRecords" end
  local found = self:FindAreaAt(x, y, width, height)
  if hoverId and found == hoverId then return "icon:" .. hoverId end
  if found == shapeId then return "notApplied:" .. tostring(hoverId) end
  return "found:" .. tostring(found) .. ":" .. tostring(hoverId)
end

function Map:ProbeHover()
  local probe = self.hoverProbe
  local canvas = GetCanvas()
  local width, height = GetCanvasSize(canvas)
  if not probe or not width or not self.currentMap or not Contours then return end
  local x, y = CursorOnCanvas(canvas, width, height)
  if not x then return end
  local shapeId = ShapeAreaAt(self, x, y)
  local hoverId = self.hoverId
  if not shapeId and not hoverId then return end

  local key = shapeId or hoverId
  local stats = probe.areas[key]
  if not stats then
    stats = { inside = 0, hovered = 0, missed = 0, reasons = {} }
    probe.areas[key] = stats
  end
  if shapeId then stats.inside = stats.inside + 1 end
  if shapeId == hoverId then
    stats.hovered = stats.hovered + 1
    return
  end

  local getFocus = MouseFocusGetter()
  local focus = nil
  if type(getFocus) == "function" then
    local ok, frame = pcall(getFocus)
    if ok then focus = frame end
  end
  local reason = HoverMissReason(self, canvas, focus, shapeId, x, y, width, height)
  stats.missed = stats.missed + 1
  stats.reasons[reason] = (stats.reasons[reason] or 0) + 1

  -- One sample per reason and cursor spot, so a still cursor fills nothing.
  if probe.lastReason == reason and probe.lastArea == key
      and mathAbs(probe.lastX - x) < 0.5 and mathAbs(probe.lastY - y) < 0.5 then
    return
  end
  probe.lastReason, probe.lastArea, probe.lastX, probe.lastY = reason, key, x, y
  if #probe.samples >= HOVER_PROBE_SAMPLES then
    probe.dropped = probe.dropped + 1
    return
  end
  table.insert(probe.samples, {
    area = key, reason = reason, x = Round2(x), y = Round2(y),
    focus = ProbeFocusLabel(focus), map = self.currentMap,
    width = Round2(width), height = Round2(height),
  })
end

-- Chat lines for /wfd map hover report: per area, cursor samples inside its
-- shape, how many showed its hover, and the most frequent miss reasons.
function Map:HoverProbeReport()
  local probe = self.hoverProbe
  if not probe then return { "hover probe is off (/wfd map hover probe)" } end
  local lines = {}
  for id, stats in pairs(probe.areas) do
    local reasons = {}
    for reason, count in pairs(stats.reasons) do
      reasons[#reasons + 1] = { reason, count }
    end
    table.sort(reasons, function(a, b) return a[2] > b[2] end)
    local text = id .. " inside=" .. stats.inside .. " hovered=" .. stats.hovered
      .. " missed=" .. stats.missed
    local index = 1
    while index <= 3 and reasons[index] do
      text = text .. " " .. reasons[index][1] .. "=" .. reasons[index][2]
      index = index + 1
    end
    lines[#lines + 1] = text
  end
  table.sort(lines)
  if #lines == 0 then
    lines[#lines + 1] = "no sample inside an area yet (open the map, move the cursor)"
  end
  table.insert(lines, "samples kept=" .. #probe.samples .. " dropped=" .. probe.dropped
    .. " (/reload saves them)")
  return lines
end

-- A hidden frame gets no OnUpdate: hiding the driver stops Map:Tick.
function Map:WakeDriver()
  local driver = self.driver
  if driver and type(driver.Show) == "function" then pcall(driver.Show, driver) end
end

function Map:SleepDriver()
  local driver = self.driver
  if driver and type(driver.Hide) == "function" then pcall(driver.Hide, driver) end
end

local function CanvasVisible()
  local canvas = GetCanvas()
  if not canvas then return false end
  if type(canvas.IsVisible) ~= "function" then return true end
  local ok, visible = pcall(canvas.IsVisible, canvas)
  return not ok or visible and true or false
end

function Map:Tick()
  self.ticks = (self.ticks or 0) + 1
  local open = CanvasVisible()
  self:StepBuilds(open)
  -- A closed map needs no hover or refresh; one last hover pass clears its
  -- tooltip, and the first tick after reopening refreshes at once.
  if not open then
    if self.canvasWasVisible then
      self.canvasWasVisible = false
      local hoverOk, hoverError = pcall(self.UpdateHover, self)
      if not hoverOk and WF.RecordError then WF.RecordError("map hover", hoverError) end
    end
    -- Nothing left to do while closed: stop the per-frame driver. The map's
    -- OnShow hook and QueueBuild wake it (only once that hook is in place).
    if self.wakeHooked and self:BuildCount() == 0 then self:SleepDriver() end
    return
  end
  self.openTicks = (self.openTicks or 0) + 1
  if not self.canvasWasVisible then
    self.canvasWasVisible = true
    self.lastRefreshAt, self.fallbackTicks = nil, 15
  end
  if self.campaignRoutes.nodeCount > 0 or next(self.zoneSiegeIcons) ~= nil then
    local stepOk, stepError = pcall(self.AnimateSieges, self)
    if not stepOk and WF.RecordError then WF.RecordError("map siege flipbook", stepError) end
  end
  local now = WF.Now and WF.Now() or 0
  if type(now) == "number" and now > 0
      and (not self.lastHoverAt or now - self.lastHoverAt >= HOVER_INTERVAL) then
    self.lastHoverAt = now
    local hoverOk, hoverError = pcall(self.UpdateHover, self)
    if not hoverOk and WF.RecordError then WF.RecordError("map hover", hoverError) end
    if self.hoverProbe then
      local probeOk, probeError = pcall(self.ProbeHover, self)
      if not probeOk and WF.RecordError then WF.RecordError("map hover probe", probeError) end
    end
  end
  -- refreshNow: the shown map changed or the open map's builds just finished.
  if type(now) == "number" and now > 0 then
    if self.refreshNow or not self.lastRefreshAt or now - self.lastRefreshAt >= REFRESH_INTERVAL then
      self.refreshNow = nil
      self.lastRefreshAt = now
      self:Refresh()
    end
  else
    self.fallbackTicks = (self.fallbackTicks or 0) + 1
    if self.refreshNow or self.fallbackTicks >= 15 then
      self.refreshNow = nil
      self.fallbackTicks = 0
      self:Refresh()
    end
  end
end

-- Diagnostic squares for the area-patch texture, built like a real area group.
-- Each square isolates one suspect, left to right:
-- 1 white WHITE8X8 (control), 2 profile fill, 3 the same fill with mirrored u
-- (every real patch has u1 > u2), 4 the fill stacked from 48 strips 0.83 units
-- tall (the real patch height), 5 the whole profile strip (border gradient).
local PROBE_SIZE = 40
local PROBE_STRIPS = 48

function Map:ShowProbe(enabled)
  if self.probe then
    HideObject(self.probe)
    self.probe = nil
  end
  if not enabled then return true, "probe removed" end

  local canvas = GetCanvas()
  local create = GetGlobal("CreateFrame")
  if not canvas or type(create) ~= "function" then return false, "no WorldMapButton" end
  local ok, frame = pcall(create, "Frame", nil, canvas)
  if not ok or not frame then return false, "CreateFrame failed" end
  frame:SetAllPoints(canvas)
  frame:EnableMouse(false)
  frame:SetFrameLevel(canvas:GetFrameLevel() + 1)
  self.probe = frame

  local results = {}
  local function Square(index, path, u1, u2, v1, v2, top, height)
    local texture = frame:CreateTexture(nil, "ARTWORK")
    local loaded = texture:SetTexture(path)
    texture:SetTexCoord(u1, u2, v1, v2)
    texture:SetVertexColor(1, 0.2, 0.8, 1)
    texture:SetPoint("TOPLEFT", frame, "TOPLEFT",
      40 + (index - 1) * (PROBE_SIZE + 12), -(40 + top))
    texture:SetWidth(PROBE_SIZE)
    texture:SetHeight(height)
    texture:Show()
    return loaded
  end

  results[1] = Square(1, "Interface\\Buttons\\WHITE8X8", 0, 1, 0, 1, 0, PROBE_SIZE)
  results[2] = Square(2, PROFILE_TEXTURE, 0.95, 0.99, 0.25, 0.75, 0, PROBE_SIZE)
  results[3] = Square(3, PROFILE_TEXTURE, 0.99, 0.95, 0.25, 0.75, 0, PROBE_SIZE)
  local strip = PROBE_SIZE / PROBE_STRIPS
  local index = 1
  while index <= PROBE_STRIPS do
    results[4] = Square(4, PROFILE_TEXTURE, 0.95, 0.99, 0.25, 0.75,
      (index - 1) * strip, strip)
    index = index + 1
  end
  results[5] = Square(5, PROFILE_TEXTURE, 0, 1, 0, 1, 0, PROBE_SIZE)
  frame:Show()
  return true, "SetTexture white=" .. tostring(results[1])
    .. " profile=" .. tostring(results[2])
end

Kit.CanvasVisible = CanvasVisible
