#!/usr/bin/env python3
"""Builds the release zip for mod.io: dist/<folder>.zip.

Only what the game loads (mod.json, strings.json, content/) and the
licence go in. The repository's .git, tests/, tools/ and README stay out:
players don't need them, and the git history would otherwise ship with
every download.

Usage (from anywhere): python3 tools/package.py
"""
import os
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INCLUDE_FILES = ["mod.json", "strings.json", "LICENSE"]
INCLUDE_DIRS = ["content"]


def files_to_pack():
    for name in INCLUDE_FILES:
        path = os.path.join(ROOT, name)
        if not os.path.isfile(path):
            sys.exit("missing " + name)
        yield path, name
    for top in INCLUDE_DIRS:
        for dirpath, dirnames, filenames in os.walk(os.path.join(ROOT, top)):
            dirnames[:] = sorted(d for d in dirnames if not d.startswith("."))
            for f in sorted(filenames):
                if f.startswith("."):
                    continue
                path = os.path.join(dirpath, f)
                yield path, os.path.relpath(path, ROOT).replace(os.sep, "/")


def main():
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
