-- BGRep: battleground reputation after every match.
-- Saves your standing when you enter a battleground, compares it when the match
-- ends and again when you leave, and keeps a history of your matches.
-- /bgrep shows the last match, /bgrep reset clears the history.

local B = {}
BGRep = B

-- Battleground factions, in the order they are shown.
B.FACTIONS = {
  Alliance = { 890, 509, 730 },   -- Silverwing Sentinels, League of Arathor, Stormpike Guard
  Horde = { 889, 510, 729 },      -- Warsong Outriders, The Defilers, Frostwolf Clan
}
B.STANDINGS = { "Hated", "Hostile", "Unfriendly", "Neutral", "Friendly", "Honored", "Revered", "Exalted" }
B.SHORT = { ["Warsong Gulch"] = "WSG", ["Arathi Basin"] = "AB", ["Alterac Valley"] = "AV",
            ["Darkspear Islands"] = "DI", ["Battle for the Darkspear Islands"] = "DI" }
-- Battleground factions whose ID numbers aren't known yet. BGRep finds them
-- in your reputation list by name, and learns any other faction a match
-- gives rep to from the "Reputation with X increased" chat line.
B.NAMES = {
  Alliance = { "Theramore Expeditionary" },
  Horde = { "Darkspear Raiders" },
}
B.BANNER = { Alliance = "Interface\\Icons\\INV_BannerPVP_02", Horde = "Interface\\Icons\\INV_BannerPVP_01" }
B.MARKS = { { 20558, "WSG" }, { 20559, "AB" }, { 20560, "AV" } }   -- Marks of Honor
B.KEEP = 50   -- matches kept in the history
B.RECENT_MAX = 20   -- most recent matches the window can list
-- Each faction's battleground, by its Mark of Honor (the row icon).
B.MARK_OF = { [890] = 20558, [889] = 20558, [509] = 20559, [510] = 20559, [730] = 20560, [729] = 20560 }

-- Formatting ------------------------------------------------------------------

local function Number(n)
  local s = tostring(math.floor(math.abs(n) + 0.5))
  local out = (s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
  return (n < 0 and "-" or "") .. out
end
B.Number = Number

function B.Signed(n) return (n > 0 and "+" or "") .. Number(n) end

-- 872 seconds -> "14:32".
function B.Clock(sec)
  sec = math.max(0, math.floor(sec or 0))
  local h, m, s = math.floor(sec / 3600), math.floor(sec % 3600 / 60), sec % 60
  if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
  return string.format("%d:%02d", m, s)
end

-- 2.6 hours -> "2h 36m"; 0.5 -> "30m".
function B.Hours(h)
  local m = math.floor(h * 60 + 0.5)
  if m < 60 then return m .. "m" end
  if m % 60 == 0 then return math.floor(m / 60) .. "h" end
  return string.format("%dh %dm", math.floor(m / 60), m % 60)
end

local function StandingName(n)
  return (n and _G["FACTION_STANDING_LABEL" .. n]) or B.STANDINGS[n] or "?"
end

-- Reputation ------------------------------------------------------------------

-- One faction's standing, from whichever reputation call this client has.
-- Returns { name, standing (1 to 8), min, max, value } or nil.
function B.Info(id)
  if C_Reputation and C_Reputation.GetFactionDataByID then
    local ok, d = pcall(C_Reputation.GetFactionDataByID, id)
    if ok and d and d.name then
      return { id = id, name = d.name, standing = d.reaction, min = d.currentReactionThreshold,
               max = d.nextReactionThreshold, value = d.currentStanding }
    end
  end
  if GetFactionInfoByID then
    local ok, name, _, standing, min, max, value = pcall(GetFactionInfoByID, id)
    if ok and name then
      return { id = id, name = name, standing = standing, min = min, max = max, value = value }
    end
  end
end

local function Group() return B.FACTIONS[UnitFactionGroup("player")] and UnitFactionGroup("player") or "Alliance" end

-- Your reputation list, as { name, id } pairs. Collapsed headers hide their
-- factions, so if a name isn't found the caller can ask to open them.
local function FactionList(expand)
  local out = {}
  if C_Reputation and C_Reputation.GetNumFactions and C_Reputation.GetFactionDataByIndex then
    if expand and C_Reputation.ExpandAllFactionHeaders then pcall(C_Reputation.ExpandAllFactionHeaders) end
    local ok, n = pcall(C_Reputation.GetNumFactions)
    for i = 1, (ok and n or 0) do
      local okD, d = pcall(C_Reputation.GetFactionDataByIndex, i)
      if okD and d and d.name and d.factionID then out[#out + 1] = { name = d.name, id = d.factionID } end
    end
  elseif GetNumFactions and GetFactionInfo then
    if expand and ExpandFactionHeader then pcall(ExpandFactionHeader, 0) end
    for i = 1, GetNumFactions() do
      local name, _, _, _, _, _, _, _, _, _, _, _, _, id = GetFactionInfo(i)
      if name and id then out[#out + 1] = { name = name, id = id } end
    end
  end
  return out
end

-- A faction's ID from its name, or nil. With loose set, a name that starts
-- the same way also counts ("Theramore Expeditionary" finds "... Force").
function B.FindFaction(name, loose)
  local want = name:lower()
  for pass = 1, 2 do
    for _, f in ipairs(FactionList(pass == 2)) do
      local have = f.name:lower()
      if have == want then return f.id end
      if loose and (have:sub(1, #want) == want or want:sub(1, #have) == have) then return f.id end
    end
  end
end

local function Learned()
  BGRepDB = BGRepDB or {}
  BGRepDB.learned = BGRepDB.learned or {}
  local g = Group()
  BGRepDB.learned[g] = BGRepDB.learned[g] or {}
  return BGRepDB.learned[g]
end

-- Remembers a faction for your side, so later matches track it from the start.
function B.Learn(id)
  local list = Learned()
  for _, have in ipairs(list) do if have == id then return end end
  for _, have in ipairs(B.FACTIONS[Group()]) do if have == id then return end end
  list[#list + 1] = id
end

-- The factions tracked for your side: the classic three, then any learned.
function B.MyFactions()
  local g = Group()
  if not B.namesChecked then
    B.namesChecked = true
    for _, name in ipairs(B.NAMES[g] or {}) do
      local id = B.FindFaction(name, true)
      if id then B.Learn(id) end
    end
  end
  local ids = {}
  for _, id in ipairs(B.FACTIONS[g]) do ids[#ids + 1] = id end
  for _, id in ipairs(Learned()) do ids[#ids + 1] = id end
  return ids
end

-- "Reputation with %s increased by %d." -> a Lua pattern for name and amount.
function B.GainPattern(format)
  format = format or FACTION_STANDING_INCREASED or "Reputation with %s increased by %d."
  format = format:gsub("%.$", "")
  local pat = format:gsub("([%(%)%.%[%]%*%+%-%?%^%$])", "%%%1")
  pat = pat:gsub("%%s", "(.-)"):gsub("%%d", "(%%d+)")
  return "^" .. pat
end

function B.Snap(ids)
  local snap = {}
  for _, id in ipairs(ids) do
    local info = B.Info(id)
    if info and info.value then snap[id] = info.value end
  end
  return snap
end

-- Reputation gained between two snaps, as a list of { id, gain }.
function B.Gains(before, after, ids)
  local out = {}
  for _, id in ipairs(ids) do
    local a, b = after[id], before[id]
    if a and b and a ~= b then out[#out + 1] = { id = id, gain = a - b } end
  end
  return out
end

function B.Total(gains)
  local t = 0
  for _, g in ipairs(gains or {}) do t = t + g.gain end
  return t
end

-- History ---------------------------------------------------------------------

-- "WSG" for the known battlegrounds, initials for new ones.
function B.Short(zone)
  if not zone then return "?" end
  if B.SHORT[zone] then return B.SHORT[zone] end
  local initials = zone:gsub("^Battle for the ", ""):gsub("(%a)%a*%s*", "%1")
  return #zone <= 5 and zone or initials:upper()
end

local function Day(t) return date("%Y-%m-%d", t) end

-- Today's matches: { n, wins, losses, gain, seconds, perFaction = { [id] = gain } }.
function B.Today(history, now)
  local today = Day(now)
  local s = { n = 0, wins = 0, losses = 0, gain = 0, seconds = 0, perFaction = {} }
  for _, m in ipairs(history) do
    if m.finish and Day(m.finish) == today then
      s.n = s.n + 1
      if m.result == "Victory" then s.wins = s.wins + 1 elseif m.result == "Defeat" then s.losses = s.losses + 1 end
      s.seconds = s.seconds + (m.seconds or 0)
      for _, g in ipairs(m.gains or {}) do
        s.gain = s.gain + g.gain
        s.perFaction[g.id] = (s.perFaction[g.id] or 0) + g.gain
      end
    end
  end
  return s
end

-- Rep an hour with one faction, from today's matches; nil until there is some.
function B.PerHour(today, id)
  local g = today.perFaction[id]
  if not g or g <= 0 or today.seconds < 60 then return end
  return g / (today.seconds / 3600)
end

-- One faction's row: name, gain, the bar, and the line under it.
function B.Row(info, gain, perHour)
  local row = { name = info.name, gain = "", standing = info.standing, id = info.id, gainFill = 0 }
  if gain and gain ~= 0 then row.gain = B.Signed(gain) end
  if info.standing == 8 or not info.max or info.max <= info.min then
    row.bar, row.fill, row.sub = StandingName(8), 1, "Nothing left to earn"
    return row
  end
  local have, need = info.value - info.min, info.max - info.min
  local left = need - have
  row.fill = have / need
  if gain and gain > 0 then row.gainFill = math.min(gain, have) / need end
  row.bar = string.format("%s  %s / %s", StandingName(info.standing), Number(have), Number(need))
  row.sub = string.format("%s to %s", Number(left), StandingName(info.standing + 1))
  if gain and gain > 0 then
    local games = math.ceil(left / gain)
    row.sub = row.sub .. string.format(", about %d %s", games, games == 1 and "match" or "matches")
  end
  if perHour then row.sub = row.sub .. string.format(" (%s at today's pace)", B.Hours(left / perHour)) end
  return row
end

-- The whole report for one match.
function B.Report(m, history, now)
  local today = B.Today(history or {}, now or time())
  local r = { title = m.zone or "Battleground", result = m.result, clock = m.seconds and B.Clock(m.seconds),
              rows = {}, today = today, recent = {} }
  for _, g in ipairs(m.gains or {}) do
    local info = B.Info(g.id)
    if info then r.rows[#r.rows + 1] = B.Row(info, g.gain, B.PerHour(today, g.id)) end
  end
  if #r.rows == 0 then r.note = "No battleground reputation this match." end
  for i = #(history or {}), math.max(1, #history - (B.RECENT_MAX - 1)), -1 do
    r.recent[#r.recent + 1] = history[i]
  end
  return r
end

-- Standings with no match, for /bgrep before your first match.
function B.Standings(history, now)
  local today = B.Today(history or {}, now or time())
  local r = { title = "Battleground reputation", rows = {}, today = today, recent = {} }
  for _, id in ipairs(B.MyFactions()) do
    local info = B.Info(id)
    if info then r.rows[#r.rows + 1] = B.Row(info, nil, B.PerHour(today, id)) end
  end
  return r
end

-- Today's line: "4 matches  3-1  +420 rep  840/h".
function B.TodayText(t)
  if t.n == 0 then return "No matches yet today" end
  local s = string.format("%d %s   %d-%d   %s rep", t.n, t.n == 1 and "match" or "matches", t.wins, t.losses, B.Signed(t.gain))
  if t.seconds >= 60 and t.gain > 0 then s = s .. string.format("   %s/h", Number(t.gain / (t.seconds / 3600))) end
  return s
end

-- Marks of Honor in your bags: "WSG 12  AB 4", or nil if none.
function B.MarksText()
  local count = (C_Item and C_Item.GetItemCount) or GetItemCount
  if not count then return end
  local parts = {}
  for _, mk in ipairs(B.MARKS) do
    local ok, n = pcall(count, mk[1], true)
    if ok and n and n > 0 then parts[#parts + 1] = mk[2] .. " " .. n end
  end
  if #parts > 0 then return table.concat(parts, "   ") end
end

-- Window -------------------------------------------------------------------

local WIDTH, HEADER, ROW, PAD, LINE, ICON = 340, 34, 54, 12, 18, 34
local BARX = ICON + 10                      -- bars start right of the icon
local WHITE = "Interface\\Buttons\\WHITE8x8"
local BAR = "Interface\\TargetingFrame\\UI-StatusBar"
local SPARK = "Interface\\CastingBar\\UI-CastingBar-Spark"
local QUESTION = "Interface\\Icons\\INV_Misc_QuestionMark"
local CREST = { Alliance = "Interface\\TargetingFrame\\UI-PVP-Alliance", Horde = "Interface\\TargetingFrame\\UI-PVP-Horde" }
local BAR_COLORS = {   -- used when the game's FACTION_BAR_COLORS is missing
  { r = .8, g = .3, b = .22 }, { r = .8, g = .3, b = .22 }, { r = .75, g = .27, b = 0 }, { r = .9, g = .7, b = 0 },
  { r = 0, g = .6, b = .1 }, { r = 0, g = .6, b = .1 }, { r = 0, g = .6, b = .1 }, { r = 0, g = .6, b = .1 },
}
local RESULT = { Victory = { .3, .85, .4 }, Defeat = { 1, .35, .35 }, Draw = { .8, .8, .8 } }
local GREEN, GOLD, GREY = "|cff4cd964", "|cffffd100", "|cff8c8c8c"

local function Hex(c) return string.format("|cff%02x%02x%02x", math.floor(c[1] * 255 + .5), math.floor(c[2] * 255 + .5), math.floor(c[3] * 255 + .5)) end
local function Colored(result)
  if not result then return "" end
  return Hex(RESULT[result] or { 1, .82, 0 }) .. result .. "|r"
end

local function ItemIcon(item)
  local get = (C_Item and C_Item.GetItemIconByID) or GetItemIcon
  local ok, icon = pcall(get or function() end, item)
  return (ok and icon) or QUESTION
end

-- Top-to-bottom gradient on a texture, on both the old and new client calls.
local function Gradient(t, top, bottom)
  t:SetTexture(WHITE)
  if CreateColor and pcall(t.SetGradient, t, "VERTICAL", CreateColor(unpack(bottom)), CreateColor(unpack(top))) then return end
  if t.SetGradientAlpha then
    pcall(t.SetGradientAlpha, t, "VERTICAL", bottom[1], bottom[2], bottom[3], bottom[4], top[1], top[2], top[3], top[4])
  end
end

local frame

local function Text(parent, font, justify)
  local t = parent:CreateFontString(nil, "OVERLAY", font)
  t:SetJustifyH(justify or "LEFT")
  return t
end

local function Rule(f)
  local t = f:CreateTexture(nil, "ARTWORK")
  t:SetHeight(1)
  t:SetColorTexture(1, 1, 1, .07)
  return t
end

local function Section(f, label)
  local t = Text(f, "GameFontNormalSmall")
  t:SetText(label:upper())
  t:SetTextColor(.6, .6, .65)
  return t
end

-- A 1-pixel dark frame around a region.
local function Border(parent, region, a)
  local b = parent:CreateTexture(nil, "BORDER")
  b:SetPoint("TOPLEFT", region, "TOPLEFT", -1, 1)
  b:SetPoint("BOTTOMRIGHT", region, "BOTTOMRIGHT", 1, -1)
  b:SetColorTexture(0, 0, 0, a or 1)
  return b
end

local function NewRow(f)
  local row = CreateFrame("Frame", nil, f)
  row:SetHeight(ROW)
  row.icon = row:CreateTexture(nil, "ARTWORK")
  row.icon:SetSize(ICON, ICON)
  row.icon:SetPoint("TOPLEFT", row, "TOPLEFT", 1, -3)
  row.icon:SetTexCoord(.08, .92, .08, .92)
  Border(row, row.icon)
  row.gain = Text(row, "GameFontNormal", "RIGHT")
  row.gain:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, 0)
  row.gain:SetTextColor(.3, .85, .4)
  row.name = Text(row, "GameFontHighlight")
  row.name:SetPoint("TOPLEFT", row, "TOPLEFT", BARX, 0)
  row.name:SetPoint("RIGHT", row.gain, "LEFT", -6, 0)
  row.name:SetWordWrap(false)
  row.bar = CreateFrame("StatusBar", nil, row)
  row.bar:SetPoint("TOPLEFT", row, "TOPLEFT", BARX, -18)
  row.bar:SetHeight(14)
  row.bar:SetStatusBarTexture(BAR)
  row.bar:SetMinMaxValues(0, 1)
  Border(row, row.bar)
  local bg = row.bar:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(.12, .12, .14, 1)
  -- This match's rep, drawn brighter on top of the bar.
  row.fresh = row.bar:CreateTexture(nil, "OVERLAY")
  row.fresh:SetTexture(BAR)
  row.fresh:SetHeight(14)
  row.fresh:SetBlendMode("ADD")
  row.spark = row.bar:CreateTexture(nil, "OVERLAY")
  row.spark:SetTexture(SPARK)
  row.spark:SetBlendMode("ADD")
  row.spark:SetSize(14, 30)
  row.barText = Text(row.bar, "GameFontHighlightSmall", "CENTER")
  row.barText:SetPoint("CENTER", row.bar, "CENTER", 0, 1)
  row.sub = Text(row, "GameFontDisableSmall")
  row.sub:SetPoint("TOPLEFT", row.bar, "BOTTOMLEFT", 0, -4)
  return row
end

local function NewRecent(f)
  local line = CreateFrame("Frame", nil, f)
  line:SetHeight(LINE)
  line.stripe = line:CreateTexture(nil, "BACKGROUND")
  line.stripe:SetPoint("TOPLEFT", line, "TOPLEFT", -4, 0)
  line.stripe:SetPoint("BOTTOMRIGHT", line, "BOTTOMRIGHT", 4, 0)
  line.stripe:SetColorTexture(1, 1, 1, .03)
  line.icon = line:CreateTexture(nil, "ARTWORK")
  line.icon:SetSize(14, 14)
  line.icon:SetPoint("LEFT", line, "LEFT", 0, 0)
  line.icon:SetTexCoord(.08, .92, .08, .92)
  line.zone = Text(line, "GameFontHighlightSmall")
  line.zone:SetPoint("LEFT", line, "LEFT", 20, 0)
  line.result = Text(line, "GameFontHighlightSmall")
  line.result:SetPoint("LEFT", line, "LEFT", 62, 0)
  line.rep = Text(line, "GameFontHighlightSmall", "RIGHT")
  line.rep:SetPoint("RIGHT", line, "RIGHT", -58, 0)
  line.time = Text(line, "GameFontDisableSmall", "RIGHT")
  line.time:SetPoint("RIGHT", line, "RIGHT", 0, 0)
  return line
end

local MIN_W, MAX_W, MIN_H, MAX_H = 260, 720, 120, 900

local function Saved()
  BGRepDB = BGRepDB or {}
  return BGRepDB
end

-- Remembers where the window is (its top-left corner) and its size.
local function SavePlace(f)
  if f:GetLeft() and f:GetTop() then
    Saved().place = { x = f:GetLeft(), y = f:GetTop() }
  end
end

-- How many recent matches fit: at least 5 (if there are that many), more
-- when you have made the window taller, never more than the list holds.
function B.RecentFits(available, have)
  local n = 5
  if available then n = math.max(5, math.floor(available / LINE)) end
  return math.max(0, math.min(n, have, B.RECENT_MAX))
end

local Layout

-- The grip in the bottom-right corner: drag to resize, right-click to reset.
local function Grip(f)
  local grip = CreateFrame("Button", nil, f)
  grip:SetSize(16, 16)
  grip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -2, 2)
  grip:SetFrameLevel((f:GetFrameLevel() or 1) + 10)
  grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
  grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
  grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
  grip:RegisterForClicks("RightButtonUp")
  grip:SetScript("OnClick", function()
    Saved().width, Saved().height = nil, nil
    f:SetWidth(WIDTH)
    Layout(f)
  end)
  grip:SetScript("OnMouseDown", function(_, button)
    if button ~= "LeftButton" then return end
    f.sizing = true
    f:StartSizing("BOTTOMRIGHT")
  end)
  grip:SetScript("OnMouseUp", function()
    if not f.sizing then return end
    f:StopMovingOrSizing()
    f.sizing = false
    Saved().width, Saved().height = f:GetWidth(), f:GetHeight()
    Layout(f)
    SavePlace(f)
  end)
  return grip
end

local function Window()
  if frame then return frame end
  frame = CreateFrame("Frame", "BGRepFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  frame:SetSize(WIDTH, 200)
  frame:SetPoint("TOP", UIParent, "TOP", 0, -140)
  frame:SetFrameStrata("DIALOG")
  frame:SetClampedToScreen(true)
  if frame.SetBackdrop then
    frame:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
    frame:SetBackdropColor(.06, .06, .08, .95)
    frame:SetBackdropBorderColor(.25, .25, .3, 1)
  end
  -- Soft shadow behind the window.
  local shadow = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
  shadow:SetPoint("TOPLEFT", frame, "TOPLEFT", -5, 5)
  shadow:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 5, -5)
  shadow:SetColorTexture(0, 0, 0, .45)
  frame:EnableMouse(true)
  frame:SetMovable(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", function(f)
    f:StopMovingOrSizing()
    SavePlace(f)
  end)
  frame:SetResizable(true)
  if frame.SetResizeBounds then
    frame:SetResizeBounds(MIN_W, MIN_H, MAX_W, MAX_H)
  elseif frame.SetMinResize then
    frame:SetMinResize(MIN_W, MIN_H)
    frame:SetMaxResize(MAX_W, MAX_H)
  end
  Grip(frame)
  -- Words move with the edges while you drag.
  frame:SetScript("OnSizeChanged", function(f)
    if f.report and not f.laying then Layout(f) end
  end)
  local saved = Saved()
  saved.scale = nil   -- 0.2.1 scaled the window; it resizes now
  frame:SetWidth(saved.width or WIDTH)
  if saved.place then
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", saved.place.x, saved.place.y)
  end

  -- Header: gradient lit by the result colour, faction crest, title, result.
  frame.header = frame:CreateTexture(nil, "ARTWORK")
  frame.header:SetPoint("TOPLEFT", frame, "TOPLEFT", 1, -1)
  frame.header:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -1, -1)
  frame.header:SetHeight(HEADER - 1)
  frame.accent = frame:CreateTexture(nil, "ARTWORK")
  frame.accent:SetPoint("TOPLEFT", frame, "TOPLEFT", 1, -HEADER)
  frame.accent:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -1, -HEADER)
  frame.accent:SetHeight(2)
  frame.crest = frame:CreateTexture(nil, "OVERLAY")
  frame.crest:SetSize(30, 30)
  frame.crest:SetPoint("LEFT", frame, "TOPLEFT", 6, -HEADER / 2 - 3)
  frame.crest:SetTexCoord(0, .62, 0, .62)
  frame.crest:SetTexture(CREST[UnitFactionGroup("player")] or CREST.Alliance)
  frame.title = Text(frame, "GameFontNormalLarge")
  frame.title:SetPoint("LEFT", frame, "TOPLEFT", 38, -HEADER / 2)
  frame.title:SetShadowOffset(1, -1)
  frame.result = Text(frame, "GameFontNormal", "RIGHT")
  frame.result:SetPoint("RIGHT", frame, "TOPRIGHT", -30, -HEADER / 2)
  frame.title:SetPoint("RIGHT", frame.result, "LEFT", -8, 0)
  frame.title:SetWordWrap(false)
  local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
  close:SetSize(24, 24)
  close:SetPoint("RIGHT", frame, "TOPRIGHT", -4, -HEADER / 2)

  frame.note = Text(frame, "GameFontDisable")
  frame.rows, frame.recent = {}, {}
  frame.ruleToday = Rule(frame)
  frame.todayLabel = Section(frame, "Today")
  frame.today = Text(frame, "GameFontHighlight")
  frame.marks = Text(frame, "GameFontDisableSmall", "RIGHT")
  frame.ruleRecent = Rule(frame)
  frame.recentLabel = Section(frame, "Recent matches")

  -- Fade in when it opens.
  local ok, fade = pcall(frame.CreateAnimationGroup, frame)
  if ok and fade then
    local a = fade:CreateAnimation("Alpha")
    a:SetFromAlpha(0)
    a:SetToAlpha(1)
    a:SetDuration(.25)
    frame:SetScript("OnShow", function() fade:Play() end)
  end
  tinsert(UISpecialFrames, "BGRepFrame")   -- Escape closes it
  frame:Hide()
  return frame
end

local function Place(region, f, y, left, right)
  region:ClearAllPoints()
  region:SetPoint("TOPLEFT", f, "TOPLEFT", left or PAD, -y)
  region:SetPoint("RIGHT", f, "RIGHT", -(right or PAD), 0)
end

-- Lays out the report for the window's current width. While you drag the
-- corner the height follows the mouse; otherwise it fits the contents, and a
-- taller window lists more recent matches.
Layout = function(f)
  local r = f.report
  if not r then return end
  f.laying = true
  local W = f:GetWidth() or WIDTH
  local inner = W - 2 * PAD
  local barW = inner - BARX

  f.crest:SetTexture(CREST[UnitFactionGroup("player")] or CREST.Alliance)
  f.title:SetText(r.title)
  local right = Colored(r.result)
  if r.clock then right = right .. (right ~= "" and "   " or "") .. GREY .. r.clock .. "|r" end
  f.result:SetText(right)
  local c = RESULT[r.result] or { 1, .82, 0 }
  Gradient(f.header, { c[1], c[2], c[3], .22 }, { c[1], c[2], c[3], .02 })
  f.accent:SetColorTexture(c[1], c[2], c[3], .8)

  local y = HEADER + 12
  for i, data in ipairs(r.rows) do
    local row = f.rows[i] or NewRow(f)
    f.rows[i] = row
    Place(row, f, y)
    row.icon:SetTexture(B.MARK_OF[data.id] and ItemIcon(B.MARK_OF[data.id]) or B.BANNER[Group()])
    row.name:SetText(data.name)
    row.gain:SetText(data.gain ~= "" and (data.gain .. " rep") or "")
    local col = (FACTION_BAR_COLORS or BAR_COLORS)[data.standing] or BAR_COLORS[4]
    row.bar:SetWidth(barW)
    row.bar:SetStatusBarColor(col.r, col.g, col.b)
    row.bar:SetValue(data.fill)
    row.barText:SetText(data.bar)
    local fill = math.max(0, math.min(1, data.fill or 0))
    row.spark:ClearAllPoints()
    row.spark:SetPoint("CENTER", row.bar, "LEFT", barW * fill, 0)
    if fill > 0 and fill < 1 then row.spark:Show() else row.spark:Hide() end
    if (data.gainFill or 0) > 0 then
      row.fresh:ClearAllPoints()
      row.fresh:SetPoint("LEFT", row.bar, "LEFT", barW * (fill - data.gainFill), 0)
      row.fresh:SetWidth(math.max(1, barW * data.gainFill))
      row.fresh:SetVertexColor(.5, 1, .6, .55)
      row.fresh:Show()
    else
      row.fresh:Hide()
    end
    row.sub:SetWidth(barW)
    row.sub:SetText(data.sub)
    local h = math.max(ICON + 6, 18 + 14 + 4 + (row.sub:GetStringHeight() or 12) + 6)
    row:SetHeight(h)
    row:Show()
    y = y + h
  end
  for i = #r.rows + 1, #f.rows do f.rows[i]:Hide() end
  if r.note then
    Place(f.note, f, y)
    f.note:SetWidth(inner)
    f.note:SetText(r.note)
    f.note:Show()
    y = y + (f.note:GetStringHeight() or 14) + 10
  else
    f.note:Hide()
  end

  -- Today
  Place(f.ruleToday, f, y, 1, 1)
  y = y + 9
  Place(f.todayLabel, f, y)
  local marks = B.MarksText()
  f.marks:SetText(marks and ("Marks  " .. marks) or "")
  Place(f.marks, f, y)
  y = y + 15
  Place(f.today, f, y)
  f.today:SetWidth(inner)
  f.today:SetText(B.TodayText(r.today))
  y = y + (f.today:GetStringHeight() or 14) + 10

  -- Recent matches: as many as the window's height has room for.
  local all = r.recent or {}
  local wantH = f.sizing and f:GetHeight() or Saved().height
  local n = B.RecentFits(wantH and (wantH - y - 25 - 10), #all)
  if n > 0 then
    Place(f.ruleRecent, f, y, 1, 1)
    f.ruleRecent:Show()
    y = y + 9
    Place(f.recentLabel, f, y)
    f.recentLabel:Show()
    y = y + 16
  else
    f.ruleRecent:Hide()
    f.recentLabel:Hide()
  end
  local markOf = { WSG = 20558, AB = 20559, AV = 20560 }
  for i = 1, n do
    local m = all[i]
    local line = f.recent[i] or NewRecent(f)
    f.recent[i] = line
    Place(line, f, y)
    local short = B.Short(m.zone)
    line.icon:SetTexture(markOf[short] and ItemIcon(markOf[short]) or B.BANNER[Group()])
    if i % 2 == 1 then line.stripe:Show() else line.stripe:Hide() end
    line.zone:SetText(GOLD .. short .. "|r")
    line.result:SetText(Colored(m.result or "Left early"))
    local g = B.Total(m.gains)
    line.rep:SetText(g ~= 0 and (GREEN .. B.Signed(g) .. " rep|r") or (GREY .. "no rep|r"))
    line.time:SetText(m.seconds and B.Clock(m.seconds) or "")
    line:Show()
    y = y + LINE
  end
  for i = n + 1, #f.recent do f.recent[i]:Hide() end

  if not f.sizing then f:SetHeight(y + 10) end
  f.laying = false
end

function B.Show(r)
  local f = Window()
  f.report = r
  Layout(f)
  f:Show()
end

-- Match tracking -----------------------------------------------------------

local match      -- the match you are in: { zone, start, before, ended, shown, record }

local function DB()
  BGRepDB = BGRepDB or {}
  BGRepDB.history = BGRepDB.history or {}
  return BGRepDB
end

local function InBattleground()
  local inside, kind = IsInInstance()
  return inside and kind == "pvp"
end

local function Result()
  if not GetBattlefieldWinner then return end
  local ok, winner = pcall(GetBattlefieldWinner)
  if not ok or winner == nil then return end
  if winner == 255 then return "Draw" end
  local mine = UnitFactionGroup("player") == "Horde" and 0 or 1
  return winner == mine and "Victory" or "Defeat"
end

-- Saves the match in the history (once; later calls update the same entry),
-- then shows the window. When you leave, it only shows again if the count
-- changed or you never saw it.
local function Finish(leaving)
  if not match then return end
  local db = DB()
  local ids = B.MyFactions()
  local rec = match.record
  if not rec then
    rec = { zone = match.zone, start = match.start }
    match.record = rec
    table.insert(db.history, rec)
    while #db.history > B.KEEP do table.remove(db.history, 1) end
  end
  rec.result = match.result or Result()
  rec.finish = match.finish or time()
  rec.seconds = rec.finish - (match.start or rec.finish)
  rec.gains = B.Gains(match.before, B.Snap(ids), ids)
  match.result = rec.result
  local total = B.Total(rec.gains)
  local changed = not match.shown or total ~= match.total
  match.total = total
  db.last = rec
  if leaving and not changed then return end
  B.Show(B.Report(rec, db.history, time()))
  match.shown = true
end

local function Ended()
  if not match or match.ended then return end
  match.ended = true
  match.result = Result()
  match.finish = time()
  -- The win bonus can land a moment after the match ends.
  C_Timer.After(4, Finish)
end

local events = CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_ENTERING_WORLD", "UPDATE_BATTLEFIELD_STATUS", "PVP_MATCH_COMPLETE",
                     "CHAT_MSG_COMBAT_FACTION_CHANGE" }) do
  pcall(events.RegisterEvent, events, e)
end
-- A rep line during a match: if it names a faction BGRep wasn't tracking,
-- learn it and work out where it stood before this gain.
function B.Notice(m, msg)
  local name, amount = (msg or ""):match(B.GainPattern())
  amount = tonumber(amount)
  if not name or not amount then return end
  local id = B.FindFaction(name)
  if not id or m.before[id] then return end
  local info = B.Info(id)
  if not info or not info.value then return end
  m.before[id] = info.value - amount
  B.Learn(id)
end

events:SetScript("OnEvent", function(_, event, msg)
  if event == "PLAYER_ENTERING_WORLD" then
    if InBattleground() then
      if not match then
        match = { zone = GetRealZoneText(), start = time(), before = B.Snap(B.MyFactions()) }
      end
    elseif match then
      -- You left the battleground: show the final count, with any late rep.
      Finish(true)
      match = nil
    end
  elseif event == "PVP_MATCH_COMPLETE" then
    Ended()
  elseif event == "UPDATE_BATTLEFIELD_STATUS" then
    if match and Result() then Ended() end
  elseif event == "CHAT_MSG_COMBAT_FACTION_CHANGE" then
    if match then B.Notice(match, msg) end
    -- Keep the window current if more rep arrives while it is open.
    if match and match.shown and frame and frame:IsShown() then Finish() end
  end
end)

SLASH_BGREP1 = "/bgrep"
SlashCmdList.BGREP = function(msg)
  local db = DB()
  if msg and msg:lower():match("^%s*reset") then
    db.history, db.last = {}, nil
    print("BGRep: match history cleared.")
    return
  end
  if frame and frame:IsShown() then frame:Hide() return end
  if match then
    local ids = B.MyFactions()
    B.Show(B.Report({ zone = match.zone, result = "In progress", seconds = time() - match.start,
                      gains = B.Gains(match.before, B.Snap(ids), ids) }, db.history, time()))
  elseif db.last then
    B.Show(B.Report(db.last, db.history, time()))
  else
    B.Show(B.Standings(db.history, time()))
  end
end
