# OneClickSplits

A see-through speedrun panel for leveling 1 to 60 in WoW Forever. It shows:

- the target time for your current level
- how long you've spent on this level, and the time left or how far over
- whether you're ahead of or behind the plan overall, updated live from your XP bar
- the next level's target

On every level-up it says how that level went against its target, in chat and on screen.

Two plans for a solo Enhancement Shaman, from the research report "Shaman 1 to 60 speedrun splits":

- target: 120 hours /played to 60 (ding 10 at 2.6 h, 20 at 13.9 h, 30 at 29.5 h, 40 at 50.5 h, 50 at 82.0 h)
- stretch: 100 hours (ding 20 at 11.7 h, 30 at 24.7 h, 40 at 42.2 h, 50 at 68.4 h)

Time played is read once at login without printing it in chat, then counted forward.

## Commands

- `/splits` shows or hides the panel
- `/splits plan target` or `/splits plan stretch`
- `/splits scale 1.2` resizes it
- `/splits next` hides or shows the next level's target
- `/splits alert` turns the on-screen level-up message off or on
- `/splits history` lists your recorded level times against the plan

## Releases

Pushing a tag like `OneClickSplits-v0.1.0` builds the zip, attaches it to a GitHub release and uploads it to the CurseForge project in `## X-Curse-Project-ID:` of `OneClickSplits.toc`.
