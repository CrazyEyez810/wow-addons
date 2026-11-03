# OneClickSplits

A see-through speedrun panel for leveling 1 to 60 in WoW Forever. It shows:

- the goal time for your current level, with a large timer right next to it that counts your time on the level: white while you're under the goal, red once you pass it
- whether you're ahead of or behind the plan overall, updated live from your XP bar
- the next level's target
- a goal for each bracket (1-10, 10-20, up to 50-60) with your time beside it: green or red for brackets you've finished, live for the one you're in

On every level-up it says how that level went against its target, in chat and on screen.

Two speedrun plans, each scaled to a verified solo 1-60 run on Classic Era (speedrun.com, SSF Softcore). WoW Forever uses the same XP table.

- shaman (default): 92 hours 15 minutes, the pace of the only verified Shaman 1-60 speedrun (DeepsTheBoomer, Troll Shaman). Dings 10 at 2.3 h, 20 at 10.4 h, 30 at 22.7 h, 40 at 39.3 h, 50 at 62.9 h.
- melee: 78 hours 36 minutes, the fastest verified Horde melee solo run (Thiddi, Troll Rogue). Dings 20 at 8.8 h, 30 at 19.3 h, 40 at 33.4 h, 50 at 53.6 h.

The runs publish only their totals, so the time for each level comes from the Classic XP table over an XP-per-hour curve, with Shaman adjustments (levels 10-19 slower, 25-39 faster).

Time played is read once at login without printing it in chat, then counted forward. Bracket times need the addon to have seen the bracket's first level; a bracket you started before installing shows only its goal.

## Commands

- `/splits` shows or hides the panel
- `/splits plan shaman` or `/splits plan melee`
- `/splits scale 1.2` resizes it
- `/splits next` hides or shows the next level's target
- `/splits brackets` hides or shows the bracket list
- `/splits alert` turns the on-screen level-up message off or on
- `/splits history` lists your recorded level times against the plan

## Releases

Pushing a tag like `OneClickSplits-v0.1.0` builds the zip, attaches it to a GitHub release and uploads it to the CurseForge project in `## X-Curse-Project-ID:` of `OneClickSplits.toc`.
