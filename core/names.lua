Warfront = Warfront or {}

local WF = Warfront

-- Character names on WoW: Forever (decision 0070). A character is a first
-- name plus a surname, unique per region. Chat events give the sender as
-- "First Surname": one space, no realm (CHAT_MSG_CHANNEL, measured 2026-11-07).
-- UnitName("player") returns the two parts apart
-- (Blizzard_FrameXMLUtil/Camelot/NameUtil.lua). Whisper targets and WTF
-- folders write "First-Surname". Every identity Warfront builds goes through
-- here, so a character is one key for itself and for every peer.
local Names = {
  SEPARATOR = " ",
  MAX_BYTES = 48,
}
WF.Names = Names

local strFind, strSub, strGsub, strMatch = string.find, string.sub, string.gsub, string.match

local function Global(name)
  if WF.Compat and WF.Compat.Global then return WF.Compat.Global(name) end
  return _G and _G[name] or nil
end

local function Call(name, ...)
  local fn = Global(name)
  if type(fn) ~= "function" then return false end
  return pcall(fn, ...)
end

local function IsSecret(value)
  local fn = Global("issecretvalue")
  return type(fn) == "function" and fn(value) and true or false
end

-- A non-empty string that can be compared and stored.
local function Plain(value)
  return type(value) == "string" and value ~= "" and not IsSecret(value)
end

local function Regional()
  local ok, enabled = Call("RegionalUniqueNamesEnabled")
  return ok and enabled == true
end

function Names.Realm()
  local ok, realm = Call("GetRealmName")
  if ok and Plain(realm) then return realm end
  return "unknown"
end

-- True for any spelling of the local realm a name suffix may use.
local function OwnRealm(text)
  if not Plain(text) then return false end
  local ok, realm = Call("GetRealmName")
  if ok and Plain(realm) and (text == realm or text == strGsub(realm, "%s", "")) then return true end
  local okNormalized, normalized = Call("GetNormalizedRealmName")
  return okNormalized and Plain(normalized) and text == normalized or false
end

-- A displayable character name: letters (ASCII or UTF-8) in parts joined by
-- single spaces; no realm, digit, punctuation or escape code.
function Names.Valid(name)
  if not Plain(name) or #name < 2 or #name > Names.MAX_BYTES then return false end
  if strFind(name, "[%c%p%d]") then return false end
  if strFind(name, "^ ") or strFind(name, " $") or strFind(name, "  ", 1, true) then return false end
  return true
end

-- First name and surname as one name, the way chat events write it.
function Names.Full(first, surname)
  if not Plain(first) then return nil end
  if Plain(surname) and not strFind(first, Names.SEPARATOR, 1, true) then
    return first .. Names.SEPARATOR .. surname
  end
  return first
end

-- A sender in any client spelling -> the chat name and its realm (nil for the
-- local realm). "First-Surname" becomes "First Surname" when names are
-- regional; a local realm suffix is dropped; anything else after the first
-- "-" stays a realm, as before decision 0070.
function Names.Split(sender)
  if not Plain(sender) then return nil end
  local dash = strFind(sender, "-", 1, true)
  if not dash then return sender, nil end
  if dash == 1 or dash == #sender then return nil end
  local first, rest = strSub(sender, 1, dash - 1), strSub(sender, dash + 1)
  if OwnRealm(rest) then return first, nil end
  if Regional() and not strFind(first, " ", 1, true) and not strFind(rest, "[%- ]") then
    return first .. Names.SEPARATOR .. rest, nil
  end
  return first, rest
end

-- "First Surname@Realm": the identity of a chat sender (rule R1).
function Names.Identity(sender)
  local name, realm = Names.Split(sender)
  if not name then return nil end
  return name .. "@" .. (realm or Names.Realm())
end

-- The local character as peers see it, and whether that name is final (false
-- while the client has not given the surname of a regional name yet).
function Names.Mine()
  local ok, first, surname = Call("UnitNameUnmodified", "player")
  if not ok or not Plain(first) then ok, first, surname = Call("UnitName", "player") end
  if not ok or not Plain(first) then return nil, false end
  local name = Names.Full(first, surname)
  local complete = strFind(name, Names.SEPARATOR, 1, true) ~= nil or not Regional()
  return name, complete
end

-- The chat name of an identity "Name@Realm" (display).
function Names.Short(identity)
  if type(identity) ~= "string" then return nil end
  return strMatch(identity, "^([^@]+)@") or identity
end

-- The key builds before decision 0070 used for this identity: "First@Realm".
function Names.Legacy(identity)
  if type(identity) ~= "string" then return nil end
  local name, realm = strMatch(identity, "^([^@]+)@(.+)$")
  local first = name and strMatch(name, "^([^ ]+) ")
  if not first then return nil end
  return first .. "@" .. realm
end

-- Saved tables keyed by identity: the entry under the old "First@Realm" key
-- moves to the full identity once, if that one has none yet. Characters that
-- share a first name shared that entry; the first to log in keeps it.
function Names.Adopt(t, identity)
  if type(t) ~= "table" then return false end
  local legacy = Names.Legacy(identity)
  if not legacy or t[legacy] == nil or t[identity] ~= nil then return false end
  t[identity], t[legacy] = t[legacy], nil
  return true
end
