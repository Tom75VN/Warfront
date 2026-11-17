-- Decision 0102 section 7: a read-only archive, separate from the live chain.
local WF = Warfront
local Window = WF.MainWindow
local K = Window.Kit
local Page = { items = {} }
Window.CampaignHistory = Page

function Page:Entries()
  local data = WF.Import and WF.Import.data
  local ruleset = WF.Ruleset
  if not data or not ruleset or data.scope ~= ruleset:Scope() or data.region ~= ruleset:Region() then return {}, false end
  if not data.campaignHistory then return {}, false end
  if self.source ~= data.campaignHistory then
    self.source, self.items = data.campaignHistory, {}
    for _, row in ipairs(self.source) do self.items[#self.items + 1] = row end
    table.sort(self.items, function(a, b) return a.n > b.n or (a.n == b.n and a.s > b.s) end)
    if self.list then self.list.offset = 0 end
  end
  return self.items, true
end

function Page:Describe(entry)
  local winner = entry.winner == "-" and WF.L("Draw") or WF.L("%s victory", K.FactionName(entry.winner))
  return WF.L("Campaign %d", entry.n), winner,
    WF.L("%s to %s", date("%Y-%m-%d %H:%M", entry.s), date("%Y-%m-%d %H:%M", entry.e)),
    WF.L("Duration: %d d %d h %d min", math.floor((entry.e - entry.s) / 86400),
      math.floor((entry.e - entry.s) / 3600) % 24, math.floor((entry.e - entry.s) / 60) % 60),
    WF.L("Settlements held: Alliance %d / Horde %d", entry.a, entry.h),
    WF.L("Recorded captures: %d", entry.captures)
end

local function Tooltip(row)
  if not row.entry then return end
  local title, result, dates, duration, held, captures = Page:Describe(row.entry)
  GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
  GameTooltip:AddLine(title, 1, 0.82, 0)
  for _, text in ipairs({ result, dates, duration, held, captures,
      WF.L(row.entry.reason == "capital" and "Capital captured" or "Time elapsed") }) do
    GameTooltip:AddLine(text, 1, 1, 1, true)
  end
  GameTooltip:Show()
end

function Page:Build()
  local panel = K.NewPanel(self, "Campaign history", 0, 0, K.CONTENT_WIDTH, K.CONTENT_HEIGHT)
  self.back = K.NewButton(panel, "dark", 100, 20, "Back", function() Window:Select("journal") end)
  K.Place(self.back, panel, K.CONTENT_WIDTH - 110, -25)
  self.note = K.NewText(panel, "GameFontHighlightSmall", 12, -28, K.CONTENT_WIDTH - 130)
  self.note:SetHeight(30)
  self.empty = K.NewText(panel, "GameFontHighlight", 24, -110, K.CONTENT_WIDTH - 48, "CENTER")
  self.empty:SetHeight(100)
  self.list = K.NewList(panel, 5, 72, -64, function(row)
    local width = row:GetWidth() - 16
    row.title = K.NewText(row, "GameFontNormalSmall", 8, -4, width * 0.45)
    row.result = K.NewText(row, "GameFontHighlightSmall", width * 0.45 + 8, -4, width * 0.55, "RIGHT")
    row.dates = K.NewText(row, "GameFontHighlightSmall", 8, -21, width)
    row.held = K.NewText(row, "GameFontHighlightSmall", 8, -37, width)
    row.duration = K.NewText(row, "GameFontDisableSmall", 8, -53, width)
    row:EnableMouse(true)
    row:SetScript("OnEnter", Tooltip)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row:SetScript("OnHide", function() if GameTooltip:IsOwned(row) then GameTooltip:Hide() end end)
    row:EnableMouseWheel(true)
    row:SetScript("OnMouseWheel", function(_, delta) K.Scroll.Wheel(self.list, delta) end)
  end)
end

function Page:Update()
  local items, available = self:Entries()
  K.SetText(self.note, "Completed campaigns from the last three months.")
  K.SetText(self.empty, available and "No completed campaigns to display yet."
    or "Use an up-to-date Warfront Companion to view campaign history.")
  K.Show(self.empty, #items == 0)
  K.FillList(self.list, #items, function(row, index)
    local entry = items[index]
    if row.entry ~= entry and GameTooltip:IsOwned(row) then GameTooltip:Hide() end
    row.entry = entry
    local title, result, dates, duration, held = self:Describe(entry)
    K.SetText(row.title, title)
    K.SetText(row.result, result)
    K.Skin():Color(row.result, entry.winner == "-" and "N" or entry.winner)
    K.FitText(row.dates, dates, row:GetWidth() - 16)
    K.FitText(row.held, held, row:GetWidth() - 16)
    K.FitText(row.duration, duration .. "  -  " .. WF.L(entry.reason == "capital" and "Capital captured" or "Time elapsed"), row:GetWidth() - 16)
  end)
end

function Page:Summary()
  local items = self:Entries()
  return WF.L("%d completed campaigns", #items)
end

Window:AddTab("campaign_history", "Campaign history", Page, nil, true)
