#!/usr/bin/env python3
"""Builds the release zip for mod.io: dist/<folder>.zip.

Only what the game loads goes in (mod.json, strings.json, content/, and
_metadata/ with the mod list name and cover). The repository's .git,
tests/, tools/, README and CHANGELOG stay out: players don't need them,
and the git history would otherwise ship with every download.

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
# in the repository and on the mod page. CHANGELOG.md stays out too: the
# game's mod validator keeps .md in a list next to its "only allowed on
# PC/Mac/Linux (mod will not be available on Consoles)" message, so it may
# cost the console listing; the changes go to the GitHub release and the
# mod.io change log instead
INCLUDE_FILES = ["mod.json", "strings.json"]
INCLUDE_DIRS = ["content", "_metadata"]
SKIP_SUFFIXES = ("~", ".bak", ".orig", ".swp", ".tmp")


def skipped(name):
    return name.startswith(".") or name.endswith(SKIP_SUFFIXES)


class PreflightError(Exception):
    pass


# mod.io refuses an upload whose name is longer than 50 characters (code
# 13009, seen in the in-game uploader on 2026-11-22); 250 for the summary is
# mod.io's long-standing limit. Counted in characters, not bytes.
MODINFO_LIMITS = (("name", 50), ("summary", 250))


def check_modinfo(info):
    """Raises PreflightError when _metadata/modinfo.json would be refused by
    mod.io, so the upload does not fail after the build."""
    for field, limit in MODINFO_LIMITS:
        value = info.get(field) if isinstance(info, dict) else None
        if not isinstance(value, str) or not value:
            raise PreflightError("_metadata/modinfo.json: %s must be a "
                                 "non-empty string" % field)
        if len(value) > limit:
            raise PreflightError("_metadata/modinfo.json: %s is %d "
                                 "characters, mod.io allows at most %d"
                                 % (field, len(value), limit))


def run(cmd, root):
    try:
        return subprocess.run(cmd, cwd=root, capture_output=True, text=True)
    except OSError as e:
        # luajit or git not installed: a clear stop, not a traceback
        raise PreflightError("cannot run %s: %s" % (cmd[0], e))


def check(root=None):
    """Raises PreflightError when the tree must not be packed; returns the
    lines to print (test summaries, a dirty-tree warning). tools/release.py
    runs it on a cut before it commits."""
    root = root or ROOT
    out = []
    parsed = {}
    for name in ("mod.json", "strings.json", "_metadata/modinfo.json"):
        try:
            with open(os.path.join(root, name), encoding="utf-8") as f:
                parsed[name] = json.load(f)
        except (OSError, ValueError) as e:
            raise PreflightError("%s: %s" % (name, e))
    # the in-game uploader refuses a mod without a cover, and the mod list
    # shows an empty tile: never build a release without it
    if not os.path.isfile(os.path.join(root, "_metadata", "0.png")):
        raise PreflightError("_metadata/0.png missing (1920x1080 cover "
                             "image)")
    check_modinfo(parsed["_metadata/modinfo.json"])
    tests = run(["luajit", "tests/run.lua"], root)
    if tests.returncode != 0:
        raise PreflightError(tests.stdout + tests.stderr
                             + "tests failed, no zip built")
    lines = tests.stdout.strip().splitlines()
    out.append(lines[-1] if lines else "lua tests: OK")
    # the staging tool guards the mod.io file id and the release tool the
    # version; test them before every build
    py = run([sys.executable, "-m", "unittest", "discover", "-s", "tests"],
             root)
    if py.returncode != 0:
        raise PreflightError(py.stdout + py.stderr
                             + "tool tests failed, no zip built")
    ran = [l for l in py.stderr.splitlines() if l.startswith("Ran ")]
    out.append((ran[-1] if ran else "tool tests") + ": OK")
    try:
        dirty = run(["git", "status", "--porcelain"], root).stdout.strip()
    except PreflightError:
        dirty = ""
    if dirty:
        out.append("warning: uncommitted changes:\n" + dirty)
    return out


def preflight():
    try:
        for line in check():
            print(line)
    except PreflightError as e:
        sys.exit(str(e))


def files_to_pack(root=None):
    root = root or ROOT
    for name in INCLUDE_FILES:
        path = os.path.join(root, name)
        if not os.path.isfile(path):
            sys.exit("missing " + name)
        yield path, name
    for top in INCLUDE_DIRS:
        for dirpath, dirnames, filenames in os.walk(os.path.join(root, top)):
            dirnames[:] = sorted(d for d in dirnames if not skipped(d))
            for f in sorted(filenames):
                if skipped(f):
                    continue
                path = os.path.join(dirpath, f)
                yield path, os.path.relpath(path, root).replace(os.sep, "/")


def build(root, out):
    """Writes the zip; files at the zip root, as mod.io unpacks a mod into
    its own folder. Returns the archive names."""
    names = []
    # written beside and renamed in, so a failed build leaves no half zip
    tmp = out + ".part"
    try:
        with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as z:
            for path, arc in files_to_pack(root):
                z.write(path, arc)
                names.append(arc)
        os.replace(tmp, out)
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)
    return names


def main():
    preflight()
    out_dir = os.path.join(ROOT, "dist")
    os.makedirs(out_dir, exist_ok=True)
    out = os.path.join(out_dir, os.path.basename(ROOT) + ".zip")
    for arc in build(ROOT, out):
        print("  " + arc)
    print(out)


if __name__ == "__main__":
    main()
