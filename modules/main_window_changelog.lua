local WF = Warfront
local Window = WF.MainWindow
local K = Window.Kit
-- What's new: the release notes of data/changelog.lua on one scrolling page,
-- opened from the version beside the title or in the footer (2026-11-24, user).
local Page = {}
local UI = {
  TOP = 30, PAD = 12, BAR = 6, THUMB_MIN = 12, WHEEL = 40, BULLET = 12,
  VERSION_GAP = 14, SECTION_GAP = 6, AFTER_TITLE = 3, AFTER_LINE = 3,
}

-- Wrapped at spaces over as many lines as needed, never cut with "...".
local function NewPiece(sheet, template)
  local text = K.Skin():Text(sheet, template)
  text:SetJustifyV("TOP")
  if text.SetWordWrap then text:SetWordWrap(true) end
  if text.SetNonSpaceWrap then text:SetNonSpaceWrap(false) end
  if text.SetMaxLines then text:SetMaxLines(0) end
  return text
end

function Page:ScrollTo(offset)
  offset = math.floor((offset or 0) + 0.5)
  if offset > self.range then offset = self.range end
  if offset < 0 then offset = 0 end
  self.offset = offset
  self.scroll:SetVerticalScroll(offset)
  local bar, view = self.bar, self.viewHeight
  if self.range <= 0 then
    bar.thumbHeight = nil
    bar.thumb:Hide()
    return
  end
  local thumb = math.max(UI.THUMB_MIN, math.floor(view * view / (view + self.range) + 0.5))
  bar.thumbTop, bar.thumbHeight = math.floor((view - thumb) * offset / self.range + 0.5), thumb
  bar.thumb:ClearAllPoints()
  bar.thumb:SetPoint("TOPLEFT", bar, "TOPLEFT", 0, -bar.thumbTop)
  bar.thumb:SetHeight(thumb)
  bar.thumb:Show()
end

-- The scrollbar of the Guide's reader: wheel, click on the track, drag the thumb.
function Page:BuildBar(panel)
  local bar = K.NewFrame(panel, UI.BAR, self.viewHeight)
  K.Place(bar, panel, panel.width - 6 - UI.BAR, -UI.TOP)
  local track = bar:CreateTexture(nil, "BACKGROUND")
  track:SetTexture("Interface\\Buttons\\WHITE8X8")
  track:SetVertexColor(0, 0, 0, 0.35)
  track:SetAllPoints(bar)
  bar.thumb = bar:CreateTexture(nil, "ARTWORK")
  bar.thumb:SetTexture("Interface\\Buttons\\WHITE8X8")
  bar.thumb:SetVertexColor(0.85, 0.7, 0.35, 0.85)
  bar.thumb:SetWidth(UI.BAR)
  bar.thumb:Hide()
  local function Depth()
    local cursor = K.GetGlobal("GetCursorPosition")
    local top = bar:GetTop()
    if type(cursor) ~= "function" or not top then return nil end
    local _, y = cursor()
    return top - y / bar:GetEffectiveScale()
  end
  local function Drag()
    local depth, room = Depth(), self.viewHeight - (bar.thumbHeight or 0)
    if not depth or not bar.thumbHeight or room <= 0 then return end
    self:ScrollTo((depth - bar.grab) / room * self.range)
  end
  bar:EnableMouse(true)
  bar:EnableMouseWheel(true)
  bar:SetScript("OnMouseWheel", function(_, delta) self:ScrollTo(self.offset - (delta or 0) * UI.WHEEL) end)
  bar:SetScript("OnMouseDown", function(_, button)
    if button and button ~= "LeftButton" then return end
    local depth = Depth()
    if not depth or not bar.thumbHeight then return end
    local within = depth - bar.thumbTop
    if within >= 0 and within <= bar.thumbHeight then bar.grab = within else bar.grab = bar.thumbHeight / 2 end
    bar:SetScript("OnUpdate", Drag)
    Drag()
  end)
  bar:SetScript("OnMouseUp", function() bar:SetScript("OnUpdate", nil) end)
  bar:SetScript("OnHide", function() bar:SetScript("OnUpdate", nil) end)
  self.bar = bar
end

-- Each text hangs under the previous one with no fixed height, so the client
-- wraps it freely; Measure reads the page's height once the layout settles.
function Page:Render()
  local sheet, width = self.sheet, self.sheetWidth
  local previous, previousX, gap = nil, 0, 0
  local function Add(template, text, x, color)
    local piece = NewPiece(sheet, template)
    if previous then
      piece:SetPoint("TOPLEFT", previous, "BOTTOMLEFT", x - previousX, -gap)
    else
      piece:SetPoint("TOPLEFT", sheet, "TOPLEFT", x, 0)
    end
    piece:SetWidth(width - x)
    piece:SetHeight(0)
    if color then K.Skin():Color(piece, color) end
    piece:SetText(text)
    previous, previousX = piece, x
    return piece
  end
  for index, release in ipairs(WF.Changelog or {}) do
    gap = index > 1 and UI.VERSION_GAP or 0
    Add("GameFontNormal", "v" .. release.version .. "   " .. K.Paint("DIM", release.date), 0)
    for _, section in ipairs(release.sections) do
      gap = UI.SECTION_GAP
      Add("GameFontNormalSmall", WF.L(section[1]), 0, "WHITE")
      gap = UI.AFTER_TITLE
      for _, line in ipairs(section[2]) do
        local piece = Add("GameFontHighlightSmall", WF.L(line), UI.BULLET)
        local dot = sheet:CreateTexture(nil, "ARTWORK")
        dot:SetTexture("Interface\\Buttons\\WHITE8X8")
        dot:SetVertexColor(1, 0.82, 0)
        dot:SetWidth(4)
        dot:SetHeight(4)
        dot:SetPoint("TOPLEFT", piece, "TOPLEFT", 3 - UI.BULLET, -4)
        gap = UI.AFTER_LINE
      end
    end
  end
  self.last = previous
end

function Page:Measure()
  local top = self.sheet:GetTop()
  local bottom = self.last and self.last:GetBottom()
  if not top or not bottom then return end
  local height = math.max(1, math.ceil(top - bottom) + UI.AFTER_LINE)
  self.sheet:SetHeight(height)
  self.range = math.max(0, height - self.viewHeight)
  self:ScrollTo(self.offset)
end

function Page:Build()
  local panel = K.NewPanel(self, "What's new", 0, 0, K.CONTENT_WIDTH, K.CONTENT_HEIGHT)
  local create = K.GetGlobal("CreateFrame")
  local width = panel.width - 2 * UI.PAD - UI.BAR - 2
  local scroll = create("ScrollFrame", nil, panel)
  scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", UI.PAD, -UI.TOP)
  scroll:SetWidth(width)
  scroll:SetHeight(K.CONTENT_HEIGHT - UI.TOP - 10)
  local sheet = create("Frame", nil, scroll)
  sheet:SetWidth(width)
  sheet:SetHeight(1)
  scroll:SetScrollChild(sheet)
  self.scroll, self.sheet, self.sheetWidth = scroll, sheet, width
  self.viewHeight, self.offset, self.range = K.CONTENT_HEIGHT - UI.TOP - 10, 0, 0
  local function Wheel(_, delta) self:ScrollTo(self.offset - (delta or 0) * UI.WHEEL) end
  scroll:EnableMouseWheel(true)
  scroll:SetScript("OnMouseWheel", Wheel)
  self:BuildBar(panel)
  self:Render()
  -- Opened again: back to the newest version.
  scroll:SetScript("OnShow", function() self:ScrollTo(0) end)
end

-- Wrapped heights settle once the client lays the texts out.
function Page:Update() self:Measure() end

-- The hovered version turns to the accent colour; a newer Warfront keeps
-- both red otherwise (decision 0108).
function Window:PaintVersion()
  local notice = WF.Version and WF.Version:Notice()
  local plain = "v" .. tostring(WF.version)
  for _, text in ipairs({ self.versionLabel, self.titleVersion }) do
    local color = text.hovered and "GOLD" or (notice and "BAD")
    K.SetText(text, color and K.Paint(color, plain) or plain)
  end
end

-- A click on a version text opens What's new, a second click goes back.
function Window:BindVersion(text)
  if not text then return end
  local parent = text:GetParent()
  local hit = K.GetGlobal("CreateFrame")("Button", nil, parent)
  hit:SetPoint("TOPLEFT", text, "TOPLEFT", -2, 2)
  hit:SetPoint("BOTTOMRIGHT", text, "BOTTOMRIGHT", 2, -2)
  hit:SetFrameLevel((parent:GetFrameLevel() or 0) + 1)
  hit:SetScript("OnClick", function() Window:ToggleHidden("changelog") end)
  hit:SetScript("OnEnter", function() text.hovered = true; Window:PaintVersion() end)
  hit:SetScript("OnLeave", function() text.hovered = nil; Window:PaintVersion() end)
  text.hit = hit
end

Window:AddTab("changelog", "What's new", Page, nil, true)
