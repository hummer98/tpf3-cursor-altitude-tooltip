#!/usr/bin/env python3
"""Builds the release zip for mod.io: dist/<folder>.zip.

Only what the game loads goes in (mod.json, strings.json, content/, and
_metadata/ with the mod list name and cover). The repository's .git,
tests/, tools/ and README stay out: players don't need them, and the git
history would otherwise ship with every download.

_metadata/ goes in although mod.io downloads normally lack it (the in-game
uploader sends it as mod.io data): a manual install from the zip needs it,
or the game lists the mod by its snake_case folder name.

Before packing it runs the tests, checks that the JSON files parse and
warns about uncommitted changes, so a zip is never built from a broken or
unrecorded state. Backup and editor files (.*, *~, *.bak, *.orig, *.swp)
are left out.

Usage (from anywhere): python3 tools/package.py
"""
import json
import os
import subprocess
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# no LICENSE here: the game's mod validation rejects files without an
# allowed extension ("File extension is not allowed"); the licence is stated
# in the repository and on the mod page
INCLUDE_FILES = ["mod.json", "strings.json"]
INCLUDE_DIRS = ["content", "_metadata"]
SKIP_SUFFIXES = ("~", ".bak", ".orig", ".swp", ".tmp")


def skipped(name):
    return name.startswith(".") or name.endswith(SKIP_SUFFIXES)


def preflight():
    for name in ("mod.json", "strings.json", "_metadata/modinfo.json"):
        try:
            with open(os.path.join(ROOT, name), encoding="utf-8") as f:
                json.load(f)
        except (OSError, ValueError) as e:
            sys.exit("%s: %s" % (name, e))
    tests = subprocess.run(["luajit", "tests/run.lua"], cwd=ROOT,
                           capture_output=True, text=True)
    if tests.returncode != 0:
        sys.exit(tests.stdout + tests.stderr + "tests failed, no zip built")
    print(tests.stdout.strip().splitlines()[-1])
    try:
        dirty = subprocess.run(["git", "status", "--porcelain"], cwd=ROOT,
                               capture_output=True, text=True).stdout.strip()
    except OSError:
        dirty = ""
    if dirty:
        print("warning: uncommitted changes:\n" + dirty)


def files_to_pack():
    for name in INCLUDE_FILES:
        path = os.path.join(ROOT, name)
        if not os.path.isfile(path):
            sys.exit("missing " + name)
        yield path, name
    for top in INCLUDE_DIRS:
        for dirpath, dirnames, filenames in os.walk(os.path.join(ROOT, top)):
            dirnames[:] = sorted(d for d in dirnames if not skipped(d))
            for f in sorted(filenames):
                if skipped(f):
                    continue
                path = os.path.join(dirpath, f)
                yield path, os.path.relpath(path, ROOT).replace(os.sep, "/")


def main():
    preflight()
    out_dir = os.path.join(ROOT, "dist")
    os.makedirs(out_dir, exist_ok=True)
    out = os.path.join(out_dir, os.path.basename(ROOT) + ".zip")
    # files at the zip root, as mod.io unpacks a mod into its own folder
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for path, arc in files_to_pack():
            z.write(path, arc)
            print("  " + arc)
    print(out)


if __name__ == "__main__":
    main()
