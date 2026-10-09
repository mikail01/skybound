#!/usr/bin/env bash
# Headless checks for Skybound (Linux). Downloads luau + Roblox type defs on
# first run. These are a mock engine, NOT Roblox Studio: they catch invalid
# properties/types, script errors and logic bugs, not real-engine physics.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
work="${SKY_TEST_DIR:-$here/.work}"
mkdir -p "$work"
if [ ! -x "$work/luau" ]; then
  curl -sSLf -o "$work/luau.zip" https://github.com/luau-lang/luau/releases/latest/download/luau-ubuntu.zip
  (cd "$work" && unzip -oq luau.zip && chmod +x luau)
fi
if [ ! -f "$work/globalTypes.d.luau" ]; then
  curl -sSLf -o "$work/globalTypes.d.luau" https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/main/scripts/globalTypes.d.luau
fi
python3 "$here/mock/gen_api.py" "$work/globalTypes.d.luau" "$here/mock/apidb.luau" >/dev/null
echo "== Generator fairness"
python3 "$here/generator/build.py" "$here/generator/test.luau" "$work/gen.luau"
"$work/luau" "$work/gen.luau" | tail -1
for mode in steady jitter fps240; do
  echo "== Playtest ($mode)"
  (echo "MODE = \"$mode\""; cat "$here/mock/harness.luau") > "$work/h_$mode.luau"
  (cd "$here/mock" && python3 bundle.py "$work/h_$mode.luau" "$work/o_$mode.luau" >/dev/null)
  "$work/luau" "$work/o_$mode.luau" | grep -E "FAIL|ERROR|ALL CHECKS PASSED|CHECK\(S\) FAILED"
done
if command -v "${PWSH:-pwsh}" >/dev/null 2>&1; then
  echo "== Auto-sync script"
  "$here/sync/run_sync_tests.sh" | tail -1
else
  echo "== Auto-sync script: skipped (PowerShell 7 not installed; set PWSH=/path/to/pwsh)"
fi
