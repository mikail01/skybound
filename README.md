# Skybound

A Roblox climbing game built with [Rojo](https://rojo.space): bounce up a procedurally generated sky tower, collect coins and capsules, dodge hazards and black holes, then spend your rewards in a floating hub village.

## Getting it into Roblox Studio

One-time setup:

1. Install [Git](https://git-scm.com) and [Rokit](https://github.com/rojo-rbx/rokit).
2. Clone and install the toolchain:
   ```
   git clone https://github.com/mikail01/skybound
   cd skybound
   rokit install
   ```
3. Install the matching Studio plugin: `rojo plugin install` (restart Studio afterwards).
4. In Studio, open a new **Baseplate** place.
5. Run `rojo serve` in the `skybound` folder, then click **Rojo → Connect** in Studio.
6. Press **Play**. The Output window should show `[skybound] server started`.

To test saving in Studio, enable **Game Settings → Security → Enable Studio Access to API Services**. Without it the game still runs, but warns that progress won't save.

After that, whenever new code is pushed: `git pull` in the folder and Rojo syncs it live.

## What's in it (milestone 1)

- **Hub island** built entirely from code: portal, Daily Reward stand, Upgrade machine, Gear stall, Skybrew potion stall, global leaderboard, trees, flowers, clouds.
- **Onboarding**: welcome banner, world-space arrows (Daily → Upgrade → Gear → Portal), free first upgrade, free starter jetpack, and a guided beginner section on the first run.
- **Core loop**: auto-jump climbing, one-way platforms (normal, bounce, moving, breaking, ice, fake), jetpack boost, coins, gems, potions, loot capsules, spike balls, black holes, world transitions (Cloud Valley → Sky Jungle → … → The Void), "YOUR BEST" marker, instant retry.
- **Progression**: 5 upgrade stats, 5 potions with timers, gear, 7-day daily rewards (missing a day never resets your streak), playtime rewards, height milestones, NEXT GOAL card.
- **Server authority**: DataStore saving with session locking and retries, rate-limited remotes, server-validated height (no flying or teleport scores) and pickups.
- **Analytics**: Roblox onboarding funnel + custom events for tuning.
- **Controls**: keyboard (A/D or arrows, Space to boost), gamepad (stick/D-pad, A or RT to boost), and dedicated touch zones on mobile.

## Structure

- `src/shared`: `Config` (every balance number), `Generator` (deterministic tower generation), `Formulas`, `Types`, `Remotes`
- `src/server/Systems`: `PlayerData`, `Runs`, `Economy`, `Rewards`, `Tutorial`, `Leaderboard`, `Analytics`, `Hub`
- `src/client/Controllers`: `Run`, `Hud`, `Panels`, `Tutorial`, `HubFx`

Tune the game in `src/shared/Config.luau`.

## Checks

- Format: `stylua src`
- Lint: `selene src`
