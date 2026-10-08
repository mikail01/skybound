# skybound

Roblox game built with [Rojo](https://rojo.space).

## Development

1. Install [Rokit](https://github.com/rojo-rbx/rokit), then the toolchain: `rokit install`
2. Start syncing: `rojo serve`
3. In Roblox Studio, install the Rojo plugin and click **Connect**.

## Structure

- `src/shared` → ReplicatedStorage/Shared — types, config, pure utilities
- `src/server` → ServerScriptService/Server — authoritative game systems
- `src/client` → StarterPlayerScripts/Client — rendering, input, UI

## Checks

- Format: `stylua src`
- Lint: `selene src`
