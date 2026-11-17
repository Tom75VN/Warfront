local WF = Warfront
local Window = WF.MainWindow
local K = Window.Kit
local History = WF.AlertHistory
local Journal = { category = "all", items = {} }

local function Tooltip(row)
  if not row.entry then return end
  GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
  local color = K.Skin().COLORS[row.entry.side] or K.Skin().COLORS.N
  GameTooltip:AddLine(History:Category(row.entry.category), color[1], color[2], color[3])
  GameTooltip:AddLine(row.entry.text, 1, 1, 1, true)
  GameTooltip:AddLine(WF.L("Received: %s", date("%Y-%m-%d %H:%M:%S", row.entry.at)), 0.7, 0.7, 0.7)
  GameTooltip:Show()
end

function Journal:Build()
  self.filters = {}
  local filters = K.NewPanel(self, "Alerts", 0, 0, 128, K.CONTENT_HEIGHT)
  local guide = Window.Guide
  filters.auctionBackground = guide:AuctionBackground(filters, guide.AUCTION.MENU)
  for index, category in ipairs(History.categories) do
    local key, title = category[1], category[2]
    local button = K.GetGlobal("CreateFrame")("Button", nil, filters)
    button:SetWidth(116)
    button:SetHeight(22)
    button.normal = button:CreateTexture(nil, "BACKGROUND")
    button.normal:SetAtlas(guide.AUCTION.ROW, false)
    button.normal:SetHeight(32)
    button.normal:SetPoint("TOPLEFT", button, "TOPLEFT", -2, 0)
    button.normal:SetPoint("TOPRIGHT", button, "TOPRIGHT", 2, 0)
    button.mark = button:CreateTexture(nil, "BORDER")
    button.mark:SetAtlas(guide.AUCTION.HOVER, false)
    button.mark:SetAllPoints(button)
    button.mark:SetBlendMode("BLEND")
    button.hover = button:CreateTexture(nil, "HIGHLIGHT")
    button.hover:SetAtlas(guide.AUCTION.HOVER, false)
    button.hover:SetAllPoints(button)
    button.hover:SetBlendMode("BLEND")
    button.label = K.NewText(button, "GameFontNormalSmall", 8, -3, 100)
    button:SetScript("OnClick", function()
      self.category, self.revision, self.list.offset = key, nil, 0
      self:Update()
    end)
    K.Place(button, filters, 6, -24 - (index - 1) * 22)
    self.filters[index] = button
  end
  self.campaigns = K.NewButton(filters, "dark", 116, 24, "Campaigns", function() Window:Select("campaign_history") end)
  K.Place(self.campaigns, filters, 6, -34 - #History.categories * 22)
  local panel = K.NewPanel(self, "Journal", 132, 0, K.CONTENT_WIDTH - 132, K.CONTENT_HEIGHT)
  self.empty = K.NewText(panel, "GameFontHighlightSmall", 16, -50, panel.width - 32, "CENTER")
  self.empty:SetHeight(60)
  self.list = K.NewList(panel, 7, 54, -30, function(row)
    row.faction = K.Skin():Icon(row, nil, 20, 24)
    K.Place(row.faction, row, 8, -14)
    row.category = K.NewText(row, "GameFontNormalSmall", 36, -4, 192)
    row.age = K.NewText(row, "GameFontHighlightSmall", row:GetWidth() - 150, -4, 142, "RIGHT")
    row.text = K.NewText(row, "GameFontHighlightSmall", 36, -22, row:GetWidth() - 44)
    row.text:SetHeight(28)
    row:EnableMouse(true)
    row:SetScript("OnEnter", Tooltip)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row:SetScript("OnHide", function() if GameTooltip:IsOwned(row) then GameTooltip:Hide() end end)
    row:EnableMouseWheel(true)
    row:SetScript("OnMouseWheel", function(_, delta) K.Scroll.Wheel(self.list, delta) end)
  end)
end

function Journal:Update()
  if self.revision ~= History.revision then
    -- Retain the first visible event while the player reads older entries.
    local anchor = self.list.offset > 0 and self.items[self.list.offset + 1]
    self.items = {}
    for _, entry in ipairs(History:Entries()) do
      if self.category == "all" or entry.category == self.category then
        self.items[#self.items + 1] = entry
        if entry == anchor then self.list.offset = #self.items - 1 end
      end
    end
    self.revision = History.revision
  end
  for index, button in ipairs(self.filters) do
    local category = History.categories[index]
    K.Show(button.mark, self.category == category[1])
    K.Skin():Color(button.label, self.category == category[1] and "GOLD" or "WHITE")
    K.FitText(button.label, WF.L(category[2]), 100)
  end
  K.SetText(self.empty, "No events to display.")
  K.Show(self.empty, #self.items == 0)
  local now = WF.Epoch()
  K.FillList(self.list, #self.items, function(row, index)
    local entry = self.items[index]
    if row.entry ~= entry and GameTooltip:IsOwned(row) then GameTooltip:Hide() end
    row.entry = entry
    local side = (entry.side == "A" or entry.side == "H") and entry.side or "N"
    if side ~= "N" then K.Skin():Apply(row.faction, side == "A" and "badge.alliance" or "badge.horde") end
    K.Show(row.faction, side ~= "N")
    K.Skin():Color(row.category, side)
    K.Skin():Color(row.text, "WHITE")
    K.SetText(row.category, History:Category(entry.category))
    K.SetText(row.age, History:Age(entry.at, now))
    -- Stored text is already localized; do not translate names a second time.
    row.text:SetText(entry.text)
    entry.read = true
  end)
end

function Journal:Summary() return WF.L("%d events", #self.items) end

function Window:BuildJournalButton(parent, x, y)
  self.journal = K.NewButton(parent, "tab", self.JOURNAL_WIDTH, 26, "", function() self:ToggleHidden(self.selected == "campaign_history" and "campaign_history" or "journal") end)
  K.Place(self.journal, parent, x, y)
  self.journal.icon = K.Skin():Icon(self.journal, nil, 19, 19, "ARTWORK")
  self.journal.icon:SetTexture("Interface\\AddOns\\Warfront\\media\\Textures\\UI\\Journal\\JournalTabIcon")
  self.journal.icon:SetPoint("CENTER", self.journal, "CENTER", 0, -1)
  self.journal.new = K.NewText(self.journal, "GameFontNormalSmall", self.JOURNAL_WIDTH - 15, 3, 12, "CENTER")
  self.journal.new:SetText("*")
  local enter, leave = self.journal:GetScript("OnEnter"), self.journal:GetScript("OnLeave")
  self.journal:SetScript("OnEnter", function(button)
    if enter then enter(button) end
    GameTooltip:SetOwner(button, "ANCHOR_BOTTOMLEFT")
    GameTooltip:AddLine(WF.L("Journal"), 1, 1, 1)
    GameTooltip:AddLine(WF.L("Recent events, kept between sessions."), 0.8, 0.8, 0.8, true)
    GameTooltip:AddLine(WF.L("%d unread events", History:Unread()), 1, 0.82, 0)
    GameTooltip:Show()
  end)
  self.journal:SetScript("OnLeave", function(button)
    if leave then leave(button) end
    GameTooltip:Hide()
  end)
  self:RefreshJournalButton()
end

function Window:RefreshJournalButton()
  if not self.journal then return end
  K.Skin():SetButton(self.journal, "", true, self.selected == "journal" or self.selected == "campaign_history")
  K.Show(self.journal.new, History:Unread() > 0)
end

Window:AddTab("journal", "Journal", Journal, nil, true)
