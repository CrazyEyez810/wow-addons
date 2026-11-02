-- OneClickSplits
-- A see-through speedrun panel: the target time for your current level,
-- how long you've spent on it, and whether you're ahead of or behind the
-- plan overall. Two plans for a solo Enhancement Shaman in WoW Forever:
-- "target" (120 hours /played to 60) and "stretch" (100 hours), from the
-- research report "Shaman 1 to 60 speedrun splits".

local ADDON = ...

-- Minutes for each level, 1 to 59 (level 1 means going from 1 to 2).
local PLANS = {
    target = { 5, 4, 10, 7, 12, 21, 21, 35, 40, 48, 53, 56, 60, 65, 70, 75, 80, 84, 89, 79, 83, 87, 90, 94, 93, 97, 100, 104, 108, 108, 112, 115, 120, 124, 128, 132, 136, 140, 145, 169, 173, 178, 182, 187, 192, 196, 201, 205, 209, 204, 208, 212, 217, 221, 225, 229, 234, 262, 266 },
    stretch = { 3, 3, 9, 5, 11, 20, 21, 30, 34, 40, 44, 46, 50, 54, 58, 62, 66, 70, 75, 66, 69, 72, 75, 79, 78, 81, 83, 86, 90, 90, 93, 96, 100, 103, 107, 110, 114, 117, 120, 140, 144, 148, 152, 156, 159, 163, 167, 171, 174, 170, 173, 177, 180, 184, 187, 191, 194, 218, 222 },
}
local PLAN_NAMES = { target = "Target (120h)", stretch = "Stretch (100h)" }

local GREEN, RED, WHITE, GRAY, GOLD = "|cff40ff40", "|cffff5050", "|cffffffff", "|cffb0b0b0", "|cffffd100"

local DB, CHAR
local frame
local played = { total = nil, level = nil, at = nil }
local quietPlayed = false

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99OneClickSplits:|r " .. msg)
end

local function Plan()
    return PLANS[DB.plan or "target"] or PLANS.target
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

-- Panel ----------------------------------------------------------------------

local function Lines()
    local level = UnitLevel("player")
    local plan = Plan()
    local target = plan[level]
    if not target then return nil end
    local total, levelTime = Played()
    local lines = {}
    lines[#lines + 1] = ("%sLevel %d  %starget %s"):format(GOLD, level, GRAY, FormatTime(target * 60))
    if not levelTime then
        lines[#lines + 1] = GRAY .. "Reading time played..."
        return lines
    end

    local left = target * 60 - levelTime
    if left >= 0 then
        lines[#lines + 1] = ("%sThis level %s%s %s(%s left)"):format(GRAY, WHITE, FormatTime(levelTime),
            GREEN, FormatTime(left))
    else
        lines[#lines + 1] = ("%sThis level %s%s %s(%s over)"):format(GRAY, WHITE, FormatTime(levelTime),
            RED, FormatTime(left))
    end

    -- Where the plan expects you right now: its time at the start of this
    -- level plus the same share of this level as your XP bar shows.
    local max = UnitXPMax("player")
    local share = max > 0 and UnitXP("player") / max or 0
    local expected = (PlanBefore(level) + share * target) * 60
    lines[#lines + 1] = ("%sOverall %s"):format(GRAY, Delta(total - expected))

    if DB.showNext ~= false and plan[level + 1] then
        lines[#lines + 1] = ("%sNext: %d in %s"):format(GRAY, level + 1, FormatTime(plan[level + 1] * 60))
    end
    return lines
end

local function Update()
    if not frame or not DB then return end
    local show = DB.enabled ~= false and UnitLevel("player") < MaxLevel()
    local lines = show and Lines()
    if not lines then
        frame:Hide()
        return
    end
    frame.text:SetText(table.concat(lines, "\n"))
    frame:SetSize(frame.text:GetStringWidth() + 8, frame.text:GetStringHeight() + 8)
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
    frame.text = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    frame.text:SetPoint("TOPLEFT", 4, -4)
    frame.text:SetJustifyH("LEFT")
    frame.text:SetSpacing(2)
    local font, size = frame.text:GetFont()
    if font then frame.text:SetFont(font, size, "OUTLINE") end
    frame.text:SetShadowOffset(1, -1)

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
        Print("Plan is " .. PLAN_NAMES[DB.plan or "target"] .. ". Type /splits plan target or /splits plan stretch.")
    elseif cmd == "scale" and tonumber(arg or "") then
        DB.scale = math.max(0.5, math.min(3, tonumber(arg)))
        if frame then frame:SetScale(DB.scale) end
    elseif cmd == "next" then
        DB.showNext = DB.showNext == false
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
        Print("/splits (show or hide), /splits plan target|stretch, /splits scale 1.2, "
            .. "/splits next (show the next level's target), /splits alert, /splits history")
    end
end
