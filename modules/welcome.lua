local WF = Warfront

-- The welcome window (roadmap "New-profile welcome HUD window"): one screen
-- with the first steps, matchmaking, the connection and the optional
-- companion. It opens by itself once, a few seconds after the first login of
-- a new account-wide profile (Storage.newProfile, decision 0135), and again
-- with /wf welcome. It saves nothing and changes no gameplay data.
local Welcome = {
  WIDTH = 360, LEFT = 16, GAP = 10, ROW_H = 22, BUTTON_H = 22, DELAY = 4, REFRESH = 1,
  CONNECT_WAIT = 15,
  STEPS = {
    "Type /wf or click the minimap button.",
    "Turn PvP on (level 5+).",
    "Reach the nearest Neutral or Enemy Outpost for your first capture.",
    "Gather, recruit, defend.",
  },
  TEXT = {
    title = "Welcome to Warfront",
    pitch = "Your faction's war, across the whole world.",
    match = "Allies",
    matchBody = "Add a Warfront player of the other faction as a Battle.net friend: it keeps Warfront in sync"
      .. " between Alliance and Horde.",
    find = "Find a friend",
    stop = "Stop matchmaking",
    cloud = "Managed in the Companion",
    unavailable = "Not available yet",
    connected = "Connected",
    offline = "Not connected to Warfront.",
    connecting = "Connecting...",
    retry = "Not connected yet. Try again in a moment.",
    connect = "Connect",
    companion = "Companion: ",
    inUse = "in use",
    optional = "optional, not in use",
    download = "Download",
    open = "Open Warfront",
    guide = "Guide",
    close = "Close",
  },
}
WF.Welcome = Welcome

local function GetGlobal(name)
  if WF.Compat and WF.Compat.Global then return WF.Compat.Global(name) end
  if _G then return _G[name] end
  return nil
end

local function L(text)
  if WF.L then return WF.L(text) end
  return text
end

local function Scale()
  return WF.Preferences and WF.Preferences:ScaleFactor() or 1
end

-- A wrapped text block placed under the previous one; returns the next top.
local function Block(frame, template, text, left, top, width)
  local line = WF.Skin:Text(frame, template, "LEFT")
  line:SetPoint("TOPLEFT", frame, "TOPLEFT", left, top)
  line:SetWidth(width)
  line:SetText(L(text))
  return line, top - math.ceil(tonumber(line:GetStringHeight()) or 12)
end

-- A row with a background, a status text on the left and a button on the right.
local function Row(frame, top, buttonWidth, label, onClick)
  local self, skin = Welcome, WF.Skin
  local holder = GetGlobal("CreateFrame")("Frame", nil, frame)
  holder:SetWidth(self.WIDTH - 2 * self.LEFT)
  holder:SetHeight(self.ROW_H)
  holder:SetPoint("TOPLEFT", frame, "TOPLEFT", self.LEFT, top)
  skin:RowBackground(holder, self.ROW_H)
  holder.text = skin:Text(holder, "GameFontHighlightSmall", "LEFT")
  holder.text:SetPoint("LEFT", holder, "LEFT", 8, 0)
  holder.text:SetWidth(self.WIDTH - 2 * self.LEFT - buttonWidth - 20)
  holder.button = skin:Button(holder, "red", buttonWidth, 18, onClick)
  holder.button:SetPoint("RIGHT", holder, "RIGHT", -3, 0)
  skin:SetButton(holder.button, label)
  return holder
end

function Welcome:Build()
  if self.frame then return self.frame end
  local skin, create, parent = WF.Skin, GetGlobal("CreateFrame"), GetGlobal("UIParent")
  if not skin or not skin.Panel or type(create) ~= "function" then return nil end
  local T, width = self.TEXT, self.WIDTH - 2 * self.LEFT
  local frame = skin:Panel(parent, T.title, self.WIDTH, 200)
  frame:SetPoint("CENTER", parent, "CENTER", 0, 60)
  frame:SetFrameStrata("DIALOG")
  frame:SetToplevel(true)
  frame:EnableMouse(true)
  frame:SetMovable(true)
  frame:SetClampedToScreen(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", function(panel) panel:StartMoving() end)
  frame:SetScript("OnDragStop", function(panel) panel:StopMovingOrSizing() end)
  frame:Hide()
  local close = skin:CloseButton(frame, 18, function() Welcome:Hide() end)
  close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -5, -4)

  local _, top = Block(frame, "GameFontDisableSmall", T.pitch, self.LEFT, -(skin.HEADER + 10), width)
  top = top - self.GAP
  for index = 1, #self.STEPS do
    local number = skin:Text(frame, "GameFontNormal", "LEFT")
    number:SetPoint("TOPLEFT", frame, "TOPLEFT", self.LEFT, top)
    number:SetText(tostring(index))
    local _, below = Block(frame, "GameFontHighlight", self.STEPS[index], self.LEFT + 18, top, width - 18)
    top = below - 6
  end

  top = top - self.GAP
  local _, below = Block(frame, "GameFontNormal", T.match, self.LEFT, top, width)
  _, top = Block(frame, "GameFontHighlightSmall", T.matchBody, self.LEFT, below - 4, width)
  frame.match = skin:Button(frame, "red", 170, self.BUTTON_H, function() Welcome:ToggleMatch() end)
  frame.match:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -self.LEFT, top - 6)
  top = top - 6 - self.BUTTON_H - self.GAP

  frame.connect = Row(frame, top, 84, T.connect, function() Welcome:Connect() end)
  top = top - self.ROW_H - 4
  frame.companion = Row(frame, top, 84, T.download, function()
    if WF.CompanionDownload then WF.CompanionDownload:Toggle() end
  end)
  top = top - self.ROW_H - self.GAP

  local third = math.floor((width - 12) / 3)
  local open = skin:Button(frame, "red", third, self.BUTTON_H, function() Welcome:OpenWindow(false) end)
  open:SetPoint("TOPLEFT", frame, "TOPLEFT", self.LEFT, top)
  skin:SetButton(open, T.open)
  local guide = skin:Button(frame, "dark", third, self.BUTTON_H, function() Welcome:OpenWindow(true) end)
  guide:SetPoint("LEFT", open, "RIGHT", 6, 0)
  skin:SetButton(guide, T.guide)
  local done = skin:Button(frame, "dark", third, self.BUTTON_H, function() Welcome:Hide() end)
  done:SetPoint("LEFT", guide, "RIGHT", 6, 0)
  skin:SetButton(done, T.close)
  frame:SetHeight(-(top - self.BUTTON_H - 12))

  frame.elapsed = 0
  frame:SetScript("OnUpdate", function(_, delta)
    frame.elapsed = frame.elapsed + (delta or 0)
    if frame.elapsed < Welcome.REFRESH then return end
    frame.elapsed = 0
    Welcome:Refresh()
  end)
  self.frame = frame
  return frame
end

-- Matchmaking: the button reads the current choice; nothing starts by itself.
function Welcome:ToggleMatch()
  local allies = WF.Allies
  if not allies or not allies.Command then return end
  allies:Command(allies:OptedIn() and "off" or "on")
  self:Refresh()
end

function Welcome:Connect()
  local p2p = WF.P2PTest
  if not p2p or type(p2p.JoinChannelFromUI) ~= "function" then return end
  local ok, result = pcall(p2p.JoinChannelFromUI)
  if not ok and WF.RecordError then WF.RecordError("welcome connect", result) end
  if ok and result == "joining" then
    self.connecting = WF.Now and WF.Now() or 0
  elseif not (ok and (result == "joined" or result == "chat")) then
    self.failed = true
  end
  self:Refresh()
end

local function Joined()
  local p2p = WF.P2PTest
  if not p2p or type(p2p.ChannelJoined) ~= "function" then return false end
  local ok, joined = pcall(p2p.ChannelJoined)
  return ok and joined and true or false
end

function Welcome:Refresh()
  local frame, T, skin = self.frame, self.TEXT, WF.Skin
  if not frame then return end
  local allies = WF.Allies
  if not allies or not allies.IsAvailable or not allies:IsAvailable() then
    skin:SetButton(frame.match, T.unavailable, false)
  elseif allies:CloudLocked() then
    skin:SetButton(frame.match, T.cloud, false)
  else
    skin:SetButton(frame.match, allies:OptedIn() and T.stop or T.find, true)
  end

  local joined, row = Joined(), frame.connect
  if self.connecting and not joined and (WF.Now and WF.Now() or 0) - self.connecting > self.CONNECT_WAIT then
    self.connecting, self.failed = nil, true
  end
  if joined then
    self.connecting, self.failed = nil, nil
    row.text:SetText(L(T.connected))
  elseif self.connecting then
    row.text:SetText(L(T.connecting))
  else
    row.text:SetText(L(self.failed and T.retry or T.offline))
  end
  skin:Color(row.text, joined and "GOOD" or "WHITE")
  if joined then row.button:Hide() else row.button:Show() end

  local companion = WF.Companion
  local helping = companion and companion.Helping and companion:Helping()
  row = frame.companion
  row.text:SetText(L(T.companion) .. L(helping and T.inUse or T.optional))
  if helping or not WF.CompanionDownload then row.button:Hide() else row.button:Show() end
end

function Welcome:OpenWindow(guide)
  local window = WF.MainWindow
  self:Hide()
  if not window or not window.Build then return end
  local frame = window:Build()
  if not frame then return end
  if not frame:IsShown() then frame:Show() end
  if guide and window.tabs and window.tabs.guide and window.selected ~= "guide" then window:ToggleGuide() end
  local book = window.Guide
  if guide and book and book.Open then
    book.view = "home"
    pcall(book.Open, book, "welcome", false)
  end
end

function Welcome:ApplyScale()
  if self.frame then self.frame:SetScale(Scale()) end
end

function Welcome:Show()
  local ok, frame = pcall(self.Build, self)
  if not ok or not frame then
    if WF.RecordError then WF.RecordError("welcome window", ok and "unavailable" or frame) end
    return false
  end
  -- The welcome already offers matchmaking: no second invitation this session.
  if WF.Allies then WF.Allies.popupShown = true end
  frame:SetScale(Scale())
  self:Refresh()
  frame:Show()
  return true
end

function Welcome:Hide()
  if self.frame then self.frame:Hide() end
end

function Welcome:Toggle()
  if self.frame and self.frame:IsShown() then self:Hide() return true end
  return self:Show()
end

-- First login of a new profile only: wait a few seconds after the loading
-- screen, then open once for this session.
local wait, pending = 0, false
local function OnUpdate(_, delta)
  if not pending then return end
  wait = wait + (delta or 0)
  if wait < Welcome.DELAY then return end
  pending = false
  Welcome:Show()
end

local function OnEnteringWorld()
  local storage = WF.Storage
  if Welcome.autoShown or not storage or storage.newProfile ~= true then return end
  Welcome.autoShown = true
  wait, pending = 0, true
end

if type(CreateFrame) == "function" then
  local ok, ticker = pcall(CreateFrame, "Frame", nil, UIParent)
  if ok and ticker and ticker.SetScript then ticker:SetScript("OnUpdate", OnUpdate) end
end
if WF.RegisterEvent then
  WF.RegisterEvent("PLAYER_ENTERING_WORLD", OnEnteringWorld)
end
