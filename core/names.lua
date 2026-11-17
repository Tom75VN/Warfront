Warfront = Warfront or {}

local WF = Warfront

-- Character names on WoW: Forever (decisions 0070 and 0096). A character is a
-- first name plus a surname, unique per region. Chat events give the sender as
-- "First Surname": one space, no realm (CHAT_MSG_CHANNEL, measured 2026-11-07).
-- UnitName("player") returns the two parts apart
-- (Blizzard_FrameXMLUtil/Camelot/NameUtil.lua). Whisper targets and WTF
-- folders write "First-Surname". Technical realms are not identities: every
-- identity Warfront builds is the bare full name inside the current ruleset.
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

-- "First Surname": the realm-free identity of a chat sender (rule R1,
-- decision 0096). Names are unique per region and every peer sees this spelling.
function Names.Identity(sender)
  local name = Names.Split(sender)
  if not name then return nil end
  return name
end

-- True when a chat name carries its surname, or names are not regional. A
-- first name alone is shared by several characters: never an identity.
function Names.Complete(name)
  if not Plain(name) then return false end
  return strFind(name, Names.SEPARATOR, 1, true) ~= nil or not Regional()
end

-- The local character as peers see it, and whether that name is final (false
-- while the client has not given the surname of a regional name yet).
function Names.Mine()
  local ok, first, surname = Call("UnitNameUnmodified", "player")
  if not ok or not Plain(first) then ok, first, surname = Call("UnitName", "player") end
  if not ok or not Plain(first) then return nil, false end
  local name = Names.Full(first, surname)
  return name, Names.Complete(name)
end

-- The chat name of an identity. This also strips the realm from keys saved by
-- builds before decision 0096.
function Names.Short(identity)
  if type(identity) ~= "string" then return nil end
  return strMatch(identity, "^([^@]+)@") or identity
end

-- The key builds before decision 0096 used for this identity on this technical
-- realm. Names.Adopt also finds the same full name under any former realm and
-- the pre-0070 first-name spelling.
function Names.Legacy(identity)
  identity = Names.Short(identity)
  if not identity or identity == "" then return nil end
  return identity .. "@" .. Names.Realm()
end

-- Saved tables keyed by identity: move one pre-0096 "Full Name@Realm" entry to
-- the realm-free full name on first access. Prefer the current technical realm,
-- then any former realm; the pre-0070 "First@Realm" spelling is the last
-- fallback. Existing realm-free data always wins and other aliases stay as an
-- untouched archive because their module-specific values cannot be merged
-- safely here. A first name alone is not final yet: nothing moves until the
-- surname is known, or an old entry would strand under that first name.
function Names.Adopt(t, identity)
  if type(t) ~= "table" then return false end
  identity = Names.Short(identity)
  if not identity or identity == "" or t[identity] ~= nil or not Names.Complete(identity) then return false end
  local realm = Names.Realm()
  local first = strMatch(identity, "^([^ ]+) ")
  local fullPrefix = identity .. "@"
  local firstPrefix = first and (first .. "@") or nil
  local legacy, rank
  for key, value in pairs(t) do
    if value ~= nil and type(key) == "string" then
      local candidate
      if key == fullPrefix .. realm then candidate = 1
      elseif strSub(key, 1, #fullPrefix) == fullPrefix then candidate = 2
      elseif firstPrefix and key == firstPrefix .. realm then candidate = 3
      elseif firstPrefix and strSub(key, 1, #firstPrefix) == firstPrefix then candidate = 4 end
      if candidate and (not rank or candidate < rank or (candidate == rank and key < legacy)) then
        legacy, rank = key, candidate
      end
    end
  end
  if not legacy then return false end
  t[identity], t[legacy] = t[legacy], nil
  return true
end
