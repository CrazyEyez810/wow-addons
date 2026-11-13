# wow-addons

Addons for WoW Forever by CrazyEyez810. Each folder is one addon with its own CurseForge project.

- `OneClickBars/` saves your whole setup (bars, keybindings, macros, Edit Mode layout, game and addon settings) and loads it on every new character, with leveling automation for RestedXP and Questie.
- `OneClickXP/` is an on-screen XP panel with kills to level and time to level.
- `OneClickPace/` tells you when a quest spot is contested and you should leave and come back later.
- `OneClickMail/` mails items to your own alts by rules from a One Click tab in the mailbox.
- `OneClickSplits/` is a see-through speedrun panel with a target time for each level 1-60, scaled to verified solo speedruns.
- `OneClickFlip/` is an auction house coach for personal use: click Scan at the auction house and it lists what to buy, the most to pay, what to relist it for, and what in your bags to post or vendor. It reads TradeSkillMaster's prices when TSM is loaded. It has no release tag in the workflow, so it is never uploaded to CurseForge.
- `tools/test-pace.lua` runs OneClickPace against a fake game: `luajit tools/test-pace.lua OneClickPace/OneClickPace.lua`.
- `tools/test-mail.lua` checks which bag items each OneClickMail rule picks: `luajit tools/test-mail.lua OneClickMail/OneClickMail.lua`.
- `tools/test-splits.lua` runs OneClickSplits against a fake game: `luajit tools/test-splits.lua OneClickSplits/OneClickSplits.lua`.
- `tools/test-flip.lua` runs OneClickFlip against a fake auction house, TradeSkillMaster and bags: `luajit tools/test-flip.lua OneClickFlip/OneClickFlip.lua`.
- `tools/launch-day-copy.sh` copies your addons and their settings from one WoW folder to another, such as from the beta to the live client. Put it in the World of Warcraft folder and run it with WoW closed.

## Releasing

Tag the commit with the addon's name and version, then push the tag:

    git tag OneClickXP-v1.0.0
    git push origin OneClickXP-v1.0.0

The release workflow packages that addon's folder, creates a GitHub release and uploads to CurseForge. The `CF_API_TOKEN` repository secret holds the CurseForge token.
