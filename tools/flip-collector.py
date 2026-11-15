#!/usr/bin/env python3
"""Hourly price collector for OneClickFlip.

Downloads one WoW Forever auction house from Blizzard's API, saves the
cheapest price and the units listed for every item, and writes
HourData.lua. The addon reads that file at login or /reload and draws
prices by hour of day from it.

Run it once an hour (see tools/flip-collector.plist). macOS does not let
a background job touch an external disk, so the job runs a copy of this
script in ~/.config/oneclickflip and writes HourData.lua there; the
installed addon folder holds a link to that file:
  cp tools/flip-collector.py ~/.config/oneclickflip/
  ln -sf ~/.config/oneclickflip/HourData.lua "<AddOns>/OneClickFlip/HourData.lua"

  flip-collector.py          collect one snapshot and write HourData.lua
  flip-collector.py check    say which house best matches your last in-game scan
  flip-collector.py top      list the items with the widest gap between hours

Files, all in ~/.config/oneclickflip:
  blizzard.key   client ID on one line, client secret on the next
  config.json    optional: {"region": "us", "ruleset": 1, "house": 110, "wow": "<path>"}
  prices.db      the snapshots (kept for 14 days)
  HourData.lua   what the addon reads
  collector.log  one line per run
"""
import base64
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
}
KEEP_DAYS = 14
CUT = 0.05


def config():
    cfg = dict(DEFAULTS)
    path = os.path.join(HOME, "config.json")
    if os.path.exists(path):
        with open(path) as f:
            cfg.update(json.load(f))
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


def get(cfg, tok, path):
    query = urllib.parse.urlencode({"namespace": "dynamic-forever-" + cfg["region"], "locale": "en_US"})
    url = "https://%s.api.blizzard.com%s?%s" % (cfg["region"], path, query)
    req = urllib.request.Request(url, headers={"Authorization": "Bearer " + tok})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=180) as f:
                return json.load(f)
        except (urllib.error.URLError, TimeoutError) as e:
            if attempt == 2:
                raise
            time.sleep(10)


def house_prices(cfg, tok, house):
    """item id -> [cheapest unit price, units listed, 1 if stackable]"""
    base = "/data/wow/ruleset/%d/auctions/%d" % (cfg["ruleset"], house)
    items = {}
    for a in get(cfg, tok, base + "/commodities").get("auctions", []):
        e = items.setdefault(a["item"]["id"], [a["unit_price"], 0, 1])
        e[0] = min(e[0], a["unit_price"])
        e[1] += a.get("quantity", 1)
    for a in get(cfg, tok, base).get("auctions", []):
        if not a.get("buyout"):
            continue  # bid only
        qty = max(a.get("quantity", 1), 1)
        price = a["buyout"] // qty
        e = items.setdefault(a["item"]["id"], [price, 0, 0])
        e[0] = min(e[0], price)
        e[1] += qty
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
    log("house %d: saved %d items; HourData.lua has %d items over %d days" % (cfg["house"], len(items), written, days))
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
    now = int(time.time())
    by = {}
    for item, hour, p, q, n, _ in hour_rows(db, now - KEEP_DAYS * 86400):
        if n >= 2:
            by.setdefault(item, []).append((p, hour, q))
    rows = []
    for item, hours in by.items():
        if len(hours) < 4:
            continue
        lo, hi = min(hours), max(hours)
        gap = (hi[0] * (1 - CUT) - lo[0]) / lo[0]
        rows.append((gap, item, lo, hi))
    rows.sort(reverse=True)
    if not rows:
        print("Not enough data yet: an hour counts once it has been saved on two days.")
    for gap, item, lo, hi in rows[:25]:
        print("item %d: cheapest at %02d:00 (%d copper, %d listed), dearest at %02d:00 (%d copper), %.0f%% after the cut"
              % (item, lo[1], lo[0], lo[2], hi[1], hi[0], gap * 100))
    return 0


if __name__ == "__main__":
    os.makedirs(HOME, exist_ok=True)
    command = sys.argv[1] if len(sys.argv) > 1 else "collect"
    run = {"collect": collect, "check": check, "top": top}.get(command)
    if not run:
        raise SystemExit(__doc__)
    try:
        sys.exit(run())
    except Exception as e:  # one line in the log, then fail
        log("failed: %s: %s" % (type(e).__name__, e))
        sys.exit(1)
