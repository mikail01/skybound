"""Builds fake commits (zip archives) from the real repository for tests/sync.

usage: build_fixtures.py <repo_root> <server_dir>
"""

import json
import os
import shutil
import subprocess
import sys
import zipfile

repo, srv = sys.argv[1], sys.argv[2]
BRANCH = "claude/roblox-studio-connection-isznfe"
for d in ("commits", "zips"):
    os.makedirs(os.path.join(srv, d), exist_ok=True)


def sha(tag):
    return (tag.encode().hex() * 20)[:40]


SHAS = {t: sha(t) for t in ["A", "B", "C", "EMPTY", "INCOMPLETE", "BADZIP", "MISMATCH", "BADJSON", "OLD"]}


def base_tree():
    """Real project files at HEAD, as a dict path -> bytes."""
    out = subprocess.run(["git", "-C", repo, "ls-files"], capture_output=True, text=True, check=True).stdout.split()
    tree = {}
    for rel in out:
        if rel.startswith(("src/", "tools/")) or rel in ("default.project.json", "README.md", "selene.toml", "stylua.toml", "rokit.toml", "wally.toml", ".gitignore"):
            tree[rel] = open(os.path.join(repo, rel), "rb").read()
    return tree


def write_zip(tag, tree, folder=None):
    path = os.path.join(srv, "zips", SHAS[tag] + ".zip")
    top = folder or "skybound-" + SHAS[tag]
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr(top + "/", "")
        for rel, data in sorted(tree.items()):
            z.writestr(top + "/" + rel, data)


def commit_json(tag, title):
    data = {"sha": SHAS[tag], "commit": {"message": title + "\n\nbody"}}
    with open(os.path.join(srv, "commits", SHAS[tag] + ".json"), "w") as f:
        json.dump(data, f)


a = base_tree()
write_zip("A", a)
commit_json("A", "Commit A")

b = dict(a)
b["src/shared/Format.luau"] = a["src/shared/Format.luau"] + b"\n-- changed in B\n"
b["src/shared/NewThing.luau"] = b"--!strict\nreturn { added = 'B' }\n"
del b["src/client/Lib/RunState.luau"]
# A newer sync script that would leave a marker if anything ever ran it.
b["tools/autosync.ps1"] = b"Set-Content -Path \"$env:SKYBOUND_TEST_MARKER\" -Value 'EXECUTED'\n" + a["tools/autosync.ps1"]
write_zip("B", b)
commit_json("B", "Commit B")

c = dict(b)
c["src/server/Systems/Hub.luau"] = b["src/server/Systems/Hub.luau"] + b"\n-- changed in C\n"
write_zip("C", c)
commit_json("C", "Commit C")

empty = {k: v for k, v in a.items() if not k.startswith("src/")}
write_zip("EMPTY", empty)
commit_json("EMPTY", "Empty src")

incomplete = dict(a)
del incomplete["src/server/init.server.luau"]
write_zip("INCOMPLETE", incomplete)
commit_json("INCOMPLETE", "Missing server entry")

with open(os.path.join(srv, "zips", SHAS["BADZIP"] + ".zip"), "wb") as f:
    f.write(b"this is not a zip archive at all")
commit_json("BADZIP", "Corrupt archive")

write_zip("MISMATCH", a, folder="skybound-" + SHAS["A"])
commit_json("MISMATCH", "Archive for the wrong commit")

badjson = dict(a)
badjson["default.project.json"] = b"{ this is not json"
write_zip("BADJSON", badjson)
commit_json("BADJSON", "Broken project file")

commit_json("OLD", "Older commit")  # exists, but no download (failed download case)

with open(os.path.join(srv, "order.txt"), "w") as f:
    f.write("\n".join(SHAS[t] for t in ["OLD", "A", "B", "C", "EMPTY", "INCOMPLETE", "BADZIP", "MISMATCH", "BADJSON"]))

json.dump(SHAS, open(os.path.join(srv, "shas.json"), "w"))
print(json.dumps(SHAS))
