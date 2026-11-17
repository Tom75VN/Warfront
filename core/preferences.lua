Warfront = Warfront or {}

local WF = Warfront
local Preferences = {}

WF.Preferences = Preferences

local DEFINITIONS = {
  uiScale = { default = 1.10, min = 0.50, max = 1.50 },
  mapIconScale = { default = 1.00, min = 0.50, max = 1.50 },
  mapAreaOpacity = { default = 1.00, min = 0.00, max = 1.00 },
  minimapIconScale = { default = 1.00, min = 0.50, max = 1.50 },
  minimapAreaOpacity = { default = 0.60, min = 0.00, max = 1.00 },
  mapPathOpacity = { default = 0.40, min = 0.00, max = 1.00 },
  mapLabelMode = { default = "always", choices = { always = true, hover = true, hidden = true } },
  soundEnabled = { default = true },
  captureAlerts = { default = true },
  alertCaptures = { default = true },
  alertArmies = { default = true },
  alertBattles = { default = true },
  alertScouts = { default = true },
  alertSieges = { default = true },
  alertCampaigns = { default = true },
  alertOrders = { default = true },
  alertUpdates = { default = true },
  minimapButton = { default = true },
}

local function Settings()
  local storage = WF.Storage
  if not storage or type(storage.GetDB) ~= "function" or storage.readOnly then return nil end
  local db = storage:GetDB()
  if type(db) ~= "table" or type(db.settings) ~= "table" then return nil end
  return db.settings
end

local function Normalize(definition, value)
  if definition.choices then
    return definition.choices[value] and value or definition.default
  end
  if type(definition.default) == "boolean" then return value == true end
  local number = tonumber(value)
  if not number or number ~= number then return definition.default end
  if number < definition.min then number = definition.min end
  if number > definition.max then number = definition.max end
  return number
end

function Preferences:Get(key)
  local definition = DEFINITIONS[key]
  if not definition then return nil end
  local settings = Settings()
  if not settings or settings[key] == nil then return definition.default end
  return Normalize(definition, settings[key])
end

function Preferences:Set(key, value)
  local definition = DEFINITIONS[key]
  local settings = Settings()
  if not definition or not settings then return false end
  local normalized = Normalize(definition, value)
  if normalized == definition.default then settings[key] = nil else settings[key] = normalized end
  self:Apply(key)
  return true
end

function Preferences:ScaleFactor()
  return self:Get("uiScale") / DEFINITIONS.uiScale.default
end

function Preferences:Apply(key)
  if key == "uiScale" then
    if WF.MainWindow and WF.MainWindow.FitScale then WF.MainWindow:FitScale() end
    if WF.ClassicWindow and WF.ClassicWindow.ApplyScale then WF.ClassicWindow:ApplyScale() end
    if WF.CaptureHUD and WF.CaptureHUD.ApplyScale then WF.CaptureHUD:ApplyScale() end
    if WF.Allies and WF.Allies.ApplyScale then WF.Allies:ApplyScale() end
  elseif key == "minimapIconScale" or key == "minimapAreaOpacity" then
    if WF.MinimapAreas and WF.MinimapAreas.ApplyPreferences then WF.MinimapAreas:ApplyPreferences() end
  elseif key == "minimapButton" then
    if WF.MinimapButton and WF.MinimapButton.ApplyVisibility then WF.MinimapButton:ApplyVisibility() end
  elseif key == "captureAlerts" or string.sub(key or "", 1, 5) == "alert" then
    if WF.Alerts and WF.Alerts.ApplyPreferences then WF.Alerts:ApplyPreferences() end
  elseif key == "mapIconScale" or key == "mapAreaOpacity"
      or key == "mapPathOpacity" or key == "mapLabelMode" then
    if WF.Map and WF.Map.ApplyPreferences then WF.Map:ApplyPreferences() end
  end
end
