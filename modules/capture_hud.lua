-- Standard functions cached as locals: hot paths call them often.
local mathFloor = math.floor
local mathAbs = math.abs
local mathMax = math.max
local mathMin = math.min

Warfront = Warfront or {}

local WF = Warfront
local Capture = WF.Capture
local HUD = {}

WF.CaptureHUD = HUD

-- Top-of-screen capture HUD shown while the player stands in a POI, plus the
-- alert banner sent to the defending faction (docs/capture.md, Affichage),
-- textured with the sprite atlas (modules/ui_skin.lua): no corner crests,
-- the Alliance share in blue from the left and the Horde share in
-- red from the right, a red warning line. Compact: 70% of the first layout,
-- lines stacked with no gap and the height fitted to them (HUD:Layout); the
-- -/+ button at the top right collapses it to the bar alone, saved in
-- WarfrontDB.settings.hudCollapsed.
local UPDATE_INTERVAL = 0.1
local WIDTH = 238
local HUD_TOP = 40 -- px from the screen top to the frame; the POI medallion sticks out ~17 px above it
local PAD = 8
local LINE_GAP = 7
local EDGE_GAP = 5 -- extra space above the first line and below the last, expanded only
local BAR_WIDTH = 176
local BAR_HEIGHT = 12
local BAR_INSET_X = 2
local BAR_INSET_Y = 2
local BAR_RESPONSE = 12
local BAR_FONT_SHRINK = 2 -- bar texts: GameFontHighlightSmall minus this, in px
local HUD_SCALE = 0.1
local MEDAL_SIZE = 32
local MEDAL_TITLE_GAP = 2 -- medallion bottom above the title top, px
local MEDAL_DROP = 6 -- extra top space when a medallion is shown, so it sits lower
local MEDAL_ICON_WIDTH, MEDAL_ICON_HEIGHT = 28, 26
local BADGE_WIDTH, BADGE_HEIGHT = 16, 19
local ICON_SIZE = 14
-- Resource row icon centers, px from the frame center: players, time to full, wallet.
local PEOPLE_X, REGEN_X, WALLET_X = -82, -40, 18
-- Horde and Alliance badge-and-count groups sit in the upper corners; the
-- optional remaining-time group stays in the content column.
local HORDE_COUNT_X, ALLIANCE_COUNT_X, COUNT_CLOCK_X = 76, -103, 0
local TOGGLE_SIZE = 16
local TOGGLE_INSET = 2
-- The title leaves room for the toggle on its right (and the same on its left).
local TITLE_WIDTH = WIDTH - 2 * (TOGGLE_SIZE + TOGGLE_INSET + 2)
local WIDE_WIDTH = WIDTH - 2 * PAD
local LINE_WIDTH = WIDE_WIDTH
local MEDAL_BACKGROUND = { 0.09, 0.08, 0.07 }
local BANNER_WIDTH, BANNER_HEIGHT = 540, 56
local BANNER_SHOWN = 5
local BANNER_FADE = 1.5
local FLAGS = { A = "flag.alliance", H = "flag.horde", N = "flag.neutral" }
local RESOURCE_FILLS = { gold = "fill.gold", wood = "fill.brown", food = "fill.green" }

local function GetGlobal(name)
  if WF.Compat and WF.Compat.Global then return WF.Compat.Global(name) end
  if _G then return _G[name] end
  return nil
end

local function FactionName(code)
  return Capture and Capture.FACTION_NAMES[code] or tostring(code)
end

local function AreaName(area)
  return tostring(area.label or area.id)
end

local function Clock(seconds)
  seconds = mathFloor(seconds + 0.5)
  local minutes = mathFloor(seconds / 60)
  local rest = seconds - minutes * 60
  if rest < 10 then return minutes .. ":0" .. rest end
  return minutes .. ":" .. rest
end

local function NewText(frame, template, point, y, width)
  local text = frame:CreateFontString(nil, "OVERLAY", template)
  text:SetPoint(point, frame, point, 0, y)
  text:SetWidth(width or LINE_WIDTH)
  -- Used when the client cannot measure the wrapped text.
  text.lineHeight = template == "GameFontNormal" and 12 or 10
  return text
end

local function Settings()
  local storage = WF.Storage
  if not storage or type(storage.GetDB) ~= "function" or storage.readOnly then return nil end
  local db = storage:GetDB()
  if type(db) ~= "table" or type(db.settings) ~= "table" then return nil end
  return db.settings
end

-- A FontString with a width wraps and reports its wrapped height (1.12).
local function TextHeight(text)
  local height = text.GetHeight and text:GetHeight()
  if type(height) ~= "number" or height <= 0 then return text.lineHeight or 10 end
  return height
end

local function HasText(text)
  local value = text:GetText()
  return text:IsShown() and value ~= nil and value ~= ""
end

-- HUD:Update runs 10 times a second and first resets every widget: during an
-- update, SetShown only records the wanted state; FlushShown applies the
-- final one, so a widget that stays visible is never hidden and shown again.
local pendingShown = {}
local batchingShown = false

local function SetShown(region, shown)
  shown = shown and true or false
  if batchingShown then
    pendingShown[region] = shown
    return
  end
  if (region:IsShown() and true or false) ~= shown then
    if shown then region:Show() else region:Hide() end
  end
end

local function FlushShown()
  batchingShown = false
  for region, shown in pairs(pendingShown) do
    pendingShown[region] = nil
    SetShown(region, shown)
  end
end

-- Starts a batch; an earlier batch left open by an error is applied first.
local function BeginShown()
  FlushShown()
  batchingShown = true
end

-- Sets the text only when it differs: SetText makes the client lay it out.
local function SetText(region, text)
  if text == nil then text = "" end
  if (region:GetText() or "") ~= text then region:SetText(text) end
end

-- Keeps the template's font file, BAR_FONT_SHRINK px smaller, with a thin
-- outline instead of the drop shadow.
local function ShrinkFont(text)
  if not text.GetFont or not text.SetFont then return end
  local path, size = text:GetFont()
  if path and type(size) == "number" and size > BAR_FONT_SHRINK then
    text:SetFont(path, size - BAR_FONT_SHRINK, "OUTLINE")
  end
  if text.SetShadowOffset then text:SetShadowOffset(0, 0) end
  if text.SetShadowColor then text:SetShadowColor(0, 0, 0, 0) end
end

local function Fill(bar, piece, layer, fromRight)
  local texture = bar:CreateTexture(nil, layer or "ARTWORK")
  if WF.Skin then WF.Skin:Apply(texture, piece) end
  texture:SetHeight(BAR_HEIGHT - 2 * BAR_INSET_Y)
  texture.fillPiece = piece
  texture.fillFromRight = fromRight
  return texture
end

function HUD:Build()
  if self.frame then return self.frame end
  local create = GetGlobal("CreateFrame")
  local skin = WF.Skin
  if type(create) ~= "function" then return nil end
  local ok, frame = pcall(create, "Frame", "WarfrontCaptureHUD", UIParent)
  if not ok or not frame then return nil end
  frame:SetWidth(WIDTH)
  frame:SetHeight(2 * PAD + BAR_HEIGHT)
  frame:SetPoint("TOP", UIParent, "TOP", 0, -HUD_TOP)
  if skin then
    local border = skin:Border(frame, { top = "hud.top", bottom = "hud.bottom", left = "hud.left", right = "hud.right",
      centre = "hud.centre", sideCap = 10, overlap = 8 }, HUD_SCALE)
    if border and border.parts and frame.GetFrameLevel then
      local level = frame:GetFrameLevel()
      for _, part in pairs(border.parts) do
        if part.SetFrameLevel then part:SetFrameLevel(level) end
      end
    end
  end
  self.title = NewText(frame, "GameFontNormal", "TOP", -PAD, TITLE_WIDTH)
  -- POI medallion above the title: an opaque disc, the POI picture,
  -- then the gold ring (transparent inside) on top. Its own frame sits above
  -- the border holders.
  local medal = create("Frame", nil, frame)
  medal:SetWidth(MEDAL_SIZE)
  medal:SetHeight(MEDAL_SIZE)
  medal:SetPoint("BOTTOM", self.title, "TOP", 0, MEDAL_TITLE_GAP)
  if medal.SetFrameLevel and frame.GetFrameLevel then medal:SetFrameLevel(frame:GetFrameLevel() + 3) end
  medal.disc = medal:CreateTexture(nil, "BACKGROUND")
  medal.disc:SetWidth(MEDAL_SIZE - 6)
  medal.disc:SetHeight(MEDAL_SIZE - 6)
  medal.disc:SetPoint("CENTER", medal, "CENTER", 0, 0)
  medal.icon = medal:CreateTexture(nil, "ARTWORK")
  medal.icon:SetWidth(MEDAL_ICON_WIDTH)
  medal.icon:SetHeight(MEDAL_ICON_HEIGHT)
  medal.icon:SetPoint("CENTER", medal, "CENTER", 0, 0)
  medal.ring = medal:CreateTexture(nil, "OVERLAY")
  medal.ring:SetAllPoints(medal)
  if skin then
    skin:Apply(medal.disc, "fill.disc")
    skin:Apply(medal.ring, "hud.medal.ring")
  end
  medal.disc:SetVertexColor(MEDAL_BACKGROUND[1], MEDAL_BACKGROUND[2], MEDAL_BACKGROUND[3])
  medal:Hide()
  self.medal = medal
  self.mode = NewText(frame, "GameFontHighlightSmall", "TOP", -PAD)
  self.info = NewText(frame, "GameFontHighlightSmall", "TOP", -PAD)
  if skin then
    self.resourceStateIcon = skin:Icon(frame, "icon.unitsize", ICON_SIZE, ICON_SIZE, "OVERLAY")
    self.resourceStateIcon:SetPoint("TOP", frame, "TOP", PEOPLE_X, -PAD)
    self.resourceState = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.resourceState:SetPoint("LEFT", self.resourceStateIcon, "RIGHT", 2, 0)
    self.resourceState:SetWidth(26)
    if self.resourceState.SetJustifyH then self.resourceState:SetJustifyH("LEFT") end
    self.resourceRegenIcon = skin:Icon(frame, "icon.clock", ICON_SIZE, ICON_SIZE, "OVERLAY")
    self.resourceRegenIcon:SetPoint("TOP", frame, "TOP", REGEN_X, -PAD)
    self.resourceRegen = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.resourceRegen:SetPoint("LEFT", self.resourceRegenIcon, "RIGHT", 2, 0)
    self.resourceRegen:SetWidth(32)
    if self.resourceRegen.SetJustifyH then self.resourceRegen:SetJustifyH("LEFT") end
    self.resourceWalletIcon = skin:Icon(frame, nil, ICON_SIZE, ICON_SIZE, "OVERLAY")
    self.resourceWalletIcon:SetPoint("TOP", frame, "TOP", WALLET_X, -PAD)
    self.resourceWallet = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.resourceWallet:SetPoint("LEFT", self.resourceWalletIcon, "RIGHT", 2, 0)
    self.resourceWallet:SetWidth(82)
    if self.resourceWallet.SetJustifyH then self.resourceWallet:SetJustifyH("LEFT") end
    self.countHIcon = skin:Icon(frame, "badge.horde", BADGE_WIDTH, BADGE_HEIGHT, "OVERLAY")
    self.countH = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.countH:SetPoint("LEFT", self.countHIcon, "RIGHT", 2, 0)
    self.countH:SetWidth(18)
    if self.countH.SetJustifyH then self.countH:SetJustifyH("LEFT") end
    self.countAIcon = skin:Icon(frame, "badge.alliance", BADGE_WIDTH, BADGE_HEIGHT, "OVERLAY")
    self.countA = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.countA:SetPoint("LEFT", self.countAIcon, "RIGHT", 2, 0)
    self.countA:SetWidth(18)
    if self.countA.SetJustifyH then self.countA:SetJustifyH("LEFT") end
    self.countClockIcon = skin:Icon(frame, "icon.clock", ICON_SIZE, ICON_SIZE, "OVERLAY")
    self.countClock = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.countClock:SetPoint("LEFT", self.countClockIcon, "RIGHT", 2, 0)
    self.countClock:SetWidth(36)
    if self.countClock.SetJustifyH then self.countClock:SetJustifyH("LEFT") end
  end

  -- The red warning line at the bottom, plain text: refusal reasons and the
  -- version notice.
  self.warning = NewText(frame, "GameFontHighlightSmall", "TOP", -PAD, WIDE_WIDTH)
  self.warning:SetTextColor(1, 0.35, 0.35)

  local bar = create("Frame", nil, frame)
  bar:SetWidth(BAR_WIDTH)
  bar:SetHeight(BAR_HEIGHT)
  bar:SetPoint("TOP", frame, "TOP", 0, -PAD)
  if skin then
    self.barFrame = bar:CreateTexture(nil, "BORDER")
    self.barFrame:SetAllPoints(bar)
    skin:Apply(self.barFrame, "hud.bar.frame")
  end
  self.bar = bar
  self.inner = BAR_WIDTH - 2 * BAR_INSET_X
  -- 1.12 has no texture sublevels: the grey base sits in a lower layer than
  -- the faction fills, or it may be drawn over them.
  self.neutral = Fill(bar, "fill.grey", "BACKGROUND")
  self.neutral:SetPoint("LEFT", bar, "LEFT", BAR_INSET_X, 0)
  self.neutral:SetWidth(self.inner)
  self.alliance = Fill(bar, "fill.blue")
  self.alliance:SetPoint("LEFT", bar, "LEFT", BAR_INSET_X, 0)
  self.horde = Fill(bar, "fill.red", nil, true)
  self.horde:SetPoint("RIGHT", bar, "RIGHT", -BAR_INSET_X, 0)
  self.stock = Fill(bar, "fill.gold")
  self.stock:SetPoint("LEFT", bar, "LEFT", BAR_INSET_X, 0)
  self.stock:Hide()
  self.stockValue = NewText(bar, "GameFontHighlightSmall", "CENTER", 0.5, 100)
  self.stockValue:Hide()
  self.left = NewText(bar, "GameFontHighlightSmall", "LEFT", 0.5, 50)
  self.left:SetPoint("LEFT", bar, "LEFT", 7, 0.5)
  self.right = NewText(bar, "GameFontHighlightSmall", "RIGHT", 0.5, 50)
  self.right:SetPoint("RIGHT", bar, "RIGHT", -7, 0.5)
  if self.right.SetJustifyH then self.right:SetJustifyH("RIGHT") end
  if self.left.SetJustifyH then self.left:SetJustifyH("LEFT") end
  ShrinkFont(self.stockValue)
  ShrinkFont(self.left)
  ShrinkFont(self.right)
  if skin then
    self.badgeA = skin:Icon(frame, "badge.alliance", BADGE_WIDTH, BADGE_HEIGHT, "OVERLAY")
    self.badgeA:SetPoint("RIGHT", bar, "LEFT", -1, 0)
    self.badgeH = skin:Icon(frame, "badge.horde", BADGE_WIDTH, BADGE_HEIGHT, "OVERLAY")
    self.badgeH:SetPoint("LEFT", bar, "RIGHT", 1, 0)
  end

  -- Why an Outpost takes 3 to 20 minutes, or what a siege still needs (WP10).
  self.detail = NewText(frame, "GameFontHighlightSmall", "TOP", -PAD, WIDE_WIDTH)
  self.detail:SetTextColor(0.8, 0.8, 0.8)

  self:BuildToggle(frame)
  self.zones = { self:HoverZone(frame, "bar", bar, BAR_WIDTH, BAR_HEIGHT) }
  if self.resourceStateIcon then
    self.zones[#self.zones + 1] = self:HoverZone(frame, "people", self.resourceStateIcon, ICON_SIZE + 28, ICON_SIZE + 4)
    self.zones[#self.zones + 1] = self:HoverZone(frame, "regen", self.resourceRegenIcon, ICON_SIZE + 34, ICON_SIZE + 4)
    self.zones[#self.zones + 1] = self:HoverZone(frame, "wallet", self.resourceWalletIcon, ICON_SIZE + 64, ICON_SIZE + 4)
  end
  local settings = Settings()
  self.collapsed = settings and settings.hudCollapsed and true or nil
  self:SetToggle()

  frame:Hide()
  self.frame = frame
  return frame
end

-- Hover zone: an invisible mouse frame over a HUD element (`target`, the bar
-- or a resource icon and its text) that shows the short tooltip
-- HUD.tips[key], filled by HUD:Update. Shown only while its target is
-- (HUD:Layout), so a hidden element never catches the mouse.
function HUD:HoverZone(frame, key, target, width, height)
  local create = GetGlobal("CreateFrame")
  local zone = create("Frame", nil, frame)
  zone:SetWidth(width)
  zone:SetHeight(height)
  if target == self.bar then
    zone:SetPoint("CENTER", target, "CENTER", 0, 0)
  else
    zone:SetPoint("LEFT", target, "LEFT", -2, 0)
  end
  if zone.SetFrameLevel and frame.GetFrameLevel then zone:SetFrameLevel(frame:GetFrameLevel() + 4) end
  if zone.EnableMouse then zone:EnableMouse(true) end
  zone.key = key
  zone.target = target
  zone:SetScript("OnEnter", function(self) HUD:ShowTip(self) end)
  zone:SetScript("OnLeave", function(self) HUD:HideTip(self) end)
  return zone
end

function HUD:ShowTip(zone)
  local tooltip = GetGlobal("GameTooltip")
  local lines = self.tips and self.tips[zone.key]
  if not tooltip or not lines or not lines[1] then return self:HideTip(zone) end
  self.hovered = zone
  self.hoverText = table.concat(lines, "\n")
  tooltip:SetOwner(zone, "ANCHOR_BOTTOM")
  if tooltip.ClearLines then tooltip:ClearLines() end
  tooltip:AddLine(lines[1], 1, 0.82, 0)
  local index = 2
  while lines[index] do
    tooltip:AddLine(lines[index], 1, 1, 1)
    index = index + 1
  end
  tooltip:Show()
end

function HUD:HideTip(zone)
  if not self.hovered or (zone and self.hovered ~= zone) then return end
  self.hovered = nil
  self.hoverText = nil
  local tooltip = GetGlobal("GameTooltip")
  if tooltip then tooltip:Hide() end
end

-- After each HUD:Update: the open tooltip follows its values (people, timer,
-- stock) and closes when its zone went away (OnLeave may not fire then).
function HUD:RefreshTip()
  local zone = self.hovered
  if not zone then return end
  local lines = self.tips and self.tips[zone.key]
  if not zone:IsShown() or not self.frame:IsShown() or not lines or not lines[1] then return self:HideTip(zone) end
  if table.concat(lines, "\n") ~= self.hoverText then self:ShowTip(zone) end
end

-- The -/+ button (hud.minus / hud.plus, pushed faces while held). The HUD
-- itself takes no mouse input: only this button and the hover zones catch
-- the mouse.
function HUD:BuildToggle(frame)
  local create = GetGlobal("CreateFrame")
  local button = create("Button", nil, frame)
  button:SetWidth(TOGGLE_SIZE)
  button:SetHeight(TOGGLE_SIZE)
  if button.SetFrameLevel and frame.GetFrameLevel then button:SetFrameLevel(frame:GetFrameLevel() + 4) end
  if button.EnableMouse then button:EnableMouse(true) end
  button.face = button:CreateTexture(nil, "ARTWORK")
  button.face:SetAllPoints(button)
  button.glow = button:CreateTexture(nil, "HIGHLIGHT")
  button.glow:SetAllPoints(button)
  if button.glow.SetBlendMode then button.glow:SetBlendMode("ADD") end
  if button.glow.SetAlpha then button.glow:SetAlpha(0.35) end
  button:SetScript("OnMouseDown", function(self) self.down = true HUD:SetToggle() end)
  button:SetScript("OnMouseUp", function(self) self.down = nil HUD:SetToggle() end)
  button:SetScript("OnClick", function() HUD:ToggleCollapsed() end)
  self.toggle = button
  return button
end

function HUD:SetToggle()
  local button = self.toggle
  if not button then return end
  button.sign = self.collapsed and "+" or "-"
  local piece = self.collapsed and "hud.plus" or "hud.minus"
  if WF.Skin then
    WF.Skin:Apply(button.face, button.down and piece .. ".pushed" or piece)
    WF.Skin:Apply(button.glow, piece)
  end
end

function HUD:ToggleCollapsed()
  self.collapsed = not self.collapsed or nil
  local settings = Settings()
  if settings then settings.hudCollapsed = self.collapsed end
  self:SetToggle()
  if self.frame then self:Update() end
end

-- Stacks the shown lines from the top, LINE_GAP apart, and fits the frame to them;
-- collapsed, only the bar stays. The toggle sits in the top-right corner.
-- Places region at y below the frame top; returns the next free y.
local function Place(frame, region, y, height)
  region:ClearAllPoints()
  region:SetPoint("TOP", frame, "TOP", 0, -y)
  return y + height + LINE_GAP
end

local LAYOUT_TEXTS = { "title", "mode", "info", "detail", "warning" }

-- Stores value under key in last; returns false when it changed, else same.
local function Remember(last, key, value, same)
  if last[key] ~= value then
    last[key] = value
    return false
  end
  return same
end

-- Whether every input of the anchoring pass matches the previous pass. Update
-- runs 10 times a second; re-anchoring an unchanged HUD forces a relayout.
local function LayoutUnchanged(hud, collapsed, resourceRow, countRow)
  local last = hud.lastLayout
  local same = last ~= nil
  if not last then
    last = {}
    hud.lastLayout = last
  end
  same = Remember(last, "collapsed", collapsed and true or false, same)
  same = Remember(last, "medal", hud.medal:IsShown() and true or false, same)
  same = Remember(last, "resource", resourceRow and true or false, same)
  same = Remember(last, "count", countRow and true or false, same)
  local clock = false
  if countRow and hud.countClockIcon:IsShown() then
    clock = hud.countClock.GetStringWidth and hud.countClock:GetStringWidth() or 0
  end
  same = Remember(last, "clock", clock, same)
  for index = 1, #LAYOUT_TEXTS do
    local region = hud[LAYOUT_TEXTS[index]]
    same = Remember(last, LAYOUT_TEXTS[index], HasText(region) and TextHeight(region) or false, same)
  end
  return same
end

function HUD:Layout()
  local frame = self.frame
  local collapsed = self.collapsed
  if collapsed then
    SetShown(self.title, false)
    SetShown(self.mode, false)
    SetShown(self.info, false)
    SetShown(self.detail, false)
    SetShown(self.warning, false)
    SetShown(self.medal, false)
    if self.resourceStateIcon then
      SetShown(self.resourceStateIcon, false)
      SetShown(self.resourceState, false)
      SetShown(self.resourceRegenIcon, false)
      SetShown(self.resourceRegen, false)
      SetShown(self.resourceWalletIcon, false)
      SetShown(self.resourceWallet, false)
    end
    if self.countHIcon then
      SetShown(self.countHIcon, false)
      SetShown(self.countH, false)
      SetShown(self.countAIcon, false)
      SetShown(self.countA, false)
      SetShown(self.countClockIcon, false)
      SetShown(self.countClock, false)
    end
  else
    SetShown(self.title, true)
    SetShown(self.detail, true)
  end
  -- Everything below reads IsShown: apply the update's visibility first.
  FlushShown()
  local resourceRow = self.resourceStateIcon and self.resourceStateIcon:IsShown()
  local countRow = self.countHIcon and self.countHIcon:IsShown()
  local zones = self.zones
  if zones then
    for index = 1, #zones do
      local zone = zones[index]
      if zone.target:IsShown() then SetShown(zone, true) else SetShown(zone, false) end
    end
  end
  if LayoutUnchanged(self, collapsed, resourceRow, countRow) then return end

  local edge = collapsed and PAD or PAD + EDGE_GAP
  local y = edge
  -- The medallion hangs from the title: lowering the content lowers it too.
  if not collapsed and self.medal:IsShown() then y = y + MEDAL_DROP end
  if not collapsed then
    if countRow then
      self.countHIcon:ClearAllPoints()
      self.countHIcon:SetPoint("TOP", frame, "TOP", HORDE_COUNT_X, -PAD)
      self.countAIcon:ClearAllPoints()
      self.countAIcon:SetPoint("TOP", frame, "TOP", ALLIANCE_COUNT_X, -PAD)
    end
    if HasText(self.title) then y = Place(frame, self.title, y, TextHeight(self.title)) end
    if resourceRow then
      self.resourceStateIcon:ClearAllPoints()
      self.resourceStateIcon:SetPoint("TOP", frame, "TOP", PEOPLE_X, -y)
      self.resourceRegenIcon:ClearAllPoints()
      self.resourceRegenIcon:SetPoint("TOP", frame, "TOP", REGEN_X, -y)
      self.resourceWalletIcon:ClearAllPoints()
      self.resourceWalletIcon:SetPoint("TOP", frame, "TOP", WALLET_X, -y)
      y = y + ICON_SIZE + LINE_GAP
    end
    if HasText(self.mode) then y = Place(frame, self.mode, y, TextHeight(self.mode)) end
    if countRow and self.countClockIcon:IsShown() then
      -- Center the icon-and-time group, not the icon alone.
      local textWidth = self.countClock.GetStringWidth and self.countClock:GetStringWidth() or 0
      self.countClockIcon:ClearAllPoints()
      self.countClockIcon:SetPoint("TOP", frame, "TOP",
        COUNT_CLOCK_X - mathFloor((textWidth + 2) / 2 + 0.5), -y - 2)
      y = y + ICON_SIZE + LINE_GAP
    elseif HasText(self.info) then
      y = Place(frame, self.info, y, TextHeight(self.info))
    end
  end
  y = Place(frame, self.bar, y, BAR_HEIGHT)
  if not collapsed then
    if HasText(self.detail) then y = Place(frame, self.detail, y, TextHeight(self.detail)) end
    if HasText(self.warning) then y = Place(frame, self.warning, y, TextHeight(self.warning)) end
  end
  frame:SetHeight(y - LINE_GAP + edge)

  local toggle = self.toggle
  if toggle then
    local x = -TOGGLE_INSET
    toggle:ClearAllPoints()
    if collapsed then
      toggle:SetPoint("RIGHT", frame, "RIGHT", x, 0)
    else
      toggle:SetPoint("TOPRIGHT", frame, "TOPRIGHT", x, -TOGGLE_INSET)
    end
  end
end

local function SetFill(texture, fraction, inner)
  if fraction <= 0.001 then
    SetShown(texture, false)
    return
  end
  fraction = mathMin(1, fraction)
  -- Update re-targets every bar 10 times a second: skip an unchanged fill.
  if texture.wfFraction == fraction and texture.wfInner == inner
      and texture.wfPiece == texture.fillPiece then
    SetShown(texture, true)
    return
  end
  texture.wfFraction, texture.wfInner, texture.wfPiece = fraction, inner, texture.fillPiece
  texture:SetWidth(mathMax(1, inner * fraction))
  if WF.Skin and texture.fillPiece then
    local piece = WF.Skin:Piece(texture.fillPiece)
    if piece then
      local shown = piece.w * fraction
      if texture.fillFromRight then
        WF.Skin:Apply(texture, texture.fillPiece, piece.w - shown, piece.w, 0, piece.h)
      else
        WF.Skin:Apply(texture, texture.fillPiece, 0, shown, 0, piece.h)
      end
    end
  end
  SetShown(texture, true)
end

local function TargetFill(texture, fraction, inner)
  fraction = mathMax(0, mathMin(1, fraction or 0))
  texture.targetFraction = fraction
  if texture.displayFraction == nil then texture.displayFraction = fraction end
  SetFill(texture, texture.displayFraction, inner)
end

local function SmoothFill(texture, elapsed, inner)
  if not texture.barActive then return end
  local target = texture.targetFraction
  local current = texture.displayFraction
  if target == nil or current == nil or current == target then return end
  local step = mathMin(1, elapsed * BAR_RESPONSE)
  current = current + (target - current) * step
  if mathAbs(target - current) < 0.0005 then current = target end
  texture.displayFraction = current
  SetFill(texture, current, inner)
end

function HUD:AnimateBar(elapsed)
  if not self.bar or not self.frame or not self.frame:IsShown() then return end
  SmoothFill(self.alliance, elapsed, self.inner)
  SmoothFill(self.horde, elapsed, self.inner)
  SmoothFill(self.stock, elapsed, self.inner)
end

-- Update runs 10 times a second: reapply the skin piece only when it changes.
local function SetCrest(texture, piece)
  if piece and texture.wfCrest == piece then
    SetShown(texture, true)
  elseif piece and WF.Skin and WF.Skin:Apply(texture, piece) then
    texture.wfCrest = piece
    SetShown(texture, true)
  else
    texture.wfCrest = nil
    SetShown(texture, false)
  end
end

-- The resource POI picture, inside the medallion just above the title.
-- The POI's map picture: same owner color, half-capture state and Settlement
-- level as on the world map and minimap.
local function SetPOICrest(medal, area)
  local map = WF.Map
  if not map or type(map.GetIcon) ~= "function" or not area then
    SetShown(medal, false)
    return
  end
  local level = map.SettlementLevel and map.SettlementLevel(area) or nil
  local path, left, right, top, bottom = map.GetIcon(area.type, area.colorKey, area.iconColumn, level)
  if not path then
    SetShown(medal, false)
    return
  end
  local icon = medal.icon
  if icon.wfPath ~= path or icon.wfLeft ~= left or icon.wfRight ~= right
      or icon.wfTop ~= top or icon.wfBottom ~= bottom then
    icon:SetTexture(path)
    icon:SetTexCoord(left, right, top, bottom)
    icon.wfPath, icon.wfLeft, icon.wfRight, icon.wfTop, icon.wfBottom = path, left, right, top, bottom
  end
  SetShown(medal, true)
end

local function Percent(fraction)
  if fraction <= 0.001 then return "" end
  return mathFloor(fraction * 100 + 0.5) .. "%"
end

function HUD:SetWarning(text)
  if text then
    SetText(self.warning, text)
    SetShown(self.warning, true)
  else
    SetShown(self.warning, false)
  end
end

function HUD:SetShares(horde, alliance)
  self.stock.barActive = nil
  SetShown(self.stock, false)
  SetShown(self.stockValue, false)
  SetShown(self.neutral, true)
  self.alliance.barActive = true
  self.horde.barActive = true
  TargetFill(self.alliance, alliance, self.inner)
  TargetFill(self.horde, horde, self.inner)
  SetText(self.left, Percent(alliance))
  SetText(self.right, Percent(horde))
  if self.badgeA then SetShown(self.badgeA, true) SetShown(self.badgeH, true) end
end

-- True when the player's faction holds the POI and nobody is taking it: the HUD
-- then shows no objective line, the mode line already says who controls it.
function HUD.HeldAtRest(view, mine)
  return view ~= nil and mine ~= nil and view.owner == mine and view.challenger == "-"
end

-- What the player's kills do here: nothing when their faction holds the ground
-- at rest, defend when it is contested, capture otherwise.
function HUD.HuntingObjective(view, mine)
  if not view or not mine then return "Kill the required creatures" end
  if HUD.HeldAtRest(view, mine) then return "" end
  if view.owner == mine then return "Kill the required creatures to defend it" end
  return "Kill the required creatures to capture it"
end

-- Horde and Alliance shares of the bar (0 to 1); the rest is neutral grey.
function HUD.Shares(view)
  local p = view.progress / 1000
  if view.owner == "H" then
    local alliance = view.challenger == "A" and p or 0
    return 1 - alliance, alliance
  elseif view.owner == "A" then
    local horde = view.challenger == "H" and p or 0
    return horde, 1 - horde
  end
  return view.challenger == "H" and p or 0, view.challenger == "A" and p or 0
end

-- An outdated addon (core/version.lua) is announced on entering each POI and
-- stays on the warning line.
function HUD:VersionNotice(data)
  local version = WF.Version
  if not data then
    self.enteredId = nil
    return nil
  end
  if not version or not version.newest then return nil end
  if self.enteredId ~= data.id then
    self.enteredId = data.id
    self:Alert(version:Text(), "info", "Newer Warfront version")
  end
  return version:Notice()
end

function HUD:Update()
  local data = Capture and (Capture:GetHud() or (WF.Hunting and WF.Hunting:GetHud())
    or (WF.Stock and WF.Stock:GetHud()))
  local notice = self:VersionNotice(data)
  local frame = self.frame or (data and self:Build())
  if not frame then return end
  if not data then
    self.barId = nil
    SetShown(frame, false)
    return
  end
  if self.barId ~= data.id then
    self.barId = data.id
    self.alliance.displayFraction = nil
    self.horde.displayFraction = nil
    self.stock.displayFraction = nil
  end
  -- Reset every widget, then show what this state needs; Layout applies the
  -- final visibility once (BeginShown / FlushShown).
  BeginShown()
  SetShown(self.medal, false)
  SetShown(self.mode, true)
  SetShown(self.info, true)
  SetShown(self.stockValue, false)
  if self.resourceStateIcon then
    SetShown(self.resourceStateIcon, false)
    SetShown(self.resourceState, false)
    SetShown(self.resourceRegenIcon, false)
    SetShown(self.resourceRegen, false)
    SetShown(self.resourceWalletIcon, false)
    SetShown(self.resourceWallet, false)
  end
  if self.countHIcon then
    SetShown(self.countHIcon, false)
    SetShown(self.countH, false)
    SetShown(self.countAIcon, false)
    SetShown(self.countA, false)
    SetShown(self.countClockIcon, false)
    SetShown(self.countClock, false)
  end

  if data.resource then
    -- A resource POI is never captured: its shared stock is the main visual.
    local stock = data.resource
    self.alliance.barActive = nil
    self.horde.barActive = nil
    SetShown(self.alliance, false)
    SetShown(self.horde, false)
    SetShown(self.neutral, true)
    self.stock.barActive = true
    -- SetFill applies this piece (and its crop) whenever it changes.
    self.stock.fillPiece = RESOURCE_FILLS[stock.resource] or "fill.gold"
    TargetFill(self.stock, stock.capacity > 0 and stock.level / stock.capacity or 0, self.inner)
    SetText(self.left, "")
    SetText(self.right, "")
    SetText(self.stockValue, stock.level .. " / " .. stock.capacity)
    SetShown(self.stockValue, true)
    if self.badgeA then SetShown(self.badgeA, false) SetShown(self.badgeH, false) end
    SetPOICrest(self.medal, data.area)
    SetText(self.title, AreaName(data.area))
    -- Always both: players present (gathering or not, you included) and the
    -- time the stock needs to refill if nobody gathered from now on.
    local _, _, present = Capture:Count(stock.id, WF.Now and WF.Now() or 0)
    local peopleText = tostring(mathMax(1, #present))
    local info = WF.Stock and WF.Stock:Info(stock.id)
    local regenText = "..."
    if stock.known and info and info.regen > 0 then
      regenText = Clock(mathMax(0, stock.capacity - stock.level) * 60 / info.regen)
    end
    if self.resourceStateIcon then
      SetShown(self.mode, false)
      SetShown(self.info, false)
      SetCrest(self.resourceStateIcon, "icon.unitsize")
      SetText(self.resourceState, peopleText)
      SetShown(self.resourceState, true)
      SetCrest(self.resourceRegenIcon, "icon.clock")
      SetText(self.resourceRegen, regenText)
      SetShown(self.resourceRegen, true)
      SetCrest(self.resourceWalletIcon, "icon." .. stock.resource)
      SetText(self.resourceWallet, data.owned .. " / " .. data.cap)
      SetShown(self.resourceWallet, true)
    else
      SetText(self.mode, "Players " .. peopleText .. "   Full in " .. regenText)
      SetText(self.info, data.owned .. " / " .. data.cap)
    end
    if Capture:IsLockReason(data.reason) then
      self:SetWarning("You cannot gather: " .. data.reason)
    elseif data.status == "NC" or not data.status then
      self:SetWarning("You are not gathering: " .. tostring(data.reason or "unknown"))
    else
      self:SetWarning(notice)
    end
    SetText(self.detail, "")
    self:Layout()
    SetShown(frame, true)
    return
  end

  local view = data.view
  if view and view.owner == "N" and view.challenger == "-" then
    -- No confirmed owner: show the reported one at rest, as the map does.
    local reported = Capture:TargetOwner(data.id)
    if reported == "A" or reported == "H" then
      local shown, key, value = {}, nil, nil
      for key, value in pairs(view) do shown[key] = value end
      shown.owner = reported
      view = shown
    end
  end
  local owner = view and view.owner or Capture:GetOwner(data.id)
  SetText(self.title, AreaName(data.area))
  SetPOICrest(self.medal, data.area)

  if data.hunting then
    -- Kills move the bar; there is no presence count or countdown.
    local horde, alliance = HUD.Shares(view)
    self:SetShares(horde, alliance)
    SetText(self.mode, WF.Hunting:ModeText(view))
    SetText(self.info, data.known and HUD.HuntingObjective(view, Capture:MyFaction())
      or "Waiting for the hunting ground state...")
    self:SetWarning(data.warning or notice)
    SetText(self.detail, "")
    self:Layout()
    SetShown(frame, true)
    return
  end

  if view then
    local horde, alliance = HUD.Shares(view)
    self:SetShares(horde, alliance)
    local percent = ""
    if view.challenger ~= "-" then
      percent = " - " .. FactionName(view.challenger) .. " " .. mathFloor(view.progress / 10) .. "%"
    end
    local mode = Capture:ModeText(view)
    if mode == "Controlled by " .. FactionName(owner) then mode = "" end
    SetText(self.mode, mode .. percent)
    if self.countHIcon then
      SetText(self.info, "")
      SetText(self.countH, tostring(view.nH))
      SetShown(self.countHIcon, true)
      SetShown(self.countH, true)
      SetText(self.countA, tostring(view.nA))
      SetShown(self.countAIcon, true)
      SetShown(self.countA, true)
      if data.remaining then
        SetText(self.countClock, Clock(data.remaining))
        SetShown(self.countClockIcon, true)
        SetShown(self.countClock, true)
      end
    else
      local info = "Horde " .. view.nH .. "  Alliance " .. view.nA
      if data.remaining then info = info .. "  -  " .. Clock(data.remaining) end
      SetText(self.info, info)
    end
  else
    self:SetShares(owner == "H" and 1 or 0, owner == "A" and 1 or 0)
    SetText(self.mode, "Waiting for the outpost state...")
    SetText(self.info, "")
  end

  if Capture:IsLockReason(data.reason) then
    self:SetWarning("You cannot capture: " .. data.reason)
  elseif data.status == "NC" or not data.status then
    if data.reason == "not PvP flagged" then
      self:SetWarning("Turn PvP ON (/pvp) to join the capture")
    else
      self:SetWarning("You are not counted: " .. tostring(data.reason or "unknown"))
    end
  else
    self:SetWarning(notice)
  end
  SetText(self.detail, not HUD.HeldAtRest(view, Capture:MyFaction()) and data.detail or "")
  self:Layout()
  SetShown(frame, true)
end

-- Centre-screen banner: red for a threat, gold for information, with the
-- flag of the faction it concerns on both ends; it fades out by itself.
function HUD:BuildBanner()
  if self.banner then return self.banner end
  local create = GetGlobal("CreateFrame")
  local skin = WF.Skin
  if type(create) ~= "function" or not skin then return nil end
  local ok, banner = pcall(create, "Frame", "WarfrontAlertBanner", UIParent)
  if not ok or not banner then return nil end
  banner:SetWidth(BANNER_WIDTH)
  banner:SetHeight(BANNER_HEIGHT)
  banner:SetPoint("TOP", UIParent, "TOP", 0, -190)
  banner:SetFrameStrata("HIGH")
  banner.cloth = skin:Slice3(banner, "banner.red", BANNER_HEIGHT, "BORDER")
  banner.flagLeft = skin:Icon(banner, nil, 34, 56, "ARTWORK")
  banner.flagLeft:SetPoint("TOPLEFT", banner, "TOPLEFT", -14, 6)
  banner.flagRight = skin:Icon(banner, nil, 34, 56, "ARTWORK")
  banner.flagRight:SetPoint("TOPRIGHT", banner, "TOPRIGHT", 14, 6)
  local medallion = skin:Icon(banner, "banner.medallion", 30, 36, "OVERLAY")
  medallion:SetPoint("BOTTOM", banner, "TOP", 0, -12)
  banner.title = banner:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  banner.title:SetPoint("TOP", banner, "TOP", 0, -10)
  banner.title:SetWidth(BANNER_WIDTH - 200)
  banner.text = banner:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  banner.text:SetPoint("TOP", banner, "TOP", 0, -30)
  banner.text:SetWidth(BANNER_WIDTH - 200)
  banner:SetScript("OnUpdate", function()
    local now = WF.Now and WF.Now() or 0
    local age = now - (banner.shownAt or now)
    if age >= BANNER_SHOWN + BANNER_FADE then
      banner:Hide()
    elseif age > BANNER_SHOWN then
      banner:SetAlpha(1 - (age - BANNER_SHOWN) / BANNER_FADE)
    end
  end)
  banner:Hide()
  self.banner = banner
  return banner
end

-- text goes to chat; the banner shows title (or text) and text. kind "info"
-- draws the gold banner, anything else the red one; side picks the flags.
function HUD:Alert(text, kind, title, side)
  if WF.Print then WF.Print(text) end
  local banner = self:BuildBanner()
  local shown = false
  if banner then
    local skin = WF.Skin
    skin:SetSlice3(banner.cloth, kind == "info" and "banner.gold" or "banner.red")
    local flag = FLAGS[side or (kind == "info" and "N" or "H")] or FLAGS.N
    skin:Apply(banner.flagLeft, flag)
    skin:Apply(banner.flagRight, flag)
    banner.title:SetText(title or text)
    banner.text:SetText(title and text or "")
    banner.shownAt = WF.Now and WF.Now() or 0
    banner:SetAlpha(1)
    banner:Show()
    shown = true
  end
  local raidFrame = not shown and GetGlobal("RaidWarningFrame")
  if raidFrame and type(raidFrame.AddMessage) == "function" then
    shown = pcall(raidFrame.AddMessage, raidFrame, text, 1.0, 0.28, 0.0)
  end
  if not shown then
    local errors = GetGlobal("UIErrorsFrame")
    if errors and type(errors.AddMessage) == "function" then
      pcall(errors.AddMessage, errors, text, 1.0, 0.28, 0.0)
    end
  end
  -- Forever's PlaySound takes a sound kit ID, not the 1.12 sound name.
  local sound = GetGlobal("PlaySound")
  local kits = GetGlobal("SOUNDKIT")
  local kit = type(kits) == "table" and kits.RAID_WARNING or nil
  if type(sound) == "function" and type(kit) == "number" then pcall(sound, kit) end
end

function HUD:OnCaptureEvent(kind, id, side)
  local area = Capture:Capturable(id)
  if not area then return end
  local where = AreaName(area) .. " (" .. tostring(area.map) .. ")"
  if kind == "ALERT" then
    self:Alert("The " .. FactionName(side) .. " is attacking " .. where .. "!", "threat",
      "Enemy capture at " .. AreaName(area) .. "!", side)
  elseif kind == "CAPTURED" and WF.Print then
    WF.Print("The " .. FactionName(side) .. " captured " .. where .. ".")
  end
end

if Capture then
  Capture:OnEvent(function(kind, id, side) HUD:OnCaptureEvent(kind, id, side) end)
end

local create = GetGlobal("CreateFrame")
if type(create) == "function" then
  local ok, driver = pcall(create, "Frame", "WarfrontCaptureHUDDriver", UIParent)
  if ok and driver and type(driver.SetScript) == "function" then
    driver:SetScript("OnUpdate", function(_, delta)
      local elapsed = type(delta) == "number" and delta or 0
      HUD:AnimateBar(elapsed)
      local now = WF.Now and WF.Now() or 0
      if type(now) ~= "number" or (HUD.lastAt and now - HUD.lastAt < UPDATE_INTERVAL) then return end
      HUD.lastAt = now
      local updated, err = pcall(HUD.Update, HUD)
      if not updated and WF.RecordError then WF.RecordError("capture HUD", err) end
    end)
    HUD.driver = driver
  end
end
