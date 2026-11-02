-- Runs OneClickSplits against a fake game.
-- Usage: luajit tools/test-splits.lua OneClickSplits/OneClickSplits.lua
local now, level, xp, xpMax = 1000, 10, 0, 7600
local text, shown, chat, notices = "", false, {}, {}
function GetTime() return now end
function UnitLevel() return level end
function UnitXP() return xp end
function UnitXPMax() return xpMax end
function GetMaxPlayerLevel() return 60 end
function RequestTimePlayed() end
C_Timer = { After = function(_, fn) fn() end }
DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) chat[#chat + 1] = m end }
RaidWarningFrame, ChatTypeInfo = {}, { RAID_WARNING = {} }
function RaidNotice_AddMessage(_, m) notices[#notices + 1] = m end
SlashCmdList, UIParent = {}, {}
function strsplit(sep, s) local a, b = s:match("^(.-)" .. sep .. "(.*)$") if a then return a, b end return s end
strlower, strtrim = string.lower, function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
local scripts = {}
local function Obj(isText)
  return setmetatable({}, { __index = function(self, k)
    if k == "SetScript" then return function(o, ev, fn) scripts[o] = scripts[o] or {} scripts[o][ev] = fn end end
    if k == "SetText" then return function(_, t) text = t end end
    if k == "Show" then return function() shown = true end end
    if k == "Hide" then return function() shown = false end end
    if k == "CreateFontString" then return function() return Obj(true) end end
    if k == "GetFont" then return function() return "font", 12 end end
    if k == "GetStringWidth" or k == "GetStringHeight" then return function() return 100 end end
    return function() end end })
end
local frames = {}
function CreateFrame() local f = Obj() frames[#frames + 1] = f return f end
assert(loadfile(arg[1]))("OneClickSplits")
local ev = frames[1]
local function Fire(e, ...) scripts[ev].OnEvent(ev, e, ...) end
local function Plain() return (text:gsub("|c%x%x%x%x%x%x%x%x", "")) end
local fails = 0
local function Expect(label, want)
  local ok = Plain():find(want, 1, true) ~= nil
  if not ok then fails = fails + 1 end
  print((ok and "PASS " or "FAIL ") .. label .. " -> " .. Plain():gsub("\n", " | "))
end
Fire("ADDON_LOADED", "OneClickSplits")
Fire("PLAYER_ENTERING_WORLD")
Expect("before time played", "Reading time played")
-- Level 10 on the Shaman plan: 32.9 min target; plan time before 10 = 138.5 min.
Fire("TIME_PLAYED_MSG", 138.5 * 60, 0)
Expect("start of level 10, on plan", "on pace")
now = now + 20 * 60; xp = 7600 * 0.25   -- 20 min in, 25% done: plan expects 8.2 min
Fire("PLAYER_XP_UPDATE")
Expect("slow first 20 minutes", "11m 47s behind")
Expect("time left this level", "12m 54s left")
xp = 7600 * 0.75                         -- 75% done at 20 min: plan expects 24.7 min
Fire("PLAYER_XP_UPDATE")
Expect("fast first 20 minutes", "4m 41s ahead")
now = now + 10 * 60                      -- ding at 30 min, target 32.9
level, xp, xpMax = 11, 0, 8800
Fire("PLAYER_LEVEL_UP", 11)
print("  ding message: " .. (notices[1] or "none"))
if not (notices[1] or ""):find("2m 54s under target", 1, true) then fails = fails + 1 print("FAIL ding message") end
Fire("PLAYER_XP_UPDATE")
Expect("new level resets level time", "This level 0s")
SlashCmdList.ONECLICKSPLITS("plan melee")
Expect("melee plan target for 11", "target 31m 00s")
print(fails == 0 and "ALL PASS" or fails .. " FAILED")
