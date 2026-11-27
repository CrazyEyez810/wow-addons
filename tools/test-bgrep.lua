-- Checks BGRep's math and text against fake reputation data.
-- Usage: luajit tools/test-bgrep.lua BGRep/BGRep.lua
local failed = 0
local function check(name, got, want)
  if got == want then print("ok   " .. name)
  else failed = failed + 1 print("FAIL " .. name .. ":\n  got  " .. tostring(got) .. "\n  want " .. tostring(want)) end
end

-- The game ------------------------------------------------------------------
local rep = {
  [890] = { name = "Silverwing Sentinels", reaction = 5, currentReactionThreshold = 3000, nextReactionThreshold = 9000, currentStanding = 4240 },
  [509] = { name = "League of Arathor", reaction = 4, currentReactionThreshold = 0, nextReactionThreshold = 3000, currentStanding = 100 },
  [730] = { name = "Stormpike Guard", reaction = 8, currentReactionThreshold = 42000, nextReactionThreshold = 42000, currentStanding = 42999 },
}
local list = { 890, 509, 730 }
C_Reputation = {
  GetFactionDataByID = function(id) return rep[id] end,
  GetNumFactions = function() return #list end,
  GetFactionDataByIndex = function(i) local id = list[i] return { name = rep[id].name, factionID = id } end,
}
-- The new battleground's faction, and one BGRep has never heard of.
rep[2600] = { name = "Theramore Expeditionary Force", reaction = 4, currentReactionThreshold = 0, nextReactionThreshold = 3000, currentStanding = 500 }
rep[2700] = { name = "Northwatch Legion", reaction = 4, currentReactionThreshold = 0, nextReactionThreshold = 3000, currentStanding = 0 }
list[4], list[5] = 2600, 2700
C_Item = { GetItemCount = function(id) return id == 20558 and 7 or 0 end, GetItemIconByID = function(id) return 1000 + id end }
UnitFactionGroup = function() return "Alliance" end
local zone, inside = "Warsong Gulch", true
IsInInstance = function() return inside, inside and "pvp" or "none" end
GetRealZoneText = function() return zone end
local now = os.time({ year = 2026, month = 11, day = 27, hour = 20 })
time = function() return now end
date = os.date
local winner
GetBattlefieldWinner = function() return winner end
local timers = {}
C_Timer = { After = function(_, fn) timers[#timers + 1] = fn end }
UISpecialFrames = {}
tinsert = table.insert
SlashCmdList = {}
UIParent = {}
print = function() end

local frames = {}
local function Stub()
  return setmetatable({ scripts = {}, shown = false }, { __index = function(_, k)
    if k == "SetScript" then return function(self, n, fn) self.scripts[n] = fn end end
    if k == "CreateFontString" or k == "CreateTexture" then return function() return Stub() end end
    if k == "SetText" then return function(self, t) self.text = t end end
    if k == "SetTexture" then return function(self, t) self.texture = t end end
    if k == "GetStringHeight" then return function() return 20 end end
    if k == "Show" then return function(self) self.shown = true end end
    if k == "Hide" then return function(self) self.shown = false end end
    if k == "IsShown" then return function(self) return self.shown end end
    return function() end
  end })
end
CreateFrame = function(_, name) local f = Stub() frames[#frames + 1] = f if name then _G[name] = f end return f end

dofile(arg[1])
local B = BGRep
local events = frames[1]
local function fire(e) events.scripts.OnEvent(events, e) end
local say = io.write
_G.print = function(...) say(table.concat({ ... }, " "), "\n") end

-- Pure functions --------------------------------------------------------------
check("number with commas", B.Number(42999), "42,999")
check("signed", B.Signed(-35), "-35")
check("clock", B.Clock(872), "14:32")
check("hours", B.Hours(2.6) .. " " .. B.Hours(0.5), "2h 36m 30m")
local info = B.Info(890)
check("info from the new call", info.name .. " " .. info.standing .. " " .. info.value, "Silverwing Sentinels 5 4240")
local row = B.Row(info, 40)
check("row gain", row.gain, "+40")
check("row bar", row.bar, "Friendly  1,240 / 6,000")
check("row line", row.sub, "4,760 to Honored, about 119 matches")
check("row pace", B.Row(info, 40, 476).sub, "4,760 to Honored, about 119 matches (10h at today's pace)")
check("exalted", B.Row(B.Info(730), 10).sub, "Nothing left to earn")
check("no gain shows no estimate", B.Row(B.Info(509)).sub, "2,900 to Friendly")
check("marks", B.MarksText(), "WSG 7")
check("five recent by default", B.RecentFits(nil, 12), 5)
check("taller window lists more", B.RecentFits(18 * 9, 12), 9)
check("short window still lists five", B.RecentFits(20, 12), 5)
check("never more than you played", B.RecentFits(18 * 9, 3), 3)
check("never more than twenty", B.RecentFits(18 * 40, 50), 20)

check("gain pattern", ("Reputation with Theramore Expeditionary Force increased by 35."):match(B.GainPattern()), "Theramore Expeditionary Force")
check("gain amount", select(2, ("Reputation with Darkspear Raiders increased by 120."):match(B.GainPattern())), "120")
check("short for a known one", B.Short("Warsong Gulch"), "WSG")
check("short for a new one", B.Short("Darkspear Islands") .. " " .. B.Short("Some New Valley"), "DI SNV")
check("finds a faction by name", B.FindFaction("Theramore Expeditionary Force"), 2600)
check("tracks Theramore from the start", table.concat(B.MyFactions(), ","), "890,509,730,2600")

-- A whole match ------------------------------------------------------------------
fire("PLAYER_ENTERING_WORLD")                   -- enter Warsong Gulch at 8 PM
rep[890].currentStanding = 4240 + 35           -- a flag capture
now = now + 900                                 -- 15 minutes
winner = 1                                      -- Alliance wins
fire("UPDATE_BATTLEFIELD_STATUS")
rep[890].currentStanding = 4240 + 35 + 70      -- the win bonus lands a moment later
check("window waits for the bonus", BGRepFrame == nil or not BGRepFrame.shown, true)
timers[1]()
local F = BGRepFrame
check("title", F.title.text, "Warsong Gulch")
check("result and clock", F.result.text, "|cff4dd966Victory|r   |cff8c8c8c15:00|r")
check("row name", F.rows[1].name.text, "Silverwing Sentinels")
check("row gain", F.rows[1].gain.text, "+105 rep")
check("row icon is the WSG mark", F.rows[1].icon.texture, 21558)
check("row bar text", F.rows[1].barText.text, "Friendly  1,345 / 6,000")
check("row pace from today", F.rows[1].sub.text, "4,655 to Honored, about 45 matches (11h 5m at today's pace)")
check("this match lit on the bar", F.rows[1].fresh.shown, true)
check("today", F.today.text, "1 match   1-0   +105 rep   420/h")
check("marks shown", F.marks.text, "Marks  WSG 7")
check("recent line", F.recent[1].zone.text .. " " .. F.recent[1].rep.text .. " " .. F.recent[1].time.text,
  "|cffffd100WSG|r |cff4cd964+105 rep|r 15:00")
check("saved in history", #BGRepDB.history .. " " .. BGRepDB.last.gains[1].gain, "1 105")

F.shown = false                                  -- you close it
inside = false
fire("PLAYER_ENTERING_WORLD")                   -- leave with no new rep
check("leaving with no new rep stays closed", F.shown, false)
check("not saved twice", #BGRepDB.history, 1)

SlashCmdList.BGREP("")
check("/bgrep shows the last match", F.shown and F.title.text, "Warsong Gulch")
SlashCmdList.BGREP("")
check("/bgrep again closes it", F.shown, false)

-- A match with no rep, then leaving after late rep ---------------------------------
inside, zone, winner = true, "Arathi Basin", nil
fire("PLAYER_ENTERING_WORLD")
now = now + 600
winner = 0                                      -- Horde wins
fire("PVP_MATCH_COMPLETE")
timers[2]()
check("defeat", F.result.text, "|cffff5959Defeat|r   |cff8c8c8c10:00|r")
check("no rep note", F.note.shown and F.note.text, "No battleground reputation this match.")
check("rows hidden", F.rows[1].shown, false)
F.shown = false
rep[509].currentStanding = 110
inside = false
fire("PLAYER_ENTERING_WORLD")
check("late rep shows again on leaving", F.shown and F.rows[1].gain.text, "+10 rep")
check("two matches today", F.today.text, "2 matches   1-1   +115 rep   276/h")
check("newest match first", F.recent[1].zone.text .. F.recent[2].zone.text, "|cffffd100AB|r|cffffd100WSG|r")

-- Darkspear Islands: Theramore rep, plus a faction BGRep learns from chat --------
inside, zone, winner = true, "Darkspear Islands", nil
fire("PLAYER_ENTERING_WORLD")
rep[2600].currentStanding = 500 + 200
rep[2700].currentStanding = 50
events.scripts.OnEvent(events, "CHAT_MSG_COMBAT_FACTION_CHANGE", "Reputation with Northwatch Legion increased by 50.")
now = now + 1200
winner = 1
fire("PVP_MATCH_COMPLETE")
timers[3]()
check("Theramore row", F.rows[1].name.text .. " " .. F.rows[1].gain.text, "Theramore Expeditionary Force +200 rep")
check("learned faction row", F.rows[2].name.text .. " " .. F.rows[2].gain.text, "Northwatch Legion +50 rep")
check("banner icon for new factions", F.rows[1].icon.texture, "Interface\\Icons\\INV_BannerPVP_02")
check("recent says DI", F.recent[1].zone.text, "|cffffd100DI|r")
check("learned for next time", table.concat(B.MyFactions(), ","), "890,509,730,2600,2700")

-- A Horde character ------------------------------------------------------------
inside = false
fire("PLAYER_ENTERING_WORLD")
UnitFactionGroup = function() return "Horde" end
rep[889] = { name = "Warsong Outriders", reaction = 4, currentReactionThreshold = 0, nextReactionThreshold = 3000, currentStanding = 1000 }
rep[510] = { name = "The Defilers", reaction = 5, currentReactionThreshold = 3000, nextReactionThreshold = 9000, currentStanding = 3000 }
rep[729] = { name = "Frostwolf Clan", reaction = 4, currentReactionThreshold = 0, nextReactionThreshold = 3000, currentStanding = 0 }
rep[2601] = { name = "Darkspear Raiders", reaction = 4, currentReactionThreshold = 0, nextReactionThreshold = 3000, currentStanding = 300 }
list[6], list[7], list[8], list[9] = 889, 510, 729, 2601
B.namesChecked = nil
check("Horde tracks its own factions", table.concat(B.MyFactions(), ","), "889,510,729,2601")
inside, zone, winner = true, "Warsong Gulch", nil
fire("PLAYER_ENTERING_WORLD")
rep[889].currentStanding = 1080
now = now + 900
winner = 0
fire("PVP_MATCH_COMPLETE")
timers[#timers]()
check("Horde win is a victory", F.result.text:match("Victory") ~= nil, true)
check("Horde row", F.rows[1].name.text .. " " .. F.rows[1].gain.text, "Warsong Outriders +80 rep")
check("Horde crest", F.crest.texture, "Interface\\TargetingFrame\\UI-PVP-Horde")
inside = false
fire("PLAYER_ENTERING_WORLD")
inside, zone, winner = true, "Darkspear Islands", nil
fire("PLAYER_ENTERING_WORLD")
rep[2601].currentStanding = 450
now = now + 900
winner = 1
fire("PVP_MATCH_COMPLETE")
timers[#timers]()
check("Horde loss is a defeat", F.result.text:match("Defeat") ~= nil, true)
check("Darkspear Raiders row", F.rows[1].name.text .. " " .. F.rows[1].gain.text, "Darkspear Raiders +150 rep")
check("Horde banner", F.rows[1].icon.texture, "Interface\\Icons\\INV_BannerPVP_01")

SlashCmdList.BGREP("reset")
check("reset clears history", #BGRepDB.history, 0)

print(failed == 0 and "all passed" or (failed .. " failed"))
os.exit(failed == 0 and 0 or 1)
