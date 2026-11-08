Warfront = Warfront or {}

local WF = Warfront

WF.name = "Warfront"
-- Same value as ## Version in the .toc (checked by tools/smoke.py). Every
-- channel line carries it so older builds learn that they are outdated.
-- Changed only by tools/release.py prepare, once per push (decision 0035).
WF.version = "0.1.0"
-- Compatibility level n of the channel line WF<n> (decision 0029): raised by any
-- change that can make two builds disagree on the same messages, at the next
-- tools/release.py prepare. Lines of another level are never applied.
-- Keep this exact one-line form: the companion reads it to write imports.
WF.channelLevel = 5

local listeners = {}
local registrations = {}
local pendingLog = {}
local dispatcher = CreateFrame("Frame", "WarfrontEventFrame", UIParent)

function WF.Now()
  if GetTime then return GetTime() end
  return 0
end

function WF.Epoch()
  if time then return time() end
  return 0
end

function WF.Print(message)
  local text = "|cfff5ae0aWarfront:|r " .. tostring(message)
  if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
    DEFAULT_CHAT_FRAME:AddMessage(text)
  end
end

function WF.Sanitize(value, limit)
  local source = tostring(value or "")
  local maximum = tonumber(limit) or 160
  local output = ""
  local truncated = false

  for i = 1, #source do
    local byte = string.byte(source, i)
    local piece
    if byte >= 32 and byte <= 126 then
      piece = string.char(byte)
    elseif byte == 9 then
      piece = "\\t"
    elseif byte == 10 then
      piece = "\\n"
    elseif byte == 13 then
      piece = "\\r"
    else
      piece = string.format("\\x%02X", byte)
    end

    if #output + #piece > maximum then
      truncated = true
      break
    end
    output = output .. piece
  end

  if truncated then output = output .. "..." end
  return output, truncated, #source
end

function WF.Record(kind, fields)
  if WF.Storage and WF.Storage.AddLog then
    WF.Storage:AddLog(kind, fields)
    return
  end

  pendingLog[#pendingLog + 1] = { kind = kind, fields = fields }
  while #pendingLog > 50 do
    table.remove(pendingLog, 1)
  end
end

function WF.FlushPendingLog()
  if not WF.Storage or not WF.Storage.AddLog then return end
  for i = 1, #pendingLog do
    local entry = pendingLog[i]
    WF.Storage:AddLog(entry.kind, entry.fields)
  end
  pendingLog = {}
end

function WF.RecordError(scope, errorText)
  local safe = WF.Sanitize(errorText, 240)
  if WF.Storage and WF.Storage.AddError then
    WF.Storage:AddError(scope, safe)
  else
    WF.Record("ERROR", { scope = scope, error = safe })
  end
end

-- Live, unpersisted counters of what the dispatcher receives (shown by /wf capture).
WF.eventCounts = {}
WF.unresolvedEvents = 0

-- Forever passes the frame, event name and payload directly to OnEvent.
WF.handlerShape = "frame-event-args"
dispatcher:SetScript("OnEvent", function(_, eventName, ...)
  if type(eventName) ~= "string" then
    WF.unresolvedEvents = WF.unresolvedEvents + 1
    return
  end
  WF.eventCounts[eventName] = (WF.eventCounts[eventName] or 0) + 1

  local callbacks = listeners[eventName]
  if not callbacks then return end

  local a1, a2, a3, a4, a5, a6, a7, a8, a9 = ...
  for n = 1, #callbacks do
    local callback = callbacks[n]
    if callback then
      local ok, err = pcall(callback, eventName, a1, a2, a3, a4, a5, a6, a7, a8, a9)
      if not ok then
        WF.lastHandlerError = eventName .. ": " .. WF.Sanitize(err, 160)
        WF.RecordError(eventName .. " handler", err)
      end
    end
  end
end)

function WF.RegisterEvent(eventName, callback)
  if type(eventName) ~= "string" or type(callback) ~= "function" then
    return false, "invalid registration arguments"
  end

  if not listeners[eventName] then
    listeners[eventName] = {}
    local ok, err = pcall(dispatcher.RegisterEvent, dispatcher, eventName)
    registrations[eventName] = {
      attempted = true,
      accepted = ok and true or false,
      error = ok and nil or WF.Sanitize(err, 200),
    }
    if not ok then
      listeners[eventName] = nil
      WF.RecordError("RegisterEvent(" .. eventName .. ")", err)
      return false, err
    end
  end

  listeners[eventName][#listeners[eventName] + 1] = callback
  return true
end

function WF.GetEventRegistration(eventName)
  return registrations[eventName]
end
