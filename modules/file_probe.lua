Warfront = Warfront or {}

local WF = Warfront
local FileProbe = {
  running = false,
}

WF.FileProbe = FileProbe

-- In-game probe of the nampower file bridge (ReadCustomFile/WriteCustomFile in
-- <game>\CustomData), paired with tools/file_probe_writer.py as the external
-- writer. Diagnostic only: no channel traffic, no gameplay effect.
--
-- In file (writer -> addon), LF only:
--   WFPROBE1 <seq> <len>\n<payload of len bytes>\nEND <seq>\n
-- Out file (addon -> writer):
--   WFPROBE1 <outSeq> <lastInSeq> <reads> <torn> <errors>\n
local IN_FILE = "pc_probe_in.txt"
local OUT_FILE = "pc_probe_out.txt"
local SELF_FILE = "pc_probe_self.txt"
local SEQ_FILE = "pc_probe_seq.txt" -- a few bytes, written by the writer next to IN_FILE
local DEFAULT_READ_INTERVAL = 1.0
local WRITE_INTERVAL = 2.0

local frame = nil
local stats = nil
local readInterval = DEFAULT_READ_INTERVAL
local readElapsed = 0
local writeElapsed = 0

local function Available()
  return type(ReadCustomFile) == "function"
    and type(WriteCustomFile) == "function"
    and type(CustomFileExists) == "function"
end

-- Milliseconds spent in fn(), with its pcall results. fn is a closure: nampower
-- counts arguments, so a trailing nil is refused ("Usage: WriteCustomFile...").
local function Timed(fn)
  local started
  if debugprofilestart and debugprofilestop then
    debugprofilestart()
  else
    started = WF.Now()
  end
  local ok, result = pcall(fn)
  local ms
  if started then
    ms = (WF.Now() - started) * 1000
  else
    ms = debugprofilestop()
  end
  return ok, result, ms or 0
end

local function NewStats()
  return {
    reads = 0, missing = 0, errors = 0, torn = 0, changes = 0, backwards = 0,
    lastInSeq = 0, lastBytes = 0, readMsMax = 0, readMsTotal = 0,
    writes = 0, writeErrors = 0, writeMsMax = 0, outSeq = 0,
    lastError = nil, lastTorn = nil, startedAt = WF.Now(),
    exists = { n = 0, total = 0, max = 0, errors = 0 },
    small = { n = 0, total = 0, max = 0, errors = 0 },
  }
end

-- Returns seq, nil on a complete file; nil, reason on a torn or bad one.
local function ParseIn(text)
  local _, headerEnd, seqText, lenText = string.find(text, "^WFPROBE1 (%d+) (%d+)\n")
  if not headerEnd then return nil, "header" end
  local seq = tonumber(seqText)
  local len = tonumber(lenText)
  local payload = string.sub(text, headerEnd + 1, headerEnd + len)
  if #payload ~= len then return nil, "short payload" end
  local trailer = string.sub(text, headerEnd + len + 1)
  local _, _, endSeq = string.find(trailer, "^\nEND (%d+)\n?$")
  if not endSeq then return nil, "trailer" end
  if tonumber(endSeq) ~= seq then return nil, "seq mismatch" end
  return seq, nil
end

-- Running avg/max of a cheap call, to tell open cost from size cost.
local function Cost(key, fn)
  local ok, _, ms = Timed(fn)
  local entry = stats[key]
  entry.n = entry.n + 1
  entry.total = entry.total + ms
  if ms > entry.max then entry.max = ms end
  if not ok then entry.errors = entry.errors + 1 end
end

local function ReadOnce()
  Cost("exists", function() return CustomFileExists(IN_FILE) end)
  Cost("small", function() return ReadCustomFile(SEQ_FILE) end)
  local ok, text, ms = Timed(function() return ReadCustomFile(IN_FILE) end)
  stats.reads = stats.reads + 1
  stats.readMsTotal = stats.readMsTotal + ms
  if ms > stats.readMsMax then stats.readMsMax = ms end
  if not ok then
    stats.errors = stats.errors + 1
    stats.lastError = WF.Sanitize(text, 120)
    return
  end
  if text == nil then
    stats.missing = stats.missing + 1
    return
  end
  stats.lastBytes = #text
  local seq, reason = ParseIn(text)
  if not seq then
    stats.torn = stats.torn + 1
    stats.lastTorn = reason
    return
  end
  if seq > stats.lastInSeq then
    stats.changes = stats.changes + 1
    stats.lastInSeq = seq
  elseif seq < stats.lastInSeq then
    stats.backwards = stats.backwards + 1
  end
end

local function WriteOnce()
  stats.outSeq = stats.outSeq + 1
  local line = "WFPROBE1 " .. stats.outSeq .. " " .. stats.lastInSeq .. " " .. stats.reads
    .. " " .. stats.torn .. " " .. stats.errors .. "\n"
  local ok, err, ms = Timed(function() return WriteCustomFile(OUT_FILE, line) end)
  if ms > stats.writeMsMax then stats.writeMsMax = ms end
  if ok then
    stats.writes = stats.writes + 1
  else
    stats.writeErrors = stats.writeErrors + 1
    stats.lastError = WF.Sanitize(err, 120)
  end
end

local function OnUpdate(_, delta)
  local elapsed = delta or 0
  readElapsed = readElapsed + elapsed
  writeElapsed = writeElapsed + elapsed
  if readElapsed >= readInterval then
    readElapsed = 0
    ReadOnce()
  end
  if writeElapsed >= WRITE_INTERVAL then
    writeElapsed = 0
    WriteOnce()
  end
end

-- One-shot checks: path guard, write/read-back, line endings.
local function StaticChecks()
  local version = "?"
  if type(GetNampowerVersion) == "function" then
    local ok, a, b, c = pcall(GetNampowerVersion)
    if ok then version = tostring(a) .. (b and ("." .. tostring(b)) or "") .. (c and ("." .. tostring(c)) or "") end
  end
  WF.Print("fileprobe nampower " .. version)

  local escaped = pcall(ReadCustomFile, "..\\pc_probe_escape.txt")
  WF.Print("fileprobe path guard " .. (escaped and "FAILED (read outside CustomData allowed)" or "ok (refused)"))

  -- Text mode: "\n" lands on disk as "\r\n" and reads back as "\n".
  local wrote, werr = pcall(WriteCustomFile, SELF_FILE, "ab\ncd")
  if not wrote then
    WF.Print("fileprobe self write error: " .. WF.Sanitize(werr, 120))
    return
  end
  local read, back = pcall(ReadCustomFile, SELF_FILE)
  if not read or type(back) ~= "string" then
    WF.Print("fileprobe self read error: " .. WF.Sanitize(back, 120))
    return
  end
  WF.Print("fileprobe self read-back " .. WF.Sanitize(back, 40) .. " ("
    .. (back == "ab\ncd" and "ok" or "CHANGED") .. ")")
  local checked, exists = pcall(CustomFileExists, SELF_FILE)
  WF.Print("fileprobe CustomFileExists " .. (checked and tostring(exists) or "error"))
end

function FileProbe:Start(seconds)
  if not Available() then
    WF.Print("fileprobe: optional custom-file functions are unavailable")
    return
  end
  readInterval = tonumber(seconds) or DEFAULT_READ_INTERVAL
  if readInterval < 0.1 then readInterval = 0.1 end
  StaticChecks()
  stats = NewStats()
  readElapsed = 0
  writeElapsed = 0
  if not frame then frame = CreateFrame("Frame", nil, UIParent) end
  frame:SetScript("OnUpdate", OnUpdate)
  self.running = true
  WF.Print("fileprobe running: read " .. IN_FILE .. " every " .. readInterval .. " s, write "
    .. OUT_FILE .. " every " .. WRITE_INTERVAL .. " s. Start tools/file_probe_writer.py, then /wf fileprobe report")
end

function FileProbe:Stop()
  if frame then frame:SetScript("OnUpdate", nil) end
  self.running = false
  if stats then
    self:Report()
    WF.Record("FILEPROBE", {
      reads = stats.reads, missing = stats.missing, errors = stats.errors, torn = stats.torn,
      changes = stats.changes, backwards = stats.backwards, lastInSeq = stats.lastInSeq,
      lastBytes = stats.lastBytes, readMsMax = stats.readMsMax, writes = stats.writes,
      writeErrors = stats.writeErrors, writeMsMax = stats.writeMsMax,
      lastError = stats.lastError, lastTorn = stats.lastTorn,
      existsMsMax = stats.exists.max, smallMsMax = stats.small.max,
    })
  end
  WF.Print("fileprobe stopped")
end

function FileProbe:Report()
  if not stats then
    WF.Print("fileprobe: not started (/wf fileprobe start)")
    return
  end
  local average = 0
  if stats.reads > 0 then average = stats.readMsTotal / stats.reads end
  WF.Print(string.format("fileprobe %.0f s: reads=%d missing=%d errors=%d torn=%d changes=%d backwards=%d lastSeq=%d",
    WF.Now() - stats.startedAt, stats.reads, stats.missing, stats.errors, stats.torn,
    stats.changes, stats.backwards, stats.lastInSeq))
  WF.Print(string.format("fileprobe read %d bytes, avg %.2f ms, max %.2f ms; writes=%d errors=%d max %.2f ms",
    stats.lastBytes, average, stats.readMsMax, stats.writes, stats.writeErrors, stats.writeMsMax))
  local exists, small = stats.exists, stats.small
  WF.Print(string.format("fileprobe CustomFileExists avg %.2f max %.2f ms; small read avg %.2f max %.2f ms (errors %d)",
    exists.n > 0 and exists.total / exists.n or 0, exists.max,
    small.n > 0 and small.total / small.n or 0, small.max, small.errors))
  if stats.lastError then WF.Print("fileprobe last error: " .. stats.lastError) end
  if stats.lastTorn then WF.Print("fileprobe last torn read: " .. stats.lastTorn) end
end

function FileProbe:Command(rest)
  local option = string.lower(rest or "")
  local _, _, word, value = string.find(option, "^(%S*)%s*(.*)$")
  if word == "start" then
    self:Start(value ~= "" and value or nil)
  elseif word == "stop" then
    self:Stop()
  elseif word == "report" then
    self:Report()
  else
    WF.Print("/wf fileprobe start [readSeconds] | report | stop")
  end
end
