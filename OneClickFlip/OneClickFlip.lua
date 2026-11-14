-- OneClickFlip
-- An auction house coach for WoW Forever. Open the auction house, click
-- Scan, and it lists:
--   Buy:  items listed well under their usual price, the most to pay for
--         each, what to relist them for and the profit after the cut.
--   Sell: what in your bags is worth posting and at what price, and what
--         to sell to a vendor instead.
-- It only reads prices and gives advice. You buy and post by hand.
--
-- Prices come from TradeSkillMaster when it is loaded (market value, sale
-- rate and sold per day, kept fresh by the TSM Desktop App) and from this
-- addon's own scans (the cheapest price per day, kept for 14 days).
--
-- How a flip is judged (WoW Forever has the modern auction house, so the
-- whole house is read with a browse search, then the best candidates are
-- searched one by one to see every listing):
--   1. Sell price: the lowest of TSM's market value, TSM's historical price
--      and this addon's usual price. Without a realm price, TSM's region
--      average.
--   2. Most to pay: the price that still leaves the minimum margin after
--      the 5% cut.
--   3. The item must sell: TSM's region sale rate and sold per day.
--   4. Every unit listed at or under "most to pay" must fit your budget
--      for one item. A deep wall of cheap units means the price really
--      fell, so those are skipped.
--   5. Relist just under the next listing left on the house, or at the
--      sell price if that is lower. The margin is checked again with it.
-- An item listed under its vendor price is always shown: that profit is
-- certain.
--
-- Two more guards, added after a recipe flip went wrong:
--   - Auction flips are only suggested for trade goods (ore, herbs, cloth,
--     leather and so on). They sell every day; recipes and gear can sit for
--     weeks. /flip all turns this off, /flip trade turns it back on.
--   - An item you already hold in your bags is never suggested again, so
--     scanning again cannot put more gold into the same item.
--
-- The market window (/flip market) is for working one item at a time:
--   - Every scan records, for each trade good and each hour of the day (your
--     clock), the cheapest price and how many units are listed. The window
--     draws that as 24 bars and names the cheapest and dearest hours. It
--     needs scans at many hours on at least two days before it says anything.
--   - Watched items (up to 10) have every listing read each time the auction
--     house opens, so their hours fill in without a full scan.
--   - Cornering: for a watched item it tries buying every unit up to each
--     price step, relisting just under the next listing left (never above
--     1.25 times the usual price), and keeps the step with the most profit
--     that fits the per-item budget, keeps the minimum margin and sells
--     within 7 days at TSM's pace.
--   - A full scan also suggests up to 4 trade goods worth watching.

local ADDON = ...

local DEFAULTS = {
    cut = 0.05,          -- the auction house keeps 5% of a sale
    minMargin = 0.30,    -- least profit after the cut, as a share of the cost
    maxShare = 0.25,     -- most of your gold to put into one item
    minSaleRate = 0.15,  -- TSM region sale rate: share of auctions that sell
    minSoldPerDay = 1,   -- TSM region sold per day
    minProfit = 500,     -- copper; smaller flips are not shown
    capDays = 1,         -- buy at most this many days of TSM's sold per day
    tradeOnly = true,    -- auction flips only for trade goods (ore, herbs, cloth, ...)
    scale = 1,           -- window size
}

local MAX_CHECK = 15       -- candidates searched one by one after the browse scan
local BUY_ROWS, SELL_ROWS = 5, 6
local HISTORY_DAYS = 14
local TIMEOUT = 10         -- seconds to wait for the auction house to answer
local LIVE_MAX_AGE = 1800  -- seconds a scan's prices count as current
local NEVER_SELL = { [6948] = true } -- Hearthstone
local MAX_WATCH = 10
local CORNER_DAYS = 7      -- a corner must sell within this many days of TSM's sold per day
local CORNER_CAP = 1.25    -- never relist above this times the usual price
local HOUR_MIN_DAYS = 2    -- days an hour must be seen before it counts
local HOUR_MIN_COUNT = 4   -- hours that must count before naming the best ones
local SUGGEST_ROWS, SUGGEST_CHECK = 4, 6

local DB, S
local Flip = {}            -- the pricing logic; tools/test-flip.lua checks it
local panel, market
local watchLive = {}       -- itemID -> { listings, complete, sellers, time, icon } for watched items
local suggestions = {}     -- corner ideas from the last full scan
local auctionOpen = false
local scan                 -- the running scan: { co, wait, got, dropped }
local live = {}            -- itemID -> { price, qty, key } from the last scan
local liveTime             -- time() of the last finished scan
local buys = {}            -- the buy list from the last scan
local statusText = "Click Scan to read the auction house."
local tsmScale = 1

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99OneClickFlip:|r " .. msg)
end

local function Money(c)
    c = math.floor(c + 0.5)
    local neg = c < 0
    if neg then c = -c end
    local g, s, k = math.floor(c / 10000), math.floor(c / 100) % 100, c % 100
    local out = {}
    if g > 0 then out[#out + 1] = g .. "|cffffd100g|r" end
    if s > 0 then out[#out + 1] = s .. "|cffc7c7cfs|r" end
    if k > 0 or #out == 0 then out[#out + 1] = k .. "|cffeda55fc|r" end
    return (neg and "-" or "") .. table.concat(out, " ")
end

local function Realm()
    local key = (GetRealmName() or "?") .. "-" .. (UnitFactionGroup("player") or "?")
    DB.realms = DB.realms or {}
    local r = DB.realms[key] or { history = {} }
    DB.realms[key] = r
    r.hours = r.hours or {}  -- itemID -> [hour + 1] = bucket (see Flip.RecordHour)
    r.watch = r.watch or {}  -- itemID -> name
    return r
end

local function Today() return math.floor(time() / 86400) end
local function Hour() return date("*t").hour end

local function HourName(h)
    local n = h % 12
    return (n == 0 and 12 or n) .. (h < 12 and " AM" or " PM")
end

-- ---------------------------------------------------------------------------
-- Prices
-- ---------------------------------------------------------------------------

local function HasTSM()
    return _G.TSM_API ~= nil and _G.TSM_API.GetCustomPriceValue ~= nil
end

-- A TSM price source for an item, or nil. TSM raises an error on a source
-- it does not know, so the call is wrapped.
local function TSM(source, id)
    if not HasTSM() then return nil end
    local ok, v = pcall(_G.TSM_API.GetCustomPriceValue, source, "i:" .. id)
    if ok and type(v) == "number" and v > 0 then return v end
    return nil
end

-- The cheapest price of each day, as { day, price, day, price, ... }.
function Flip.Record(history, id, price, day)
    local h = history[id]
    if not h then h = {} history[id] = h end
    local n = #h
    if n >= 2 and h[n - 1] == day then
        if price < h[n] then h[n] = price end
    else
        h[n + 1], h[n + 2] = day, price
    end
    while #h > 0 and h[1] <= day - HISTORY_DAYS do
        table.remove(h, 1)
        table.remove(h, 1)
    end
end

-- The middle of the daily prices; needs three days so one odd day can't set it.
function Flip.Usual(history, id)
    local h = history[id]
    if not h or #h < 6 then return nil end
    local p = {}
    for i = 2, #h, 2 do p[#p + 1] = h[i] end
    table.sort(p)
    local n = #p
    if n % 2 == 1 then return p[(n + 1) / 2] end
    return math.floor((p[n / 2] + p[n / 2 + 1]) / 2)
end

-- Everything known about an item's price; info.sell is the price to relist at.
function Flip.Info(id)
    local info = {
        market = TSM("DBMarket", id),
        historical = TSM("DBHistorical", id),
        region = TSM("DBRegionMarketAvg", id),
        saleRate = TSM("DBRegionSaleRate", id),
        soldPerDay = TSM("DBRegionSoldPerDay", id),
        usual = Flip.Usual(Realm().history, id),
    }
    -- TSM 4.14 returns the sale rate as 0-1. A value above 1 means this
    -- version returns it as stored (times 1000), and sold per day with it.
    if info.saleRate and info.saleRate > 1 then tsmScale = 1000 end
    if tsmScale ~= 1 then
        info.saleRate = info.saleRate and info.saleRate / tsmScale
        info.soldPerDay = info.soldPerDay and info.soldPerDay / tsmScale
    end
    local sell = info.market
    if info.usual and (not sell or info.usual < sell) then sell = info.usual end
    if not sell then sell = info.region end
    if sell and info.historical and info.historical < sell then sell = info.historical end
    info.sell = sell and math.floor(sell) or nil
    return info
end

function Flip.Vendor(id)
    local v = TSM("VendorSell", id)
    if v then return v end
    local get = C_Item and C_Item.GetItemInfo
    if not get then return nil end
    local price = select(11, get(id))
    if type(price) == "number" and price > 0 then return price end
    return nil
end

-- Trade goods: the item class of ore, herbs, cloth, leather, gems and other
-- crafting materials.
function Flip.IsTrade(id)
    local get = C_Item and C_Item.GetItemInfoInstant
    if not get then return false end
    local _, _, _, _, _, classID = get(id)
    return classID == (Enum.ItemClass and Enum.ItemClass.Tradegoods or 7)
end

-- The most to pay per unit so the minimum margin is left after the cut.
function Flip.MaxBuy(sell)
    return math.floor(sell * (1 - S.cut) / (1 + S.minMargin))
end

-- Does it sell? relax halves the bar (for items already in your bags).
function Flip.Sells(info, listed, relax)
    local f = relax and 0.5 or 1
    if info.saleRate then
        return info.saleRate >= S.minSaleRate * f and (info.soldPerDay or 0) >= S.minSoldPerDay * f
    end
    if HasTSM() then return false end -- TSM is loaded and has seen no sales
    return (listed or 0) >= (relax and 1 or 20) -- no TSM: many listed means it trades
end

-- Decides a flip from an item's listings ({ price, qty, mine }, cheapest
-- first). complete is false when the house holds more listings than were
-- read. Returns the plan, or nil and why not.
function Flip.Plan(listings, complete, info, vendor, budget)
    for _, l in ipairs(listings) do
        if l.mine then return nil, "own" end -- you already sell it
    end
    local sell = info.sell
    if sell and Flip.MaxBuy(sell) >= 1 then
        local maxBuy = Flip.MaxBuy(sell)
        local qty, cost, last, nextPrice = 0, 0, nil, nil
        for _, l in ipairs(listings) do
            if l.price <= maxBuy then
                qty, cost, last = qty + l.qty, cost + l.qty * l.price, l.price
            else
                nextPrice = l.price
                break
            end
        end
        local cap = info.soldPerDay and math.max(1, math.ceil(info.soldPerDay * S.capDays))
        local why
        if qty == 0 then why = "gone"
        elseif (not nextPrice and not complete) or cost > budget or (cap and qty > cap) then why = "wall"
        else
            local relist = sell
            if nextPrice and nextPrice - 1 < relist then relist = nextPrice - 1 end
            local profit = math.floor(qty * relist * (1 - S.cut)) - cost
            if profit >= S.minProfit and profit / cost >= S.minMargin then
                return { kind = "ah", qty = qty, cost = cost, maxPrice = last, sellEach = relist,
                    profit = profit, margin = profit / cost }
            end
            why = "thin"
        end
        if not vendor then return nil, why end
    end
    if vendor then
        local qty, cost, last = 0, 0, nil
        for _, l in ipairs(listings) do
            if l.price >= vendor then break end
            local n = math.min(l.qty, math.floor((budget - cost) / l.price))
            if n <= 0 then break end
            qty, cost, last = qty + n, cost + n * l.price, l.price
        end
        local profit = qty * vendor - cost
        if qty > 0 and profit >= S.minProfit then
            return { kind = "vendor", qty = qty, cost = cost, maxPrice = last, sellEach = vendor,
                profit = profit, margin = profit / cost }
        end
        return nil, "thin"
    end
    return nil, "nodata"
end

-- What to do with count units from your bags. livePrice is the cheapest
-- listing from a recent scan, if any.
function Flip.SellPlan(count, info, livePrice, vendor, sells)
    local sell = info.sell
    local post, why
    if sell then
        post, why = sell, "its usual price"
        if livePrice and livePrice > Flip.MaxBuy(sell) then
            -- Just under the cheapest listing, but never far above the usual price.
            post, why = math.min(livePrice - 1, math.floor(sell * 1.25)), "just under the cheapest listing"
            if post < livePrice - 1 then why = "a little above its usual price" end
        end
    elseif livePrice and livePrice > 1 then
        post, why = livePrice - 1, "just under the cheapest listing (no price history yet)"
    end
    if post and post >= 1 and sells and post * (1 - S.cut) > (vendor or 0) then
        return { kind = "ah", price = post, total = math.floor(post * count * (1 - S.cut)), why = why }
    end
    -- A vendor only when something says the auction house is no better:
    -- the price there does not beat the vendor, or TSM knows it sells badly.
    if vendor and ((post and post * (1 - S.cut) <= vendor) or (info.saleRate and not sells)) then
        return { kind = "vendor", price = vendor, total = vendor * count }
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Prices by hour of day
-- ---------------------------------------------------------------------------

-- One bucket per item and hour: { avgPrice, avgQty, days, lastDay, dayPrice, dayQty }.
-- Within a day the cheapest price and the latest quantity are kept; when a
-- new day starts that day is folded into the averages. The averages weigh
-- every day equally for the first five days, then lean on the recent ones.
local function Fold(b)
    local n = b[3]
    if n == 0 then return b[5], b[6], 1 end
    local a = math.max(1 / (n + 1), 0.2)
    return b[1] + a * (b[5] - b[1]), b[2] + a * (b[6] - b[2]), n + 1
end

function Flip.RecordHour(hours, id, hour, price, qty, day)
    local t = hours[id]
    if not t then t = {} hours[id] = t end
    local b = t[hour + 1]
    if not b then
        t[hour + 1] = { 0, 0, 0, day, price, qty }
    elseif b[4] == day then
        if price < b[5] then b[5] = price end
        b[6] = qty
    else
        b[1], b[2], b[3] = Fold(b)
        b[4], b[5], b[6] = day, price, qty
    end
end

-- The usual cheapest price and units listed at an hour, and on how many days.
function Flip.HourValue(b)
    local p, q, n = Fold(b)
    return math.floor(p + 0.5), math.floor(q + 0.5), n
end

-- Drops hours not seen for two weeks.
function Flip.PruneHours(hours, day)
    for id, t in pairs(hours) do
        for h, b in pairs(t) do
            if b[4] <= day - HISTORY_DAYS then t[h] = nil end
        end
        if next(t) == nil then hours[id] = nil end
    end
end

-- Every hour's values (vals[0..23]) and, once enough hours have been seen on
-- two days, the cheapest and dearest hours and the gap between them after
-- the cut.
function Flip.BestHours(t)
    local r = { vals = {}, covered = 0, ready = 0 }
    for h = 0, 23 do
        local b = t and t[h + 1]
        if b then
            local p, q, n = Flip.HourValue(b)
            r.vals[h] = { p = p, q = q, n = n }
            r.covered = r.covered + 1
            if n >= HOUR_MIN_DAYS then
                r.ready = r.ready + 1
                if not r.buyHour or p < r.vals[r.buyHour].p then r.buyHour = h end
                if not r.sellHour or p > r.vals[r.sellHour].p then r.sellHour = h end
            end
        end
    end
    if r.ready < HOUR_MIN_COUNT then
        r.buyHour, r.sellHour = nil, nil
    else
        r.buyPrice, r.sellPrice = r.vals[r.buyHour].p, r.vals[r.sellHour].p
        r.gap = (r.sellPrice * (1 - S.cut) - r.buyPrice) / r.buyPrice
    end
    return r
end

-- ---------------------------------------------------------------------------
-- Cornering
-- ---------------------------------------------------------------------------

-- Buying every unit listed up to a price, then relisting all of it just
-- under the next listing left (never above CORNER_CAP times the usual
-- price). Each price step is tried; the one with the most profit is kept if
-- it fits the budget, keeps the minimum margin and sells within CORNER_DAYS
-- of TSM's sold per day. Your own listings are neither bought nor undercut.
-- Returns the plan or nil and why not; the third value always holds what
-- is listed in total (allQty, allCost).
function Flip.Corner(listings, complete, info, budget)
    local others, total = {}, { allQty = 0, allCost = 0 }
    for _, l in ipairs(listings) do
        if not l.mine then
            others[#others + 1] = l
            total.allQty, total.allCost = total.allQty + l.qty, total.allCost + l.qty * l.price
        end
    end
    if #others == 0 then return nil, "gone", total end
    local ref = info.sell
    if not ref then return nil, "nodata", total end
    local cap = math.floor(ref * CORNER_CAP)
    local spd = info.soldPerDay and info.soldPerDay > 0 and info.soldPerDay or nil
    local qty, cost, best, why = 0, 0, nil, "thin"
    for i, l in ipairs(others) do
        if cost + l.qty * l.price > budget then
            if i == 1 then why = "over" end
            break
        end
        local nextL = others[i + 1]
        if not nextL and not complete then break end -- more listings were not read
        qty, cost = qty + l.qty, cost + l.qty * l.price
        local days = spd and qty / spd
        if days and days > CORNER_DAYS then
            if not best then why = "slow" end
            break
        end
        local relist = cap
        if nextL and nextL.price - 1 < relist then relist = nextL.price - 1 end
        local profit = math.floor(qty * relist * (1 - S.cut)) - cost
        if relist > l.price and profit >= S.minProfit and profit / cost >= S.minMargin
            and (not best or profit > best.profit) then
            best = { qty = qty, cost = cost, upTo = l.price, relist = relist, profit = profit,
                margin = profit / cost, days = days }
        end
    end
    if not best then return nil, why, total end
    best.allQty, best.allCost = total.allQty, total.allCost
    return best, nil, total
end

-- ---------------------------------------------------------------------------
-- Bags
-- ---------------------------------------------------------------------------

-- The unbound items in your bags, one entry per item.
local function BagItems()
    local items = {}
    for bag = 0, (_G.NUM_BAG_SLOTS or 4) do
        for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
            local it = C_Container.GetContainerItemInfo(bag, slot)
            if it and it.itemID and not it.isBound and not NEVER_SELL[it.itemID] then
                local e = items[it.itemID]
                if not e then
                    e = { id = it.itemID, count = 0, icon = it.iconFileID, quality = it.quality,
                        name = it.hyperlink and it.hyperlink:match("%[(.-)%]") or ("item " .. it.itemID) }
                    items[it.itemID] = e
                end
                e.count = e.count + (it.stackCount or 1)
            end
        end
    end
    return items
end

-- ---------------------------------------------------------------------------
-- Scanning
-- ---------------------------------------------------------------------------

local BROWSE_EVENTS = {
    AUCTION_HOUSE_BROWSE_RESULTS_UPDATED = true,
    AUCTION_HOUSE_BROWSE_RESULTS_ADDED = true,
    AUCTION_HOUSE_BROWSE_FAILURE = true,
}
local COMMODITY_EVENTS = { COMMODITY_SEARCH_RESULTS_UPDATED = true, COMMODITY_SEARCH_RESULTS_ADDED = true }
local ITEM_EVENTS = { ITEM_SEARCH_RESULTS_UPDATED = true, ITEM_SEARCH_RESULTS_ADDED = true }

local Render, RenderMarket -- defined with the windows

local function Status(text)
    statusText = text
    if Render then Render() end
    if RenderMarket then RenderMarket() end
end

-- Sends one request when the auction house is ready for it and waits for
-- its answer (inside the scan coroutine). A request the throttle drops is
-- sent again. The client does not always fire the event again for results
-- it already holds, so after a second cached() may answer instead.
local function Request(send, events, match, cached)
    for _ = 1, 3 do
        while not C_AuctionHouse.IsThrottledMessageSystemReady() do coroutine.yield() end
        scan.wait = { events = events, match = match }
        scan.got, scan.dropped = nil, nil
        send()
        local t0 = GetTime()
        while not scan.got and not scan.dropped do
            local dt = GetTime() - t0
            if dt > TIMEOUT then break end
            if cached and dt > 1 and cached() then scan.got = true break end
            coroutine.yield()
        end
        scan.wait = nil
        if scan.got then return scan.got end
        if not scan.dropped then return false end
    end
    return false
end

-- Every item on the house: { itemKey, minPrice, totalQuantity, containsOwnerItem }.
local function ReadHouse()
    local answer = Request(function()
        C_AuctionHouse.SendBrowseQuery({ searchString = "", sorts = {}, filters = {}, itemClassFilters = {} })
    end, BROWSE_EVENTS)
    if not answer or answer == "AUCTION_HOUSE_BROWSE_FAILURE" then return nil end
    local pages, stuck, count = 0, 0, #C_AuctionHouse.GetBrowseResults()
    while not C_AuctionHouse.HasFullBrowseResults() and pages < 500 and stuck < 2 do
        answer = Request(function() C_AuctionHouse.RequestMoreBrowseResults() end, BROWSE_EVENTS)
        if not answer or answer == "AUCTION_HOUSE_BROWSE_FAILURE" then break end
        local now = #C_AuctionHouse.GetBrowseResults()
        stuck = now > count and 0 or stuck + 1
        pages, count = pages + 1, now
        Status("Reading the auction house: " .. count .. " items so far.")
    end
    return C_AuctionHouse.GetBrowseResults()
end

local function KeyInfo(key)
    local t0 = GetTime()
    local info = C_AuctionHouse.GetItemKeyInfo(key)
    while not info and GetTime() - t0 < 3 do
        coroutine.yield()
        info = C_AuctionHouse.GetItemKeyInfo(key)
    end
    return info
end

-- Counts the sellers named in a search result. Returns the new count and
-- whether some sellers were left unnamed.
local function AddOwners(r, seen, count, partial)
    if type(r.owners) == "table" then
        for _, o in ipairs(r.owners) do
            if not seen[o] then seen[o], count = true, count + 1 end
        end
        if r.totalNumberOfOwners and r.totalNumberOfOwners > #r.owners then partial = true end
    end
    return count, partial
end

-- One item's listings, cheapest first, whether that is all of them, and
-- how many sellers (nil if the client does not say; a string ending in "+"
-- when some were not named).
local function ReadListings(key, keyInfo)
    local id, listings = key.itemID, {}
    local seen, sellers, partial = {}, 0, false
    local sorts = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }
    local function send() C_AuctionHouse.SendSearchQuery(key, sorts, true) end
    local complete
    if keyInfo.isCommodity then
        local function match(itemID) return itemID == id end
        local function cached()
            return C_AuctionHouse.HasFullCommoditySearchResults(id) or C_AuctionHouse.GetNumCommoditySearchResults(id) > 0
        end
        if not Request(send, COMMODITY_EVENTS, match, cached) then return nil end
        for i = 1, C_AuctionHouse.GetNumCommoditySearchResults(id) do
            local r = C_AuctionHouse.GetCommoditySearchResultInfo(id, i)
            if r and r.unitPrice and r.unitPrice > 0 then
                listings[#listings + 1] = { price = r.unitPrice, qty = r.quantity or 1, mine = r.containsOwnerItem }
                sellers, partial = AddOwners(r, seen, sellers, partial)
            end
        end
        complete = C_AuctionHouse.HasFullCommoditySearchResults(id)
    else
        local function match(itemKey) return type(itemKey) == "table" and itemKey.itemID == id end
        local function cached()
            return C_AuctionHouse.HasFullItemSearchResults(key) or C_AuctionHouse.GetNumItemSearchResults(key) > 0
        end
        if not Request(send, ITEM_EVENTS, match, cached) then return nil end
        for i = 1, C_AuctionHouse.GetNumItemSearchResults(key) do
            local r = C_AuctionHouse.GetItemSearchResultInfo(key, i)
            -- Auctions with no buyout can only be bid on; they are not flips.
            if r and r.buyoutAmount and r.buyoutAmount > 0 then
                local qty = r.quantity or 1
                listings[#listings + 1] = { price = math.floor(r.buyoutAmount / qty), qty = qty, mine = r.containsOwnerItem }
                sellers, partial = AddOwners(r, seen, sellers, partial)
            end
        end
        complete = C_AuctionHouse.HasFullItemSearchResults(key)
    end
    table.sort(listings, function(a, b) return a.price < b.price end)
    local who = sellers > 0 and (partial and sellers .. "+" or tostring(sellers)) or nil
    return listings, complete, who
end

-- Reads every listing of the watched items and records their hour.
local function ReadWatched()
    local realm, ids = Realm(), {}
    for id in pairs(realm.watch) do ids[#ids + 1] = id end
    table.sort(ids)
    local day, hour = Today(), Hour()
    for i, id in ipairs(ids) do
        Status("Reading watched item " .. i .. " of " .. #ids .. "...")
        local key = C_AuctionHouse.MakeItemKey and C_AuctionHouse.MakeItemKey(id)
        local keyInfo = key and KeyInfo(key)
        local listings, complete, sellers
        if keyInfo then listings, complete, sellers = ReadListings(key, keyInfo) end
        if listings then
            local qty = 0
            for _, l in ipairs(listings) do qty = qty + l.qty end
            if listings[1] then Flip.RecordHour(realm.hours, id, hour, listings[1].price, qty, day) end
            if keyInfo.itemName then realm.watch[id] = keyInfo.itemName end
            watchLive[id] = { listings = listings, complete = complete, sellers = sellers, time = time(), icon = keyInfo.iconFileID }
        end
    end
    return #ids
end

local function RunWatch()
    local n = ReadWatched()
    Status("Read " .. n .. (n == 1 and " watched item" or " watched items") .. " at " .. HourName(Hour()) .. ".")
end

local function RunScan()
    Status("Reading the auction house...")
    local results = ReadHouse()
    if not results then
        Status("The auction house did not answer. Try Scan again.")
        return
    end

    -- One entry per item. An item listed under several keys (gear with
    -- different endings or item levels) has no single price, so it is left out.
    local byID, total = {}, 0
    for _, r in ipairs(results) do
        local id = r.itemKey and r.itemKey.itemID
        if id and r.minPrice and r.minPrice > 0 then
            local e = byID[id]
            if e then
                e.n = e.n + 1
            else
                byID[id] = { key = r.itemKey, price = r.minPrice, qty = r.totalQuantity or 0, mine = r.containsOwnerItem, n = 1 }
                total = total + 1
            end
        end
    end

    local realm = Realm()
    local day, hour = Today(), Hour()
    live = {}
    for id, e in pairs(byID) do
        if e.n == 1 then
            Flip.Record(realm.history, id, e.price, day)
            if realm.watch[id] or Flip.IsTrade(id) then
                Flip.RecordHour(realm.hours, id, hour, e.price, e.qty, day)
            end
            live[id] = e
        end
    end
    for id, h in pairs(realm.history) do
        if #h < 2 or h[#h - 1] <= day - HISTORY_DAYS then realm.history[id] = nil end
    end
    Flip.PruneHours(realm.hours, day)
    liveTime = time()

    Status("Pricing " .. total .. " items...")
    local gold = GetMoney()
    local perItem = math.floor(gold * S.maxShare)
    local held = BagItems()
    local cands, cornerCands, priced, done = {}, {}, 0, 0
    for id, e in pairs(live) do
        -- Not what you already sell, and not what you already hold.
        if not e.mine and not held[id] then
            local info, vendor = Flip.Info(id), Flip.Vendor(id)
            if info.sell then priced = priced + 1 end
            local ah = not S.tradeOnly or Flip.IsTrade(id)
            local unit, weight
            if ah and info.sell and e.price <= Flip.MaxBuy(info.sell) and Flip.Sells(info, e.qty) then
                unit, weight = info.sell * (1 - S.cut) - e.price, info.saleRate or 0.2
            elseif vendor and e.price < vendor then
                unit, weight = vendor - e.price, 1
            end
            local n = math.min(e.qty, math.floor(perItem / e.price))
            if unit and n >= 1 then
                cands[#cands + 1] = { id = id, e = e, info = info, vendor = vendor, ah = ah, est = unit * n * weight }
            end
            -- Worth watching: a trade good that sells, listed at or under its
            -- usual price, with little enough listed to buy a real share of it.
            if not realm.watch[id] and info.sell and info.soldPerDay and e.price <= info.sell
                and Flip.IsTrade(id) and Flip.Sells(info, e.qty) then
                local share = math.min(e.qty, info.soldPerDay * CORNER_DAYS, math.floor(perItem / e.price))
                local gain = (info.sell * CORNER_CAP * (1 - S.cut) - e.price) * share
                if share >= 1 and gain > 0 then
                    cornerCands[#cornerCands + 1] = { id = id, e = e, info = info, est = gain * share / e.qty }
                end
            end
        end
        done = done + 1
        if done % 200 == 0 then coroutine.yield() end
    end
    table.sort(cands, function(a, b) return a.est > b.est end)

    local plans = {}
    for i = 1, math.min(#cands, MAX_CHECK) do
        local c = cands[i]
        Status("Checking " .. i .. " of " .. math.min(#cands, MAX_CHECK) .. " possible flips...")
        local keyInfo = KeyInfo(c.e.key)
        local listings, complete
        if keyInfo then listings, complete = ReadListings(c.e.key, keyInfo) end
        if listings then
            -- Without c.ah only the vendor flip is judged.
            local plan = Flip.Plan(listings, complete, c.ah and c.info or {}, c.vendor, perItem)
            if plan then
                plan.id, plan.key, plan.info, plan.vendor = c.id, c.e.key, c.info, c.vendor
                plan.name, plan.icon, plan.listed = keyInfo.itemName or ("item " .. c.id), keyInfo.iconFileID, c.e.qty
                plan.score = plan.profit * (plan.kind == "vendor" and 1 or (c.info.saleRate or 0.2))
                plans[#plans + 1] = plan
            end
        end
    end
    table.sort(plans, function(a, b) return a.score > b.score end)

    table.sort(cornerCands, function(a, b) return a.est > b.est end)
    suggestions = {}
    for i = 1, math.min(#cornerCands, SUGGEST_CHECK) do
        local c = cornerCands[i]
        Status("Checking " .. i .. " of " .. math.min(#cornerCands, SUGGEST_CHECK) .. " items worth watching...")
        local keyInfo = KeyInfo(c.e.key)
        local listings, complete, sellers
        if keyInfo then listings, complete, sellers = ReadListings(c.e.key, keyInfo) end
        local plan = listings and Flip.Corner(listings, complete, c.info, perItem)
        if plan then
            suggestions[#suggestions + 1] = { id = c.id, key = c.e.key, info = c.info, plan = plan, sellers = sellers,
                name = keyInfo.itemName or ("item " .. c.id), icon = keyInfo.iconFileID }
        end
    end
    table.sort(suggestions, function(a, b) return a.plan.profit > b.plan.profit end)
    while #suggestions > SUGGEST_ROWS do table.remove(suggestions) end
    ReadWatched()

    buys = {}
    local left = gold
    for _, plan in ipairs(plans) do
        if #buys < BUY_ROWS and plan.cost <= left then
            buys[#buys + 1] = plan
            left = left - plan.cost
        end
    end

    local note = ""
    if not HasTSM() then
        note = " TradeSkillMaster is not loaded, so only prices this addon has seen for 3 days are used."
    elseif priced == 0 then
        note = " TradeSkillMaster has no prices yet: run the TSM Desktop App, then /reload."
    end
    Status("Scanned " .. total .. " items, " .. #buys .. " to buy." .. note)
end

local events = CreateFrame("Frame")
local StepScan

local function StartScan(fn)
    if scan then return end
    if not (C_AuctionHouse and C_AuctionHouse.SendBrowseQuery) then
        Status("This client has no modern auction house.")
        return
    end
    scan = { co = coroutine.create(fn or RunScan) }
    events:SetScript("OnUpdate", StepScan)
end

StepScan = function()
    if not scan then events:SetScript("OnUpdate", nil) return end
    local ok, err = coroutine.resume(scan.co)
    if not ok then
        scan = nil
        Status("Scan stopped by an error.")
        Print("scan error: " .. tostring(err))
    elseif coroutine.status(scan.co) == "dead" then
        scan = nil
        if Render then Render() end
        if RenderMarket then RenderMarket() end
    end
end

-- What is in your bags: rows worth posting (best first) and the vendor total.
local function BagAdvice()
    local items = BagItems()
    local fresh = liveTime and time() - liveTime <= LIVE_MAX_AGE
    local rows, vendorCount, vendorTotal = {}, 0, 0
    for id, e in pairs(items) do
        local info, vendor = Flip.Info(id), Flip.Vendor(id)
        local l = fresh and live[id] or nil
        local plan
        if e.quality == 0 then
            plan = vendor and { kind = "vendor", price = vendor, total = vendor * e.count } or nil
        else
            plan = Flip.SellPlan(e.count, info, l and not l.mine and l.price or nil, vendor, Flip.Sells(info, l and l.qty, true))
        end
        if plan and plan.kind == "ah" then
            e.plan, e.info, e.vendor, e.key = plan, info, vendor, l and l.key
            rows[#rows + 1] = e
        elseif plan and (e.quality or 1) < 3 then -- never say "vendor" for a rare or better
            vendorCount, vendorTotal = vendorCount + 1, vendorTotal + plan.total
        end
    end
    table.sort(rows, function(a, b) return a.plan.total > b.plan.total end)
    return rows, vendorCount, vendorTotal
end

-- ---------------------------------------------------------------------------
-- Window
-- ---------------------------------------------------------------------------

local function Speed(info)
    if not info.saleRate then return nil end
    if info.saleRate >= 0.4 then return "sells fast" end
    if info.saleRate >= 0.2 then return "sells steadily" end
    return "sells slowly"
end

-- Opens the item in Blizzard's auction window, where you buy it yourself.
local function ShowInAH(data)
    if scan then Print("Wait for the scan to finish.") return end
    local f = _G.AuctionHouseFrame
    if not f or not f:IsShown() then
        Print("Open the default auction window to search from here. In TradeSkillMaster, click its button that switches to the default window.")
        return
    end
    local key = data.key or (C_AuctionHouse.MakeItemKey and C_AuctionHouse.MakeItemKey(data.id))
    if key and f.SelectBrowseResult and C_AuctionHouse.GetItemKeyInfo(key) then
        local l = live[data.id]
        if pcall(f.SelectBrowseResult, f, { itemKey = key, minPrice = l and l.price or 0, totalQuantity = l and l.qty or 0 }) then
            return
        end
    end
    -- Otherwise search by name in the Buy tab's list.
    if f.SetDisplayMode and _G.AuctionHouseFrameDisplayMode then
        pcall(f.SetDisplayMode, f, _G.AuctionHouseFrameDisplayMode.Buy)
    end
    C_AuctionHouse.SendBrowseQuery({ searchString = data.name, sorts = {}, filters = {}, itemClassFilters = {} })
end

local Watch -- defined with the market window

local function RowTooltip(self)
    local d = self.data
    if not d then return end
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine(d.name, 1, 1, 1)
    local info = d.info or {}
    local function line(label, value) if value then GameTooltip:AddDoubleLine(label, value, 0.8, 0.8, 0.8, 1, 1, 1) end end
    local l = live[d.id]
    line("Cheapest listing", l and Money(l.price))
    line("Units listed", l and tostring(l.qty))
    line("TSM market value", info.market and Money(info.market))
    line("TSM historical price", info.historical and Money(info.historical))
    line("TSM region average", info.region and Money(info.region))
    line("Usual price in your scans", info.usual and Money(info.usual))
    line("Vendor pays", d.vendor and Money(d.vendor))
    line("TSM sale rate", info.saleRate and string.format("%.0f%%", info.saleRate * 100))
    line("TSM sold per day", info.soldPerDay and string.format("%.1f", info.soldPerDay))
    if d.margin then line("Profit on what you pay", string.format("%.0f%%", d.margin * 100)) end
    GameTooltip:AddLine("Click to open it in the auction window.", 0.2, 1, 0.6)
    GameTooltip:AddLine("Alt-click to watch it in the market window.", 0.2, 1, 0.6)
    GameTooltip:Show()
end

local function MakeRow(parent)
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(344, 32)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(28, 28)
    row.icon:SetPoint("LEFT", 0, 0)
    row.profit = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.profit:SetPoint("TOPRIGHT", 0, -2)
    row.profit:SetJustifyH("RIGHT")
    row.top = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.top:SetPoint("TOPLEFT", 34, -2)
    row.top:SetPoint("RIGHT", row.profit, "LEFT", -6, 0)
    row.top:SetJustifyH("LEFT")
    row.top:SetWordWrap(false)
    row.bottom = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.bottom:SetPoint("BOTTOMLEFT", 34, 3)
    row.bottom:SetPoint("RIGHT", 0, 0)
    row.bottom:SetJustifyH("LEFT")
    row.bottom:SetWordWrap(false)
    row.bottom:SetTextColor(0.75, 0.75, 0.75)
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.08)
    row:SetScript("OnClick", function(self)
        if not self.data then return end
        if IsAltKeyDown and IsAltKeyDown() then Watch(self.data.id, self.data.name) else ShowInAH(self.data) end
    end)
    row:SetScript("OnEnter", RowTooltip)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return row
end

local function Header(parent, text)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetText(text)
    return fs
end

local ShowMarket -- defined with the market window

local function Build()
    panel = CreateFrame("Frame", "OneClickFlipPanel", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    panel:SetSize(364, 150 + (BUY_ROWS + SELL_ROWS) * 34)
    panel:SetFrameStrata("HIGH")
    panel:SetClampedToScreen(true)
    panel:SetMovable(true)
    panel:EnableMouse(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", panel.StartMoving)
    panel:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint(1)
        DB.pos = { point, relPoint, x, y }
    end)
    if DB.pos then
        panel:SetPoint(DB.pos[1], UIParent, DB.pos[2], DB.pos[3], DB.pos[4])
    else
        panel:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -20, -110)
    end
    if panel.SetBackdrop then
        panel:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 14,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        panel:SetBackdropColor(0, 0, 0, 0.92)
        panel:SetBackdropBorderColor(1, 0.82, 0, 1)
    end

    panel.title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    panel.title:SetPoint("TOPLEFT", 10, -10)
    panel.title:SetText("OneClickFlip")
    local close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 0, 0)

    panel.gold = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    panel.gold:SetPoint("TOPLEFT", 10, -32)

    panel.scan = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    panel.scan:SetSize(80, 22)
    panel.scan:SetPoint("TOPLEFT", 8, -48)
    panel.scan:SetText("Scan")
    panel.scan:SetScript("OnClick", function() StartScan(RunScan) end)
    panel.marketButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    panel.marketButton:SetSize(70, 20)
    panel.marketButton:SetPoint("TOPRIGHT", -28, -8)
    panel.marketButton:SetText("Market")
    panel.marketButton:SetScript("OnClick", function() ShowMarket() end)
    panel.status = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    panel.status:SetPoint("TOPLEFT", panel.scan, "TOPRIGHT", 6, 0)
    panel.status:SetPoint("RIGHT", -10, 0)
    panel.status:SetHeight(24)
    panel.status:SetJustifyH("LEFT")
    panel.status:SetJustifyV("MIDDLE")

    local y = -78
    panel.buyHeader = Header(panel, "Buy (click a row to open it)")
    panel.buyHeader:SetPoint("TOPLEFT", 10, y)
    y = y - 18
    panel.buyRows = {}
    for i = 1, BUY_ROWS do
        local row = MakeRow(panel)
        row:SetPoint("TOPLEFT", 10, y)
        panel.buyRows[i] = row
        y = y - 34
    end
    panel.buyEmpty = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    panel.buyEmpty:SetPoint("TOPLEFT", panel.buyRows[1], "TOPLEFT", 0, -4)
    panel.buyEmpty:SetWidth(344)
    panel.buyEmpty:SetJustifyH("LEFT")

    y = y - 4
    panel.sellHeader = Header(panel, "Sell from your bags")
    panel.sellHeader:SetPoint("TOPLEFT", 10, y)
    y = y - 18
    panel.sellRows = {}
    for i = 1, SELL_ROWS do
        local row = MakeRow(panel)
        row:SetPoint("TOPLEFT", 10, y)
        panel.sellRows[i] = row
        y = y - 34
    end
    panel.sellEmpty = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    panel.sellEmpty:SetPoint("TOPLEFT", panel.sellRows[1], "TOPLEFT", 0, -4)
    panel.sellEmpty:SetWidth(344)
    panel.sellEmpty:SetJustifyH("LEFT")

    panel.vendor = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    panel.vendor:SetPoint("BOTTOMLEFT", 10, 10)
    panel.vendor:SetPoint("RIGHT", -10, 0)
    panel.vendor:SetJustifyH("LEFT")

    panel:Hide()
end

local function FillRow(row, data, top, profit, bottom)
    row.data = data
    row.icon:SetTexture(data.icon or 134400)
    row.top:SetText(top)
    row.profit:SetText("|cff33ff99+" .. Money(profit) .. "|r")
    row.bottom:SetText(bottom)
    row:Show()
end

Render = function()
    if not panel or not panel:IsShown() then return end
    local gold = GetMoney()
    panel.gold:SetText("Gold: " .. Money(gold) .. ". At most " .. Money(math.floor(gold * S.maxShare)) .. " into one item.")
    local status = statusText
    if not scan and liveTime and time() - liveTime > 600 then
        status = "Prices are " .. math.floor((time() - liveTime) / 60) .. " minutes old. Scan again before buying."
    end
    panel.status:SetText(status)
    panel.buyHeader:SetText(S.tradeOnly and "Buy: trade goods only (click a row to open it)" or "Buy: every kind of item (click a row to open it)")
    if scan then panel.scan:Disable() else panel.scan:Enable() end

    for i, row in ipairs(panel.buyRows) do
        local p = buys[i]
        if p then
            local bottom
            if p.kind == "vendor" then
                bottom = "Pay up to " .. Money(p.maxPrice) .. " each (" .. Money(p.cost) .. "). A vendor pays " .. Money(p.sellEach) .. " each."
            else
                local speed = Speed(p.info)
                bottom = "Pay up to " .. Money(p.maxPrice) .. " each (" .. Money(p.cost) .. "). Relist at " .. Money(p.sellEach)
                    .. " each" .. (speed and ", " .. speed or "") .. "."
            end
            FillRow(row, p, "Buy " .. p.qty .. " " .. p.name, p.profit, bottom)
        else
            row.data = nil
            row:Hide()
        end
    end
    panel.buyEmpty:SetText(#buys == 0 and (liveTime and "No safe flips right now. Scan again later." or "Nothing scanned yet.") or "")

    local rows, vendorCount, vendorTotal = BagAdvice()
    for i, row in ipairs(panel.sellRows) do
        local e = rows[i]
        if e then
            FillRow(row, e, "Post " .. e.count .. " " .. e.name, e.plan.total,
                "At " .. Money(e.plan.price) .. " each: " .. e.plan.why .. ".")
        else
            row.data = nil
            row:Hide()
        end
    end
    panel.sellEmpty:SetText(#rows == 0 and "Nothing in your bags is worth posting." or "")
    if vendorCount > 0 then
        panel.vendor:SetText("Sell the rest to a vendor: " .. vendorCount .. (vendorCount == 1 and " item" or " items") .. " for " .. Money(vendorTotal) .. ".")
    else
        panel.vendor:SetText("")
    end
end

local function ShowPanel()
    if not panel then Build() end
    panel:SetScale(S.scale)
    panel:Show()
    Render()
end


-- ---------------------------------------------------------------------------
-- Market window: prices by hour, watched items, cornering
-- ---------------------------------------------------------------------------

local GRAPH_W, GRAPH_H, BAR_W = 360, 140, 15

local function ItemName(id)
    local get = C_Item and C_Item.GetItemInfo
    local name = get and get(id)
    return type(name) == "string" and name or nil
end

local function WatchedIDs()
    local realm, ids = Realm(), {}
    for id in pairs(realm.watch) do ids[#ids + 1] = id end
    table.sort(ids, function(a, b) return tostring(realm.watch[a]) < tostring(realm.watch[b]) end)
    return ids
end

local function Count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- The hour advice for an item, as one sentence.
local function TimesText(id)
    local r = Flip.BestHours(Realm().hours[id])
    if not r.buyHour then
        return "Not enough data yet: " .. r.ready .. " of 24 hours seen on two days (" .. HOUR_MIN_COUNT
            .. " needed). Open the auction house at different times of day."
    end
    local text = "Cheapest around " .. HourName(r.buyHour) .. ", usually " .. Money(r.buyPrice)
        .. ". Dearest around " .. HourName(r.sellHour) .. ", usually " .. Money(r.sellPrice)
        .. ". Buying at the first and selling at the second makes " .. string.format("%.0f%%", r.gap * 100) .. " after the cut"
    if r.gap < S.minMargin then
        text = text .. ", under your " .. math.floor(S.minMargin * 100 + 0.5) .. "% margin, so timing alone will not pay."
    else
        text = text .. "."
    end
    return text, r
end

-- What is listed now and the corner plan for a watched item.
local function CornerText(id)
    local w = watchLive[id]
    if not w then return "Not read yet. Its listings are read when the auction house opens.", nil end
    local info = Flip.Info(id)
    local budget = math.floor(GetMoney() * S.maxShare)
    local plan, why, total = Flip.Corner(w.listings, w.complete, info, budget)
    local age = math.floor((time() - w.time) / 60)
    local supply = "Listed now: " .. total.allQty .. " for " .. Money(total.allCost) .. " in all"
        .. (w.sellers and (", " .. w.sellers .. " sellers") or "")
        .. (info.soldPerDay and string.format(". TSM: %.0f sold a day in the region", info.soldPerDay) or "")
        .. (age >= 1 and (". Read " .. age .. " min ago.") or ".")
    local held = BagItems()[id]
    if held then supply = supply .. " You hold " .. held.count .. "." end
    local text
    if plan then
        text = "Corner: buy all " .. plan.qty .. " up to " .. Money(plan.upTo) .. " each (" .. Money(plan.cost)
            .. "), relist at " .. Money(plan.relist) .. ". Profit " .. Money(plan.profit)
            .. string.format(" (%.0f%%)", plan.margin * 100)
            .. (plan.days and string.format(", about %.0f days of TSM sales.", math.max(1, plan.days)) or ", sale pace unknown.")
    elseif why == "over" then
        text = "No corner: even the cheapest listings cost more than your limit of " .. Money(budget) .. " for one item."
    elseif why == "slow" then
        text = "No corner: buying enough to move the price would take over " .. CORNER_DAYS .. " days to sell."
    elseif why == "nodata" then
        text = "No corner: no TSM price or usual price yet to relist at."
    elseif why == "gone" then
        text = "Nothing listed by anyone else."
    else
        text = "No corner: no price step leaves your " .. math.floor(S.minMargin * 100 + 0.5) .. "% margin within " .. Money(budget) .. "."
    end
    return supply, text
end

local function BarTooltip(self)
    local v = self.vals and self.vals[self.hour]
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine(HourName(self.hour), 1, 1, 1)
    if v then
        GameTooltip:AddDoubleLine("Cheapest listing, usually", Money(v.p), 0.8, 0.8, 0.8, 1, 1, 1)
        GameTooltip:AddDoubleLine("Units listed, usually", tostring(v.q), 0.8, 0.8, 0.8, 1, 1, 1)
        GameTooltip:AddDoubleLine("Days seen", tostring(v.n), 0.8, 0.8, 0.8, 1, 1, 1)
    else
        GameTooltip:AddLine("No scans at this hour yet.", 0.8, 0.8, 0.8)
    end
    GameTooltip:Show()
end

local function Text(parent, font, width)
    local fs = parent:CreateFontString(nil, "OVERLAY", font)
    fs:SetJustifyH("LEFT")
    if width then fs:SetWidth(width) end
    return fs
end

local function BuildMarket()
    market = CreateFrame("Frame", "OneClickFlipMarket", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    market:SetSize(570, 580)
    market:SetFrameStrata("HIGH")
    market:SetClampedToScreen(true)
    market:SetMovable(true)
    market:EnableMouse(true)
    market:RegisterForDrag("LeftButton")
    market:SetScript("OnDragStart", market.StartMoving)
    market:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint(1)
        DB.marketPos = { point, relPoint, x, y }
    end)
    if DB.marketPos then
        market:SetPoint(DB.marketPos[1], UIParent, DB.marketPos[2], DB.marketPos[3], DB.marketPos[4])
    else
        market:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -400, -110)
    end
    if market.SetBackdrop then
        market:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 14,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        market:SetBackdropColor(0, 0, 0, 0.92)
        market:SetBackdropBorderColor(1, 0.82, 0, 1)
    end

    local title = market:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 10, -10)
    title:SetText("OneClickFlip: market")
    local close = CreateFrame("Button", nil, market, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 0, 0)
    close:SetScript("OnClick", function() DB.marketShown = false market:Hide() end)

    -- Watched items on the left.
    local head = Header(market, "Watching")
    head:SetPoint("TOPLEFT", 10, -38)
    market.watchRows = {}
    for i = 1, MAX_WATCH do
        local b = CreateFrame("Button", nil, market)
        b:SetSize(170, 22)
        b:SetPoint("TOPLEFT", 10, -56 - (i - 1) * 22)
        b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        b.text = Text(b, "GameFontHighlight", 170)
        b.text:SetPoint("LEFT", 2, 0)
        b.text:SetWordWrap(false)
        local hl = b:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.08)
        b:SetScript("OnClick", function(self, button)
            if not self.id then return end
            if button == "RightButton" then
                local realm = Realm()
                Print("Stopped watching " .. tostring(realm.watch[self.id]) .. ".")
                realm.watch[self.id], watchLive[self.id] = nil, nil
            else
                Realm().selected = self.id
            end
            RenderMarket()
        end)
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            GameTooltip:AddLine("Click to show it. Right-click to stop watching it.", 1, 1, 1)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        market.watchRows[i] = b
    end
    market.watchEmpty = Text(market, "GameFontDisableSmall", 170)
    market.watchEmpty:SetPoint("TOPLEFT", 12, -58)
    market.watchEmpty:SetText("Nothing watched yet. Alt-click an item in the main window, click an item under Worth watching, or type /flip watch and shift-click an item.")
    market.read = CreateFrame("Button", nil, market, "UIPanelButtonTemplate")
    market.read:SetSize(130, 22)
    market.read:SetPoint("TOPLEFT", 10, -58 - MAX_WATCH * 22)
    market.read:SetText("Read watched")
    market.read:SetScript("OnClick", function()
        if not auctionOpen then Print("Open the auction house first.") return end
        StartScan(RunWatch)
    end)

    -- The graph on the right.
    local x0 = 192
    market.name = market:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    market.name:SetPoint("TOPLEFT", x0, -38)
    market.name:SetWidth(GRAPH_W)
    market.name:SetJustifyH("LEFT")
    market.name:SetWordWrap(false)
    local graph = CreateFrame("Frame", nil, market)
    graph:SetSize(GRAPH_W, GRAPH_H)
    graph:SetPoint("TOPLEFT", x0, -62)
    local bg = graph:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(1, 1, 1, 0.05)
    market.bars = {}
    for h = 0, 23 do
        local b = CreateFrame("Frame", nil, graph)
        b:SetSize(BAR_W, GRAPH_H)
        b:SetPoint("BOTTOMLEFT", h * BAR_W, 0)
        b:EnableMouse(true)
        b.hour = h
        b.tex = b:CreateTexture(nil, "ARTWORK")
        b.tex:SetPoint("BOTTOMLEFT", 1, 0)
        b.tex:SetPoint("BOTTOMRIGHT", -1, 0)
        b.tex:SetHeight(1)
        b:SetScript("OnEnter", BarTooltip)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        market.bars[h] = b
    end
    market.top = Text(graph, "GameFontHighlightSmall")
    market.top:SetPoint("TOPLEFT", 3, -3)
    market.bottom = Text(graph, "GameFontHighlightSmall")
    market.bottom:SetPoint("BOTTOMLEFT", 3, 3)
    market.now = graph:CreateTexture(nil, "OVERLAY")
    market.now:SetSize(BAR_W, 3)
    market.now:SetColorTexture(1, 1, 1, 0.9)
    for _, h in ipairs({ 0, 6, 12, 18 }) do
        local fs = Text(market, "GameFontHighlightSmall")
        fs:SetPoint("TOPLEFT", graph, "BOTTOMLEFT", h * BAR_W, -6)
        fs:SetText(HourName(h))
    end
    market.key = Text(market, "GameFontHighlightSmall", GRAPH_W)
    market.key:SetPoint("TOPLEFT", graph, "BOTTOMLEFT", 0, -22)
    market.key:SetText("|cff33ff66Green|r: cheapest hour. |cffffcc00Gold|r: dearest. Gray: seen on one day only. White line: now.")
    market.times = Text(market, "GameFontHighlight", GRAPH_W)
    market.times:SetPoint("TOPLEFT", market.key, "BOTTOMLEFT", 0, -8)
    market.supply = Text(market, "GameFontHighlight", GRAPH_W)
    market.supply:SetPoint("TOPLEFT", market.times, "BOTTOMLEFT", 0, -8)
    market.corner = Text(market, "GameFontHighlight", GRAPH_W)
    market.corner:SetPoint("TOPLEFT", market.supply, "BOTTOMLEFT", 0, -8)

    -- Suggestions along the bottom.
    market.suggestHeader = Header(market, "Worth watching (from your last full scan; click to watch)")
    market.suggestHeader:SetPoint("BOTTOMLEFT", 10, 30 + SUGGEST_ROWS * 34)
    market.suggestRows = {}
    for i = 1, SUGGEST_ROWS do
        local row = MakeRow(market)
        row:SetWidth(550)
        row:SetPoint("BOTTOMLEFT", 10, 28 + (SUGGEST_ROWS - i) * 34)
        row:SetScript("OnClick", function(self) if self.data then Watch(self.data.id, self.data.name) end end)
        market.suggestRows[i] = row
    end
    market.suggestEmpty = Text(market, "GameFontDisableSmall", 550)
    market.suggestEmpty:SetPoint("TOPLEFT", market.suggestRows[1], "TOPLEFT", 0, -4)
    market.status = Text(market, "GameFontHighlightSmall", 550)
    market.status:SetPoint("BOTTOMLEFT", 10, 10)
    market:Hide()
end

RenderMarket = function()
    if not market or not market:IsShown() then return end
    local realm = Realm()
    local ids = WatchedIDs()
    if not (realm.selected and realm.watch[realm.selected]) then realm.selected = ids[1] end
    local id = realm.selected
    for i, b in ipairs(market.watchRows) do
        local wid = ids[i]
        b.id = wid
        if wid then
            b.text:SetText(realm.watch[wid])
            if wid == id then b.text:SetTextColor(1, 0.82, 0) else b.text:SetTextColor(1, 1, 1) end
            b:Show()
        else
            b:Hide()
        end
    end
    if #ids == 0 then market.watchEmpty:Show() else market.watchEmpty:Hide() end
    if scan or not auctionOpen then market.read:Disable() else market.read:Enable() end

    local hourNow = Hour()
    if id then
        market.name:SetText(realm.watch[id])
        local times, r = TimesText(id)
        r = r or Flip.BestHours(realm.hours[id])
        local lo, hi
        for _, v in pairs(r.vals) do
            if not lo or v.p < lo then lo = v.p end
            if not hi or v.p > hi then hi = v.p end
        end
        local base = lo and math.floor(lo * 0.9) or 0
        local range = hi and math.max(hi - base, 1) or 1
        for h = 0, 23 do
            local b, v = market.bars[h], r.vals[h]
            b.vals = r.vals
            if v then
                b.tex:SetHeight(math.max(2, (v.p - base) / range * (GRAPH_H - 20)))
                if h == r.buyHour then b.tex:SetColorTexture(0.2, 1, 0.4, 0.95)
                elseif h == r.sellHour then b.tex:SetColorTexture(1, 0.8, 0, 0.95)
                elseif v.n < HOUR_MIN_DAYS then b.tex:SetColorTexture(0.5, 0.5, 0.5, 0.8)
                else b.tex:SetColorTexture(0.35, 0.6, 1, 0.9) end
                b.tex:Show()
            else
                b.tex:Hide()
            end
        end
        market.top:SetText(hi and Money(hi) or "")
        market.bottom:SetText(lo and Money(base) or "No scans yet")
        market.now:ClearAllPoints()
        market.now:SetPoint("BOTTOMLEFT", market.bars[hourNow], "BOTTOMLEFT", 0, -4)
        market.now:Show()
        market.times:SetText(times)
        local supply, corner = CornerText(id)
        market.supply:SetText(supply)
        market.corner:SetText(corner or "")
    else
        market.name:SetText("Pick an item to watch")
        for h = 0, 23 do market.bars[h].tex:Hide() market.bars[h].vals = nil end
        market.top:SetText("")
        market.bottom:SetText("")
        market.now:Hide()
        market.times:SetText("")
        market.supply:SetText("")
        market.corner:SetText("")
    end

    for i, row in ipairs(market.suggestRows) do
        local sg = suggestions[i]
        if sg and not realm.watch[sg.id] then
            local p = sg.plan
            FillRow(row, sg, "Watch " .. sg.name .. (sg.sellers and (" (" .. sg.sellers .. " sellers)") or ""), p.profit,
                "Corner: buy all " .. p.qty .. " up to " .. Money(p.upTo) .. " (" .. Money(p.cost) .. "), relist at "
                .. Money(p.relist) .. (p.days and string.format(", about %.0f days to sell.", math.max(1, p.days)) or "."))
        else
            row.data = nil
            row:Hide()
        end
    end
    market.suggestEmpty:SetText(#suggestions == 0 and "Run a full Scan in the main window to find trade goods worth watching." or "")
    market.status:SetText(statusText)
end

ShowMarket = function()
    if not market then BuildMarket() end
    market:SetScale(S.scale)
    DB.marketShown = true
    market:Show()
    RenderMarket()
end

Watch = function(id, name)
    if not id then return end
    local realm = Realm()
    if not realm.watch[id] then
        if Count(realm.watch) >= MAX_WATCH then
            Print("You watch " .. MAX_WATCH .. " items already. Right-click one in the market window to stop watching it.")
            return
        end
        realm.watch[id] = name or ItemName(id) or ("item " .. id)
        Print("Watching " .. realm.watch[id] .. ". Its listings are read each time the auction house opens.")
    end
    realm.selected = id
    ShowMarket()
    if auctionOpen and not scan and not watchLive[id] then StartScan(RunWatch) end
end

-- An item from a link, an item ID or an exact name.
local function ParseItem(text)
    local id = tonumber(text:match("item:(%d+)")) or tonumber(text:match("^(%d+)$"))
    local name = text:match("%[(.-)%]")
    if not id and text ~= "" and C_Item and C_Item.GetItemInfo then
        local n, link = C_Item.GetItemInfo(text)
        if type(link) == "string" then id, name = tonumber(link:match("item:(%d+)")), n end
    end
    return id, name
end

-- ---------------------------------------------------------------------------
-- Events and slash command
-- ---------------------------------------------------------------------------

local function Percent(msg, key, label)
    local n = tonumber(msg:match("(%d+)"))
    if n and n >= 1 and n <= 500 then
        DB.settings[key] = n / 100
        Print(label .. " is now " .. n .. "%.")
    else
        Print(label .. " is " .. math.floor(S[key] * 100 + 0.5) .. "%.")
    end
    if Render then Render() end
end

local function Slash(raw)
    raw = strtrim(raw or "")
    local msg = strlower(raw)
    local rest = raw:match("^%S+%s+(.+)$") or ""
    if msg:find("^watch") or msg:find("^unwatch") or msg:find("^times") then
        local id, name = ParseItem(rest)
        if not id then
            Print("Name the item: type /flip " .. msg:match("^%a+") .. " and shift-click the item, or give its exact name or ID.")
        elseif msg:find("^watch") then
            Watch(id, name)
        elseif msg:find("^unwatch") then
            local realm = Realm()
            Print(realm.watch[id] and ("Stopped watching " .. realm.watch[id] .. ".") or "That item is not watched.")
            realm.watch[id], watchLive[id] = nil, nil
            if RenderMarket then RenderMarket() end
        else
            Print((name or Realm().watch[id] or ItemName(id) or ("item " .. id)) .. ": " .. TimesText(id))
        end
    elseif msg == "market" then
        if market and market:IsShown() then DB.marketShown = false market:Hide() else ShowMarket() end
    elseif msg:find("^size") then
        local n = tonumber(msg:match("(%d+)"))
        if n and n >= 70 and n <= 200 then DB.settings.scale = n / 100 end
        Print("Window size is " .. math.floor(S.scale * 100 + 0.5) .. "%. /flip size 130 makes it bigger (70 to 200).")
        if panel then panel:SetScale(S.scale) end
        if market then market:SetScale(S.scale) end
    elseif msg:find("^margin") then
        Percent(msg, "minMargin", "Least profit on what you pay")
    elseif msg:find("^share") then
        Percent(msg, "maxShare", "Most of your gold for one item")
    elseif msg == "all" or msg == "trade" then
        DB.settings.tradeOnly = msg == "trade"
        Print(msg == "trade" and "Auction flips are suggested for trade goods only."
            or "Auction flips are suggested for every kind of item. Recipes and gear can take weeks to sell.")
        if Render then Render() end
    elseif msg == "scan" then
        ShowPanel()
        StartScan(RunScan)
    elseif msg == "" then
        if panel and panel:IsShown() then panel:Hide() else ShowPanel() end
    else
        Print("/flip shows or hides the window. /flip scan, /flip market, /flip watch <item>, /flip unwatch <item>, /flip times <item>, /flip size 130, /flip margin 30, /flip share 25, /flip trade, /flip all.")
    end
end

local function OnEvent(_, event, a1)
    if event == "ADDON_LOADED" then
        if a1 ~= ADDON then return end
        OneClickFlipDB = OneClickFlipDB or {}
        DB = OneClickFlipDB
        DB.settings = DB.settings or {}
        S = setmetatable(DB.settings, { __index = DEFAULTS })
        SLASH_ONECLICKFLIP1 = "/flip"
        SLASH_ONECLICKFLIP2 = "/oneclickflip"
        SlashCmdList.ONECLICKFLIP = Slash
    elseif event == "AUCTION_HOUSE_SHOW" then
        auctionOpen = true
        ShowPanel()
        if DB.marketShown then ShowMarket() end
        if next(Realm().watch) then StartScan(RunWatch) end
    elseif event == "AUCTION_HOUSE_CLOSED" then
        auctionOpen = false
        if market then market:Hide() end
        if scan then
            scan = nil
            statusText = "Scan stopped: the auction house closed."
        end
        if panel then panel:Hide() end
    elseif event == "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED" then
        if scan then scan.dropped = true end
    elseif event == "BAG_UPDATE_DELAYED" or event == "PLAYER_MONEY" then
        if Render then Render() end
        if RenderMarket then RenderMarket() end
    elseif scan and scan.wait and scan.wait.events[event] then
        if not scan.wait.match or scan.wait.match(a1) then scan.got = event end
    end
end

for _, e in ipairs({
    "ADDON_LOADED", "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED", "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED",
    "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", "AUCTION_HOUSE_BROWSE_RESULTS_ADDED", "AUCTION_HOUSE_BROWSE_FAILURE",
    "COMMODITY_SEARCH_RESULTS_UPDATED", "COMMODITY_SEARCH_RESULTS_ADDED",
    "ITEM_SEARCH_RESULTS_UPDATED", "ITEM_SEARCH_RESULTS_ADDED",
    "BAG_UPDATE_DELAYED", "PLAYER_MONEY",
}) do
    pcall(events.RegisterEvent, events, e)
end
events:SetScript("OnEvent", OnEvent)
