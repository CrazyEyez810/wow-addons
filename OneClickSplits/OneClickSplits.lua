-- OneClickSplits
-- A see-through speedrun panel: the target time for your current level,
-- how long you've spent on it, and whether you're ahead of or behind the
-- plan overall. The default plan is 100 hours: the Shaman speedrun below
-- stretched by 8%. Two speedrun plans, both scaled to verified solo 1-60 runs
-- on Classic Era (speedrun.com, SSF Softcore), which WoW Forever's XP table
-- matches:
--   shaman: 92h 15m, DeepsTheBoomer, Troll Shaman (the only verified
--           Shaman 1-60 speedrun)
--   melee:  78h 36m, Thiddi, Troll Rogue (fastest Horde melee solo run)
-- The runs only publish totals, so the per-level spread comes from the
-- Classic XP table over an XP-per-hour curve (6k/h at 1 to 55k/h at 60)
-- with Shaman bracket factors (10-19 slower, 25-39 faster).

local ADDON = ...

-- Minutes for each level, 1 to 59 (level 1 means going from 1 to 2).
local PLANS = {
    ["100"] = { 3.4, 6.9, 9.9, 13.6, 16.7, 20.1, 23.4, 26.3, 29.9, 35.7, 39.5, 43.3, 46.7, 50.7, 54.4, 58.2, 62, 65.6, 69.6, 68, 71.1, 74.4, 77.3, 80.5, 79.7, 82.6, 85.6, 88.5, 92, 92.6, 95.4, 98.6, 102.3, 106, 109.5, 113.2, 116.5, 120.1, 123.7, 137.3, 141.1, 144.8, 148.4, 152.2, 156, 159.6, 163.3, 166.9, 170.6, 174.3, 177.9, 181.6, 185.3, 188.8, 192.5, 196.1, 199.7, 203.3, 206.9 },
    shaman = { 3.1, 6.4, 9.1, 12.5, 15.4, 18.5, 21.6, 24.3, 27.6, 32.9, 36.4, 39.9, 43.1, 46.8, 50.2, 53.7, 57.2, 60.5, 64.2, 62.7, 65.6, 68.6, 71.3, 74.3, 73.5, 76.2, 79, 81.6, 84.9, 85.4, 88, 91, 94.4, 97.8, 101, 104.4, 107.5, 110.8, 114.1, 126.7, 130.2, 133.6, 136.9, 140.4, 143.9, 147.2, 150.6, 154, 157.4, 160.8, 164.1, 167.5, 170.9, 174.2, 177.6, 180.9, 184.2, 187.5, 190.9 },
    melee = { 2.7, 5.4, 7.7, 10.6, 13.1, 15.7, 18.4, 20.7, 23.5, 28.1, 31, 34, 36.7, 39.9, 42.8, 45.7, 48.7, 51.5, 54.7, 53.4, 55.9, 58.4, 60.7, 63.3, 62.6, 65, 67.3, 69.6, 72.3, 72.7, 75, 77.5, 80.4, 83.3, 86.1, 88.9, 91.6, 94.4, 97.2, 108, 110.9, 113.8, 116.7, 119.6, 122.6, 125.4, 128.4, 131.2, 134.1, 137, 139.9, 142.7, 145.6, 148.4, 151.3, 154.2, 156.9, 159.8, 162.7 },
}
local PLAN_NAMES = { ["100"] = "100 hours", shaman = "Shaman speedrun (92h)", melee = "Melee record (79h)" }
local DEFAULT_PLAN = "100"

local GREEN, RED, WHITE, GRAY, GOLD = "|cff40ff40", "|cffff5050", "|cffffffff", "|cffb0b0b0", "|cffffd100"

local DB, CHAR
local frame
local played = { total = nil, level = nil, at = nil }
local quietPlayed = false

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99OneClickSplits:|r " .. msg)
end

local function Plan()
    return PLANS[DB.plan or DEFAULT_PLAN] or PLANS[DEFAULT_PLAN]
end

-- Minutes the plan allows before reaching `level` (sum of levels 1..level-1).
local function PlanBefore(level)
    local plan, sum = Plan(), 0
    for l = 1, math.min(level - 1, #plan) do sum = sum + plan[l] end
    return sum
end

local function FormatTime(seconds)
    seconds = math.floor(math.abs(seconds) + 0.5)
    local h, m = math.floor(seconds / 3600), math.floor((seconds % 3600) / 60)
    if h > 0 then return ("%dh %02dm"):format(h, m) end
    if m > 0 then return ("%dm %02ds"):format(m, seconds % 60) end
    return seconds .. "s"
end

-- Stopwatch style: 12:54 or 1:04:12.
local function Clock(seconds)
    seconds = math.floor(math.abs(seconds))
    local h, m, sec = math.floor(seconds / 3600), math.floor((seconds % 3600) / 60), seconds % 60
    if h > 0 then return ("%d:%02d:%02d"):format(h, m, sec) end
    return ("%d:%02d"):format(m, sec)
end

local function Delta(seconds)
    -- Negative = ahead of the plan.
    if math.abs(seconds) < 30 then return WHITE .. "on pace" end
    if seconds < 0 then return GREEN .. FormatTime(seconds) .. " ahead" end
    return RED .. FormatTime(seconds) .. " behind"
end

-- Time played: asked from the server once at login without printing it in
-- chat, then counted forward locally.
local function RequestPlayedQuietly()
    quietPlayed = true
    C_Timer.After(3, function() quietPlayed = false end)
    RequestTimePlayed()
end

if ChatFrameUtil and ChatFrameUtil.DisplayTimePlayed then
    local original = ChatFrameUtil.DisplayTimePlayed
    ChatFrameUtil.DisplayTimePlayed = function(...)
        if quietPlayed then return end
        return original(...)
    end
elseif _G.ChatFrame_DisplayTimePlayed then
    local original = _G.ChatFrame_DisplayTimePlayed
    _G.ChatFrame_DisplayTimePlayed = function(...)
        if quietPlayed then return end
        return original(...)
    end
end

local function Played()
    if not played.at then return nil, nil end
    local since = GetTime() - played.at
    return played.total + since, played.level + since
end

local function MaxLevel()
    return (GetMaxPlayerLevel and GetMaxPlayerLevel()) or 60
end

-- Time played since reaching `from`, up to reaching `to` (or now when `to`
-- is the current level). Uses the played time saved at each ding, else the
-- saved level splits. Nil when the addon missed part of the bracket.
local function Spent(from, to, level, total, levelTime)
    local reached = CHAR.reached or {}
    local finish = to > level and total or reached[to]
    if reached[from] and finish then return finish - reached[from] end
    local sum = 0
    for l = from, math.min(to, level + 1) - 1 do
        local s = l == level and levelTime or (CHAR.splits and CHAR.splits[l])
        if not s then return nil end
        sum = sum + s
    end
    return sum
end

-- One line per bracket: 1-10, 10-20 ... 50-60. Finished brackets are green
-- (under the goal) or red (over); the current one is white until it passes
-- its goal; later ones show only the goal.
local function BracketLines(level, total, levelTime)
    local lines = {}
    for to = 10, 60, 10 do
        local from = to == 10 and 1 or to - 10
        local goal = (PlanBefore(to) - PlanBefore(from)) * 60
        local label = ("%d-%d"):format(from, to)
        if level < from then
            lines[#lines + 1] = ("%s%s  goal %s"):format(GRAY, label, FormatTime(goal))
        else
            local spent = Spent(from, to, level, total, levelTime)
            local done = level >= to
            local color = spent and spent > goal and RED or (done and GREEN or WHITE)
            local line = ("%s%s  %sgoal %s%s"):format(done and GRAY or GOLD, label, GRAY, WHITE, FormatTime(goal))
            if spent then line = line .. ("  %syou %s%s"):format(GRAY, color, FormatTime(spent)) end
            lines[#lines + 1] = line
        end
    end
    return lines
end

-- Panel ----------------------------------------------------------------------

-- Returns the goal line, the timer next to it, and the lines below.
local function Lines()
    local level = UnitLevel("player")
    local plan = Plan()
    local target = plan[level]
    if not target then return nil end
    local total, levelTime = Played()
    local goal = ("%sLevel %d  %sgoal %s%s"):format(GOLD, level, GRAY, WHITE, Clock(target * 60))
    if not levelTime then
        return goal, GRAY .. "0:00", { GRAY .. "Reading time played..." }
    end

    -- Time on this level, counting up; red once it passes the goal.
    local timer = (levelTime > target * 60 and RED or WHITE) .. Clock(levelTime)

    local lines = {}

    -- Where the plan expects you right now: its time at the start of this
    -- level plus the same share of this level as your XP bar shows.
    local max = UnitXPMax("player")
    local share = max > 0 and UnitXP("player") / max or 0
    local expected = (PlanBefore(level) + share * target) * 60
    lines[#lines + 1] = ("%sOverall %s"):format(GRAY, Delta(total - expected))

    if DB.showNext ~= false and plan[level + 1] then
        lines[#lines + 1] = ("%sNext: %d in %s"):format(GRAY, level + 1, Clock(plan[level + 1] * 60))
    end
    if DB.showBrackets ~= false then
        for _, line in ipairs(BracketLines(level, total, levelTime)) do lines[#lines + 1] = line end
    end
    return goal, timer, lines
end

local function Update()
    if not frame or not DB then return end
    local show = DB.enabled ~= false and UnitLevel("player") < MaxLevel()
    local goal, timer, lines
    if show then goal, timer, lines = Lines() end
    if not goal then
        frame:Hide()
        return
    end
    frame.goal:SetText(goal)
    frame.timer:SetText(timer)
    frame.text:SetText(table.concat(lines, "\n"))
    -- Lines start below whichever is taller: the goal or the big timer.
    local top = math.max(frame.goal:GetStringHeight(), frame.timer:GetStringHeight())
    frame.text:ClearAllPoints()
    frame.text:SetPoint("TOPLEFT", frame, "TOPLEFT", 4, -(top + 10))
    local width = math.max(frame.goal:GetStringWidth() + 12 + frame.timer:GetStringWidth(), frame.text:GetStringWidth())
    frame:SetSize(width + 8, top + 14 + frame.text:GetStringHeight())
    frame:Show()
end

local function CreatePanel()
    if frame then return end
    frame = CreateFrame("Frame", "OneClickSplitsFrame", UIParent)
    frame:SetSize(200, 60)
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    -- See-through: no background, outlined text so it reads on any scene.
    local function Text(scale)
        local fs = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        local font, size = fs:GetFont()
        if font then fs:SetFont(font, math.floor(size * scale + 0.5), "OUTLINE") end
        fs:SetShadowOffset(1, -1)
        fs:SetJustifyH("LEFT")
        return fs
    end
    frame.goal = Text(1.15)
    frame.goal:SetPoint("TOPLEFT", 4, -8)
    -- The level timer sits right next to the goal, twice the size.
    frame.timer = Text(2)
    frame.timer:SetPoint("LEFT", frame.goal, "RIGHT", 12, 0)
    frame.text = Text(1)
    frame.text:SetSpacing(2)

    local pos = DB.pos
    if pos then
        frame:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
    else
        frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 20, -200)
    end
    frame:SetScale(DB.scale or 1)
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        DB.pos = { point, relPoint, x, y }
    end)
    local elapsed = 0
    frame:SetScript("OnUpdate", function(_, dt)
        elapsed = elapsed + dt
        if elapsed >= 1 then
            elapsed = 0
            Update()
        end
    end)
end

-- Level-ups ----------------------------------------------------------------------

-- Announces how the finished level went against the plan and saves it.
local function OnDing(newLevel)
    local doneLevel = newLevel - 1
    local total, levelTime = Played()
    if levelTime and Plan()[doneLevel] then
        local target = Plan()[doneLevel] * 60
        CHAR.splits = CHAR.splits or {}
        CHAR.splits[doneLevel] = math.floor(levelTime + 0.5)
        CHAR.reached = CHAR.reached or {}
        CHAR.reached[newLevel] = math.floor(total + 0.5)
        local diff = levelTime - target
        local verdict = math.abs(diff) < 30 and "on target"
            or (diff < 0 and (FormatTime(diff) .. " under target") or (FormatTime(diff) .. " over target"))
        local overall = total - PlanBefore(newLevel) * 60
        local msg = ("Level %d done in %s, %s. Overall: %s"):format(doneLevel, FormatTime(levelTime), verdict,
            math.abs(overall) < 30 and "on pace" or (overall < 0 and (FormatTime(overall) .. " ahead")
                or (FormatTime(overall) .. " behind")))
        Print(msg)
        if DB.dingAlert ~= false and RaidNotice_AddMessage and RaidWarningFrame and ChatTypeInfo then
            RaidNotice_AddMessage(RaidWarningFrame, msg, ChatTypeInfo["RAID_WARNING"])
        end
    end
    -- Time played this level starts over.
    if total then played.total, played.level, played.at = total, 0, GetTime() end
end

-- Events -----------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("TIME_PLAYED_MSG")
events:RegisterEvent("PLAYER_LEVEL_UP")
events:RegisterEvent("PLAYER_XP_UPDATE")

events:SetScript("OnEvent", function(_, event, arg1, arg2)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON then return end
        OneClickSplitsDB = OneClickSplitsDB or {}
        OneClickSplitsChar = OneClickSplitsChar or {}
        DB, CHAR = OneClickSplitsDB, OneClickSplitsChar
        if DB.plan and not PLANS[DB.plan] then DB.plan = nil end -- plans from 0.1.0
        -- Played time when each level was reached; level 1 starts at zero.
        CHAR.reached = CHAR.reached or {}
        CHAR.reached[1] = 0
        return
    end
    if not DB then return end
    if event == "PLAYER_ENTERING_WORLD" then
        CreatePanel()
        -- Another addon (OneClickXP, RestedXP) may already ask for time
        -- played; ask ourselves only if nothing has arrived.
        C_Timer.After(4, function()
            if not played.at then RequestPlayedQuietly() end
        end)
        Update()
    elseif event == "TIME_PLAYED_MSG" then
        played.total, played.level, played.at = arg1, arg2, GetTime()
        local level = UnitLevel("player")
        if not CHAR.reached[level] then CHAR.reached[level] = math.floor(arg1 - arg2 + 0.5) end
        Update()
    elseif event == "PLAYER_LEVEL_UP" then
        OnDing(arg1)
        Update()
    elseif event == "PLAYER_XP_UPDATE" then
        Update()
    end
end)

-- Slash command ------------------------------------------------------------------

SLASH_ONECLICKSPLITS1 = "/splits"
SlashCmdList.ONECLICKSPLITS = function(input)
    local cmd, arg = strsplit(" ", strlower(strtrim(input or "")), 2)
    if cmd == "" or cmd == "on" or cmd == "off" then
        if cmd == "" then DB.enabled = DB.enabled == false else DB.enabled = cmd == "on" end
        Print("Panel: " .. (DB.enabled ~= false and "on" or "off"))
        Update()
    elseif cmd == "plan" and PLANS[arg or ""] then
        DB.plan = arg
        Print("Plan: " .. PLAN_NAMES[arg])
        Update()
    elseif cmd == "plan" then
        Print("Plan is " .. PLAN_NAMES[PLANS[DB.plan or ""] and DB.plan or DEFAULT_PLAN] .. ". Type /splits plan 100, /splits plan shaman or /splits plan melee.")
    elseif cmd == "scale" and tonumber(arg or "") then
        DB.scale = math.max(0.5, math.min(3, tonumber(arg)))
        if frame then frame:SetScale(DB.scale) end
    elseif cmd == "next" then
        DB.showNext = DB.showNext == false
        Update()
    elseif cmd == "brackets" then
        DB.showBrackets = DB.showBrackets == false
        Update()
    elseif cmd == "alert" then
        DB.dingAlert = DB.dingAlert == false
        Print("Level-up message on screen: " .. (DB.dingAlert ~= false and "on" or "off"))
    elseif cmd == "history" then
        local any = false
        for level = 1, 59 do
            local s = CHAR.splits and CHAR.splits[level]
            if s then
                any = true
                Print(("Level %d: %s (target %s)"):format(level, FormatTime(s), FormatTime(Plan()[level] * 60)))
            end
        end
        if not any then Print("No levels recorded on this character yet.") end
    else
        Print("/splits (show or hide), /splits plan 100|shaman|melee, /splits scale 1.2, "
            .. "/splits next (show the next level's target), /splits brackets (1-10, 10-20 ...), "
            .. "/splits alert, /splits history")
    end
end
