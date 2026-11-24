Warfront = Warfront or {}

-- Release notes of the What's new page (modules/main_window_changelog.lua),
-- copied from CHANGELOG.md at each release, newest first. Every string other
-- than a version or a date is a key of all five catalogs
-- (tools/check_locales.py); the first version is the .toc version
-- (tools/smoke.py). 0.1.0 keeps one line: its full list is the launch.
Warfront.Changelog = {
  { version = "0.2.0", date = "2026-11-24", sections = {
    { "Added", {
      "Group Finder: find players of your faction to capture, siege or defend together, or list your group so they can join you (Players tab, /wf groups).",
      "Journal: see what was captured while you were away, so you know how the front moved before you play; with the Companion, more of them and when they happened.",
      "Players tab: see who is online in the other faction and on other rulesets, to know how many players are at war right now.",
      "Warfront window: click the version beside the title or at the bottom left to see what's new after each update.",
    } },
    { "Changed", {
      "Scoreboard: the Players rankings now include everyone, not only Companion users, so you see where you really stand.",
      "Players tab: see the ruleset of players from other realms after a short wait, to know who shares your war map.",
      "Chat: if Warfront is out of date, you are reminded every hour until you update.",
      "Map: a place you cannot capture now says why: your faction's front is not active there.",
      "Players tab: larger faction emblems, to tell Alliance from Horde at a glance.",
      "Territory tab: the places list shows no \"Other zones\" title when your zone has none.",
    } },
    { "Fixed", {
      "Players tab: Skyborne players had no faction emblem, so you could not tell their side.",
      "Warfront windows: some borders were missing, and buttons lit up on mouse-over without their bottom edge.",
    } },
  } },
  { version = "0.1.3", date = "2026-11-23", sections = {
    { "Heads up", {
      "Warfront window: until you are connected to other players, a connecting page replaces the tabs and you cannot capture, gather, scout or attack.",
    } },
    { "Added", {
      "Ironforge, Darnassus, Undercity and Thunder Bluff: recruit and send armies and scouts from there, like Stormwind and Orgrimmar.",
      "Capture banner: beside Join it, the layer changes you have used this hour (10 at most); the button waits when they are used up.",
      "Journal: with the Companion, captures made while you were away are listed after you log in.",
      "Journal: when the enemy captures a neutral place, the Journal says which faction took it.",
    } },
    { "Changed", {
      "Warfront now works on the RP and RP-PvP rulesets, each with its own map.",
      "Warfront now connects by itself when you click in the game, and reconnects if the connection drops.",
      "Scoreboard tab: Territory is sorted by Points until captures are confirmed.",
      "Players tab: hover a name to see the player's class and level.",
      "Players tab: shows the ruleset of more players.",
      "Connect button: tooltip says what to do if Warfront won't connect.",
      "Players tab: a turning arrow shows while Warfront is connecting.",
    } },
    { "Fixed", {
      "Capture banner: fights on another layer were no longer noticed after the game update, so Join it never showed.",
    } },
  } },
  { version = "0.1.2", date = "2026-11-23", sections = {
    { "Added", {
      "The Faction relay buttons in the Synchronization panel and the Players tab now show a green dot while Faction relay is on or managed in the Companion, and their tooltip says which.",
    } },
    { "Changed", {
      "Matchmaking is now called Faction relay, to say what it is for: sharing war data between Alliance and Horde.",
      "The Companion tooltip in the Synchronization panel is shorter and says it syncs your map with the cloud while the game is closed.",
    } },
    { "Fixed", {
      "The Companion synchronizes again after the latest game update.",
      "Normal and PvP realms no longer mix their war maps.",
      "After the latest game update, the Players tab again shows the region of every listed player and the ruleset of players from your own realm, and of other realms once Warfront has learned them, and some war news that stopped arriving arrives again.",
      "The War Camps of both continents in the War Balance now have the same size.",
    } },
  } },
  { version = "0.1.1", date = "2026-11-21", sections = {
    { "Added", {
      "A welcome window opens on your very first login with Warfront: your first steps, Matchmaking, your connection and the optional Companion. /wf welcome shows it again.",
      "While the Warfront Companion is not in use, a \"Get the Companion\" button on the Territory tab and a \"Download\" button in the Synchronization panel open its Windows and Mac download links, ready to copy.",
      "The Players tab now shows a faction emblem before each player's name and their region and realm type (such as \"EU PvP\") when the game can tell.",
      "During a siege, the animated catapult now also appears beside the besieged Settlement or Capital icon on its zone map.",
      "The Army tab now shows how many of each unit you have on the bottom-right corner of its portrait, instead of after its name.",
      "The Matchmaking button in the Synchronization panel and the one in the Players tab now have a short tooltip.",
      "A chat line now shows the Warfront name and version at login.",
    } },
    { "Changed", {
      "Faction capitals on the continent map's campaign route and in the War Balance now show the capital crown instead of the faction emblem.",
      "In the War Balance, once the attackers hold the first stop, the start of each front's line fades out and the stops move left to fill the space.",
      "Selecting Warfront in the AddOns options now shows the general options directly instead of an empty page.",
    } },
    { "Fixed", {
      "In the Garrison tab, +1 and +5 now add up: pick several units and resources, then confirm once to give them all. Your picks show as icons in the confirmation bar and as green \"+N\" on the garrison, capture time, units and War Chest, and what you keep shows on each portrait and resource icon.",
      "Capture alerts now name the place type (\"Outpost captured\", \"War Camp lost\", \"Settlement captured\", \"Capital lost\"...) instead of \"Territory captured\" or \"Territory lost\", and the Journal entry starts with the same title.",
      "Map markers and routes now update at once when switching between the world, continent and zone maps.",
      "The Yes/No confirmations for garrison pledges and army launches now show on a dark, gold-framed bar, so their text is easy to read.",
      "The siege catapult on a besieged capital now animates on the continent map instead of staying still.",
      "In the War Balance, when both factions face each other between two stops, their arrows now sit side by side instead of on top of each other.",
      "The Matchmaking invitation windows now grow to fit their text in every language, so it never overlaps the buttons.",
      "Map areas on a square minimap now fill it to the corners instead of being cut to a circle.",
    } },
  } },
  { version = "0.1.0", date = "2026-11-18", sections = {
    { "Added", {
      "First public release of Warfront.",
    } },
  } },
}
