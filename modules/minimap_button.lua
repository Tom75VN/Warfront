Warfront = Warfront or {}

local WF = Warfront
local Button = {}

WF.MinimapButton = Button

-- Minimap button opening the main window (modules/main_window.lua). Dragged
-- around the minimap edge (circle or square, following Button:IsSquare);
-- its angle in degrees is saved in
-- WarfrontDB.settings.minimapAngle. The 1.12 globals cos, sin and atan2
-- work in degrees.
local NAME = "WarfrontMinimapButton"
local DEFAULT_ANGLE = 200
local FALLBACK_RADIUS = 80
local BUTTON_RADIUS = 5
local FRAME_SIZE = 31
local ICON_SIZE = 24 -- slightly under the ring so the disc fills it
local BACKGROUND_SIZE = 20
local BORDER_SIZE = 53
local ICON_TEXTURE = "Interface\\AddOns\\Warfront\\media\\Textures\\UI\\WarfrontMinimapIcon"
local BACKGROUND = "Interface\\Minimap\\UI-Minimap-Background"
local BORDER = "Interface\\Minimap\\MiniMap-TrackingBorder"
local HIGHLIGHT = "Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight"

Button.DEFAULT_ANGLE = DEFAULT_ANGLE

local function GetGlobal(name)
  if WF.Compat and WF.Compat.Global then return WF.Compat.Global(name) end
  if _G then return _G[name] end
  return nil
end

local function Settings()
  local storage = WF.Storage
  if not storage or type(storage.GetDB) ~= "function" or storage.readOnly then return nil end
  local db = storage:GetDB()
  if type(db) ~= "table" or type(db.settings) ~= "table" then return nil end
  return db.settings
end

function Button:Angle()
  local settings = Settings()
  local angle = settings and tonumber(settings.minimapAngle)
  if not angle or angle ~= angle or angle < 0 or angle >= 360 then return DEFAULT_ANGLE end
  return angle
end

-- FlareUI (formerly PandaUI) owns the optional circle/square minimap style;
-- the standard GetMinimapShape() hook of other minimap addons is the
-- fallback. Anything unknown stays round. Also read by MinimapAreas.
local function AddonSquare(owner, method)
  if type(owner) ~= "table" or type(owner[method]) ~= "function" then return nil end
  local ok, square = pcall(owner[method])
  if ok then return square == true end
  return nil
end

function Button:IsSquare()
  local flareUI = GetGlobal("FlareUI")
  local square = AddonSquare(type(flareUI) == "table" and flareUI.Minimap or nil, "IsSquare")
  if square == nil then square = AddonSquare(GetGlobal("PandaUI"), "MinimapIsSquare") end
  if square ~= nil then return square end
  local shape = GetGlobal("GetMinimapShape")
  if type(shape) == "function" then
    local ok, name = pcall(shape)
    return ok and name == "SQUARE"
  end
  return false
end

function Button:Place(angle)
  local frame, minimap = self.frame, GetGlobal("Minimap")
  local cos, sin = GetGlobal("cos"), GetGlobal("sin")
  if not frame or not minimap then return end
  frame:ClearAllPoints()
  if type(cos) ~= "function" or type(sin) ~= "function" then
    frame:SetPoint("CENTER", minimap, "BOTTOMLEFT", 0, 0)
    return
  end
  local c, s = cos(angle), sin(angle)
  local width, height = minimap:GetWidth(), minimap:GetHeight()
  local reachX, reachY = FALLBACK_RADIUS + BUTTON_RADIUS, FALLBACK_RADIUS + BUTTON_RADIUS
  if type(width) == "number" and type(height) == "number" and width > 0 and height > 0 then
    reachX = width / 2 + BUTTON_RADIUS
    reachY = height / 2 + BUTTON_RADIUS
  end
  self.square = self:IsSquare()
  if self.square then
    -- Match LibDBIcon's square-edge projection used by Questie and DungeonJournal.
    local diagonalX = math.sqrt(2 * reachX * reachX) - 10
    local diagonalY = math.sqrt(2 * reachY * reachY) - 10
    c = math.max(-reachX, math.min(c * diagonalX, reachX))
    s = math.max(-reachY, math.min(s * diagonalY, reachY))
  else
    c, s = c * reachX, s * reachY
  end
  frame:SetPoint("CENTER", minimap, "CENTER", c, s)
end

-- The circle/square setting can change while playing: re-place on a change.
local function OnShapeWatch(_, elapsed)
  Button.shapeElapsed = (Button.shapeElapsed or 0) + (elapsed or 0)
  if Button.shapeElapsed < 1 then return end
  Button.shapeElapsed = 0
  if Button.frame and Button:IsSquare() ~= Button.square then Button:Place(Button:Angle()) end
end

-- Angle of the cursor around the minimap centre, in [0, 360).
function Button:CursorAngle()
  local cursor, atan2, minimap = GetGlobal("GetCursorPosition"), GetGlobal("atan2"), GetGlobal("Minimap")
  if type(cursor) ~= "function" or type(atan2) ~= "function" or not minimap then return nil end
  local x, y = cursor()
  local scale = minimap:GetEffectiveScale()
  local cx, cy = minimap:GetCenter()
  if not x or not y or not cx or not cy or not scale or scale <= 0 then return nil end
  return ((atan2(y / scale - cy, x / scale - cx) + 360) % 360)
end

function Button:SetAngle(angle)
  if type(angle) ~= "number" or angle ~= angle then return end
  angle = ((math.floor(angle + 0.5) + 360) % 360)
  local settings = Settings()
  if settings then settings.minimapAngle = angle end
  self:Place(angle)
end

function Button:Enabled()
  return not WF.Preferences or WF.Preferences:Get("minimapButton")
end

function Button:ApplyVisibility()
  local frame = self.frame
  if not frame and self:Enabled() then frame = self:Build() end
  if not frame then return end
  if self:Enabled() then frame:Show() else frame:Hide() end
end

local function OnDragUpdate()
  Button:SetAngle(Button:CursorAngle())
end

function Button:ShowTooltip()
  local tooltip = GetGlobal("GameTooltip")
  if not tooltip or not self.frame then return end
  tooltip:SetOwner(self.frame, "ANCHOR_LEFT")
  tooltip:AddLine("|cfff5ae0aWarfront|r")
  tooltip:AddLine(WF.L("Left-click: open or close the window"), 1, 1, 1)
  tooltip:AddLine(WF.L("Right-click: open settings"), 1, 1, 1)
  tooltip:AddLine(WF.L("Drag: move this button"), 0.8, 0.8, 0.8)
  tooltip:Show()
end

function Button:Build()
  if self.frame then return self.frame end
  local create, minimap = GetGlobal("CreateFrame"), GetGlobal("Minimap")
  if type(create) ~= "function" or not minimap then return nil end
  local ok, frame = pcall(create, "Button", NAME, minimap)
  if not ok or not frame then return nil end
  self.frame = frame
  frame:SetWidth(FRAME_SIZE)
  frame:SetHeight(FRAME_SIZE)
  frame:SetFrameStrata("MEDIUM")
  frame:SetFrameLevel(minimap:GetFrameLevel() + 8)

  -- LibDBIcon-style layers; the round icon is enlarged to fill the ring.
  local background = frame:CreateTexture(nil, "BACKGROUND")
  background:SetTexture(BACKGROUND)
  background:SetWidth(BACKGROUND_SIZE)
  background:SetHeight(BACKGROUND_SIZE)
  background:SetPoint("TOPLEFT", frame, "TOPLEFT", 7, -5)

  local icon = frame:CreateTexture(nil, "ARTWORK")
  icon:SetWidth(ICON_SIZE)
  icon:SetHeight(ICON_SIZE)
  icon:SetPoint("CENTER", background, "CENTER", 0, 0)
  icon:SetTexture(ICON_TEXTURE)

  local border = frame:CreateTexture(nil, "OVERLAY")
  border:SetTexture(BORDER)
  border:SetWidth(BORDER_SIZE)
  border:SetHeight(BORDER_SIZE)
  border:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
  frame:SetHighlightTexture(HIGHLIGHT)
  self.background = background
  self.border = border
  self.icon = icon

  frame:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnMouseDown", function()
    Button.icon:ClearAllPoints()
    Button.icon:SetPoint("CENTER", Button.background, "CENTER", 1, -1)
  end)
  frame:SetScript("OnMouseUp", function()
    Button.icon:ClearAllPoints()
    Button.icon:SetPoint("CENTER", Button.background, "CENTER", 0, 0)
  end)
  frame:SetScript("OnClick", function(_, mouseButton) Button:OnClick(mouseButton) end)
  frame:SetScript("OnDragStart", function(self)
    self:LockHighlight()
    self:SetScript("OnUpdate", OnDragUpdate)
  end)
  frame:SetScript("OnDragStop", function(self)
    self:SetScript("OnUpdate", nil)
    self:UnlockHighlight()
  end)
  frame:SetScript("OnEnter", function() Button:ShowTooltip() end)
  frame:SetScript("OnLeave", function()
    local tooltip = GetGlobal("GameTooltip")
    if tooltip then tooltip:Hide() end
  end)
  self:Place(self:Angle())
  local watcher = create("Frame", NAME .. "ShapeWatch", frame)
  if watcher then
    watcher:SetScript("OnUpdate", OnShapeWatch)
    self.watcher = watcher
  end
  self:ApplyVisibility()
  return frame
end

function Button:OnClick(mouseButton)
  if mouseButton == "RightButton" then
    if WF.SettingsPanel and WF.SettingsPanel.Open then WF.SettingsPanel:Open() end
    return
  end
  if WF.MainWindow and WF.MainWindow.Toggle then WF.MainWindow:Toggle() end
end

-- After ADDON_LOADED: the saved angle and the faction are known.
if WF.RegisterEvent then
  WF.RegisterEvent("PLAYER_LOGIN", function() Button:Build() end)
end
