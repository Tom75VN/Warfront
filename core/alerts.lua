Warfront = Warfront or {}

local WF = Warfront
local Alerts = {
  queue = {},
  active = nil,
}

WF.Alerts = Alerts

local MAX_QUEUE = 16
local CATEGORY_PREFERENCES = {
  captures = "alertCaptures",
  armies = "alertArmies",
  battles = "alertBattles",
  scouts = "alertScouts",
  sieges = "alertSieges",
  campaigns = "alertCampaigns",
  orders = "alertOrders",
  updates = "alertUpdates",
}

function Alerts:Enabled(category)
  local preferences = WF.Preferences
  if not preferences or type(preferences.Get) ~= "function" then return true end
  if not preferences:Get("captureAlerts") then return false end
  local key = CATEGORY_PREFERENCES[category]
  return not key or preferences:Get(key)
end

function Alerts:DisplayNext()
  if self.active then return true end
  local hud = WF.CaptureHUD
  if not hud or type(hud.ShowAlert) ~= "function" then return false end
  while #self.queue > 0 do
    local item = table.remove(self.queue, 1)
    if self:Enabled(item.category) then
      self.active = item
      local shown, waits = hud:ShowAlert(item.text, item.title, item.side, item.sound, item.category)
      if waits then return true end
      self.active = nil
      if shown then return self:DisplayNext() end
    end
  end
  return false
end

-- Sources call this only after their own acceptance and idempotence checks.
-- Chat remains the durable local fallback; settings control banners and sounds.
function Alerts:Push(category, text, options)
  options = type(options) == "table" and options or {}
  if WF.AlertHistory then WF.AlertHistory:Add(category, text, options.side) end
  if options.chat ~= false and WF.Print then WF.Print(text) end
  if not self:Enabled(category) then return false end
  if #self.queue >= MAX_QUEUE then table.remove(self.queue, 1) end
  self.queue[#self.queue + 1] = {
    category = category,
    text = text,
    title = options.title,
    side = options.side,
    sound = options.sound == true,
  }
  self:DisplayNext()
  return true
end

function Alerts:Finish()
  self.active = nil
  return self:DisplayNext()
end

function Alerts:ApplyPreferences()
  local filtered = {}
  for index = 1, #self.queue do
    local item = self.queue[index]
    if self:Enabled(item.category) then filtered[#filtered + 1] = item end
  end
  self.queue = filtered
  if self.active and not self:Enabled(self.active.category) then
    local hud = WF.CaptureHUD
    if hud and type(hud.HideAlert) == "function" then hud:HideAlert() end
    self.active = nil
  end
  self:DisplayNext()
end
