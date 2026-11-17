Warfront = Warfront or {}

local WF = Warfront
local Locale = {}

WF.Locale = Locale
WF.Locales = WF.Locales or {}

local DEFAULT_LANGUAGE = "enUS"
local CLIENT_LANGUAGE = {
  enUS = "enUS",
  enGB = "enUS",
  frFR = "frFR",
  esES = "esES",
  esMX = "esES",
  ruRU = "ruRU",
  zhCN = "zhCN",
}
local LANGUAGES = {
  { value = "enUS", label = "English" },
  { value = "frFR", label = "French" },
  { value = "esES", label = "Spanish" },
  { value = "ruRU", label = "Russian" },
  { value = "zhCN", label = "Simplified Chinese" },
}
local SUPPORTED = {}

for _, language in ipairs(LANGUAGES) do SUPPORTED[language.value] = true end

Locale.DEFAULT = DEFAULT_LANGUAGE

local function TranslateFragments(text, sources, catalog, protected, start)
  -- Search only original pieces: French "Le front" must not be translated again.
  for index = start or 1, #sources do
    local source = sources[index]
    local replacement = catalog[source]
    if not protected[source] and #source >= 4 and string.find(source, "%s")
      and replacement and replacement ~= source then
      local first, last = string.find(text, source, 1, true)
      if first then
        return TranslateFragments(string.sub(text, 1, first - 1), sources, catalog, protected, index + 1)
          .. replacement .. TranslateFragments(string.sub(text, last + 1), sources, catalog, protected, index)
      end
    end
  end
  return text
end

function Locale:ProtectedNames()
  if self.protectedNames then return self.protectedNames end
  if type(WF.POIData) ~= "table" or type(WF.FrontData) ~= "table" then return {} end
  local names = {}
  for _, poi in ipairs(WF.POIData) do
    if type(poi.label) == "string" and poi.label ~= "" then names[poi.label] = true end
  end
  for _, set in pairs(WF.FrontData.routeSets or {}) do
    if type(set.name) == "string" and set.name ~= "" then names[set.name] = true end
  end
  self.protectedNames = names
  return names
end

function Locale:Register(language, catalog)
  if not SUPPORTED[language] or type(catalog) ~= "table" then return false end
  WF.Locales[language] = catalog
  self.orderedSources = nil
  return true
end

function Locale:Sources()
  if self.orderedSources then return self.orderedSources end
  local sources = {}
  for source in pairs(WF.Locales.enUS or {}) do table.insert(sources, source) end
  table.sort(sources, function(left, right)
    if string.len(left) == string.len(right) then return left < right end
    return string.len(left) > string.len(right)
  end)
  self.orderedSources = sources
  return sources
end

local function SavedSettings()
  local storage = WF.Storage
  if not storage or type(storage.GetDB) ~= "function" or storage.readOnly then return nil end
  local db = storage:GetDB()
  if type(db) ~= "table" or type(db.settings) ~= "table" then return nil end
  return db.settings
end

function Locale:ClientDefault()
  local getLocale = _G and _G.GetLocale
  if type(getLocale) ~= "function" then return DEFAULT_LANGUAGE end
  local ok, clientLanguage = pcall(getLocale)
  if not ok then return DEFAULT_LANGUAGE end
  return CLIENT_LANGUAGE[clientLanguage] or DEFAULT_LANGUAGE
end

function Locale:Get()
  local settings = SavedSettings()
  local language = settings and settings.language
  if SUPPORTED[language] then return language end
  if language ~= nil then return DEFAULT_LANGUAGE end
  return self:ClientDefault()
end

function Locale:Set(language)
  if not SUPPORTED[language] then return false end
  local settings = SavedSettings()
  if not settings then return false end
  settings.language = language
  return true
end

function Locale:Choices()
  local choices = {}
  for _, language in ipairs(LANGUAGES) do
    table.insert(choices, { value = language.value, label = self:Text(language.label) })
  end
  return choices
end

function Locale:Translate(source)
  if source == nil then return "" end
  if type(source) ~= "string" then return tostring(source) end
  local protected = self:ProtectedNames()
  if protected[source] then return source end
  local english = WF.Locales.enUS or {}
  local catalog = WF.Locales[self:Get()] or english
  local exact = catalog[source] or english[source]
  if exact then return exact end

  -- Some existing UI lines are assembled from trusted static fragments. The
  -- longest registered fragments are translated here while the migration keeps
  -- player names, numbers and identifiers intact. Single words are exact-only
  -- so a character name such as "Wood" is never translated by accident.
  if catalog == english then return source end
  return TranslateFragments(source, self:Sources(), catalog, protected)
end

function Locale:Text(source, ...)
  local translated = self:Translate(source)
  if select("#", ...) == 0 then return translated end
  local ok, formatted = pcall(string.format, translated, ...)
  if ok then return formatted end
  return translated
end

WF.L = function(source, ...) return Locale:Text(source, ...) end

function Locale:Initialize()
  local settings = SavedSettings()
  if settings and settings.language == nil then
    settings.language = self:ClientDefault()
  end
end

local function OnAddonLoaded(_, addonName)
  if string.lower(tostring(addonName or "")) == string.lower(WF.name) then
    Locale:Initialize()
  end
end

if WF.RegisterEvent then WF.RegisterEvent("ADDON_LOADED", OnAddonLoaded) end
