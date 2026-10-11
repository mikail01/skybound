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

## Using the imported hub island (FloatingIslandMap.glb)

The hub can use the hand-made floating island instead of the one built from code. Do this once in Studio:

1. **Home → Import 3D**, pick `assets/FloatingIslandMap.glb` (in this repo), keep the default settings and click **Import**. It lands in the Workspace.
2. Open **View → Command Bar**, paste the whole of [`tools/setup_island.luau`](tools/setup_island.luau) and press Enter. It names the model `FloatingIslandMap`, anchors it, turns off collision on decoration (outlines, plants, water, paths, butterflies), gives the ground, trees and props precise collision, and moves it to **ServerStorage**.
3. **Save the place** (the island lives in the place file, not in this repo).
4. Press **Play**. The Output shows `self-check passed` with `hub island: imported FloatingIslandMap`.

On Play the hub clones the island in, scales it to `Config.HUB_MAP_SCALE` studs per map unit, centres its meadow on `Config.HUB_CENTER` and puts everything on it:

- **Spawn** on the island's spawn pad; **portal** = the island's own arch (step onto its base to start a run), with vortex sparkles and light.
- **Daily Reward** and **Upgrades** on the upper terrace next to the spawn; **Gear**, **Skybrew**, **Quest Board** and **Leaderboard** in the meadow below.
- Wooden **stairs** between the levels (spawn ↔ meadow, west path ↔ meadow, spawn pad ↔ portal plateau), and an invisible wall around the rim.
- The map's VFX markers become effects: crystal glow, waterfall mist, golden sparkles, fireflies and a lantern light, plus a glow under the island.

Without `FloatingIslandMap` in ServerStorage the hub falls back to the island built from code, so nothing breaks. If the Output warns that island meshes don't use precise collision, run step 2 again.

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
- `src/server/Systems`: `PlayerData`, `Runs`, `Economy`, `Rewards`, `Tutorial`, `Leaderboard`, `Analytics`, `Hub`, `HubMap` (places the imported island)
- `src/client/Controllers`: `Run`, `Hud`, `Panels`, `Tutorial`, `HubFx`

Tune the game in `src/shared/Config.luau`.

## Checks

- Format: `stylua src`
- Lint: `selene src`
