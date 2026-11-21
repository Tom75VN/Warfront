Warfront = Warfront or {}

local WF = Warfront
local Allies = WF.Allies

-- The invitation popup and /wf match (decision 0127 point C). Player-facing
-- text speaks only of what the player sees and chooses.
local TEXT = {
  title = "Help make Warfront better for everyone",
  body = "Become BattleTag friends with a volunteer from the other faction.\n\n"
    .. "Every cross-faction friend makes the war map faster and more accurate, for you and for everyone.\n\n"
    .. "Only that friend sees your BattleTag. Stop anytime: /wf allies off.",
  join = "Join",
  later = "Later",
  hide = "Don't show again",
  joined = "You volunteer to meet allies across the front. /wf allies off stops it.",
  left = "You no longer volunteer to meet allies across the front.",
  readOnly = "This choice cannot be saved right now.",
  unavailable = "Finding allies across the front is not available yet.",
  partner = "%s (%s) would like to become your BattleTag friend. Accept to share your BattleTag with this player once you have both agreed.",
  ready = "%s (%s) accepted. Open Add Friend and confirm the request yourself.",
  accept = "Accept",
  add = "Add Friend",
  block = "Decline and block",
  waiting = "Looking for an ally from the other faction. You can keep playing.",
  cloud = "Manage your ally search in the companion. After sharing a BattleTag, wait seven days before switching to the in-game search.",
  failed = "This invitation is no longer available. Try again later.",
}
Allies.TEXT = TEXT

function Allies:ApplyScale()
  local factor = WF.Preferences and WF.Preferences:ScaleFactor() or 1
  for _, panel in ipairs({ self.popup, self.partnerPopup }) do
    if panel and type(panel.SetScale) == "function" then panel:SetScale(factor) end
  end
end

-- Grow a panel so its wrapped body text never reaches the controls below it,
-- whatever the language. `below` is the space the controls need under the text.
local function FitHeight(panel, minHeight, below)
  local body = panel and panel.body
  if not body or type(body.GetStringHeight) ~= "function" then return end
  local textHeight = tonumber(body:GetStringHeight()) or 0
  local need = WF.Skin.HEADER + 14 + math.ceil(textHeight) + below
  panel:SetHeight(need > minHeight and need or minHeight)
end

local function Build()
  local skin = WF.Skin
  local create = _G.CreateFrame
  if type(create) ~= "function" or not skin or not skin.Panel then return nil end
  local panel = skin:Panel(UIParent, TEXT.title, 380, 206)
  panel:SetScale(WF.Preferences and WF.Preferences:ScaleFactor() or 1)
  panel:SetFrameStrata("DIALOG")
  panel:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
  panel:EnableMouse(true)
  panel:Hide()

  local body = skin:Text(panel, "GameFontHighlight", "LEFT")
  body:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -(skin.HEADER + 14))
  body:SetWidth(348)
  body:SetText(WF.L(TEXT.body))
  panel.body = body

  local check = create("CheckButton", nil, panel, "UICheckButtonTemplate")
  check:SetWidth(24)
  check:SetHeight(24)
  check:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 12, 40)
  local label = skin:Text(panel, "GameFontNormalSmall", "LEFT")
  label:SetPoint("LEFT", check, "RIGHT", 2, 0)
  label:SetText(WF.L(TEXT.hide))
  panel.check = check

  local function Close(join)
    if check:GetChecked() then Allies:SetPopupHidden(true) end
    if join then
      if Allies:SetOptIn(true) then WF.Print(TEXT.joined) else WF.Print(TEXT.readOnly) end
    end
    panel:Hide()
  end

  local join = skin:Button(panel, "red", 150, 24, function() Close(true) end)
  join:SetPoint("BOTTOMRIGHT", panel, "BOTTOM", -6, 12)
  skin:SetButton(join, TEXT.join)
  local later = skin:Button(panel, "dark", 150, 24, function() Close(false) end)
  later:SetPoint("BOTTOMLEFT", panel, "BOTTOM", 6, 12)
  skin:SetButton(later, TEXT.later)
  -- Forever's own close button (atlas RedButton-Exit), our click handler.
  local close = create("Button", nil, panel, "UIPanelCloseButtonNoScripts")
  close:SetWidth(22)
  close:SetHeight(22)
  close:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -2, -1)
  close:SetScript("OnClick", function() Close(false) end)
  return panel
end

function Allies:ShowPopup()
  if not self:IsAvailable() or self:CloudLocked() then return false end
  if not self.popup then
    local ok, panel = pcall(Build)
    if not ok or not panel then
      WF.RecordError("allies popup", ok and "unavailable" or panel)
      return false
    end
    self.popup = panel
  end
  self.popup.check:SetChecked(self:PopupHidden())
  -- Checkbox top sits 64 px above the bottom edge; keep a 12 px gap.
  FitHeight(self.popup, 206, 76)
  self.popup:Show()
  return true
end

-- /wf match [on|off] (/wf allies remains a compatibility alias)
function Allies:Command(rest)
  local action = string.lower(string.match(rest or "", "^%s*(%S*)") or "")
  if action ~= "off" and not self:IsAvailable() then
    WF.Print(TEXT.unavailable)
    return
  end
  if self:CloudLocked() and (action == "on" or action == "off" or #self:MatchRows() == 0) then WF.Print(TEXT.cloud) return end
  if action == "on" or action == "off" then
    if not self:SetOptIn(action == "on") then
      WF.Print(TEXT.readOnly)
    else
      WF.Print(action == "on" and TEXT.joined or TEXT.left)
    end
    return
  end
  if self:OptedIn() or #self:MatchRows() > 0 then
    if not self:ShowNextMatch(true) then WF.Print(TEXT.waiting) end
  else
    self:ShowPopup()
  end
end

local dismissed = {}
local function PartnerPanel()
  local skin = WF.Skin
  if not skin or not skin.Panel then return nil end
  local panel = skin:Panel(UIParent, TEXT.title, 460, 230)
  panel:SetScale(WF.Preferences and WF.Preferences:ScaleFactor() or 1)
  panel:SetFrameStrata("DIALOG")
  panel:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
  panel:EnableMouse(true)
  local body = skin:Text(panel, "GameFontHighlight", "LEFT")
  body:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -(skin.HEADER + 14))
  body:SetWidth(428)
  panel.body = body
  local function Later()
    if panel.row then dismissed[panel.row.name] = panel.row.status end
    panel:Hide()
  end
  local primary = skin:Button(panel, "red", 138, 24, function()
    local row = panel.row
    if not row then return end
    local ok
    if row.status == 'ready' then ok = Allies:OpenMatchFriend(row.name)
    else ok = Allies:ConfirmMatch(row.name) end
    if ok then Later() else WF.Print(TEXT.failed) end
  end)
  primary:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 12, 14)
  panel.primary = primary
  local block = skin:Button(panel, "dark", 148, 24, function()
    if panel.row then Allies:DeclineMatch(panel.row.name) end
    Later()
  end)
  block:SetPoint("LEFT", primary, "RIGHT", 6, 0)
  skin:SetButton(block, TEXT.block)
  local later = skin:Button(panel, "dark", 138, 24, Later)
  later:SetPoint("LEFT", block, "RIGHT", 6, 0)
  skin:SetButton(later, TEXT.later)
  local close = _G.CreateFrame("Button", nil, panel, "UIPanelCloseButtonNoScripts")
  close:SetWidth(22) close:SetHeight(22)
  close:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -2, -1)
  close:SetScript("OnClick", Later)
  panel:Hide()
  return panel
end

function Allies:ShowNextMatch(force)
  if not self:CanPrompt() or (self.popup and self.popup:IsShown()) then return false end
  local current = {} for _, row in ipairs(self:MatchRows()) do current[row.name] = row end
  for name in pairs(dismissed) do if not current[name] then dismissed[name] = nil end end
  if self.partnerPopup and self.partnerPopup:IsShown() then
    local old = self.partnerPopup.row
    if old and current[old.name] and current[old.name].status == old.status then return true end
    self.partnerPopup:Hide()
  end
  for _, row in ipairs(self:MatchRows()) do
    if row.status ~= 'waiting' and (force or dismissed[row.name] ~= row.status) then
      if not self.partnerPopup then self.partnerPopup = PartnerPanel() end
      local panel = self.partnerPopup
      if not panel then return false end
      panel.row = row
      local faction = row.faction == 'HORDE' and WF.L("Horde") or WF.L("Alliance")
      panel.body:SetText(string.format(WF.L(row.status == 'ready' and TEXT.ready or TEXT.partner), row.name, faction))
      WF.Skin:SetButton(panel.primary, row.status == 'ready' and TEXT.add or TEXT.accept)
      -- Buttons top sits 38 px above the bottom edge; keep a 14 px gap.
      FitHeight(panel, 230, 52)
      panel:Show()
      return true
    end
  end
  return false
end
