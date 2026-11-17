local WF = Warfront
local Window = WF.MainWindow
local Guide = Window.Guide

-- Guide wiki pages (roadmap item 12). Rules and values follow
-- docs/player-guide-sources.md and the decisions it links; numbers are read
-- from the modules that own them each time a page opens, so a balance change
-- reaches the Guide by itself. Player-facing text only: what the player sees
-- and does, never how Warfront works inside (.claude/security-and-p2p.md).
--
-- Page markup, one line per entry: "# Title" is a heading, "- text" a bullet,
-- "" a gap, anything else a paragraph. "{id}" links to a page with its title,
-- "{id|text}" with other text. Never write "|" outside a link: the client
-- reads it as an escape code.
local Wiki = {}
Guide.Wiki = Wiki

Wiki.CATEGORIES = {
  { title = "Getting started", pages = { "welcome", "joining", "window", "commands" } },
  { title = "The map", pages = { "map", "outposts", "settlements", "warcamps", "capitals", "resourcepois" } },
  { title = "Capturing", pages = { "capture", "banner", "layers" } },
  { title = "The front", pages = { "campaigns", "front", "siege", "capitalsiege", "network" } },
  { title = "Economy", pages = { "resources", "gathering", "professions" } },
  { title = "Army", pages = { "units", "counters", "reserve", "garrisons", "warchest" } },
  { title = "Warfare", pages = { "scouting", "attacks", "battles", "travel" } },
  { title = "Scoreboard", pages = { "scoreboard", "points" } },
  { title = "Help", pages = { "news", "companion", "glossary" } },
}

local function Num(n)
  local text = tostring(math.floor(n or 0))
  local count
  repeat
    text, count = string.gsub(text, "^(-?%d+)(%d%d%d)", "%1,%2")
  until count == 0
  return text
end

local function Plural(n, word)
  return Num(n) .. " " .. word .. (n == 1 and "" or "s")
end

-- 180 -> "3 min", 117 -> "1 min 57 s", 10800 -> "3 hours", 1209600 -> "14 days".
local function Time(seconds)
  seconds = math.floor((seconds or 0) + 0.5)
  if seconds > 86400 and seconds % 86400 == 0 then return Plural(seconds / 86400, "day") end
  if seconds >= 3600 and seconds % 3600 == 0 then return Plural(seconds / 3600, "hour") end
  if seconds >= 60 and seconds % 60 == 0 then return Num(seconds / 60) .. " min" end
  if seconds > 60 then return Num(math.floor(seconds / 60)) .. " min " .. (seconds % 60) .. " s" end
  return seconds .. " s"
end

local function Unit(key)
  local unit = WF.Army.UNITS[key]
  return WF.L(unit.names.A) .. " / " .. WF.L(unit.names.H)
end

local function Cost(unit)
  return unit.gold + unit.wood + unit.food
end

-- The unit a combat unit is weak against: the one whose `beats` names it.
local function WeakTo(key)
  local units = WF.Army.UNITS
  for other, unit in pairs(units) do
    if unit.beats == key then return other end
  end
end

local function ISqrt(n)
  local root = math.floor(math.sqrt(n))
  while root * root > n do root = root - 1 end
  while (root + 1) * (root + 1) <= n do root = root + 1 end
  return root
end

-- Settlements in play on the running campaign's routes, as Assault Capacity counts them.
local function SettlementsInPlay()
  local total = 0
  for _, area in pairs(WF.Map and WF.Map.areas or {}) do
    if type(area) == "table" and area.enabled and area.type == "SETTLEMENT" then total = total + 1 end
  end
  return total
end

local function AreaLabel(id)
  local area = WF.Map and WF.Map.areas and WF.Map.areas[id]
  return area and WF.L(tostring(area.label or id)) or tostring(id)
end

local function MyFaction()
  local mine = WF.Capture and WF.Capture:MyFaction()
  if mine == "H" or mine == "A" then return mine end
end

local FACTIONS = { H = "Horde", A = "Alliance" }
local OTHER = { H = "A", A = "H" }

local P = {}
Wiki.PAGES = P

-- Getting started ---------------------------------------------------------------
-- Pages say each fact once, as short as it stays clear; a link replaces any
-- repeat (user, 2026-11-16).

P.welcome = { title = "Welcome to Warfront", build = function()
  return {
    "Alliance and Horde fight over the open world's {outposts|Outposts}, {settlements|Settlements} and"
      .. " {warcamps|War Camps}. Orange words are links; Back returns.",
    "# The game loop",
    "- {gathering|Gather} gold, wood and food.",
    "- {reserve|Recruit} units.",
    "- {capture|Capture} Outposts and War Camps.",
    "- Defend with {garrisons}.",
    "- {scouting|Scout}, then {attacks|attack}.",
    "- Take a zone's Outposts to open its Settlement {siege}.",
    "- Reach the enemy {capitals|capital} to win the {campaigns|campaign}.",
    "# Start here",
    "{joining|Taking part}, {window|the window}, {map|the map}, {commands|commands}, {glossary}.",
  }
end }

P.joining = { title = "Taking part", build = function()
  return {
    "- Normal and PvP rulesets.",
    "- Level 5 or higher.",
    "- PvP flag on to capture and gather ({professions} need none).",
    "# Counted in a place",
    "Inside it, alive, not mounted, stealthed, invisible or AFK. One place at a time; the {banner} says why you are"
      .. " not counted.",
  }
end }

P.window = { title = "The Warfront window", build = function()
  return {
    "/wf or the minimap button (drag to move it). ? opens this Guide.",
    "- Territory: War Balance (routes, {network|Front Network}) and places near you.",
    "- Resources: your {resources} and {gathering}.",
    "- Army: {reserve} and recruiting; its Garrison tab inside your places ({garrisons}).",
    "- War: campaign time left, {front|fronts}, open {siege|sieges}.",
    "- Scoreboard: {scoreboard|rankings}.",
    "- Players: Warfront players around you.",
    "- Right drawer: your Active Front objective. Bottom drawer: {news}.",
    "",
    "/wf classic: text-only window.",
  }
end }

P.commands = { title = "Slash commands", build = function()
  return {
    "- /wf: window. /wf help: this list. /wf classic: text window.",
    "- /wf tab: reopen the Warfront chat tab.",
    "- /wf where: your place and {layers|layer}.",
    "- /wf layerhelp on or off: help allies join your layer.",
    "- /wf army, /wf recruit <unit> [count]: {reserve}.",
    "- /wf res: {resources} and the stock here.",
    "- /wf garrison, /wf pledge <unit, gold or wood> [count] confirm: {garrisons}.",
    "- /wf scout [POI id]: {scouting}.",
    "- /wf attack [POI id footmen riflemen mortars]: {attacks}.",
    "- /wf companion [hide or show]: {companion}.",
    "",
    "Units: footman, rifleman, mortar, scout (Horde names work).",
  }
end }

-- The map -------------------------------------------------------------------------

P.map = { title = "Map and places", build = function()
  return {
    "On the world, continent and mini maps; the world map's Warfront checkbox hides them.",
    "- Capturable: {outposts|Outpost}, {settlements|Settlement}, {warcamps|War Camp}, {capitals|Capital}.",
    "- Shared, never captured: {resourcepois|Gold Mine, Forest, Farm}.",
    "# Reading it",
    "- Area colour = owner: blue Alliance, red Horde, grey neutral.",
    "- Icon: challenger past 50%, Settlement level 1 to 3, siege animation.",
    "- Route: emblems on held stops, gold active front, grey locked parts.",
    "- Dotted lines: scouts and armies marching (sender and units hidden).",
    "- Hover: owner, capture, garrison, siege, scouting, armies.",
    "",
    "Only route zones of the {campaigns|campaign} are in play; War Camps and resources always are.",
  }
end }

P.outposts = { title = "Outposts", build = function()
  local cap, gar = WF.Capture, WF.Garrison
  return {
    "- {capture|Capture}: " .. Time(cap.CAPTURE_DURATION) .. ", up to " .. Time(cap.OUTPOST_MAX_DURATION)
      .. " with a full garrison.",
    "- {garrisons|Garrison}: " .. gar.OUTPOST_CAPACITY .. " Unit Size.",
    "- Attack where the {front|Active Front} allows; always defendable.",
    "- Departure point for {scouting|scouts} and {attacks|armies}.",
    "- All Outposts of a front zone open its {siege}.",
  }
end }

P.settlements = { title = "Settlements", build = function()
  local cap, sizes = WF.Capture, WF.Garrison.SETTLEMENT_CAPACITY
  return {
    "Route stops, neutral at start, taken by {siege} only.",
    "- Capture: " .. Time(cap.SETTLEMENT_DURATION) .. ", up to " .. Time(cap.SETTLEMENT_MAX_DURATION)
      .. " with a full garrison.",
    "- Garrison: " .. sizes[1] .. " / " .. sizes[2] .. " / " .. sizes[3] .. " Unit Size by {warchest|level}.",
    "- Held: recruit here, send {scouting|scouts} and {attacks|armies}, raise your Assault Capacity.",
    "- Enemy-held zone: +30% {gathering}.",
    "- Lost: garrison, level and War Chest reset.",
  }
end }

P.warcamps = { title = "War Camps", build = function()
  local net = WF.FrontNetwork
  local lines = {
    "- Open to both factions at any time.",
    "- Capture: " .. Time(WF.Capture.WAR_CAMP_DURATION) .. ", no garrison.",
    "- Held: recruit every unit and scouts.",
    "- Never a departure point or a target.",
    "- Feeds your {network|Front Network}; 2 {points|Territory points} per capture, 1 per defense.",
    "- Neutral again each {campaigns|campaign}.",
  }
  if net then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Today: " .. net:Total("EK") .. " in the Eastern Kingdoms, " .. net:Total("KA") .. " in Kalimdor."
  end
  return lines
end }

P.capitals = { title = "Capitals", build = function()
  return {
    "Stormwind (Alliance) and Orgrimmar (Horde) end the routes.",
    "- Always open to recruit and as a departure point for their faction.",
    "- No garrison, scouting or army attack: taken only in a {capitalsiege|capital siege}.",
    "- Its fall ends the {campaigns|campaign}.",
  }
end }

P.resourcepois = { title = "Gold Mines, Forests and Farms", build = function()
  local types = WF.Stock.TYPES
  local function Line(name, key, resource)
    local t = types[key]
    return "- " .. WF.L(name) .. ": " .. WF.L(resource) .. ", stock " .. Num(t.capacity) .. ", +" .. t.regen .. " per min."
  end
  return {
    "Shared by both factions, never captured. Stand inside, PvP flag on, to {gathering|gather}.",
    Line("Gold Mine", "GOLD_MINE", "Gold"),
    Line("Forest", "FOREST", "Wood"),
    Line("Farm", "FARM", "Food"),
    "",
    "An empty stock gives nothing until it refills. The top banner shows stock and refill time.",
  }
end }

-- Capturing -------------------------------------------------------------------------

P.capture = { title = "Capturing a place", build = function()
  local cap = WF.Capture
  return {
    "Stand inside, {joining|counted}. One shared bar:",
    "- More players: full speed, never faster.",
    "- Equal numbers: frozen.",
    "- Empty: returns at half speed.",
    "- Enemy place: yours at 100%. Neutral: first push the other side back to 0.",
    "# Full bar",
    "- {outposts|Outpost} " .. Time(cap.CAPTURE_DURATION) .. " to " .. Time(cap.OUTPOST_MAX_DURATION) .. ", {settlements|Settlement} "
      .. Time(cap.SETTLEMENT_DURATION) .. " to " .. Time(cap.SETTLEMENT_MAX_DURATION) .. " (by garrison).",
    "- {warcamps|War Camp} " .. Time(cap.WAR_CAMP_DURATION) .. ", {capitals|Capital} " .. Time(cap.CAPITAL_DURATION) .. ".",
    "- Garrison changes keep the reached %; your {network|Front Network} can shorten it.",
    "# Also",
    "- Where you may attack: {front|Active Front}. Defending is always open.",
    "- A start alerts the enemy (banner, chat, sound; once a minute per place).",
    "- A capture wipes the garrison; a Settlement also loses its level and {warchest|War Chest}.",
  }
end }

P.banner = { title = "Capture banner", build = function()
  return {
    "Top of the screen, inside a place:",
    "- name, state, players per side, bar, time left;",
    "- details, such as {siege} time or what is missing;",
    "- \"You are not counted\" and why ({joining}).",
    "",
    "+/- folds it. At {resourcepois|resources} it shows the stock. Fight on another layer: Join it ({layers}).",
  }
end }

P.layers = { title = "World layers", build = function()
  return {
    "Layers are copies of a zone; players on different ones do not see each other.",
    "- The fight is on the layer with the most counted players.",
    "- Enemies on another layer halve your speed, never freeze it; the {banner} counts them.",
    "- Join it (banner button): an ally there invites you; you leave the group after the jump. Out of combat,"
      .. " toward the fight only, with a cooldown.",
    "",
    "/wf layerhelp off stops you inviting; /wf where shows your layer.",
  }
end }

-- The front -------------------------------------------------------------------------

P.campaigns = { title = "Campaigns", build = function()
  local front, campaign = WF.Front, WF.Campaign
  local lines = {}
  local name = front and front.HasRoutes and front:HasRoutes() and front.campaignName
  local left = campaign and campaign.LeftText and campaign:LeftText()
  if type(left) ~= "string" or left == "" then left = nil end
  if type(name) == "string" and name ~= "" then
    lines[#lines + 1] = "Now: " .. name .. "." .. (left and (" " .. left .. ".") or "")
  elseif left then
    lines[#lines + 1] = left .. "."
  end
  local rest = {
    "- Up to 14 days; ends at once when a {capitals|capital} falls. The next starts immediately.",
    "- Winner: the capital taker; at the time limit, the most route Settlements; otherwise none.",
    "# New campaign",
    "- All places neutral; garrisons, War Chests, levels and scouting cleared.",
    "- You keep your {resources} and {reserve}; marching armies and waiting gifts return to it.",
    "- Routes may change.",
    "",
    "No {capitalsiege|capital siege} starts in the last 24 hours.",
  }
  for index = 1, #rest do lines[#lines + 1] = rest[index] end
  return lines
end }

P.front = { title = "Active Front", build = function()
  local front = WF.Front
  local lines = { "One route of Settlements per continent, ending at the defender's {capitals|capital}." }
  local routes = front and front.HasRoutes and front:HasRoutes() and front.routes
  if type(routes) == "table" and #routes > 0 then
    for r = 1, #routes do
      local route = routes[r]
      local nodes, names = route.nodes, {}
      for n = 1, #nodes do names[n] = AreaLabel(nodes[n].id) end
      local capital = front.capitalOf and front.capitalOf[route.id]
      lines[#lines + 1] = "# " .. tostring(route.name or route.id)
      lines[#lines + 1] = table.concat(names, ", ") .. (capital and (", " .. AreaLabel(capital)) or "") .. "."
      lines[#lines + 1] = WF.L(FACTIONS[route.advancing]) .. " from " .. names[1] .. ", "
        .. WF.L(FACTIONS[OTHER[route.advancing]]) .. " from " .. names[#names] .. "."
    end
  else
    lines[#lines + 1] = "Routes appear when the first {campaigns|campaign} begins."
  end
  local rest = {
    "# Rules",
    "- Your target: the next Settlement after your held chain, from your end. Never skipped.",
    "- {outposts|Outposts}: capturable from your end to your target's zone.",
    "- All Outposts of the target zone start its {siege} (one per continent at a time).",
    "- During a siege its zone's Outposts are locked, and the defender cannot attack in its own target zone"
      .. " (defending stays open).",
    "- Taken: the front moves. Failed: the besieger's Outposts there turn neutral.",
    "- Whole route held: {capitalsiege|capital siege}.",
  }
  for index = 1, #rest do lines[#lines + 1] = rest[index] end
  return lines
end }

P.siege = { title = "Settlement sieges", build = function()
  local cap, front = WF.Capture, WF.Front
  return {
    "Starts when your faction takes the last {outposts|Outpost} of its target zone. Lasts " .. Time(front.WINDOW) .. ".",
    "# To capture",
    "- your faction's target, siege running;",
    "- every Outpost of the zone held;",
    "- a {scouting} in the last hour (enemy-held only);",
    "- 1 attacker inside (neutral) or " .. cap.SIEGE_ATTACKERS .. " (enemy).",
    "The War tab checks each one.",
    "# Capture",
    "- " .. Time(cap.SETTLEMENT_DURATION) .. " to " .. Time(cap.SETTLEMENT_MAX_DURATION) .. " by garrison; never blocked by it.",
    "- Lone attacker, empty enemy Settlement: frozen.",
    "- Nobody inside: slow return; open until the siege ends.",
    "- Taken: garrison, level and {warchest|War Chest} reset. Held: the besieger's Outposts turn neutral.",
    "# Armies and gifts",
    "- {attacks|Armies} may attack it only during its siege.",
    "- No unit gifts while " .. cap.SIEGE_ATTACKERS .. " attackers are inside, a battle waits, or one killed defenders"
      .. " in the last 5 min. Gold and wood: blocked only during a capture.",
  }
end }

P.capitalsiege = { title = "Capital sieges", build = function()
  local cap, front = WF.Capture, WF.Front
  return {
    "Starts once the advancing faction holds its whole route. Lasts " .. Time(front.CAPITAL_WINDOW) .. ".",
    "- Locks every Outpost and Settlement of that continent; the other goes on.",
    "- Never in a {campaigns|campaign}'s last 24 hours.",
    "# Capture",
    "- " .. cap.CAPITAL_ATTACKERS .. "+ attackers inside, more than defenders; " .. Time(cap.CAPITAL_DURATION) .. ".",
    "- No garrison, army or scouting.",
    "- Under " .. cap.CAPITAL_ATTACKERS .. " attackers: frozen. None: slow return. More defenders: pushed back.",
    "# Result",
    "- Fallen: campaign won ({points|10 points} per attacker inside).",
    "- Held: the last Settlement and its Outposts turn neutral.",
  }
end }

P.network = { title = "Front Network", build = function()
  local net = WF.FrontNetwork
  local lines = {
    "{warcamps|War Camps} your faction holds on a continent:",
    "- Travel: {scouting|scouts} and {attacks|armies} going there up to " .. net.TRAVEL_MAX .. "% faster (set at"
      .. " departure).",
    "- Capture: your Outpost and Settlement captures there up to " .. net.CAPTURE_MAX .. "% faster while you"
      .. " outnumber the enemy.",
    "- Not for War Camps or capitals.",
  }
  -- One table for every continent with the same number of camps (user,
  -- 2026-11-16: the same rows twice were noise); a continent with another
  -- count gets its own.
  local done = {}
  for c = 1, #net.CONTINENTS do
    local total = net:Total(net.CONTINENTS[c])
    if not done[total] then
      done[total] = true
      local names = {}
      for other = 1, #net.CONTINENTS do
        local code = net.CONTINENTS[other]
        if net:Total(code) == total then names[#names + 1] = WF.L(net.CONTINENT_NAMES[code]) end
      end
      lines[#lines + 1] = "# " .. table.concat(names, " and ") .. ": " .. total .. " camps"
      if total <= 0 then
        lines[#lines + 1] = "None placed yet."
      else
        for held = 1, total do
          lines[#lines + 1] = "- " .. held .. " held: travel -" .. net.Percent(net.TRAVEL_MAX, held, total)
            .. "%, capture -" .. net.Percent(net.CAPTURE_MAX, held, total) .. "%"
        end
      end
    end
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Shown in the Territory tab under each route."
  return lines
end }

-- Economy ---------------------------------------------------------------------------

P.resources = { title = "Gold, wood and food", build = function()
  local caps = WF.Economy.CAPS
  return {
    "Warfront-only resources, kept across {campaigns|campaigns}.",
    "- Limit: " .. Num(caps.gold) .. " gold, " .. Num(caps.wood) .. " wood, " .. Num(caps.food) .. " food.",
    "- Earn: {gathering}, {professions}.",
    "- Spend: {reserve|recruits}, {warchest|War Chests}.",
    "",
    "Resources tab or /wf res.",
  }
end }

P.gathering = { title = "Gathering", build = function()
  local stock = WF.Stock
  return {
    "Inside a {resourcepois|Gold Mine, Forest or Farm}, {joining|counted}: +" .. stock.GATHER_AMOUNT .. " every "
      .. stock.GATHER_TICK .. " s.",
    "- Shared stock; empty gives nothing until it refills.",
    "- A full resource stops that one.",
    "- Enemy-held zone: +30% (\"+30% enemy land\"). Not in your own, neutral or off-route zones.",
  }
end }

P.professions = { title = "Professions", build = function()
  local rewards = WF.Professions and WF.Professions.REWARDS or {}
  local function Reward(key, label)
    local r = rewards[key]
    if not r then return nil end
    return "- " .. WF.L(label) .. ": +" .. r.amount .. " " .. WF.L(r.name)
  end
  local lines = {}
  local list = { Reward("ore", "Ore node"), Reward("herb", "Herb"), Reward("fish", "Fish"), Reward("dish", "Cooked dish") }
  for index = 1, 4 do
    if list[index] then lines[#lines + 1] = list[index] end
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Anywhere, no flag or level, up to your {resources|limits}."
  return lines
end }

-- Army ------------------------------------------------------------------------------

P.units = { title = "Units", build = function()
  local army = WF.Army
  local lines = { "Alliance / Horde names:" }
  for index = 1, #army.ORDER do
    local key = army.ORDER[index]
    local u = army.UNITS[key]
    local line = "- " .. Unit(key) .. ": " .. u.gold .. " gold, " .. u.wood .. " wood, " .. u.food .. " food. Size "
      .. u.size
    if u.scout then
      line = line .. ", {scouting|scout} only."
    else
      line = line .. ", ATK " .. u.atk .. ", DEF " .. u.def .. "."
    end
    lines[#lines + 1] = line
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Per Unit Size every fighter is equal; only {counters} differ. Size counts in your {reserve},"
    .. " {garrisons} and {attacks|armies}."
  return lines
end }

P.counters = { title = "Strengths and weaknesses", build = function()
  local army = WF.Army
  local lines = {}
  for index = 1, #army.ORDER do
    local key = army.ORDER[index]
    local u = army.UNITS[key]
    if u.beats then lines[#lines + 1] = "- " .. Unit(key) .. " beats " .. Unit(u.beats) .. "." end
  end
  local rest = {
    "# Per 20 Unit Size sent",
    "Destroys about 17 with the counter, 13 neutral, 9 wrong, 13 against a mixed garrison.",
    "# Tips",
    "- {scouting|Scout}, then send the counter.",
    "- Defend mixed: no weakness.",
  }
  for index = 1, #rest do lines[#lines + 1] = rest[index] end
  return lines
end }

P.reserve = { title = "Reserve and recruiting", build = function()
  return {
    "Up to " .. WF.Army.RESERVE_CAPACITY .. " Unit Size, scouts included; kept across {campaigns|campaigns}.",
    "- Recruit in your {capitals|capital}, or a held {settlements|Settlement} or {warcamps|War Camp}.",
    "- Army tab (+1, +5) or /wf recruit. All or nothing.",
    "- Units leave for {garrisons}, {scouting|scouts} and {attacks|armies} and never return (except armies"
      .. " marching when a campaign ends).",
  }
end }

P.garrisons = { title = "Garrisons", build = function()
  local cap, gar = WF.Capture, WF.Garrison
  local sizes = gar.SETTLEMENT_CAPACITY
  return {
    "Units given to a held {outposts|Outpost} or {settlements|Settlement}, from inside. Final.",
    "- Capacity: Outpost " .. gar.OUTPOST_CAPACITY .. "; Settlement " .. sizes[1] .. " / " .. sizes[2] .. " / "
      .. sizes[3] .. " by {warchest|level}.",
    "- Slows enemy captures (Outpost up to " .. Time(cap.OUTPOST_MAX_DURATION) .. ", Settlement "
      .. Time(cap.SETTLEMENT_MAX_DURATION) .. "); never blocks.",
    "- Fought by {attacks|armies}, seen by {scouting|scouts}, wiped by a capture.",
    "- No scouts; nothing for a neutral Settlement.",
    "# Gifts blocked",
    "- during an enemy capture;",
    "- 2 min before an enemy army arrives;",
    "- while a battle waits, then a lock ({battles});",
    "- in a {siege}, per its rules.",
    "",
    "The Garrison tab shows the added capture time before Yes.",
  }
end }

P.warchest = { title = "War Chest and levels", build = function()
  local gar = WF.Garrison
  local gold, wood, sizes = gar.LEVEL_GOLD, gar.LEVEL_WOOD, gar.SETTLEMENT_CAPACITY
  return {
    "Gold and wood given to a held {settlements|Settlement} (final). Totals set its level:",
    "- Level 1: garrison " .. sizes[1] .. ".",
    "- Level 2: " .. Num(gold[2]) .. " gold + " .. Num(wood[2]) .. " wood; garrison " .. sizes[2] .. ".",
    "- Level 3: " .. Num(gold[3]) .. " gold + " .. Num(wood[3]) .. " wood; garrison " .. sizes[3] .. ".",
    "",
    "Closed during an enemy capture. Reset when the Settlement falls or a {campaigns|campaign} ends. Counts as"
      .. " {points|War effort}.",
  }
end }

-- Warfare ---------------------------------------------------------------------------

P.scouting = { title = "Scouting", build = function()
  local scout = WF.Army.UNITS.SCOUT.names
  return {
    "Send a " .. WF.L(scout.A) .. " / " .. WF.L(scout.H) .. " from your Outpost, Settlement or capital to an enemy Outpost or"
      .. " Settlement. Used up.",
    "- Arrival: target discovered " .. Time(WF.Scout.DISCOVERY) .. " for your faction (garrison visible,"
      .. " {attacks} allowed).",
    "- One scout out per player; none to a discovered target or one already scouted toward.",
    "- Target captured first: nothing found.",
    "- Needed for an enemy {siege}. Time: {travel}.",
    "",
    "/wf scout [POI id]",
  }
end }

P.attacks = { title = "Attacks", build = function()
  local atk = WF.Attack
  local min, max = atk.ASSAULT.min, atk.ASSAULT.max
  local total = SettlementsInPlay()
  local lines = {
    "From your Outpost, Settlement or capital to a {scouting|discovered} enemy Outpost or Settlement (Settlement:"
      .. " {siege} only).",
    "- One per player; units never return.",
    "- Target changes hands first: cancelled, units lost.",
    "- The enemy sees the route, not the army.",
    "- Time: {travel}; then a {battles|battle}.",
    "# Assault Capacity",
    "Max army Unit Size, " .. min .. " to " .. max .. " by Settlements held:",
  }
  if total > 0 then
    local values, span = {}, max - min
    for held = 0, total do
      values[#values + 1] = held .. " = " .. (min + ISqrt(math.floor(span * span * held / total)))
    end
    lines[#lines + 1] = "- " .. table.concat(values, ", ")
    local mine = MyFaction()
    if mine and atk.AssaultCapacity then
      lines[#lines + 1] = "- Your faction now: " .. atk:AssaultCapacity(mine)
    end
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "/wf attack [POI id footmen riflemen mortars]"
  return lines
end }

P.battles = { title = "Battles", build = function()
  return {
    "One battle on arrival: kills defenders only, never captures.",
    "- Losses follow numbers and {counters}.",
    "- The army is spent.",
    "# Reinforcement lock (after kills)",
    "- Outpost: 1 min per Unit Size sent, max " .. Time(WF.Attack.LOCK_MAX) .. ", not stacked.",
    "- Besieged Settlement: 5 min.",
  }
end }

P.travel = { title = "Travel times", build = function()
  local t = WF.Scout.TRAVEL
  return {
    "- Same zone: " .. t.speed .. " yards per second, " .. Time(t.sameZone[1]) .. " to " .. Time(t.sameZone[2]) .. ".",
    "- Same continent: " .. Time(t.sameContinent) .. ".",
    "- Other continent: " .. Time(t.otherContinent) .. ".",
    "",
    "Up to -" .. WF.FrontNetwork.TRAVEL_MAX .. "% with your {network|Front Network}.",
  }
end }

-- Scoreboard ------------------------------------------------------------------------

P.scoreboard = { title = "Scoreboard", build = function()
  return {
    "- Current {campaigns|campaign} or History; Players or Guilds.",
    "- Boards: Territory, PvP, War effort ({points}).",
    "- Click a column title to sort.",
    "- Your row and your guild's always show (in the top 100 or below it).",
    "- Full rankings need the {companion|Companion} (yours, or a guild or group member's).",
  }
end }

P.points = { title = "Scoring points", build = function()
  local units = WF.Army.UNITS
  return {
    "# Territory",
    "- Capture: {warcamps|War Camp} 2, {outposts|Outpost} 4, {settlements|Settlement} 20, {capitals|capital} 80"
      .. " (inside during its last minute).",
    "- Defense, half: 1, 2, 10, 40. A real enemy capture fails while you hold the place to the end.",
    "- Captures once per place per hour; defenses once per siege, or per hour where there is none.",
    "# PvP",
    "- Kills (killing blows + assists) against the other faction. Deaths and K/D shown.",
    "- Your killing blow on the same player counts once per hour.",
    "# War effort",
    "- 1 point per gold or wood given to {warchest|War Chests}.",
    "- Units sent or given: " .. WF.L(units.FOOTMAN.names.A) .. " " .. Cost(units.FOOTMAN) .. ", " .. WF.L(units.RIFLEMAN.names.A)
      .. " " .. Cost(units.RIFLEMAN) .. ", " .. WF.L(units.MORTAR.names.A) .. " " .. Cost(units.MORTAR) .. ".",
    "- {scouting|Scouts} sent: " .. WF.L(units.SCOUT.names.A) .. " " .. Cost(units.SCOUT) .. ".",
  }
end }

-- Help ------------------------------------------------------------------------------

P.news = { title = "News and connection", build = function()
  return {
    "News may arrive late, most of all when few players are online.",
    "- Bottom drawer light: green, orange or red freshness.",
    "- Not connected: use the Connect button.",
    "- Guild, group and friends with Warfront, and the {companion|Companion}, keep it fresher.",
    "- Keep Warfront up to date.",
    "",
    "/wf tab reopens the Warfront chat tab.",
  }
end }

P.companion = { title = "Warfront Companion", build = function()
  return {
    "Optional program; Warfront works without it.",
    "- Fresher map, also after time away.",
    "- Full {scoreboard} rankings.",
    "- /wf companion: status; hide or show: tips.",
  }
end }

P.glossary = { title = "Glossary", build = function()
  return {
    "- {front|Active Front}: the next Settlement a faction may besiege.",
    "- {attacks|Assault Capacity}: max Unit Size of one army.",
    "- {campaigns|Campaign}: up to 14 days, ends when a capital falls.",
    "- {capitals|Capital}: Stormwind or Orgrimmar.",
    "- {counters|Counter}: the unit that beats another.",
    "- {scouting|Discovered}: scouted by your faction in the last hour.",
    "- {network|Front Network}: your held War Camps' bonuses.",
    "- {garrisons|Garrison}: units defending a place.",
    "- {layers|Layer}: one copy of a zone.",
    "- {outposts|Outpost}: capturable place around a Settlement.",
    "- {reserve|Reserve}: your own units.",
    "- {settlements|Settlement}: route stop, taken by siege.",
    "- {siege|Siege}: timed window to take a Settlement or capital.",
    "- {units|Unit Size}: room a unit takes.",
    "- {warcamps|War Camp}: open camp feeding the Front Network.",
    "- {warchest|War Chest}: gold and wood that level a Settlement.",
    "- {points|War effort}: what you gave to the war.",
  }
end }

-- Home view -------------------------------------------------------------------------

-- The Guide sub-tab: a Contents list of categories, one open at a time with its
-- pages under it, and a reader with the open page. Links ("{id}") show in
-- yellow-orange; a click opens their page, Back returns along the pages read.
local Kit = Window.Kit
local UI = {
  CONTENTS_WIDTH = 178, LINK = "ffffa31a", PREFIX = "wfguide:", HISTORY = 30,
  TOP = 30, PAD = 12, BAR = 6, THUMB_MIN = 12, WHEEL = 40, TIP_X = 12, TIP_Y = 14,
  BULLET = 12, GAP = 6, HEADING_GAP = 8, AFTER_HEADING = 4, AFTER_LINE = 3,
}
Wiki.UI = UI

Guide.page = "welcome"
Guide.open = 1
Guide.history = {}
Guide.items = {}

local function CategoryOf(id)
  for index = 1, #Wiki.CATEGORIES do
    local pages = Wiki.CATEGORIES[index].pages
    for p = 1, #pages do
      if pages[p] == id then return index end
    end
  end
end

-- "{id}" and "{id|text}" become links to the page; an unknown id stays plain text.
function Wiki.Format(text)
  return (string.gsub(text, "{([%w_]+)|?([^}]*)}", function(id, label)
    local page = P[id]
    if label == "" then label = page and (WF.L and WF.L(page.title) or page.title) or id end
    if not page then return label end
    return "|c" .. UI.LINK .. "|H" .. UI.PREFIX .. id .. "|h" .. label .. "|h|r"
  end))
end

-- A page's lines, built now so its numbers are current.
function Wiki.Lines(id)
  local page = P[id]
  if not page then return nil end
  local ok, lines = pcall(page.build)
  if ok and type(lines) == "table" then
    if WF.L then
      for index = 1, #lines do lines[index] = WF.L(lines[index]) end
    end
    return lines
  end
  return { WF.L and WF.L("This page cannot be shown right now.") or "This page cannot be shown right now." }
end

function Guide:Open(id, remember)
  if not P[id] then return end
  if id ~= self.page then
    if remember then
      table.insert(self.history, self.page)
      if #self.history > UI.HISTORY then table.remove(self.history, 1) end
    end
    self.page = id
  end
  self.open = CategoryOf(id) or self.open
  self.rendered = nil
  self:Update()
end

function Guide:Back()
  local id = table.remove(self.history)
  if not id then return end
  self.page = id
  self.open = CategoryOf(id) or self.open
  self.rendered = nil
  self:Update()
end

function Guide:Pick(entry)
  if not entry then return end
  if entry.kind == "category" then
    if self.open == entry.index then self.open = 0 else self.open = entry.index end
    self:Update()
  else
    self:Open(entry.id, true)
  end
end

function Guide:BuildHome(height)
  local create = Kit.GetGlobal("CreateFrame")
  local skin = Kit.Skin()
  local width = UI.CONTENTS_WIDTH
  local contents = skin:Panel(self.home, "Contents", width, height)
  Kit.Place(contents, self.home, 0, 0)
  contents.auctionBackground = self:AuctionBackground(contents, self.AUCTION.MENU)
  -- As many 22 px rows as fit, stretched to end on the panel's bottom edge.
  local slots = math.floor((height - 26) / 22)
  self.menu = Kit.NewList(contents, slots, (height - 26) / slots, -24, function(row)
    row.normal = row:CreateTexture(nil, "BACKGROUND")
    if row.normal.SetAtlas then row.normal:SetAtlas(Guide.AUCTION.ROW, false) end
    -- Blizzard draws this 64 px atlas member at 32 UI px over a 21 px button;
    -- shrinking it to the hit row halves the visible painted height.
    row.normal:SetHeight(32)
    row.normal:SetPoint("TOPLEFT", row, "TOPLEFT", -2, 0)
    row.normal:SetPoint("TOPRIGHT", row, "TOPRIGHT", 2, 0)
    row.mark = row:CreateTexture(nil, "BORDER")
    if row.mark.SetAtlas then
      row.mark:SetAtlas(Guide.AUCTION.HOVER, false)
    else
      row.mark:SetTexture("Interface\\Buttons\\WHITE8X8")
      row.mark:SetVertexColor(0.22, 0.38, 1, 0.85)
    end
    row.mark:SetBlendMode("BLEND")
    row.mark:SetAllPoints(row)
    row.mark:Hide()
    row.hover = row:CreateTexture(nil, "BORDER")
    if row.hover.SetAtlas then row.hover:SetAtlas(Guide.AUCTION.HOVER, false) end
    row.hover:SetBlendMode("BLEND")
    row.hover:SetAllPoints(row)
    row.hover:Hide()
    row.heading = Kit.NewText(row, "GameFontNormalSmall", 8, -3, row:GetWidth() - 16)
    row.text = Kit.NewText(row, "GameFontHighlightSmall", 20, -3, row:GetWidth() - 28)
    -- A click opens the category or the page; the wheel still scrolls the list.
    local hit = create("Button", nil, row)
    hit:SetAllPoints(row)
    hit:EnableMouseWheel(true)
    hit:SetScript("OnClick", function() Guide:Pick(row.entry) end)
    hit:SetScript("OnMouseWheel", function(_, delta) Kit.Scroll.Wheel(Guide.menu, delta) end)
  end, true)
  -- The longest menu (every category and the largest one open) fits its rows,
  -- so the rows take the scrollbar's gutter and reach the panel's right side
  -- (user, 2026-11-16).
  for index = 1, #self.menu.rows do self.menu.rows[index]:SetWidth(contents.width - 12) end
  self.menu.bar:Hide()
  local reader = skin:Panel(self.home, "", Kit.CONTENT_WIDTH - width - Kit.GAP, height)
  Kit.Place(reader, self.home, width + Kit.GAP, 0)
  reader.auctionBackground = self:AuctionBackground(reader, self.AUCTION.PANEL)
  self.reader = reader
  self.back = skin:Button(reader, "dark", 56, 16, function() Guide:Back() end)
  self.back:SetPoint("TOPRIGHT", reader, "TOPRIGHT", -8, -5)
  self:BuildSheet(reader, height)
  -- Opening the window again rebuilds the page, so its numbers are current.
  self.home:SetScript("OnShow", function() Guide.rendered = nil end)
end

-- The reader's scrolling page: a scroll frame, its page frame (links enabled)
-- and a scrollbar like the lists' (wheel, click on the track, drag the thumb).
function Guide:BuildSheet(reader, height)
  local create = Kit.GetGlobal("CreateFrame")
  local width = reader.width - 2 * UI.PAD - UI.BAR - 2
  local scroll = create("ScrollFrame", nil, reader)
  scroll:SetPoint("TOPLEFT", reader, "TOPLEFT", UI.PAD, -UI.TOP)
  scroll:SetWidth(width)
  scroll:SetHeight(height - UI.TOP - 10)
  local sheet = create("Frame", nil, scroll)
  sheet:SetWidth(width)
  sheet:SetHeight(1)
  scroll:SetScrollChild(sheet)
  self.scroll, self.sheet, self.sheetWidth, self.viewHeight = scroll, sheet, width, height - UI.TOP - 10
  self.offset, self.range, self.pool = 0, 0, { heading = { used = 0 }, body = { used = 0 }, dot = { used = 0 } }
  local function Wheel(_, delta) Guide:ScrollTo(Guide.offset - (delta or 0) * UI.WHEEL) end
  scroll:EnableMouseWheel(true)
  scroll:SetScript("OnMouseWheel", Wheel)
  sheet:EnableMouse(true)
  sheet:EnableMouseWheel(true)
  sheet:SetScript("OnMouseWheel", Wheel)
  if sheet.SetHyperlinksEnabled then sheet:SetHyperlinksEnabled(true) end
  sheet:SetScript("OnHyperlinkClick", function(_, link)
    local id = string.match(tostring(link or ""), "^" .. UI.PREFIX .. "([%w_]+)")
    if id then Guide:Open(id, true) end
  end)
  sheet:SetScript("OnHyperlinkEnter", function(frame, link)
    local id = string.match(tostring(link or ""), "^" .. UI.PREFIX .. "([%w_]+)")
    local tip = Kit.GetGlobal("GameTooltip")
    if not id or not P[id] or not tip then return end
    -- Above and right of the pointer, clear of the hovered line (user, 2026-11-16).
    local cursor, parent = Kit.GetGlobal("GetCursorPosition"), Kit.GetGlobal("UIParent")
    tip:SetOwner(frame, "ANCHOR_NONE")
    tip:ClearAllPoints()
    if type(cursor) == "function" and parent then
      local x, y = cursor()
      local scale = parent:GetEffectiveScale()
      tip:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", x / scale + UI.TIP_X, y / scale + UI.TIP_Y)
    else
      tip:SetPoint("BOTTOMLEFT", frame, "TOPLEFT", 0, 4)
    end
  tip:SetText(WF.L("Click for more details."), 1, 1, 1)
    tip:Show()
  end)
  sheet:SetScript("OnHyperlinkLeave", function()
    local tip = Kit.GetGlobal("GameTooltip")
    if tip then tip:Hide() end
  end)
  self:BuildBar(reader)
end

function Guide:BuildBar(reader)
  local bar = Kit.NewFrame(reader, UI.BAR, self.viewHeight)
  Kit.Place(bar, reader, reader.width - 6 - UI.BAR, -UI.TOP)
  local track = bar:CreateTexture(nil, "BACKGROUND")
  track:SetTexture("Interface\\Buttons\\WHITE8X8")
  track:SetVertexColor(0, 0, 0, 0.35)
  track:SetAllPoints(bar)
  bar.thumb = bar:CreateTexture(nil, "ARTWORK")
  bar.thumb:SetTexture("Interface\\Buttons\\WHITE8X8")
  bar.thumb:SetVertexColor(0.85, 0.7, 0.35, 0.85)
  bar.thumb:SetWidth(UI.BAR)
  bar.thumb:Hide()
  -- Distance from the bar's top to the cursor, in the bar's own units.
  local function Depth()
    local cursor = Kit.GetGlobal("GetCursorPosition")
    local top = bar:GetTop()
    if type(cursor) ~= "function" or not top then return nil end
    local _, y = cursor()
    return top - y / bar:GetEffectiveScale()
  end
  local function Drag()
    local depth, room = Depth(), Guide.viewHeight - (bar.thumbHeight or 0)
    if not depth or not bar.thumbHeight or room <= 0 then return end
    Guide:ScrollTo((depth - bar.grab) / room * Guide.range)
  end
  bar:EnableMouse(true)
  bar:EnableMouseWheel(true)
  bar:SetScript("OnMouseWheel", function(_, delta) Guide:ScrollTo(Guide.offset - (delta or 0) * UI.WHEEL) end)
  bar:SetScript("OnMouseDown", function(_, button)
    if button and button ~= "LeftButton" then return end
    local depth = Depth()
    if not depth or not bar.thumbHeight then return end
    -- Held where it was taken; a click on the track centres the thumb there.
    local within = depth - bar.thumbTop
    if within >= 0 and within <= bar.thumbHeight then bar.grab = within else bar.grab = bar.thumbHeight / 2 end
    bar:SetScript("OnUpdate", Drag)
    Drag()
  end)
  bar:SetScript("OnMouseUp", function() bar:SetScript("OnUpdate", nil) end)
  bar:SetScript("OnHide", function() bar:SetScript("OnUpdate", nil) end)
  self.bar = bar
end

function Guide:ScrollTo(offset)
  offset = math.floor((offset or 0) + 0.5)
  if offset > self.range then offset = self.range end
  if offset < 0 then offset = 0 end
  self.offset = offset
  self.scroll:SetVerticalScroll(offset)
  local bar, view = self.bar, self.viewHeight
  if self.range <= 0 then
    bar.thumbHeight = nil
    bar.thumb:Hide()
    return
  end
  local thumb = math.max(UI.THUMB_MIN, math.floor(view * view / (view + self.range) + 0.5))
  local top = math.floor((view - thumb) * offset / self.range + 0.5)
  bar.thumbTop, bar.thumbHeight = top, thumb
  bar.thumb:ClearAllPoints()
  bar.thumb:SetPoint("TOPLEFT", bar, "TOPLEFT", 0, -top)
  bar.thumb:SetHeight(thumb)
  bar.thumb:Show()
end

-- Pooled pieces of the page: heading and body texts, bullet dots.
local TEMPLATES = { heading = "GameFontNormal", body = "GameFontHighlightSmall" }

function Guide:Take(kind)
  local pool = self.pool[kind]
  pool.used = pool.used + 1
  local piece = pool[pool.used]
  if not piece then
    if kind == "dot" then
      piece = self.sheet:CreateTexture(nil, "ARTWORK")
      piece:SetTexture("Interface\\Buttons\\WHITE8X8")
      piece:SetVertexColor(1, 0.82, 0)
      piece:SetWidth(4)
      piece:SetHeight(4)
    else
      piece = Kit.Skin():Text(self.sheet, TEMPLATES[kind])
      piece:SetJustifyV("TOP")
      -- Wrap at spaces only, never inside a word, and never cut with "...".
      if piece.SetWordWrap then piece:SetWordWrap(true) end
      if piece.SetNonSpaceWrap then piece:SetNonSpaceWrap(false) end
      if piece.SetMaxLines then piece:SetMaxLines(0) end
    end
    pool[pool.used] = piece
  end
  piece:ClearAllPoints()
  piece:Show()
  return piece
end

-- Each text keeps its width and no fixed height, so the client wraps it over
-- as many lines as it needs (user, 2026-11-16: never truncate); each piece
-- hangs under the previous one, so no height is measured to place it.
function Guide:Render()
  local sheet, width = self.sheet, self.sheetWidth
  for _, pool in pairs(self.pool) do pool.used = 0 end
  local lines = Wiki.Lines(self.page) or {}
  local previous, previousX, gap = nil, 0, 0
  for index = 1, #lines do
    local line = lines[index]
    if line == "" then
      gap = gap + UI.GAP
    else
      local kind, text, x = "body", line, 0
      local prefix = string.sub(line, 1, 2)
      if prefix == "# " then
        kind, text = "heading", string.sub(line, 3)
        if previous then gap = gap + UI.HEADING_GAP end
      elseif prefix == "- " then
        text, x = string.sub(line, 3), UI.BULLET
      end
      local piece = self:Take(kind)
      if previous then
        piece:SetPoint("TOPLEFT", previous, "BOTTOMLEFT", x - previousX, -gap)
      else
        piece:SetPoint("TOPLEFT", sheet, "TOPLEFT", x, -gap)
      end
      piece:SetWidth(width - x)
      piece:SetHeight(0)
      piece:SetText(Wiki.Format(text))
      if x > 0 then
        local dot = self:Take("dot")
        dot:SetPoint("TOPLEFT", piece, "TOPLEFT", 3 - x, -4)
      end
      previous, previousX = piece, x
      gap = kind == "heading" and UI.AFTER_HEADING or UI.AFTER_LINE
    end
  end
  for _, pool in pairs(self.pool) do
    for index = pool.used + 1, #pool do pool[index]:Hide() end
  end
  self.last = previous
  self.range, self.measures = 0, 3
  self:ScrollTo(0)
  self:Measure()
  -- Wrapped heights settle once the client lays the texts out: measure again
  -- on the next frames, then stop.
  self.scroll:SetScript("OnUpdate", function()
    Guide:Measure()
    Guide.measures = Guide.measures - 1
    if Guide.measures <= 0 then Guide.scroll:SetScript("OnUpdate", nil) end
  end)
  Kit.SetText(self.reader.title, P[self.page] and P[self.page].title or "")
  self.rendered = self.page
end

-- The page's height, from its top to the last text's bottom, sets the scroll range.
function Guide:Measure()
  local top = self.sheet:GetTop()
  local bottom = self.last and self.last:GetBottom()
  if not top or not bottom then return end
  local height = math.max(1, math.ceil(top - bottom) + UI.AFTER_LINE)
  self.sheet:SetHeight(height)
  self.range = math.max(0, height - self.viewHeight)
  self:ScrollTo(self.offset)
end

function Guide:UpdateHome()
  if not P[self.page] then self.page = "welcome" end
  local items, count = self.items, 0
  local function Add(kind, index, id)
    count = count + 1
    local entry = items[count] or {}
    entry.kind, entry.index, entry.id = kind, index, id
    items[count] = entry
  end
  for index = 1, #Wiki.CATEGORIES do
    Add("category", index, nil)
    if self.open == index then
      local pages = Wiki.CATEGORIES[index].pages
      for p = 1, #pages do Add("page", index, pages[p]) end
    end
  end
  while #items > count do items[#items] = nil end
  Kit.FillList(self.menu, count, function(row, item)
    local entry = items[item]
    local category = entry.kind == "category"
    row.entry = entry
    row.normal:SetAlpha(category and 1 or Guide.AUCTION.SUBMENU_ALPHA)
    Kit.Show(row.heading, category)
    Kit.Show(row.text, not category)
    Kit.Show(row.mark, not category and entry.id == Guide.page)
    if category then
      row.heading:SetText((Guide.open == entry.index and "- " or "+ ") .. WF.L(Wiki.CATEGORIES[entry.index].title))
    else
      Kit.SetText(row.text, P[entry.id].title)
      Kit.Skin():Color(row.text, entry.id == Guide.page and "GOLD" or "WHITE")
    end
  end)
  if self.rendered ~= self.page then self:Render() end
  Kit.Skin():SetButton(self.back, "Back", #self.history > 0)
end
