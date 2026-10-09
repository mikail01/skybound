#!/usr/bin/env bash
# Exercises tools/autosync.ps1 against a local fake GitHub and a throwaway
# project folder. Needs: python3, pwsh (PowerShell 7). Linux-only stand-in for
# the Windows run: same script, real file operations, fake network.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
script="$repo/tools/autosync.ps1"
PWSH="${PWSH:-pwsh}"
work="$(mktemp -d)"
srv="$work/srv"
proj="$work/project"
port=$((20000 + RANDOM % 20000))
pass=0
fail=0
trap 'kill $server 2>/dev/null; rm -rf "$work"' EXIT

python3 "$here/build_fixtures.py" "$repo" "$srv" >/dev/null
sha() { python3 -c "import json;print(json.load(open('$srv/shas.json'))['$1'])"; }
python3 "$here/fake_github.py" "$srv" "$port" &
server=$!
sleep 1

BR="claude__roblox-studio-connection-isznfe"
set_branch() { cp "$srv/commits/$(sha "$1").json" "$srv/commits/$BR.json"; }

export SKYBOUND_TEST_MARKER="$work/EXECUTED.txt"
export POWERSHELL_TELEMETRY_OPTOUT=1 POWERSHELL_UPDATECHECK=Off
export NO_PROXY="127.0.0.1,localhost${NO_PROXY:+,$NO_PROXY}" no_proxy="127.0.0.1,localhost${no_proxy:+,$no_proxy}"
sync() { # extra args...; stdin may carry the YES answer
	timeout 120 "$PWSH" -NoProfile -NonInteractive -File "$script" -Project "$proj" -NoRojo -Once \
		-ApiBase "http://127.0.0.1:$port" -DownloadBase "http://127.0.0.1:$port" "$@" 2>&1
}
check() {
	if eval "$2"; then
		echo "  PASS $1"
		pass=$((pass + 1))
	else
		echo "  FAIL $1"
		fail=$((fail + 1))
	fi
}
snapshot() { (cd "$proj" && find . -type f -not -path './.skybound-sync/*' -print0 | sort -z | xargs -0 sha256sum); }
matches_commit() { # project managed files == commit tree
	local tag=$1 tmp="$work/cmp-$1"
	rm -rf "$tmp" && mkdir -p "$tmp" && (cd "$tmp" && unzip -q "$srv/zips/$(sha "$tag").zip")
	diff -r "$tmp/skybound-$(sha "$tag")/src" "$proj/src" -x MyNotes.txt >/dev/null &&
		cmp -s "$tmp/skybound-$(sha "$tag")/default.project.json" "$proj/default.project.json"
}

# Fixture project: an older Skybound (commit A with older files) + the user's own files.
mkdir -p "$proj"
git -C "$repo" archive 633758b | tar -x -C "$proj" src default.project.json README.md
echo "my notes" >"$proj/notes.txt"
mkdir -p "$proj/.vscode" && echo '{"editor.tabSize": 4}' >"$proj/.vscode/settings.json"
echo "user file inside src" >"$proj/src/client/MyNotes.txt"
echo '{"mine": true}' >"$proj/mysettings.json"
orig_hash="$(snapshot)"

echo "== 1. First run: dry run changes nothing"
set_branch A
out="$(sync -DryRun)"
echo "$out" | grep -q "Dry run only" && echo "$out" | grep -q "Plan for commit $(sha A)"
check "dry run prints a plan for the commit SHA" "[ $? -eq 0 ]"
check "dry run left the project untouched" '[ "$(snapshot)" = "$orig_hash" ]'

echo "== 2. First run: answering anything but YES changes nothing"
out="$(echo "no" | sync)"
check "declined first sync changed nothing" '[ "$(snapshot)" = "$orig_hash" ] && [ ! -f "$proj/.skybound-sync/state.json" ]'
echo "$out" | grep -q "Type YES" ; check "first sync asked for confirmation" "[ $? -eq 0 ]"

echo "== 3. First run: YES applies commit A"
out="$(echo "YES" | sync)"
check "project now matches commit A" "matches_commit A"
check "state records commit A" "grep -q $(sha A) $proj/.skybound-sync/state.json"
check "original backup created" '[ -f "$proj/.skybound-sync/original/src/server/init.server.luau" ]'
orig_backup="$(cd "$proj/.skybound-sync/original" && find . -type f -print0 | sort -z | xargs -0 sha256sum)"
check "user files untouched (notes, .vscode, mysettings, src/client/MyNotes.txt)" \
	'[ "$(cat $proj/notes.txt)" = "my notes" ] && [ -f $proj/.vscode/settings.json ] && [ -f $proj/mysettings.json ] && [ -f $proj/src/client/MyNotes.txt ]'
echo "$out" | grep -q "MyNotes.txt  (not from Skybound; left untouched)"; check "unknown file in src reported, not deleted" "[ $? -eq 0 ]"

echo "== 4. Normal update to B (change, add, remove; includes a new sync script)"
set_branch B
out="$(sync)"
check "project now matches commit B" "matches_commit B"
check "file removed upstream was removed" '[ ! -f "$proj/src/client/Lib/RunState.luau" ]'
check "file added upstream was added" '[ -f "$proj/src/shared/NewThing.luau" ]'
check "updated sync script saved locally" 'grep -q EXECUTED "$proj/tools/autosync.ps1"'
check "updated sync script was NOT executed" '[ ! -f "$SKYBOUND_TEST_MARKER" ]'
echo "$out" | grep -q "was NOT run"; check "user told the new script was not run" "[ $? -eq 0 ]"
state_b="$(snapshot)"

for bad in EMPTY INCOMPLETE BADZIP MISMATCH BADJSON; do
	echo "== 5. Rejects $bad"
	python3 - "$srv" "$bad" <<'EOF'
import json, sys
srv, tag = sys.argv[1], sys.argv[2]
order = open(srv + "/order.txt").read().split()
shas = json.load(open(srv + "/shas.json"))
# move the bad commit to the newest position so it looks like a normal update
order.remove(shas[tag]); order.append(shas[tag])
open(srv + "/order.txt", "w").write("\n".join(order))
EOF
	set_branch "$bad"
	out="$(sync)"
	check "$bad: sync reported failure" 'echo "$out" | grep -q "Sync failed"'
	check "$bad: project unchanged (still B)" '[ "$(snapshot)" = "$state_b" ]'
done

echo "== 6. Failed download (commit exists, archive 404)"
python3 - "$srv" <<'EOF'
import json, sys
srv = sys.argv[1]
order = open(srv + "/order.txt").read().split()
shas = json.load(open(srv + "/shas.json"))
order.remove(shas["OLD"]); order.append(shas["OLD"])
open(srv + "/order.txt", "w").write("\n".join(order))
EOF
set_branch OLD
out="$(sync)"
check "failed download reported" 'echo "$out" | grep -q "Download failed"'
check "project unchanged after failed download" '[ "$(snapshot)" = "$state_b" ]'

echo "== 7. Fault during apply rolls back automatically"
python3 - "$srv" <<'EOF'
import json, sys
srv = sys.argv[1]
shas = json.load(open(srv + "/shas.json"))
order = [shas[t] for t in ["OLD", "A", "B", "EMPTY", "INCOMPLETE", "BADZIP", "MISMATCH", "BADJSON", "C"]]
open(srv + "/order.txt", "w").write("\n".join(order))
EOF
set_branch C
out="$(SKYBOUND_SYNC_FAULT_AFTER=1 SKYBOUND_SYNC_FAULT_MODE=throw sync)"
check "fault reported as rolled back" 'echo "$out" | grep -q "rolled back"'
check "project restored to B after fault" '[ "$(snapshot)" = "$state_b" ] && grep -q $(sha B) $proj/.skybound-sync/state.json'
check "no journal left behind" '[ ! -d "$proj/.skybound-sync/journal" ]'

echo "== 8. Process killed mid-update recovers on next run"
SKYBOUND_SYNC_FAULT_AFTER=1 SKYBOUND_SYNC_FAULT_MODE=exit sync >/dev/null
check "journal exists after the kill (update was interrupted)" '[ -f "$proj/.skybound-sync/journal/journal.json" ]'
out="$(sync -DryRun)"
check "next run rolled back the interrupted update" 'echo "$out" | grep -q "previous update was interrupted"'
check "project is back to B" '[ "$(snapshot)" = "$state_b" ] && grep -q $(sha B) $proj/.skybound-sync/state.json'
out="$(sync)"
check "then applies C cleanly" "matches_commit C"

echo "== 9. Branch moving backwards is refused"
set_branch A
out="$(sync)"
check "older branch head refused" 'echo "$out" | grep -q "not syncing an older"'
check "project still C" "matches_commit C"

echo "== 10. Pinning to a specific commit"
out="$(sync -Pin "$(sha A)")"
check "pinned sync applied commit A and reported its SHA" "matches_commit A && echo \"\$out\" | grep -q $(sha A)"

echo "== 11. A Skybound file you edited is never overwritten"
echo "-- my local edit" >>"$proj/src/shared/Config.luau"
edited="$(sha256sum "$proj/src/shared/Config.luau")"
set_branch C
python3 - "$srv" <<'EOF'
import json, sys
srv = sys.argv[1]
shas = json.load(open(srv + "/shas.json"))
order = [shas[t] for t in ["OLD", "A", "B", "C"]]
open(srv + "/order.txt", "w").write("\n".join(order))
EOF
out="$(sync)"
check "update refused because of the local edit" 'echo "$out" | grep -q "changed locally"'
check "your edit is intact" '[ "$(sha256sum "$proj/src/shared/Config.luau")" = "$edited" ]'

echo "== 12. Original backup is never overwritten"
now_backup="$(cd "$proj/.skybound-sync/original" && find . -type f -print0 | sort -z | xargs -0 sha256sum)"
check "original backup identical to first-run copy" '[ "$now_backup" = "$orig_backup" ]'
check "original backup holds the pre-sync file" \
	'cmp -s "$proj/.skybound-sync/original/src/server/init.server.luau" <(git -C "$repo" show 633758b:src/server/init.server.luau)'

echo
echo "sync tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
