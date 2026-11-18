local WF = Warfront

-- Download links of the optional Warfront Companion (decision 0046). The game
-- cannot open a browser: a small window shows one read-only field per
-- installer, its text selected so the player copies it with Ctrl+C. Opened
-- from the Territory tab and the Synchronization drawer while the companion
-- does not help (Companion:Helping). Only local drawing; it reads nothing.
local Download = {
  LINKS = {
    { label = "Windows",
      url = "https://github.com/Tom75VN/Warfront-Companion/releases/latest/download/Warfront-Companion-win-x64.msi" },
    { label = "Mac (Apple Silicon)",
      url = "https://github.com/Tom75VN/Warfront-Companion/releases/latest/download/Warfront-Companion-osx-arm64.dmg" },
  },
  WIDTH = 600, HEIGHT = 166, LEFT = 14, FIELD_H = 22, ROW_TOP = -50, ROW_STEP = 44,
}
WF.CompanionDownload = Download

local function GetGlobal(name)
  if WF.Compat and WF.Compat.Global then return WF.Compat.Global(name) end
  if _G then return _G[name] end
  return nil
end

local function L(text)
  if WF.L then return WF.L(text) end
  return text
end

-- True while the companion is loaded and does not feed Warfront yet.
function Download.Wanted()
  local companion = WF.Companion
  return companion ~= nil and companion.Helping ~= nil and not companion:Helping()
end

-- Read-only: any edit puts the link back, selected.
local function Select(box)
  if box:GetText() ~= box.url then box:SetText(box.url) end
  box:HighlightText()
end

function Download:Field(parent, link, top)
  local skin = WF.Skin
  local label = skin:Text(parent, "GameFontNormalSmall", "LEFT")
  label:SetPoint("TOPLEFT", parent, "TOPLEFT", self.LEFT, top)
  label:SetText(L(link.label))
  local holder = GetGlobal("CreateFrame")("Frame", nil, parent)
  holder:SetWidth(self.WIDTH - 2 * self.LEFT)
  holder:SetHeight(self.FIELD_H)
  holder:SetPoint("TOPLEFT", parent, "TOPLEFT", self.LEFT, top - 14)
  skin:RowBackground(holder, self.FIELD_H)
  local box = GetGlobal("CreateFrame")("EditBox", nil, holder)
  box:SetPoint("TOPLEFT", holder, "TOPLEFT", 8, 0)
  box:SetPoint("BOTTOMRIGHT", holder, "BOTTOMRIGHT", -8, 0)
  box:SetAutoFocus(false)
  box:SetFontObject(GetGlobal("GameFontHighlightSmall"))
  box.url = link.url
  box:SetText(link.url)
  box:SetCursorPosition(0)
  box:SetScript("OnEditFocusGained", Select)
  box:SetScript("OnMouseUp", Select)
  box:SetScript("OnTextChanged", function(edit) if edit:GetText() ~= edit.url then Select(edit) end end)
  box:SetScript("OnEditFocusLost", function(edit) edit:HighlightText(0, 0) end)
  box:SetScript("OnEscapePressed", function() Download:Hide() end)
  box:SetScript("OnEnterPressed", function(edit) edit:ClearFocus() end)
  return box
end

function Download:Build()
  if self.frame then return self.frame end
  local skin = WF.Skin
  local frame = skin:Panel(GetGlobal("UIParent"), "Warfront Companion", self.WIDTH, self.HEIGHT)
  frame:SetPoint("CENTER", GetGlobal("UIParent"), "CENTER", 0, 80)
  frame:SetFrameStrata("DIALOG")
  frame:EnableMouse(true)
  frame:Hide()
  local close = skin:CloseButton(frame, 18, function() Download:Hide() end)
  close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -5, -4)
  local pitch = skin:Text(frame, "GameFontHighlightSmall", "LEFT")
  pitch:SetPoint("TOPLEFT", frame, "TOPLEFT", self.LEFT, -30)
  pitch:SetWidth(self.WIDTH - 2 * self.LEFT)
  local companion = WF.Companion
  pitch:SetText(L(companion and companion.HINT_PITCH or ""))
  frame.boxes = {}
  for index = 1, #self.LINKS do
    frame.boxes[index] = self:Field(frame, self.LINKS[index], self.ROW_TOP - (index - 1) * self.ROW_STEP)
  end
  local hint = skin:Text(frame, "GameFontDisableSmall", "LEFT")
  hint:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", self.LEFT, 12)
  hint:SetWidth(self.WIDTH - 2 * self.LEFT)
  hint:SetText(L("Click a link, then press Ctrl+C (Cmd+C on Mac) and paste it into your browser."))
  self.frame = frame
  return frame
end

function Download:Show()
  local frame = self:Build()
  frame:Show()
  -- Windows first: its link is ready to copy at once.
  frame.boxes[1]:SetFocus()
  Select(frame.boxes[1])
end

function Download:Hide()
  local frame = self.frame
  if not frame then return end
  for index = 1, #frame.boxes do frame.boxes[index]:ClearFocus() end
  frame:Hide()
end

function Download:Toggle()
  if self.frame and self.frame:IsShown() then self:Hide() else self:Show() end
end
