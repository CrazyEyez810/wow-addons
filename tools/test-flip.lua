-- Runs OneClickFlip against a fake auction house, fake TradeSkillMaster and
-- fake bags, and checks the buy and sell advice.
-- Usage: luajit tools/test-flip.lua OneClickFlip/OneClickFlip.lua
local failed = 0
local function check(name, got, want)
  if got == want then print("ok   " .. name)
  else failed = failed + 1 print("FAIL " .. name .. ": got " .. tostring(got) .. ", want " .. tostring(want)) end
end
local function plain(s) return (tostring(s or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end

-- The game ------------------------------------------------------------------
local now, clock, gold = 1700000000, 0, 130000 -- 13g
time = function() return now end
GetTime = function() return clock end
GetMoney = function() return gold end
GetRealmName = function() return "Realm" end
UnitFactionGroup = function() return "Horde" end
strlower, strtrim = string.lower, function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) print("     chat: " .. plain(m)) end }
SlashCmdList = {}
Enum = { AuctionHouseSortOrder = { Price = 4 } }

local frames = {}
local function Stub()
  return setmetatable({ scripts = {}, shown = true }, { __index = function(_, k)
    if k == "SetScript" then return function(self, n, fn) self.scripts[n] = fn end end
    if k == "CreateFontString" or k == "CreateTexture" then return function() return Stub() end end
    if k == "SetText" then return function(self, t) self.text = t end end
    if k == "Show" then return function(self) self.shown = true end end
    if k == "Hide" then return function(self) self.shown = false end end
    if k == "IsShown" then return function(self) return self.shown end end
    if k == "GetPoint" then return function() return "CENTER", nil, "CENTER", 0, 0 end end
    return function() end
  end })
end
CreateFrame = function(_, name) local f = Stub() frames[#frames + 1] = f if name then _G[name] = f end return f end
UIParent, GameTooltip = Stub(), Stub()

-- The auction house: id -> name, commodity or not, listings cheapest first.
local house = {
  [2770] = { name = "Copper Ore", commodity = true, listings = { { 40, 20 }, { 95, 300 } } },      -- a real flip
  [2589] = { name = "Linen Cloth", commodity = true, listings = { { 20, 2000 } } },                -- deep cheap wall
  [2318] = { name = "Light Leather", commodity = true, listings = { { 10, 10 }, { 60, 50 } } },    -- cheap but never sells
  [2835] = { name = "Rough Stone", commodity = true, listings = { { 5, 100 }, { 30, 40 } } },      -- under vendor price
  [2447] = { name = "Peacebloom", commodity = true, mine = true, listings = { { 20, 5 }, { 80, 9 } } }, -- you sell it
  [4306] = { name = "Silk Cloth", commodity = true, listings = { { 100, 10 }, { 150, 500 } } },    -- too thin after relisting
  [5000] = { name = "Recipe: Thing", listings = { { 20000, 1 }, { 48000, 1 } } },                  -- a single cheap item
  [765]  = { name = "Silverleaf", commodity = true, partial = true, listings = { { 10, 30 } } },   -- more cheap ones not loaded
  [9999] = { name = "Belt", keys = 2, listings = { { 100, 1 } } },                                 -- two endings, no one price
}
local tsm = {
  [2770] = { DBMarket = 100, DBHistorical = 110, DBRegionMarketAvg = 120, DBRegionSaleRate = 0.6, DBRegionSoldPerDay = 200 },
  [2589] = { DBMarket = 50, DBRegionSaleRate = 0.5, DBRegionSoldPerDay = 400 },
  [2318] = { DBMarket = 60, DBRegionSaleRate = 0.05, DBRegionSoldPerDay = 0.5 },
  [2835] = { VendorSell = 15 },
  [2447] = { DBMarket = 80, DBRegionSaleRate = 0.5, DBRegionSoldPerDay = 50 },
  [4306] = { DBMarket = 200, DBRegionSaleRate = 0.5, DBRegionSoldPerDay = 100 },
  [5000] = { DBMarket = 50000, DBRegionSaleRate = 0.3, DBRegionSoldPerDay = 2 },
  [765]  = { DBMarket = 40, DBRegionSaleRate = 0.5, DBRegionSoldPerDay = 100 },
  [7]    = { VendorSell = 25 },
}
TSM_API = { GetCustomPriceValue = function(source, itemString)
  local known = { DBMarket = 1, DBHistorical = 1, DBRegionMarketAvg = 1, DBRegionSaleRate = 1, DBRegionSoldPerDay = 1, VendorSell = 1 }
  assert(known[source], "unknown price source " .. tostring(source))
  local t = tsm[tonumber(itemString:match("^i:(%d+)$"))]
  return t and t[source] or nil
end }

local queue, browse, shown, sent, dropNext = {}, {}, 0, 0, false
local function fire(event, arg) queue[#queue + 1] = { event, arg } end
local function send(event, arg)
  sent = sent + 1
  if dropNext then dropNext = false fire("AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED") else fire(event, arg) end
end
C_AuctionHouse = {
  IsThrottledMessageSystemReady = function() return #queue == 0 end,
  SendBrowseQuery = function(q)
    browse = {}
    for id, h in pairs(house) do
      if h.name:lower():find(q.searchString:lower(), 1, true) then
        for n = 1, h.keys or 1 do
          local total = 0
          for _, l in ipairs(h.listings) do total = total + l[2] end
          browse[#browse + 1] = { itemKey = { itemID = id, itemSuffix = n - 1 }, minPrice = h.listings[1][1], totalQuantity = total, containsOwnerItem = h.mine }
        end
      end
    end
    shown = math.min(3, #browse)
    send("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
  end,
  RequestMoreBrowseResults = function() shown = math.min(shown + 3, #browse) send("AUCTION_HOUSE_BROWSE_RESULTS_ADDED") end,
  HasFullBrowseResults = function() return shown >= #browse end,
  GetBrowseResults = function() local t = {} for i = 1, shown do t[i] = browse[i] end return t end,
  GetItemKeyInfo = function(key) local h = house[key.itemID] return { itemName = h.name, iconFileID = 1, isCommodity = h.commodity or false } end,
  MakeItemKey = function(id) return { itemID = id } end,
  SendSearchQuery = function(key)
    if house[key.itemID].commodity then send("COMMODITY_SEARCH_RESULTS_UPDATED", key.itemID) else send("ITEM_SEARCH_RESULTS_UPDATED", key) end
  end,
  GetNumCommoditySearchResults = function(id) return #house[id].listings end,
  GetCommoditySearchResultInfo = function(id, i) local l = house[id].listings[i] return { unitPrice = l[1], quantity = l[2], containsOwnerItem = house[id].mine and i == 1 } end,
  HasFullCommoditySearchResults = function(id) return not house[id].partial end,
  GetNumItemSearchResults = function(key) return #house[key.itemID].listings end,
  GetItemSearchResultInfo = function(key, i) local l = house[key.itemID].listings[i] return { buyoutAmount = l[1], quantity = l[2] } end,
  HasFullItemSearchResults = function() return true end,
}

local bags = {
  { itemID = 2770, stackCount = 20, quality = 1, hyperlink = "|Hitem:2770|h[Copper Ore]|h" },
  { itemID = 2770, stackCount = 20, quality = 1, hyperlink = "|Hitem:2770|h[Copper Ore]|h" },
  { itemID = 2447, stackCount = 10, quality = 1, hyperlink = "|Hitem:2447|h[Peacebloom]|h" },
  { itemID = 7, stackCount = 3, quality = 0, hyperlink = "|Hitem:7|h[Broken Fang]|h" },
  { itemID = 2318, stackCount = 5, quality = 1, hyperlink = "|Hitem:2318|h[Light Leather]|h" },
  { itemID = 8, stackCount = 1, quality = 3, hyperlink = "|Hitem:8|h[Rare Sword]|h" },
  { itemID = 6948, stackCount = 1, quality = 1, hyperlink = "|Hitem:6948|h[Hearthstone]|h" },
  { itemID = 9, stackCount = 1, quality = 2, isBound = true, hyperlink = "|Hitem:9|h[Bound Ring]|h" },
}
C_Container = {
  GetContainerNumSlots = function(bag) return bag == 0 and #bags or 0 end,
  GetContainerItemInfo = function(bag, slot) return bag == 0 and bags[slot] or nil end,
}
local vendorPrices = { [2318] = 15, [8] = 5000 }
C_Item = { GetItemInfo = function(id) return "x", nil, 1, 1, 1, "", "", 1, "", 1, vendorPrices[id] or 0 end }

-- Load the addon --------------------------------------------------------------
assert(loadfile(arg[1]))("OneClickFlip")
local events
for _, f in ipairs(frames) do if f.scripts.OnEvent then events = f end end
local OnEvent = events.scripts.OnEvent
OnEvent(events, "ADDON_LOADED", "OneClickFlip")

local function find(fn, name, seen)
  seen = seen or {}
  if seen[fn] then return nil end
  seen[fn] = true
  local i, subs = 1, {}
  while true do
    local n, v = debug.getupvalue(fn, i)
    if not n then break end
    if n == name then return v end
    if type(v) == "function" then subs[#subs + 1] = v end
    i = i + 1
  end
  for _, v in ipairs(subs) do local r = find(v, name, seen) if r ~= nil then return r end end
end
local Flip = find(OnEvent, "Flip")

local function tick()
  clock = clock + 0.1
  local q = queue
  queue = {}
  for _, e in ipairs(q) do OnEvent(events, e[1], e[2]) end
  if events.scripts.OnUpdate then events.scripts.OnUpdate(events, 0.1) end
end
local function runScan()
  SlashCmdList.ONECLICKFLIP("scan")
  local n = 0
  while events.scripts.OnUpdate and n < 5000 do tick() n = n + 1 end
  return n
end

-- The math ------------------------------------------------------------------------
check("most to pay for something that sells at 1s", Flip.MaxBuy(100), 73)
local h = {}
Flip.Record(h, 1, 50, 100) Flip.Record(h, 1, 40, 100) Flip.Record(h, 1, 90, 101)
check("two days of prices is not a usual price", Flip.Usual(h, 1), nil)
Flip.Record(h, 1, 60, 102)
check("usual price is the middle of the daily lows", Flip.Usual(h, 1), 60)
Flip.Record(h, 1, 70, 120)
check("days older than two weeks are dropped", #h[1], 2)

local function sellPlan(info, livePrice, vendor, sells)
  local p = Flip.SellPlan(10, info, livePrice, vendor, sells)
  return p and (p.kind .. " " .. p.price) or "nothing"
end
check("post just under the cheapest listing", sellPlan({ sell = 100 }, 95, 5, true), "ah 94")
check("do not undercut a mispriced listing", sellPlan({ sell = 100 }, 40, 5, true), "ah 100")
check("a lone high listing does not set the price", sellPlan({ sell = 100 }, 500, 5, true), "ah 125")
check("vendor when the auction house pays no more", sellPlan({ sell = 100 }, nil, 99, true), "vendor 99")
check("vendor when TSM says it sells badly", sellPlan({ sell = 100, saleRate = 0.01 }, nil, 5, false), "vendor 5")
check("say nothing about an item with no data", sellPlan({}, nil, 5, false), "nothing")

-- A full scan ---------------------------------------------------------------------
OnEvent(events, "AUCTION_HOUSE_SHOW")
dropNext = true -- the first request is dropped by the throttle and must be sent again
local ticks = runScan()
local panel = OneClickFlipPanel
print("     scan took " .. ticks .. " ticks and " .. sent .. " requests")
print("     status: " .. plain(panel.status.text))
local function row(list, i)
  local r = panel[list][i]
  if not r.shown then return "" end
  return plain(r.top.text) .. " | +" .. plain(r.profit.text):gsub("^%+", "") .. " | " .. plain(r.bottom.text)
end
for i = 1, 5 do if row("buyRows", i) ~= "" then print("     buy " .. i .. ": " .. row("buyRows", i)) end end
check("best flip is the single cheap recipe", row("buyRows", 1),
  "Buy 1 Recipe: Thing | +2g 55s 99c | Pay up to 2g each (2g). Relist at 4g 79s 99c each, sells steadily.")
check("then the stone under vendor price", row("buyRows", 2),
  "Buy 100 Rough Stone | +10s | Pay up to 5c each (5s). A vendor pays 15c each.")
check("then the ore, relisted under the next listing", row("buyRows", 3),
  "Buy 20 Copper Ore | +9s 86c | Pay up to 40c each (8s). Relist at 94c each, sells fast.")
check("nothing else: wall, slow seller, own item, thin margin, partial results, gear endings", row("buyRows", 4), "")

for i = 1, 6 do if row("sellRows", i) ~= "" then print("     sell " .. i .. ": " .. row("sellRows", i)) end end
check("post the ore at its usual price, not under the mispriced one", row("sellRows", 1),
  "Post 40 Copper Ore | +38s | At 1s each: its usual price.")
check("your own listing is not undercut", row("sellRows", 2),
  "Post 10 Peacebloom | +7s 60c | At 80c each: its usual price.")
check("only those two are worth posting", row("sellRows", 3), "")
check("gray item and the leather that never sells go to a vendor; the rare is left alone",
  plain(panel.vendor.text), "Sell the rest to a vendor: 2 items for 1s 50c.")

-- Less gold: the recipe no longer fits a quarter of it.
gold = 40000
runScan()
check("with 4g the 2g recipe is over the per-item limit", row("buyRows", 1):match("^Buy %d+ %a+ %a+"), "Buy 100 Rough Stone")

-- Closing the auction house stops a scan.
SlashCmdList.ONECLICKFLIP("scan")
tick()
OnEvent(events, "AUCTION_HOUSE_CLOSED")
tick()
check("closing the auction house stops the scan", events.scripts.OnUpdate, nil)

-- Without TradeSkillMaster the addon's own prices are used: the ore's daily
-- lows are 40c (the scans above), 1s, 1s, 1s, then 40c again today.
TSM_API = nil
gold = 130000
OnEvent(events, "AUCTION_HOUSE_SHOW")
for d = 1, 4 do
  now = now + 86400
  house[2770].listings = d < 4 and { { 100, 400 } } or { { 40, 20 }, { 95, 300 } }
  runScan()
end
check("no TSM: ore under its usual price is still found", row("buyRows", 1):match("^Buy %d+ %a+ %a+ | %+%w+ %w+"), "Buy 20 Copper Ore | +9s 86c")
print("     status: " .. plain(panel.status.text))

print(failed == 0 and "all passed" or (failed .. " FAILED"))
os.exit(failed == 0 and 0 or 1)
