#!/usr/bin/env python3
"""Hourly price collector for OneClickFlip.

Downloads one WoW Forever auction house from Blizzard's API, saves the
cheapest price and the units listed for every item, and writes two files:
HourData.lua, which the addon reads at login or /reload, and chart.html,
a page of price charts for the target items.

Run it once an hour (see tools/flip-collector.plist). macOS does not let
a background job touch an external disk, so the job runs a copy of this
script in ~/.config/oneclickflip and writes its files there; the
installed addon folder holds a link to HourData.lua:
  cp tools/flip-collector.py ~/.config/oneclickflip/
  ln -sf ~/.config/oneclickflip/HourData.lua "<AddOns>/OneClickFlip/HourData.lua"

  flip-collector.py          collect one snapshot, write HourData.lua and chart.html
  flip-collector.py chart    write chart.html again from what is saved
  flip-collector.py targets  pick the target items by the rules below (run by hand:
                             it reads TradeSkillMaster's data from the game folder)
  flip-collector.py check    say which house best matches your last in-game scan
  flip-collector.py top      list the items with the widest gap between hours

Target rules (change them under "rules" in config.json). An item is a target when:
  - Blizzard files it as a trade good and it is stackable
  - TSM's region sale rate is at least 70% and at least 500 sell a day in the region
  - your house lists at least 1,000 units at 20 or more different prices
  - the cheapest unit costs between 50 copper and 10 silver

Files, all in ~/.config/oneclickflip:
  blizzard.key   client ID on one line, client secret on the next
  config.json    optional: {"region": "us", "ruleset": 1, "house": 110, "wow": "<path>", ...}
  targets.json   the target items, written by "targets"
  prices.db      the snapshots (kept for 14 days)
  HourData.lua   what the addon reads
  chart.html     the price charts
  collector.log  one line per run
"""
import base64
import collections
import html
import json
import os
import re
import sqlite3
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

HOME = os.path.expanduser("~/.config/oneclickflip")
DEFAULTS = {
    "region": "us",
    "ruleset": 1,   # 1 PvP, 2 Normal, 3 Roleplay, 15 Roleplay PvP
    "house": 110,   # found with "check": the house whose prices match your scan
    "wow": "/Volumes/External_SSD/World of Warcraft/_forever_",
    "wake": [4.0, 4.5],  # the hours you are usually at the auction house, shaded on the charts
    "rules": {"sale_rate": 0.70, "sold_per_day": 500, "units": 1000, "prices": 20,
              "min_price": 50, "max_price": 1000},
}
KEEP_DAYS = 14
CHART_DAYS = 3
CUT = 0.05
MIN_DAYS = 2    # days an hour must be seen before it counts
MIN_HOURS = 4   # hours that must count before the best ones are named


def config():
    cfg = json.loads(json.dumps(DEFAULTS))
    path = os.path.join(HOME, "config.json")
    if os.path.exists(path):
        with open(path) as f:
            user = json.load(f)
        cfg["rules"].update(user.pop("rules", {}))
        cfg.update(user)
    return cfg


def log(msg):
    line = time.strftime("%Y-%m-%d %H:%M:%S ") + msg
    print(line)
    with open(os.path.join(HOME, "collector.log"), "a") as f:
        f.write(line + "\n")


def token():
    with open(os.path.join(HOME, "blizzard.key")) as f:
        lines = [line.strip() for line in f if line.strip()]
    if len(lines) < 2:
        raise SystemExit("blizzard.key needs the client ID on one line and the secret on the next.")
    auth = base64.b64encode((lines[0] + ":" + lines[1]).encode()).decode()
    req = urllib.request.Request("https://oauth.battle.net/token", data=b"grant_type=client_credentials",
                                 headers={"Authorization": "Basic " + auth})
    with urllib.request.urlopen(req, timeout=30) as f:
        return json.load(f)["access_token"]


def get(cfg, tok, path, namespace="dynamic"):
    query = urllib.parse.urlencode({"namespace": "%s-forever-%s" % (namespace, cfg["region"]), "locale": "en_US"})
    url = "https://%s.api.blizzard.com%s?%s" % (cfg["region"], path, query)
    req = urllib.request.Request(url, headers={"Authorization": "Bearer " + tok})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=180) as f:
                return json.load(f)
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return None
            if attempt == 2:
                raise
        except (urllib.error.URLError, TimeoutError):
            if attempt == 2:
                raise
        time.sleep(10)


def house_prices(cfg, tok, house):
    """item id -> [cheapest unit price, units listed, 1 if stackable, different prices]"""
    base = "/data/wow/ruleset/%d/auctions/%d" % (cfg["ruleset"], house)
    items, levels = {}, collections.defaultdict(set)
    for a in (get(cfg, tok, base + "/commodities") or {}).get("auctions", []):
        e = items.setdefault(a["item"]["id"], [a["unit_price"], 0, 1, 0])
        e[0] = min(e[0], a["unit_price"])
        e[1] += a.get("quantity", 1)
        levels[a["item"]["id"]].add(a["unit_price"])
    for a in (get(cfg, tok, base) or {}).get("auctions", []):
        if not a.get("buyout"):
            continue  # bid only
        qty = max(a.get("quantity", 1), 1)
        price = a["buyout"] // qty
        e = items.setdefault(a["item"]["id"], [price, 0, 0, 0])
        e[0] = min(e[0], price)
        e[1] += qty
        levels[a["item"]["id"]].add(price)
    for item, e in items.items():
        e[3] = len(levels[item])
    return items


def database():
    db = sqlite3.connect(os.path.join(HOME, "prices.db"))
    db.execute("CREATE TABLE IF NOT EXISTS snap (ts INTEGER, day INTEGER, hour INTEGER, item INTEGER,"
               " price INTEGER, qty INTEGER, stack INTEGER)")
    db.execute("CREATE INDEX IF NOT EXISTS snap_item ON snap (item, hour, day)")
    return db


def saved_variables(cfg):
    acct = os.path.join(cfg["wow"], "WTF", "Account")
    out = []
    if os.path.isdir(acct):
        for name in os.listdir(acct):
            path = os.path.join(acct, name, "SavedVariables", "OneClickFlip.lua")
            if os.path.exists(path):
                with open(path, encoding="utf-8", errors="replace") as f:
                    out.append(f.read())
    return out


def hour_rows(db, since):
    """item, hour, usual cheapest price, usual units listed, days seen, stackable"""
    return db.execute(
        "SELECT item, hour, AVG(p), AVG(q), COUNT(*), MAX(stack) FROM"
        " (SELECT item, hour, day, MIN(price) p, AVG(qty) q, MAX(stack) stack FROM snap WHERE ts >= ?"
        "  GROUP BY item, hour, day) GROUP BY item, hour", (since,))


def best_hours(hours):
    """hours: {hour: (price, qty, days)}. The cheapest and dearest hours seen
    on enough days, and the gap between them after the cut; None until then."""
    ready = [(v[0], h) for h, v in hours.items() if v[2] >= MIN_DAYS]
    if len(ready) < MIN_HOURS:
        return None
    lo, hi = min(ready), max(ready)
    if lo[1] == hi[1]:
        return None
    return {"buy": lo[1], "buy_price": lo[0], "sell": hi[1], "sell_price": hi[0],
            "gap": (hi[0] * (1 - CUT) - lo[0]) / lo[0]}


def write_lua(cfg, db, now):
    items = {}
    for item, hour, p, q, n, _ in hour_rows(db, now - KEEP_DAYS * 86400):
        items.setdefault(item, [""] * 24)[hour] = "%d:%d:%d" % (round(p), round(q), n)
    days = db.execute("SELECT COUNT(DISTINCT day) FROM snap").fetchone()[0]
    lines = ["-- Written by tools/flip-collector.py. Do not edit.",
             "OneClickFlipHourData = {",
             "updated = %d," % now, "house = %d," % cfg["house"], "days = %d," % days, "items = {"]
    for item in sorted(items):
        lines.append('[%d] = "%s",' % (item, ",".join(items[item])))
    lines += ["},", "}", ""]
    tmp = os.path.join(HOME, "HourData.lua.tmp")
    with open(tmp, "w") as f:
        f.write("\n".join(lines))
    os.replace(tmp, os.path.join(HOME, "HourData.lua"))
    return len(items), days


# ---------------------------------------------------------------------------
# The chart page
# ---------------------------------------------------------------------------

def money(c):
    c = int(round(c))
    g, s, k = c // 10000, c // 100 % 100, c % 100
    parts = []
    if g:
        parts.append("%dg" % g)
    if s:
        parts.append("%ds" % s)
    if k or not parts:
        parts.append("%dc" % k)
    return " ".join(parts)


def hour_name(h):
    return "%d %s" % (h % 12 or 12, "AM" if h < 12 else "PM")


def clock(ts):
    lt = time.localtime(ts)
    return "%s %s" % (time.strftime("%a", lt), hour_name(lt.tm_hour))


def nice_ticks(lo, hi, count=4):
    span = max(hi - lo, 1)
    step = span / count
    mag = 10 ** len(str(int(step))) / 10 if step >= 1 else 1
    for m in (1, 2, 2.5, 5, 10):
        if step <= m * mag:
            step = m * mag
            break
    first = int(lo // step) * step
    ticks, v = [], first
    while v <= hi + step:
        ticks.append(v)
        v += step
    return ticks


W, H, ML, MR, MT, MB = 900, 300, 96, 24, 34, 46


def svg_chart(points, xmin, xmax, xticks, bands, label, readout):
    """points: [(x, price, text for the readout)]. One line, its lowest and
    highest points marked and labelled, and a wide hover target per point."""
    prices = [p[1] for p in points]
    pad = max((max(prices) - min(prices)) * 0.12, 1)  # room for the Low and High labels
    ticks = nice_ticks(max(min(prices) - pad, 0), max(prices) + pad)
    ymin, ymax = ticks[0], ticks[-1]
    sx = lambda x: ML + (x - xmin) / max(xmax - xmin, 1e-9) * (W - ML - MR)
    sy = lambda y: MT + (1 - (y - ymin) / max(ymax - ymin, 1e-9)) * (H - MT - MB)
    out = ['<svg viewBox="0 0 %d %d" role="img" aria-label="%s">' % (W, H, html.escape(label))]
    for x0, x1 in bands:
        if x1 > xmin and x0 < xmax:
            a, b = sx(max(x0, xmin)), sx(min(x1, xmax))
            out.append('<rect class="wake" x="%.1f" y="%d" width="%.1f" height="%d"/>' % (a, MT, max(b - a, 3), H - MT - MB))
    for t in ticks:
        out.append('<line class="grid" x1="%d" x2="%d" y1="%.1f" y2="%.1f"/>' % (ML, W - MR, sy(t), sy(t)))
        out.append('<text class="tick" x="%d" y="%.1f" text-anchor="end">%s</text>' % (ML - 10, sy(t) + 6, money(t)))
    for x, text in xticks:
        out.append('<text class="tick" x="%.1f" y="%d" text-anchor="middle">%s</text>' % (sx(x), H - MB + 26, html.escape(text)))
    out.append('<polyline class="line" points="%s"/>'
               % " ".join("%.1f,%.1f" % (sx(p[0]), sy(p[1])) for p in points))
    if len(points) == 1:
        out.append('<circle class="dot" cx="%.1f" cy="%.1f" r="5"/>' % (sx(points[0][0]), sy(points[0][1])))
    lo, hi = min(points, key=lambda p: p[1]), max(points, key=lambda p: p[1])
    if lo[1] != hi[1]:
        for p, word, dy in ((lo, "Low", 26), (hi, "High", -14)):
            x, y = sx(p[0]), sy(p[1])
            anchor = "start" if x < ML + 150 else "end" if x > W - MR - 150 else "middle"
            out.append('<circle class="dot" cx="%.1f" cy="%.1f" r="6"/>' % (x, y))
            out.append('<text class="mark" x="%.1f" y="%.1f" text-anchor="%s">%s %s</text>'
                       % (x, min(max(y + dy, 18), H - MB - 6), anchor, word, money(p[1])))
    gap = (W - ML - MR) / max(len(points), 1)
    for p in points:
        out.append('<rect class="hit" x="%.1f" y="%d" width="%.1f" height="%d" data-r="%s" data-x="%.1f" data-y="%.1f" data-t="%s"/>'
                   % (sx(p[0]) - gap / 2, MT, gap, H - MT - MB, readout, sx(p[0]), sy(p[1]), html.escape(p[2], quote=True)))
    out.append('<circle class="cursor" r="7" cx="-20" cy="-20"/></svg>')
    return "".join(out)


CSS = """
:root{color-scheme:light;--surface:#fcfcfb;--card:#ffffff;--text:#0b0b0b;--muted:#52514e;--grid:#dddcd6;--line:#2a78d6;--wake:#eda100;--edge:#c9c8c0}
@media (prefers-color-scheme:dark){:root{color-scheme:dark;--surface:#121211;--card:#1a1a19;--text:#f0efec;--muted:#c3c2b7;--grid:#3a3a37;--line:#3987e5;--wake:#c98500;--edge:#4a4a46}}
*{box-sizing:border-box}
body{margin:0;padding:24px 16px 60px;background:var(--surface);color:var(--text);font:20px/1.5 -apple-system,"Helvetica Neue",Arial,sans-serif}
main{max-width:1000px;margin:0 auto}
h1{font-size:34px;margin:0 0 8px}h2{font-size:28px;margin:44px 0 10px}h3{font-size:24px;margin:0 0 6px}
p{margin:8px 0}.muted{color:var(--muted)}
.card{background:var(--card);border:1px solid var(--edge);border-radius:10px;padding:18px;margin:18px 0}
.answer{font-size:22px;font-weight:600}
table{border-collapse:collapse;width:100%;font-size:19px}
th,td{text-align:left;padding:10px 12px;border-bottom:1px solid var(--grid);vertical-align:top}
th{color:var(--muted);font-weight:600}td.n,th.n{text-align:right;font-variant-numeric:tabular-nums}
.scroll{overflow-x:auto}
svg{width:100%;height:auto;display:block;margin-top:8px}
.grid{stroke:var(--grid);stroke-width:1}.tick{fill:var(--muted);font-size:17px}
.line{fill:none;stroke:var(--line);stroke-width:3;stroke-linejoin:round;stroke-linecap:round}
.dot{fill:var(--line);stroke:var(--card);stroke-width:2}.mark{fill:var(--text);font-size:19px;font-weight:600}
.wake{fill:var(--wake);opacity:.28}.hit{fill:transparent}.cursor{fill:none;stroke:var(--text);stroke-width:2;pointer-events:none}
.readout{min-height:32px;font-size:21px;font-weight:600}
.key{display:inline-block;width:22px;height:14px;background:var(--wake);opacity:.5;vertical-align:middle;margin-right:6px}
a{color:var(--line)}
"""

JS = """
document.querySelectorAll('rect.hit').forEach(function(r){
  function show(){var o=document.getElementById(r.dataset.r);if(o)o.textContent=r.dataset.t;
    var c=r.parentNode.querySelector('.cursor');c.setAttribute('cx',r.dataset.x);c.setAttribute('cy',r.dataset.y);}
  r.addEventListener('mouseenter',show);r.addEventListener('touchstart',show,{passive:true});r.addEventListener('click',show);
});
"""


def write_chart(cfg, db, now):
    path = os.path.join(HOME, "targets.json")
    if not os.path.exists(path):
        return 0
    with open(path) as f:
        targets = json.load(f)["items"]
    since = now - CHART_DAYS * 86400
    wake = cfg["wake"]
    first = db.execute("SELECT MIN(ts), COUNT(DISTINCT ts), COUNT(DISTINCT day) FROM snap").fetchone()
    hours_by = collections.defaultdict(dict)
    for item, hour, p, q, n, _ in hour_rows(db, now - KEEP_DAYS * 86400):
        hours_by[item][hour] = (p, q, n)

    # Shade the wake window of each day on the timeline.
    bands, day0 = [], time.localtime(since)
    midnight = time.mktime((day0.tm_year, day0.tm_mon, day0.tm_mday, 0, 0, 0, 0, 0, -1))
    for d in range(CHART_DAYS + 2):
        lt = time.localtime(midnight + d * 86400 + 43200)
        base = time.mktime((lt.tm_year, lt.tm_mon, lt.tm_mday, 0, 0, 0, 0, 0, -1))
        bands.append((base + wake[0] * 3600, base + wake[1] * 3600))

    cards, rows = [], []
    for n, t in enumerate(targets):
        item = t["id"]
        snaps = db.execute("SELECT ts, price, qty FROM snap WHERE item = ? AND ts >= ? ORDER BY ts", (item, since)).fetchall()
        if not snaps:
            continue
        best = best_hours(hours_by[item])
        now_price, now_qty = snaps[-1][1], snaps[-1][2]
        lo, hi = min(snaps, key=lambda s: s[1]), max(snaps, key=lambda s: s[1])
        if best:
            answer = ("Buy around %s (usually %s). Post around %s (usually %s). That gap is %.0f%% after the 5%% cut."
                      % (hour_name(best["buy"]), money(best["buy_price"]), hour_name(best["sell"]),
                         money(best["sell_price"]), best["gap"] * 100))
        else:
            answer = ("Still collecting. So far the lowest was %s at %s and the highest %s at %s."
                      % (money(lo[1]), clock(lo[0]), money(hi[1]), clock(hi[0])))
        xmin, xmax = max(since, snaps[0][0] - 1800), max(now, snaps[0][0] + 6 * 3600)
        xticks, tick = [], (int(xmin) // 21600 + 1) * 21600
        lt = time.localtime(tick)
        tick -= (lt.tm_hour % 6) * 3600 + lt.tm_min * 60 + lt.tm_sec
        while tick <= xmax:
            if tick >= xmin:
                xticks.append((tick, clock(tick)))
            tick += 6 * 3600
        if len(xticks) > 7:
            xticks = xticks[::2]
        pts = [(s[0], s[1], "%s: %s each, %s listed" % (clock(s[0]), money(s[1]), format(s[2], ","))) for s in snaps]
        body = ['<div class="card" id="i%d"><h3>%s</h3><p class="answer">%s</p>' % (item, html.escape(t["name"]), answer),
                '<p class="muted">Now %s each, %s listed. A vendor pays %s.</p>'
                % (money(now_price), format(now_qty, ","), money(t.get("vendor") or 0)),
                '<p class="muted">Cheapest price, every hour, last %d days</p>' % CHART_DAYS,
                '<p class="readout" id="r%da">Point at the chart to read a value.</p>' % item,
                svg_chart(pts, xmin, xmax, xticks, bands, t["name"] + ": cheapest price every hour", "r%da" % item)]
        hrs = hours_by[item]
        ready = sorted(h for h, v in hrs.items() if v[2] >= MIN_DAYS)
        if len(ready) >= MIN_HOURS:
            hp = [(h, hrs[h][0], "%s: usually %s each, %s listed, from %d days"
                   % (hour_name(h), money(hrs[h][0]), format(int(round(hrs[h][1])), ","), hrs[h][2])) for h in ready]
            body += ['<p class="muted">Usual price at each hour of the day</p>',
                     '<p class="readout" id="r%db">Point at the chart to read a value.</p>' % item,
                     svg_chart(hp, -0.5, 23.5, [(h, hour_name(h)) for h in range(0, 24, 3)], [tuple(wake)],
                               t["name"] + ": usual price by hour of day", "r%db" % item)]
        body.append("</div>")
        key = best["gap"] if best else -1 + (hi[1] * (1 - CUT) - lo[1]) / max(lo[1], 1) / 1000
        cards.append((key, n, "".join(body)))
        rows.append((key, n, item, t["name"], now_price, now_qty, best, lo, hi))

    cards.sort(key=lambda c: (-c[0], c[1]))
    rows.sort(key=lambda r: (-r[0], r[1]))
    any_best = any(r[6] for r in rows)
    head = ("<tr><th>Item</th><th class='n'>Now</th><th>Buy around</th><th>Post around</th><th class='n'>Gap after cut</th></tr>"
            if any_best else
            "<tr><th>Item</th><th class='n'>Now</th><th>Lowest so far</th><th>Highest so far</th><th class='n'>Listed</th></tr>")
    trs = []
    for _, _, item, name, price, qty, best, lo, hi in rows:
        link = '<a href="#i%d">%s</a>' % (item, html.escape(name))
        if any_best:
            if best:
                trs.append("<tr><td>%s</td><td class='n'>%s</td><td>%s, %s</td><td>%s, %s</td><td class='n'>%.0f%%</td></tr>"
                           % (link, money(price), hour_name(best["buy"]), money(best["buy_price"]),
                              hour_name(best["sell"]), money(best["sell_price"]), best["gap"] * 100))
            else:
                trs.append("<tr><td>%s</td><td class='n'>%s</td><td colspan='3'>Still collecting</td></tr>" % (link, money(price)))
        else:
            trs.append("<tr><td>%s</td><td class='n'>%s</td><td>%s, %s</td><td>%s, %s</td><td class='n'>%s</td></tr>"
                       % (link, money(price), money(lo[1]), clock(lo[0]), money(hi[1]), clock(hi[0]), format(qty, ",")))
    hours_seen = first[1] or 0
    if any_best:
        status = "Hours are named once they have been saved on %d different days." % MIN_DAYS
    else:
        status = ("Not enough yet to name the best hours: an hour has to be saved on %d different days. "
                  "Until then the table shows the lowest and highest prices seen so far." % MIN_DAYS)
    r = cfg["rules"]
    page = ["<!doctype html><html lang='en'><head><meta charset='utf-8'>",
            "<meta name='viewport' content='width=device-width,initial-scale=1'><meta http-equiv='refresh' content='900'>",
            "<title>Flip price charts</title><style>", CSS, "</style></head><body><main>",
            "<h1>Trade goods: when to buy, when to post</h1>",
            "<p>Updated %s. %d hourly snapshots over %d days from house %d. All times are your Mac's clock.</p>"
            % (time.strftime("%A %-I:%M %p", time.localtime(now)), hours_seen, first[2] or 0, cfg["house"]),
            "<p>%s</p>" % status,
            "<p class='muted'><span class='key'></span>Shaded: %s to %s, when you are usually at the auction house. "
            "Blizzard publishes prices about once an hour, so times are to the hour.</p>"
            % (time.strftime("%-I:%M %p", time.gmtime(wake[0] * 3600)), time.strftime("%-I:%M %p", time.gmtime(wake[1] * 3600))),
            "<h2>All targets</h2><div class='card scroll'><table>", head, "".join(trs), "</table></div>",
            "<h2>Charts</h2>", "".join(c[2] for c in cards),
            "<h2>How the targets are picked</h2><div class='card'><p>An item is a target when all of these are true:</p><ul>",
            "<li>Blizzard files it as a trade good and it is stackable.</li>",
            "<li>TSM's region sale rate is at least %.0f%%, and at least %s sell a day in the region.</li>"
            % (r["sale_rate"] * 100, format(r["sold_per_day"], ",")),
            "<li>Your house lists at least %s units at %d or more different prices.</li>" % (format(r["units"], ","), r["prices"]),
            "<li>The cheapest unit costs between %s and %s.</li>" % (money(r["min_price"]), money(r["max_price"])),
            "</ul></div></main><script>", JS, "</script></body></html>"]
    tmp = os.path.join(HOME, "chart.html.tmp")
    with open(tmp, "w") as f:
        f.write("".join(page))
    os.replace(tmp, os.path.join(HOME, "chart.html"))
    return len(cards)


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

def collect():
    cfg = config()
    now = int(time.time())
    lt = time.localtime(now)
    day = int(time.mktime((lt.tm_year, lt.tm_mon, lt.tm_mday, 12, 0, 0, 0, 0, -1)) // 86400)
    items = house_prices(cfg, token(), cfg["house"])
    if not items:
        log("house %d returned no auctions; nothing saved" % cfg["house"])
        return 1
    db = database()
    db.executemany("INSERT INTO snap VALUES (?, ?, ?, ?, ?, ?, ?)",
                   [(now, day, lt.tm_hour, i, e[0], e[1], e[2]) for i, e in items.items()])
    db.execute("DELETE FROM snap WHERE ts < ?", (now - KEEP_DAYS * 86400,))
    db.commit()
    written, days = write_lua(cfg, db, now)
    charts = write_chart(cfg, db, now)
    log("house %d: saved %d items; HourData.lua has %d items over %d days; %d charts"
        % (cfg["house"], len(items), written, days, charts))
    return 0


def chart():
    print("%d charts written to %s" % (write_chart(config(), database(), int(time.time())), os.path.join(HOME, "chart.html")))
    return 0


def tsm_table(text, tag):
    """A table from TradeSkillMaster_AppHelper/AppData.lua: item id -> numbers (stored in base 32)."""
    m = re.search(r'LoadData\("%s","[^"]+",\[\[return \{downloadTime=\d+,fields=\{[^}]*\},data=\{(.*?)\}\}\]\]\)' % tag, text, re.S)
    out = {}
    for row in re.findall(r"\{([^{}]*)\}", m.group(1)) if m else []:
        parts = row.split(",")
        try:
            out[int(parts[0])] = [int(x, 32) for x in parts[1:]]
        except ValueError:
            pass
    return out


def targets():
    cfg = config()
    r = cfg["rules"]
    path = os.path.join(cfg["wow"], "Interface", "AddOns", "TradeSkillMaster_AppHelper", "AppData.lua")
    with open(path, encoding="utf-8", errors="replace") as f:
        sale = tsm_table(f.read(), "AUCTIONDB_REGION_SALE")  # sale price, sold per day x1000, sale rate x1000
    if not sale:
        raise SystemExit("No TSM sale data in " + path)
    tok = token()
    found = []
    for item, e in house_prices(cfg, tok, cfg["house"]).items():
        s = sale.get(item)
        if not (e[2] and s and len(s) >= 3):
            continue
        spd, rate = s[1] / 1000, s[2] / 1000
        if (rate >= r["sale_rate"] and spd >= r["sold_per_day"] and e[1] >= r["units"] and e[3] >= r["prices"]
                and r["min_price"] <= e[0] <= r["max_price"]):
            found.append((spd * e[0], item, e, spd, rate))
    found.sort(reverse=True)
    items = []
    for _, item, e, spd, rate in found:
        info = get(cfg, tok, "/data/wow/item/%d" % item, "static")
        if not info or info.get("item_class", {}).get("id") != 7:
            continue
        items.append({"id": item, "name": info.get("name") or ("item %d" % item), "kind": info.get("item_subclass", {}).get("name"),
                      "vendor": info.get("sell_price") or 0, "sold_per_day": round(spd), "sale_rate": round(rate, 2)})
        print("%-24s %-14s %8s each, %6d listed at %3d prices, %5d sold a day, %2.0f%% sell"
              % (items[-1]["name"], items[-1]["kind"], money(e[0]), e[1], e[3], spd, rate * 100))
    with open(os.path.join(HOME, "targets.json"), "w") as f:
        json.dump({"picked": int(time.time()), "rules": r, "items": items}, f, indent=1)
    print("%d targets saved." % len(items))
    return 0


def check():
    cfg = config()
    last = {}
    for text in saved_variables(cfg):
        start = text.find('["history"]')
        for m in re.finditer(r"\[(\d+)\] = \{\n([\d,\n]+)\}", text[start:] if start >= 0 else ""):
            nums = [int(x) for x in m.group(2).replace("\n", "").split(",") if x]
            if len(nums) >= 2:
                last[int(m.group(1))] = nums[-1]
    if not last:
        raise SystemExit("No OneClickFlip scan found. Click Scan at the auction house, log out, then run this again.")
    tok = token()
    index = get(cfg, tok, "/data/wow/ruleset/%d/auctions/" % cfg["ruleset"])
    print("Items in your last in-game scan: %d. Scan in game and log out right before this for a clear answer." % len(last))
    for h in index.get("auctions", []):
        prices = house_prices(cfg, tok, h["id"])
        both = [i for i in last if i in prices]
        exact = sum(1 for i in both if prices[i][0] == last[i])
        mark = "  <- in use" if h["id"] == cfg["house"] else ""
        print("house %d (%s): %d items, %d with the same cheapest price as your scan%s"
              % (h["id"], h["name"], len(prices), exact, mark))
    return 0


def top():
    db = database()
    by = collections.defaultdict(dict)
    for item, hour, p, q, n, _ in hour_rows(db, int(time.time()) - KEEP_DAYS * 86400):
        by[item][hour] = (p, q, n)
    rows = sorted(((b["gap"], item, b) for item, b in ((i, best_hours(h)) for i, h in by.items()) if b), reverse=True)
    if not rows:
        print("Not enough data yet: an hour counts once it has been saved on two days.")
    for gap, item, b in rows[:25]:
        print("item %d: cheapest around %s (%s), dearest around %s (%s), %.0f%% after the cut"
              % (item, hour_name(b["buy"]), money(b["buy_price"]), hour_name(b["sell"]), money(b["sell_price"]), gap * 100))
    return 0


if __name__ == "__main__":
    os.makedirs(HOME, exist_ok=True)
    command = sys.argv[1] if len(sys.argv) > 1 else "collect"
    run = {"collect": collect, "chart": chart, "targets": targets, "check": check, "top": top}.get(command)
    if not run:
        raise SystemExit(__doc__)
    try:
        sys.exit(run())
    except Exception as e:  # one line in the log, then fail
        log("failed: %s: %s" % (type(e).__name__, e))
        sys.exit(1)
