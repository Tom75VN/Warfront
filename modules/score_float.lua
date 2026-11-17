local WF = Warfront

-- Floating score text: each scoreboard credit of this character (War record
-- Add) rises above the screen centre like combat text, as the points it is
-- worth on its board (Scoreboard weights). Each resource gathering tick at a
-- POI (Stock:Gather) shows the same way, as the resource icon and the amount
-- received. Local display only; PvP deaths are not points and never show.
local ScoreFloat = {}
WF.ScoreFloat = ScoreFloat

local MAX_LINES = 6
local DURATION = 2.2      -- seconds a line stays on screen
local FADE_IN = 0.15
local FADE_OUT = 0.7
local RISE = 70           -- pixels a line climbs over its life
local START_Y = 140       -- above the screen centre
-- Gathering lines start like Blizzard_CombatText: the text's top on the
-- screen centre (its startY = 384 / 768 of WorldFrame), at the character's head.
local RESOURCE_START_Y = 0
local LINE_GAP = 26       -- pixels between lines shown together
local MERGE_WINDOW = 0.6  -- seconds during which a new credit adds to the same board's line
local FONT_SIZE = 24
local ICON_SIZE = 26      -- resource icon width, left of its amount
local ICON_GAP = 4

local BOARD_COLORS = {
  territory = { 1, 0.82, 0 },
  pvp = { 1, 0.3, 0.25 },
  effort = { 0.35, 0.9, 0.35 },
}

local RESOURCE_COLORS = {
  gold = { 1, 0.82, 0 },
  wood = { 0.85, 0.62, 0.36 },
  food = { 0.6, 0.92, 0.4 },
}

local driver, lines = nil, {}

-- Board and points of one credit; nil when it is worth nothing.
local function Points(category, key, amount)
  local board = WF.Scoreboard
  if not board then return nil end
  if category == "capture" then
    return "territory", (board.CAPTURE_POINTS[key] or 0) * amount
  elseif category == "defense" then
    return "territory", (board.DEFENSE_POINTS[key] or 0) * amount
  elseif category == "pvp" then
    if key == "kills" or key == "assists" then return "pvp", amount end
    return nil
  elseif category == "chest" then
    return "effort", amount
  elseif category == "attack" or category == "garrison" then
    return "effort", board.UnitCost(key) * amount
  end
  return nil
end

local function Label(line)
  if line.resource then return string.format("+%d", line.points) end
  local def = WF.Scoreboard.BOARDS[line.board]
  local title = def and def.title or ""
  if WF.L then title = WF.L(title) end
  return string.format("+%d %s", line.points, title)
end

local function NewText()
  local text = driver:CreateFontString(nil, "OVERLAY")
  local font = _G.CombatTextFont or _G.GameFontNormalLarge
  if font then text:SetFontObject(font) end
  local path = text:GetFont()
  if path then text:SetFont(path, FONT_SIZE, "OUTLINE") end
  text:SetShadowOffset(1, -1)
  text:SetShadowColor(0, 0, 0, 0.8)
  text:Hide()
  return text
end

local function NewIcon(text)
  local icon = driver:CreateTexture(nil, "OVERLAY")
  icon:SetWidth(ICON_SIZE)
  icon:SetHeight(ICON_SIZE)
  icon:SetPoint("RIGHT", text, "LEFT", -ICON_GAP, 0)
  icon:Hide()
  return icon
end

local function Layout(now)
  local active = 0
  for index = 1, #lines do
    local line = lines[index]
    if line.start then
      local age = now - line.start
      if age >= DURATION then
        line.start = nil
        line.text:Hide()
        line.icon:Hide()
      else
        active = active + 1
        local alpha = 1
        if age < FADE_IN then
          alpha = age / FADE_IN
        elseif age > DURATION - FADE_OUT then
          alpha = (DURATION - age) / FADE_OUT
        end
        line.text:SetAlpha(alpha)
        line.icon:SetAlpha(alpha)
        -- With an icon, the pair (icon, gap, text) is centred as one.
        local x = line.resource and (ICON_SIZE + ICON_GAP) / 2 or 0
        local point = line.resource and "TOP" or "CENTER"
        local y = line.resource and RESOURCE_START_Y or START_Y
        line.text:ClearAllPoints()
        line.text:SetPoint(point, UIParent, "CENTER", x, y + line.slot * LINE_GAP + RISE * age / DURATION)
      end
    end
  end
  if active == 0 then driver:Hide() end
end

local function Driver()
  if driver then return driver end
  driver = CreateFrame("Frame", nil, UIParent)
  driver:SetFrameStrata("HIGH")
  driver:SetAllPoints(UIParent)
  driver:Hide()
  driver:SetScript("OnUpdate", function() Layout(GetTime()) end)
  for index = 1, MAX_LINES do
    local text = NewText()
    lines[index] = { text = text, icon = NewIcon(text), slot = index - 1 }
  end
  return driver
end

-- Sets a line's icon to the resource's atlas piece, keeping its proportions;
-- false when the piece is missing (the amount then shows alone).
local function ApplyIcon(icon, resource)
  local skin = WF.Skin
  local name = "icon." .. resource
  local piece = skin and skin:Piece(name)
  if not piece or not skin:Apply(icon, name) then return false end
  icon:SetHeight(ICON_SIZE * piece.h / piece.w)
  return true
end

-- key merges lines; resource is set only for a gathering line.
local function Show(key, points, color, resource)
  Driver()
  local now = GetTime()
  local free, oldest
  for index = 1, #lines do
    local line = lines[index]
    if line.start and line.board == key and now - line.start < MERGE_WINDOW then
      line.points = line.points + points
      line.start = now
      line.text:SetText(Label(line))
      return
    end
    if not line.start then
      if not free then free = line end
    elseif not oldest or line.start < oldest.start then
      oldest = line
    end
  end
  local line = free or oldest
  line.board, line.points, line.start, line.resource = key, points, now, nil
  if resource and ApplyIcon(line.icon, resource) then
    line.resource = resource
    line.icon:SetAlpha(0)
    line.icon:Show()
  else
    line.icon:Hide()
  end
  line.text:SetTextColor(color[1], color[2], color[3])
  line.text:SetText(Label(line))
  line.text:SetAlpha(0)
  line.text:Show()
  driver:Show()
end

-- Called after a credit was saved; never affects the credit itself.
function ScoreFloat:Credit(category, key, amount)
  if type(amount) ~= "number" or amount < 1 then return end
  local boardKey, points = Points(category, key, amount)
  if not boardKey or type(points) ~= "number" or points < 1 then return end
  Show(boardKey, points, BOARD_COLORS[boardKey] or BOARD_COLORS.territory)
end

-- Called after a gathering tick was added to the wallet; display only.
function ScoreFloat:Gathered(resource, amount)
  if type(amount) ~= "number" or amount < 1 then return end
  local color = RESOURCE_COLORS[resource]
  if not color then return end
  Show("res:" .. resource, amount, color, resource)
end
