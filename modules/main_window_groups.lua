local WF = Warfront
local Window = WF.MainWindow
local K = Window.Kit
-- Group Finder (decision 0145): a hidden page opened from the Players page or
-- /wf groups. Two tabs on top: "Find a group" lists the groups of our faction;
-- "My group" lists ours and shows who waits to join. A local view of
-- WF.GroupFinder.
local Page = { view = "find" }
local UI = {
  FOOTER = 30, ROW = 44, APP_ROW = 64, FORM_W = 300, LINE = 26, BUTTON_W = 100, APPLY_H = 92,
  LEVEL_W = 40, LABEL_W = 100,
}
local ROLE_ORDER = { "T", "H", "D" }
local REASONS = { Full = "Full", Level = "Level", Listed = "Listed", ["In group"] = "In group", Closed = "Closed" }
-- Why a Join button is greyed, in its tooltip (2026-11-24, user).
local REASON_TIPS = {
  Listed = "Your group is listed: remove your listing in My group to join another group.",
  Full = "This group is full.",
  ["In group"] = "You are already in this group.",
}
local STATES = {
  invited = "Invited", declined = "Declined", full = "Full", closed = "Closed", level = "Level", expired = "No answer",
}

local function GF() return WF.GroupFinder end

-- The client's class name and colour for a class file name ("WARRIOR").
local function ClassText(classFile)
  if type(classFile) ~= "string" or classFile == "" then return nil, nil end
  local names = K.GetGlobal("LOCALIZED_CLASS_NAMES_MALE")
  local name = type(names) == "table" and type(names[classFile]) == "string" and names[classFile]
    or (string.sub(classFile, 1, 1) .. string.lower(string.sub(classFile, 2)))
  local colors = K.GetGlobal("RAID_CLASS_COLORS")
  local color = type(colors) == "table" and colors[classFile] or nil
  if type(color) == "table" and type(color.r) == "number" and type(color.g) == "number" and type(color.b) == "number" then
    return name, string.format("%02x%02x%02x", color.r * 255, color.g * 255, color.b * 255)
  end
  return name, nil
end

local function Tint(hex, text)
  if not hex then return text end
  return "|cff" .. hex .. text .. "|r"
end

local function LevelRange(low, high)
  if low == 0 and high == 0 then return "" end
  if high == 0 then return string.format(WF.L("Level %d+"), low) end
  if low == 0 then return string.format(WF.L("Up to level %d"), high) end
  return string.format(WF.L("Level %d-%d"), low, high)
end

local function Needs(row)
  local parts = {}
  if row.tanks > 0 then parts[#parts + 1] = row.tanks .. " " .. WF.L("Tank") end
  if row.healers > 0 then parts[#parts + 1] = row.healers .. " " .. WF.L("Healer") end
  if row.dps > 0 then parts[#parts + 1] = row.dps .. " " .. WF.L("Damage") end
  if #parts == 0 then return "" end
  return WF.L("Needs:") .. " " .. table.concat(parts, ", ")
end

-- Text already translated, or a player's own words: never translated again.
local function Raw(text, value)
  value = value or ""
  if text.value ~= value then
    text.value = value
    text:SetText(value)
  end
end

-- Translated, then painted.
local function Painted(color, text) return K.Paint(color, WF.L(text)) end

local function Tooltip(button, title, body)
  local enter, leave = button:GetScript("OnEnter"), button:GetScript("OnLeave")
  button:SetScript("OnEnter", function(frame, ...)
    if enter then enter(frame, ...) end
    local tip = frame.tip
    if not tip then return end
    GameTooltip:SetOwner(frame, "ANCHOR_TOP")
    GameTooltip:AddLine(WF.L(tip[1]), 1, 1, 1)
    if tip[2] then GameTooltip:AddLine(WF.L(tip[2]), 0.8, 0.8, 0.8, 1) end
    GameTooltip:Show()
  end)
  button:SetScript("OnLeave", function(frame, ...)
    if leave then leave(frame, ...) end
    GameTooltip:Hide()
  end)
  button.tip = title and { title, body } or nil
end

local function NewEdit(parent, x, y, width, maxBytes, numeric)
  local holder = K.NewFrame(parent, width, 20)
  K.Place(holder, parent, x, y)
  K.Skin():RowBackground(holder, 20)
  local box = K.GetGlobal("CreateFrame")("EditBox", nil, holder)
  box:SetPoint("TOPLEFT", holder, "TOPLEFT", 6, 0)
  box:SetPoint("BOTTOMRIGHT", holder, "BOTTOMRIGHT", -6, 0)
  box:SetAutoFocus(false)
  box:SetFontObject(K.GetGlobal("GameFontHighlightSmall"))
  if box.SetMaxBytes then box:SetMaxBytes(maxBytes + 1) end
  if numeric and box.SetNumeric then box:SetNumeric(true) end
  box:SetScript("OnEscapePressed", function(edit) edit:ClearFocus() end)
  box:SetScript("OnEnterPressed", function(edit) edit:ClearFocus() end)
  box.holder = holder
  return box
end

-- Find a group --------------------------------------------------------------------

function Page:BuildFind(height)
  local panel = K.NewPanel(self, "Group Finder", 0, 0, K.CONTENT_WIDTH, height)
  self.findPanel = panel
  local slots = math.floor((height - 26) / UI.ROW)
  local rowWidth = panel.width - 12 - K.Scroll.GUTTER
  local textWidth = rowWidth - UI.BUTTON_W - 200
  self.findList = K.NewList(panel, slots, UI.ROW, -24, function(row)
    row.head = K.NewText(row, "GameFontNormalSmall", 8, -5, textWidth)
    row.leader = K.NewText(row, "GameFontHighlightSmall", 8, -23, textWidth)
    row.facts = K.NewText(row, "GameFontHighlightSmall", rowWidth - UI.BUTTON_W - 190, -5, 180, "RIGHT")
    row.needs = K.NewText(row, "GameFontHighlightSmall", rowWidth - UI.BUTTON_W - 190, -23, 180, "RIGHT")
    row.join = K.NewButton(row, "dark", UI.BUTTON_W, 22, "Join", nil)
    K.Place(row.join, row, rowWidth - UI.BUTTON_W - 4, -10)
    Tooltip(row.join)
  end)
  self.empty = K.NewText(panel, "GameFontHighlight", 12, -60, panel.width - 24, "CENTER")
  self:BuildApply(panel)
end

-- The bar that asks the role and an optional note before applying.
function Page:BuildApply(panel)
  local bar = K.Skin():Panel(self.frame, "", panel.width, UI.APPLY_H)
  K.Place(bar, self.frame, 0, -((self.shift or 0) + panel:GetHeight() - UI.APPLY_H))
  bar:SetFrameLevel((panel:GetFrameLevel() or 0) + 20)
  bar:EnableMouse(true)
  bar:Hide()
  self.applyBar = bar
  bar.roleLabel = K.NewText(bar, "GameFontNormalSmall", 12, -32, 80)
  bar.roles = {}
  for index, role in ipairs(ROLE_ORDER) do
    local button = K.NewButton(bar, "tab", 84, 22, GF().ROLES[role], function() Page.applyRole = role Page:PaintApply() end)
    K.Place(button, bar, 96 + (index - 1) * 88, -28)
    bar.roles[role] = button
  end
  bar.noteLabel = K.NewText(bar, "GameFontNormalSmall", 12, -62, 80)
  bar.note = NewEdit(bar, 96, -60, panel.width - 96 - 2 * UI.BUTTON_W - 28, GF().K.NOTE)
  bar.send = K.NewButton(bar, "red", UI.BUTTON_W, 22, "Send request", function() Page:SendApply() end)
  K.Place(bar.send, bar, panel.width - 2 * UI.BUTTON_W - 16, -59)
  bar.cancel = K.NewButton(bar, "dark", UI.BUTTON_W, 22, "Cancel", function() Page:CloseApply() end)
  K.Place(bar.cancel, bar, panel.width - UI.BUTTON_W - 10, -59)
end

function Page:OpenApply(key)
  local row = GF().listings[key]
  if not row then return end
  self.applyKey, self.applyRole = key, self.applyRole or "D"
  local bar = self.applyBar
  Raw(bar.title, string.format(WF.L("Join %s's group"), row.leader))
  K.SetText(bar.roleLabel, "Your role")
  K.SetText(bar.noteLabel, "Note")
  bar.note:SetText("")
  self:PaintApply()
  bar:Show()
end

function Page:PaintApply()
  for role, button in pairs(self.applyBar.roles) do
    K.Skin():SetButton(button, GF().ROLES[role], true, role == self.applyRole)
  end
end

function Page:CloseApply()
  self.applyKey = nil
  self.applyBar.note:ClearFocus()
  self.applyBar:Hide()
end

function Page:SendApply()
  local key = self.applyKey
  if not key then return end
  local ok, why = GF():Apply(key, self.applyRole, self.applyBar.note:GetText())
  self:CloseApply()
  if not ok and why then Window:SetStatus(why, "BAD") end
end

function Page:JoinClicked(key)
  local finder = GF()
  local app = finder.mine[key]
  if app and app.state == "sent" then finder:Withdraw(key) return end
  self:OpenApply(key)
end

function Page:FillFind(now)
  local finder = GF()
  local rows = finder:Rows()
  K.FillList(self.findList, #rows, function(row, index)
    local item = rows[index]
    -- The title and note are the leader's own words, shown untranslated.
    local head = Painted("GOLD", finder.ActivityLabel(item.activity))
    if item.title ~= "" then head = head .. "  " .. item.title end
    Raw(row.head, head)
    local className, hex = ClassText(item.class)
    local leader = Tint(hex, item.leader)
    if item.note ~= "" then leader = leader .. "  " .. K.Paint("DIM", item.note) end
    Raw(row.leader, leader)
    local facts = WF.L(finder.LANGUAGE_NAMES[item.lang] or item.lang) .. "   " .. item.have .. "/" .. item.size
    local range = LevelRange(item.min, item.max)
    if range ~= "" then facts = range .. "   " .. facts end
    Raw(row.facts, facts)
    local needs = Needs(item)
    Raw(row.needs, needs ~= "" and K.Paint("DIM", needs) or "")
    local app = finder.mine[item.key]
    local why = finder:CannotJoin(item)
    local label, enabled, tip = item.auto and "Join" or "Apply", true, nil
    if app and app.state == "sent" then
      label, tip = "Cancel", { "Waiting for the leader", "Click to cancel your request." }
    elseif app and STATES[app.state] then
      label, enabled = STATES[app.state], app.state ~= "invited"
      if app.state == "declined" then enabled = false end
    elseif why then
      label, enabled = REASONS[why] or why, false
      tip = { REASONS[why] or why, REASON_TIPS[why] }
      if why == "Level" then tip = { "Level", LevelRange(item.min, item.max) } end
    elseif item.auto then
      tip = { "Join", "You get an invitation right away." }
    else
      tip = { "Apply", "The leader sees your request and invites you." }
    end
    K.SetAction(row.join, label, Window.JoinRow, item.key, nil, enabled)
    row.join.tip = tip
  end)
  local empty = ""
  if #rows == 0 then empty = "No group is looking for players right now. New groups can take a few minutes to appear." end
  Raw(self.empty, empty ~= "" and Painted("DIM", empty) or "")
  Raw(self.findPanel.title, #rows > 0 and string.format(WF.L("Group Finder (%d)"), #rows) or WF.L("Group Finder"))
  if self.applyKey and not finder.listings[self.applyKey] then self:CloseApply() end
end

function Window:JoinRow(key) Page:JoinClicked(key) end


-- My group ---------------------------------------------------------------------

-- A dropdown in the skin's style: the value on a dark button with the client's
-- dropdown arrow, a list of choices under it. choices = { { value, label } }.
local DROP_ATLAS = "common-dropdown-a-button"
local menus = {}

local function CloseMenus(except)
  for _, menu in ipairs(menus) do
    if menu ~= except then menu:Hide() end
  end
end

local function NewDropdown(parent, x, y, width, choices, onPick)
  local button = K.NewButton(parent, "dark", width, 20, "", nil)
  K.Place(button, parent, x, y)
  local arrow = button:CreateTexture(nil, "OVERLAY")
  arrow:SetWidth(14)
  arrow:SetHeight(14)
  arrow:SetPoint("RIGHT", button, "RIGHT", -4, 0)
  local textures = K.GetGlobal("C_Texture")
  local known, info = false, nil
  if type(textures) == "table" and type(textures.GetAtlasInfo) == "function" then
    known, info = pcall(textures.GetAtlasInfo, DROP_ATLAS)
  end
  if not (known and type(info) == "table" and arrow.SetAtlas and pcall(arrow.SetAtlas, arrow, DROP_ATLAS)) then
    arrow:Hide()
  end
  local menu = K.GetGlobal("CreateFrame")("Frame", nil, parent)
  menu:SetWidth(width)
  menu:SetHeight(#choices * 20 + 8)
  menu:SetPoint("TOPLEFT", button, "BOTTOMLEFT", 0, -2)
  menu:SetFrameStrata("DIALOG")
  menu:SetToplevel(true)
  menu:EnableMouse(true)
  K.Skin():Slice9(menu, "panel", 0.25, "BACKGROUND")
  -- Plain text rows, no button art: white, the selected value gold, a faint
  -- band under the cursor (2026-11-24, user).
  local options = {}
  local create = K.GetGlobal("CreateFrame")
  for index, choice in ipairs(choices) do
    local option = create("Button", nil, menu)
    option:SetWidth(width - 8)
    option:SetHeight(20)
    K.Place(option, menu, 4, -4 - (index - 1) * 20)
    option.hover = K.Skin():RowStripe(option, K.Skin().HOVER_ALPHA)
    option.text = K.Skin():Text(option, "GameFontHighlightSmall", "CENTER")
    option.text:SetPoint("CENTER", option, "CENTER", 0, 0)
    option.text:SetText(WF.L(choice[2]))
    option.value = choice[1]
    option:SetScript("OnEnter", function(row) row.hover:Show() end)
    option:SetScript("OnLeave", function(row) row.hover:Hide() end)
    option:SetScript("OnClick", function()
      menu:Hide()
      button.value = choice[1]
      K.Skin():SetButton(button, choice[2], true)
      onPick(choice[1])
    end)
    options[index] = option
  end
  menu:SetScript("OnShow", function()
    for _, option in ipairs(options) do
      K.Skin():Color(option.text, option.value == button.value and "GOLD" or "WHITE")
    end
  end)
  menu:Hide()
  menus[#menus + 1] = menu
  button.action = function()
    local shown = menu:IsShown()
    CloseMenus()
    if not shown then menu:Show() end
  end
  button.choices = choices
  return button
end

local function SetDropdown(button, value)
  for _, choice in ipairs(button.choices) do
    if choice[1] == value then
      button.value = value
      K.Skin():SetButton(button, choice[2], true)
      return
    end
  end
end

local function Choices(field)
  local finder, out = GF(), {}
  if field == "activity" then
    for _, item in ipairs(finder.ACTIVITIES) do out[#out + 1] = { item.code, item.label } end
  elseif field == "lang" then
    for _, code in ipairs(finder.LANGUAGES) do out[#out + 1] = { code, finder.LANGUAGE_NAMES[code] } end
  else
    for _, size in ipairs(finder.SIZES) do out[#out + 1] = { size, string.format(WF.L("%d players"), size) } end
  end
  return out
end

local function Label(parent, y, text)
  local label = K.NewText(parent, "GameFontNormalSmall", 12, y - 4, UI.LABEL_W)
  K.SetText(label, text)
  return label
end

function Page:BuildCreate(height)
  local form = K.NewPanel(self, "My group", 0, 0, UI.FORM_W, height)
  self.formPanel = form
  local x, wide = 12 + UI.LABEL_W, UI.FORM_W - UI.LABEL_W - 24
  local y = -32
  self.drops = {}
  for _, row in ipairs({ { "activity", "Activity" }, { "lang", "Language" }, { "size", "Group size" } }) do
    Label(form, y, row[2])
    local field = row[1]
    self.drops[field] = NewDropdown(form, x, y, wide, Choices(field), function(value) Page.form[field] = value end)
    y = y - UI.LINE
  end
  self.roleBoxes = {}
  for _, row in ipairs({ { "tanks", "Tanks needed" }, { "healers", "Healers needed" }, { "dps", "Damage needed" } }) do
    Label(form, y, row[2])
    self.roleBoxes[row[1]] = NewEdit(form, x, y, UI.LEVEL_W, 1, true)
    y = y - UI.LINE
  end
  Label(form, y, "Level range")
  self.minLevel = NewEdit(form, x, y, UI.LEVEL_W, 2, true)
  local dash = K.NewText(form, "GameFontHighlightSmall", x + UI.LEVEL_W, y - 4, 20, "CENTER")
  K.SetText(dash, "-")
  self.maxLevel = NewEdit(form, x + UI.LEVEL_W + 20, y, UI.LEVEL_W, 2, true)
  local any = K.NewText(form, "GameFontHighlightSmall", x + 2 * UI.LEVEL_W + 26, y - 4, 70)
  Raw(any, Painted("DIM", "(optional)"))
  y = y - UI.LINE
  local check = K.GetGlobal("CreateFrame")("CheckButton", nil, form, "UICheckButtonTemplate")
  check:SetWidth(24)
  check:SetHeight(24)
  K.Place(check, form, 8, y + 2)
  check:SetScript("OnClick", function(box) Page.form.auto = box:GetChecked() and true or false end)
  check:SetScript("OnEnter", function(box)
    GameTooltip:SetOwner(box, "ANCHOR_TOP")
    GameTooltip:AddLine(WF.L("Join without approval"), 1, 1, 1)
    GameTooltip:AddLine(WF.L("Checked: players who fit join at once. Unchecked: you choose who joins."), 0.8, 0.8, 0.8, 1)
    GameTooltip:Show()
  end)
  check:SetScript("OnLeave", function() GameTooltip:Hide() end)
  self.autoCheck = check
  local checkLabel = K.NewText(form, "GameFontNormalSmall", 34, y - 4, UI.FORM_W - 46)
  K.SetText(checkLabel, "Join without approval")
  y = y - UI.LINE
  Label(form, y, "Title")
  self.titleBox = NewEdit(form, x, y, wide, GF().K.TITLE)
  y = y - UI.LINE
  Label(form, y, "Note")
  self.noteBox = NewEdit(form, x, y, wide, GF().K.NOTE)
  y = y - UI.LINE - 6
  self.publish = K.NewButton(form, "red", 132, 24, "List my group", Window.GroupPublish)
  K.Place(self.publish, form, 12, y)
  self.close = K.NewButton(form, "dark", 132, 24, "Remove listing", function() GF():Close() Page:LoadForm() end)
  K.Place(self.close, form, UI.FORM_W - 144, y)
  self.formNote = K.NewText(form, "GameFontHighlightSmall", 12, y - 32, UI.FORM_W - 24, "LEFT")
  self.formNote:SetHeight(40)
  if self.formNote.SetWordWrap then self.formNote:SetWordWrap(true) end
  form:SetScript("OnHide", function() CloseMenus() end)

  local waiting = K.NewPanel(self, "Waiting to join", UI.FORM_W + K.GAP, 0, K.CONTENT_WIDTH - UI.FORM_W - K.GAP, height)
  self.waitPanel = waiting
  local rowWidth = waiting.width - 12 - K.Scroll.GUTTER
  local slots = math.floor((height - 26) / UI.APP_ROW)
  self.waitList = K.NewList(waiting, slots, UI.APP_ROW, -24, function(row)
    row.name = K.NewText(row, "GameFontNormalSmall", 8, -5, rowWidth - 16)
    row.note = K.NewText(row, "GameFontHighlightSmall", 8, -21, rowWidth - 16)
    local width = math.floor((rowWidth - 24) / 3)
    row.invite = K.NewButton(row, "red", width, 20, "Invite", nil)
    K.Place(row.invite, row, 6, -38)
    row.decline = K.NewButton(row, "dark", width, 20, "Decline", nil)
    K.Place(row.decline, row, 12 + width, -38)
    row.ignore = K.NewButton(row, "dark", width, 20, "Ignore", nil)
    K.Place(row.ignore, row, 18 + 2 * width, -38)
  end)
  self.waitEmpty = K.NewText(waiting, "GameFontHighlightSmall", 12, -60, waiting.width - 24, "CENTER")
end

local function Number(box)
  return tonumber(box:GetText()) or 0
end

-- The form from the listing, or the last one saved.
function Page:LoadForm()
  local form = GF():Form()
  self.form = form
  for field, button in pairs(self.drops) do SetDropdown(button, form[field]) end
  for field, box in pairs(self.roleBoxes) do box:SetText(tostring(form[field] or 0)) end
  self.minLevel:SetText(form.min > 0 and tostring(form.min) or "")
  self.maxLevel:SetText(form.max > 0 and tostring(form.max) or "")
  self.autoCheck:SetChecked(form.auto and true or false)
  self.titleBox:SetText(form.title or "")
  self.noteBox:SetText(form.note or "")
end

function Page:Publish()
  local form = self.form
  for field, box in pairs(self.roleBoxes) do form[field] = math.min(9, Number(box)) end
  form.min, form.max = Number(self.minLevel), Number(self.maxLevel)
  form.auto = self.autoCheck:GetChecked() and true or false
  form.title, form.note = self.titleBox:GetText(), self.noteBox:GetText()
  for _, box in ipairs({ self.minLevel, self.maxLevel, self.titleBox, self.noteBox }) do box:ClearFocus() end
  for _, box in pairs(self.roleBoxes) do box:ClearFocus() end
  CloseMenus()
  local ok, why = GF():Publish(form)
  if ok then
    Window:SetStatus("Your group is listed in the Group Finder.", "GOOD")
    self:LoadForm()
  else
    Window:SetStatus(why or "Check the group settings.", "BAD")
  end
end

function Window:GroupPublish() Page:Publish() end

function Window:GroupAnswer(key, action)
  local finder = GF()
  if action == "invite" then
    local ok, why = finder:Accept(key)
    if not ok and why then Window:SetStatus(why, "BAD") end
  elseif action == "decline" then
    finder:Decline(key)
  else
    local app = finder.applicants[key]
    if app then finder:Ignore(app.identity) end
  end
end

function Page:FillCreate(now)
  local finder = GF()
  local own = finder.own
  local why = finder:CannotList()
  K.SetAction(self.publish, own and "Update" or "List my group", Window.GroupPublish, nil, nil, why == nil)
  K.Show(self.close, own ~= nil)
  local note = WF.L(why or "Fill in what you are looking for, then list your group.")
  if not why and own then note = string.format(WF.L("Listed: %d/%d players."), own.have or 1, own.size) end
  Raw(self.formNote, K.Paint(why and "BAD" or "DIM", note))
  local apps = finder:Applicants()
  K.FillList(self.waitList, #apps, function(row, index)
    local app = apps[index]
    local className, hex = ClassText(app.class)
    local line = Tint(hex, app.identity) .. "  " .. K.Paint("DIM",
      string.format(WF.L("Level %d"), app.level) .. (className and (" " .. className) or "")
      .. "  " .. WF.L(finder.ROLES[app.role] or ""))
    Raw(row.name, line)
    Raw(row.note, app.note or "")
    K.SetAction(row.invite, "Invite", Window.GroupAnswer, app.key, "invite")
    K.SetAction(row.decline, "Decline", Window.GroupAnswer, app.key, "decline")
    K.SetAction(row.ignore, "Ignore", Window.GroupAnswer, app.key, "ignore")
  end)
  local empty = ""
  if #apps == 0 then empty = own and "Nobody is waiting to join." or "" end
  Raw(self.waitEmpty, empty ~= "" and Painted("DIM", empty) or "")
end

-- Page --------------------------------------------------------------------------

-- Two Scoreboard-style tabs above the panels, like Army and Garrison.
local VIEWS = { { "find", "Find a group" }, { "create", "My group" } }

function Page:SetView(view)
  self.view = view
  CloseMenus()
  if self.applyKey then self:CloseApply() end
  self:Update(K.Now())
end

function Page:Build()
  local ArmyTab = K.ArmyTab
  ArmyTab.Backdrop(self)
  local height = K.CONTENT_HEIGHT - ArmyTab.SHIFT - UI.FOOTER
  self:BuildFind(height)
  self:BuildCreate(height)
  local level = (self.frame:GetFrameLevel() or 0) + 6
  local x = 12
  self.switch = {}
  for _, view in ipairs(VIEWS) do
    local tab = ArmyTab.New(self, level, view[1], view[2])
    tab:SetScript("OnClick", function(b) Page:SetView(b.key) end)
    K.Place(tab, self.frame, x, -ArmyTab.TOP)
    x = x + tab:GetWidth() + 2
    self.switch[view[1]] = tab
  end
  self.back = K.NewButton(self.frame, "dark", UI.BUTTON_W, 24, "Players", function() Window:ToggleHidden("players") end)
  K.Place(self.back, self.frame, K.CONTENT_WIDTH - UI.BUTTON_W, -(ArmyTab.SHIFT + height + 4))
  self:LoadForm()
end

-- The tabs: the selected one in gold; My group shows who waits.
function Page:PaintTabs(waiting)
  local create = self.switch.create
  local title = waiting > 0 and string.format(WF.L("My group (%d)"), waiting) or WF.L("My group")
  if create.label:GetText() ~= title then
    create.label:SetText(title)
    create:SetWidth(math.max(86, math.floor((create.label:GetStringWidth() or 0) + 0.5) + 36))
  end
  for key, tab in pairs(self.switch) do
    tab.selected = key == self.view
    K.ArmyTab.Paint(tab)
  end
end

function Page:Update(now)
  local finder = GF()
  if not finder then return end
  local find = self.view == "find"
  K.Show(self.findPanel, find)
  K.Show(self.formPanel, not find)
  K.Show(self.waitPanel, not find)
  if not find and self.applyKey then self:CloseApply() end
  self:PaintTabs(#finder:Applicants())
  if find then self:FillFind(now) else self:FillCreate(now) end
end

function Page:Summary()
  local count = #GF():Rows()
  if count == 1 then return WF.L("1 group looking for players") end
  return string.format(WF.L("%d groups looking for players"), count)
end

-- /wf groups: open the window on this page.
function Window:OpenGroups()
  local frame = self:Build()
  if not frame then return false end
  frame:Show()
  if self.selected ~= "groups" then self:ToggleHidden("groups") end
  return true
end

Window:AddTab("groups", "Group Finder", Page, nil, true)
