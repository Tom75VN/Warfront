Warfront = Warfront or {}

local WF = Warfront
local Panel = {}

WF.SettingsPanel = Panel

local function GetSettingsAPI()
  return _G and _G.Settings or nil
end

local function IsVisible(methodName)
  local map = WF.Map
  local method = map and map[methodName]
  if type(method) ~= "function" then return true end
  return not method(map)
end

local function SetVisible(methodName, visible)
  local map = WF.Map
  local method = map and map[methodName]
  if type(method) == "function" then method(map, visible ~= true) end
end

local function Language()
  local locale = WF.Locale
  return locale and locale.Get and locale:Get() or "enUS"
end

local function SetLanguage(language)
  local locale = WF.Locale
  if locale and locale.Set then locale:Set(language) end
end

local function ClientLanguage()
  local locale = WF.Locale
  return locale and locale.ClientDefault and locale:ClientDefault() or "enUS"
end

local function LanguageChoices()
  local locale = WF.Locale
  return locale and locale.Choices and locale:Choices() or {}
end

local function Preference(key, fallback)
  local preferences = WF.Preferences
  if preferences and preferences.Get then return preferences:Get(key) end
  return fallback
end

local function SetPreference(key, value)
  local preferences = WF.Preferences
  if preferences and preferences.Set then preferences:Set(key, value) end
end

local function Percent(value)
  return string.format("%d%%", math.floor((tonumber(value) or 0) * 100 + 0.5))
end

local function LabelChoices()
  return {
    { value = "always", label = WF.L("Always") },
    { value = "hover", label = WF.L("On hover") },
    { value = "hidden", label = WF.L("Hidden") },
  }
end

-- Every native option is declared here. See docs/settings.md before adding one.
local SECTIONS = {
  { key = "general", label = "General" },
  { key = "map", label = "Map" },
  { key = "alerts", label = "Alerts" },
}

local ROWS = {
  {
    section = "general",
    kind = "dropdown",
    variable = "Warfront_Language",
    label = "Language",
    tooltip = "Choose the language used by Warfront. Reload the interface to update every open panel.",
    default = ClientLanguage,
    get = Language,
    set = SetLanguage,
    choices = LanguageChoices,
  },
  {
    section = "general", kind = "slider", variable = "Warfront_UIScale", label = "Interface scale",
    tooltip = "Scale Warfront windows, capture HUD, alerts and popups.",
    default = 1.10, get = function() return Preference("uiScale", 1.10) end,
    set = function(value) SetPreference("uiScale", value) end,
    min = 0.50, max = 1.50, step = 0.05, format = Percent,
  },
  {
    section = "map", kind = "slider", variable = "Warfront_MapIconScale", label = "Map icon size",
    tooltip = "Adjust the size of Warfront points of interest on the world map.",
    default = 1, get = function() return Preference("mapIconScale", 1) end,
    set = function(value) SetPreference("mapIconScale", value) end,
    min = 0.50, max = 1.50, step = 0.10, format = Percent,
  },
  {
    section = "map", kind = "slider", variable = "Warfront_MapAreaOpacity", label = "Map area opacity",
    tooltip = "Adjust the coloured area shown around points of interest on the world map.",
    default = 1, get = function() return Preference("mapAreaOpacity", 1) end,
    set = function(value) SetPreference("mapAreaOpacity", value) end,
    min = 0, max = 1, step = 0.10, format = Percent,
  },
  {
    section = "map", kind = "slider", variable = "Warfront_MinimapIconScale", label = "Minimap icon size",
    tooltip = "Adjust the size of Warfront points of interest on the minimap.",
    default = 1, get = function() return Preference("minimapIconScale", 1) end,
    set = function(value) SetPreference("minimapIconScale", value) end,
    min = 0.50, max = 1.50, step = 0.10, format = Percent,
  },
  {
    section = "map", kind = "slider", variable = "Warfront_MinimapAreaOpacity", label = "Minimap area opacity",
    tooltip = "Adjust the coloured area shown around points of interest on the minimap.",
    default = 0.60, get = function() return Preference("minimapAreaOpacity", 0.60) end,
    set = function(value) SetPreference("minimapAreaOpacity", value) end,
    min = 0, max = 1, step = 0.10, format = Percent,
  },
  {
    section = "map", kind = "slider", variable = "Warfront_MapPathOpacity", label = "Scout and army path opacity",
    tooltip = "Adjust the opacity of scout and army paths on the map.",
    default = 0.40, get = function() return Preference("mapPathOpacity", 0.40) end,
    set = function(value) SetPreference("mapPathOpacity", value) end,
    min = 0, max = 1, step = 0.10, format = Percent,
  },
  {
    section = "map", kind = "dropdown", variable = "Warfront_MapLabels", label = "Map icon details",
    tooltip = "Choose when resource stocks are shown below map icons.",
    default = "always", get = function() return Preference("mapLabelMode", "always") end,
    set = function(value) SetPreference("mapLabelMode", value) end, choices = LabelChoices,
  },
  {
    section = "alerts", kind = "checkbox", variable = "Warfront_Sounds", label = "Alert sounds",
    tooltip = "Play a sound for important Warfront alerts.",
    default = true, get = function() return Preference("soundEnabled", true) end,
    set = function(value) SetPreference("soundEnabled", value) end,
  },
  {
    section = "alerts", kind = "checkbox", variable = "Warfront_CaptureAlerts", label = "All alerts",
    tooltip = "Show every Warfront alert banner and sound.",
    default = true, get = function() return Preference("captureAlerts", true) end,
    set = function(value) SetPreference("captureAlerts", value) end,
  },
  {
    section = "alerts", kind = "checkbox", variable = "Warfront_AlertCaptures", label = "Capture alerts",
    tooltip = "Show alerts when captures start, finish, or are lost.",
    default = true, get = function() return Preference("alertCaptures", true) end,
    set = function(value) SetPreference("alertCaptures", value) end,
  },
  {
    section = "alerts", kind = "checkbox", variable = "Warfront_AlertArmies", label = "Army alerts",
    tooltip = "Show alerts for enemy armies marching toward your faction.",
    default = true, get = function() return Preference("alertArmies", true) end,
    set = function(value) SetPreference("alertArmies", value) end,
  },
  {
    section = "alerts", kind = "checkbox", variable = "Warfront_AlertBattles", label = "Battle alerts",
    tooltip = "Show battle results and reinforcement availability.",
    default = true, get = function() return Preference("alertBattles", true) end,
    set = function(value) SetPreference("alertBattles", value) end,
  },
  {
    section = "alerts", kind = "checkbox", variable = "Warfront_AlertScouts", label = "Scout alerts",
    tooltip = "Show alerts when your scouts arrive and reveal a target.",
    default = true, get = function() return Preference("alertScouts", true) end,
    set = function(value) SetPreference("alertScouts", value) end,
  },
  {
    section = "alerts", kind = "checkbox", variable = "Warfront_AlertSieges", label = "Siege alerts",
    tooltip = "Show alerts when sieges start, near their end, or finish.",
    default = true, get = function() return Preference("alertSieges", true) end,
    set = function(value) SetPreference("alertSieges", value) end,
  },
  {
    section = "alerts", kind = "checkbox", variable = "Warfront_AlertCampaigns", label = "Campaign alerts",
    tooltip = "Show campaign victories, defeats, and new campaigns.",
    default = true, get = function() return Preference("alertCampaigns", true) end,
    set = function(value) SetPreference("alertCampaigns", value) end,
  },
  {
    section = "alerts", kind = "checkbox", variable = "Warfront_AlertOrders", label = "Order alerts",
    tooltip = "Show alerts for your armies and scouts sent, cancelled, or expired.",
    default = true, get = function() return Preference("alertOrders", true) end,
    set = function(value) SetPreference("alertOrders", value) end,
  },
  {
    section = "alerts", kind = "checkbox", variable = "Warfront_AlertUpdates", label = "Addon update alerts",
    tooltip = "Show important notices when Warfront should be updated.",
    default = true, get = function() return Preference("alertUpdates", true) end,
    set = function(value) SetPreference("alertUpdates", value) end,
  },
  {
    section = "general", kind = "checkbox", variable = "Warfront_MinimapButton", label = "Minimap button",
    tooltip = "Show the Warfront button around the minimap.",
    default = true, get = function() return Preference("minimapButton", true) end,
    set = function(value) SetPreference("minimapButton", value) end,
  },
  {
    section = "map",
    kind = "checkbox",
    variable = "Warfront_MapPointsOfInterest",
    label = "Points of interest",
    tooltip = "Show Outposts, Settlements, War Camps and resources on the map and minimap.",
    default = true,
    get = function() return IsVisible("Hidden") end,
    set = function(value) SetVisible("SetHidden", value) end,
  },
  {
    section = "map",
    kind = "checkbox",
    variable = "Warfront_MapUnits",
    label = "Scouts and armies",
    tooltip = "Show scouts and armies on their way, with their path.",
    default = true,
    get = function() return IsVisible("UnitsHidden") end,
    set = function(value) SetVisible("SetUnitsHidden", value) end,
  },
  {
    section = "map",
    kind = "checkbox",
    variable = "Warfront_MapRoutes",
    label = "Campaign routes",
    tooltip = "Show the front line and captured zones on continent maps.",
    default = true,
    get = function() return IsVisible("RoutesHidden") end,
    set = function(value) SetVisible("SetRoutesHidden", value) end,
  },
}

local function DropdownOptions(api, choices)
  return function()
    local container = api.CreateControlTextContainer()
    for _, choice in ipairs(choices()) do
      container:Add(choice.value, choice.label)
    end
    return container:GetData()
  end
end

local function SliderOptions(api, row)
  local options = api.CreateSliderOptions(row.min, row.max, row.step)
  local mixin = _G and _G.MinimalSliderWithSteppersMixin
  local labels = mixin and mixin.Label
  if options and type(options.SetLabelFormatter) == "function" and labels and row.format then
    pcall(options.SetLabelFormatter, options, labels.Right, row.format)
  end
  return options
end

local function RegisterRow(api, category, row)
  if row.created then return true end
  local default = type(row.default) == "function" and row.default() or row.default
  local setting = row.setting or api.RegisterProxySetting(
    category,
    row.variable,
    type(default),
    WF.L(row.label),
    default,
    row.get,
    row.set
  )
  if not setting then error("setting unavailable: " .. row.variable) end
  row.setting = setting
  if row.section == "alerts" then
    row.created = true
  elseif row.kind == "checkbox" and type(api.CreateCheckbox) == "function" then
    api.CreateCheckbox(category, setting, WF.L(row.tooltip))
  elseif row.kind == "slider"
    and type(api.CreateSlider) == "function"
    and type(api.CreateSliderOptions) == "function" then
    api.CreateSlider(category, setting, SliderOptions(api, row), WF.L(row.tooltip))
  elseif row.kind == "dropdown"
    and type(api.CreateDropdown) == "function"
    and type(api.CreateControlTextContainer) == "function" then
    api.CreateDropdown(category, setting, DropdownOptions(api, row.choices), WF.L(row.tooltip))
  else
    error("control unavailable: " .. row.variable)
  end
  row.created = true
  return true
end

local function AlertRows()
  local rows, master, sounds = {}, nil, nil
  for _, row in ipairs(ROWS) do
    if row.section == "alerts" then
      if row.variable == "Warfront_CaptureAlerts" then master = row
      elseif row.variable == "Warfront_Sounds" then sounds = row
      else rows[#rows + 1] = row end
    end
  end
  local ordered = {}
  if master then ordered[#ordered + 1] = master end
  if sounds then ordered[#ordered + 1] = sounds end
  for index = 1, #rows do ordered[#ordered + 1] = rows[index] end
  return ordered
end

function Panel:RefreshAlertGrid()
  for variable, button in pairs(self.alertButtons or {}) do
    local row = button.row
    if row and type(button.SetChecked) == "function" then
      button:SetChecked(row.get() and true or false)
    end
  end
end

local function AlertTooltip(button, row)
  local tooltip = _G and _G.GameTooltip
  if not tooltip or type(tooltip.SetOwner) ~= "function" then return end
  tooltip:SetOwner(button, "ANCHOR_RIGHT")
  if type(tooltip.SetText) == "function" then tooltip:SetText(WF.L(row.label)) end
  if type(tooltip.AddLine) == "function" then
    tooltip:AddLine(WF.L(row.tooltip), 1, 1, 1, true)
  end
  if type(tooltip.Show) == "function" then tooltip:Show() end
end

local function BuildAlertButton(self, row, index)
  if self.alertButtons[row.variable] then return true end
  local create = _G and _G.CreateFrame
  if type(create) ~= "function" then return false end
  local ok, button = pcall(create, "CheckButton", nil, self.alertCanvas, "UICheckButtonTemplate")
  if not ok or not button then return false end
  button.row = row
  local column = (index - 1) - math.floor((index - 1) / 2) * 2
  local line = math.floor((index - 1) / 2)
  button:SetPoint("TOPLEFT", self.alertCanvas, "TOPLEFT", 24 + column * 285, -20 - line * 36)
  if button.Text and type(button.Text.SetText) == "function" then
    button.Text:SetText(WF.L(row.label))
  end
  if type(button.SetHitRectInsets) == "function" then button:SetHitRectInsets(0, -235, 0, 0) end
  button:SetScript("OnClick", function(control)
    local value = control:GetChecked() and true or false
    local setting = row.setting
    if setting and type(setting.SetValue) == "function" then setting:SetValue(value)
    else row.set(value) end
    self:RefreshAlertGrid()
  end)
  button:SetScript("OnEnter", function(control) AlertTooltip(control, row) end)
  button:SetScript("OnLeave", function()
    local tooltip = _G and _G.GameTooltip
    if tooltip and type(tooltip.Hide) == "function" then tooltip:Hide() end
  end)
  self.alertButtons[row.variable] = button
  return true
end

function Panel:BuildAlertGrid()
  if not self.alertCanvas then return false end
  self.alertButtons = self.alertButtons or {}
  local rows = AlertRows()
  for index = 1, #rows do
    if not BuildAlertButton(self, rows[index], index) then return false end
  end
  self.alertCanvas:SetSize(600, math.ceil(#rows / 2) * 36 + 24)
  self.alertCanvas.OnRefresh = function() self:RefreshAlertGrid() end
  self.alertCanvas.OnDefault = function() self:RefreshAlertGrid() end
  self:RefreshAlertGrid()
  return true
end

function Panel:Register()
  if self.registered then return true end
  local api = GetSettingsAPI()
  if not api
    or type(api.RegisterVerticalLayoutCategory) ~= "function"
    or type(api.RegisterVerticalLayoutSubcategory) ~= "function"
    or type(api.RegisterCanvasLayoutSubcategory) ~= "function"
    or type(api.RegisterProxySetting) ~= "function"
    or type(api.RegisterAddOnCategory) ~= "function" then
    return false
  end

  local ok, category = true, self.category
  if not category then ok, category = pcall(api.RegisterVerticalLayoutCategory, "Warfront") end
  if not ok or not category then return false end
  self.category = category

  self.sections = self.sections or {}
  for _, descriptor in ipairs(SECTIONS) do
    if not self.sections[descriptor.key] then
      local sectionOk, section
      if descriptor.key == "alerts" then
        if not self.alertCanvas then
          local create = _G and _G.CreateFrame
          if type(create) ~= "function" then return false end
          local canvasOk, canvas = pcall(create, "Frame", "WarfrontAlertsSettingsPanel")
          if not canvasOk or not canvas then return false end
          self.alertCanvas = canvas
        end
        sectionOk, section = pcall(api.RegisterCanvasLayoutSubcategory,
          category, self.alertCanvas, WF.L(descriptor.label))
      else
        sectionOk, section = pcall(api.RegisterVerticalLayoutSubcategory,
          category, WF.L(descriptor.label))
      end
      if not sectionOk or not section then
        if WF.RecordError then WF.RecordError("settings section " .. descriptor.key, section) end
        return false
      end
      self.sections[descriptor.key] = section
    end
  end

  local complete = true
  for _, row in ipairs(ROWS) do
    local rowCategory = self.sections[row.section]
    local added, err = pcall(RegisterRow, api, rowCategory, row)
    if not added then
      complete = false
      if WF.RecordError then WF.RecordError("settings " .. row.variable, err) end
    end
  end

  local gridOk, gridResult = pcall(self.BuildAlertGrid, self)
  if not gridOk or not gridResult then
    complete = false
    if WF.RecordError then WF.RecordError("settings alerts grid", gridResult) end
  end

  if not self.categoryAdded then
    local added, err = pcall(api.RegisterAddOnCategory, category)
    if not added then
      if WF.RecordError then WF.RecordError("settings category", err) end
      return false
    end
    self.categoryAdded = true
  end
  self.registered = complete
  return complete
end

function Panel:Open()
  local api = GetSettingsAPI()
  if not self.category then self:Register() end
  if not api or type(api.OpenToCategory) ~= "function"
    or not self.category or type(self.category.GetID) ~= "function" then
    return false
  end
  local idOk, categoryID = pcall(self.category.GetID, self.category)
  if not idOk or categoryID == nil then return false end
  local opened, err = pcall(api.OpenToCategory, categoryID)
  if not opened and WF.RecordError then WF.RecordError("settings open", err) end
  return opened
end

local function OnAddonLoaded(_, addonName)
  if string.lower(tostring(addonName or "")) == string.lower(WF.name) then
    Panel:Register()
  end
end

if WF.RegisterEvent then WF.RegisterEvent("ADDON_LOADED", OnAddonLoaded) end
