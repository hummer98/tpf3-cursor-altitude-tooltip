#!/usr/bin/env python3
"""Copies the mod into the game's staging area for an in-game mod.io update.

The in-game uploader (MOD hub > My mods) only sees mods in
local/staging_area/<folder>/. After the first upload the game writes
_metadata/mod.io_fileid.txt there, and that file is what makes the next
upload update the same mod.io page; without it the game would publish a
second mod. So the staging copy is rebuilt from the repository while every
_metadata/mod.io_* file the game wrote is carried over.

Checks before touching the staging area:
- the tests pass and the JSON files parse (same preflight as package.py);
- the working tree is committed, so what goes to mod.io is in git history
  (--allow-dirty skips this);
- mod.json's revision is higher than the staged one once the mod has been
  uploaded, so players' copies are seen as outdated (--keep-revision skips
  this, e.g. for a metadata-only update).

The new copy is built next to the staging area and swapped in with
renames, so the game never sees a half-written folder.

Usage (from anywhere): python3 tools/stage.py [--allow-dirty] [--keep-revision]
"""
import argparse
import json
import os
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import package  # noqa: E402

ROOT = package.ROOT
# <Steam>/userdata/<id>/3493540/local/mods/<folder> -> local/staging_area
DEFAULT_STAGING_AREA = os.path.join(os.path.dirname(os.path.dirname(ROOT)),
                                    "staging_area")
# written by the game after an upload; never in the repository
PRESERVE_PREFIX = "mod.io_"


class StageError(Exception):
    pass


def revision(mod_json_path):
    with open(mod_json_path, encoding="utf-8") as f:
        rev = json.load(f).get("revision")
    if not isinstance(rev, int):
        raise StageError("%s: revision is not an integer" % mod_json_path)
    return rev


def preserved_files(target):
    meta = os.path.join(target, "_metadata")
    if not os.path.isdir(meta):
        return []
    return sorted(os.path.join(meta, f) for f in os.listdir(meta)
                  if f.startswith(PRESERVE_PREFIX)
                  and os.path.isfile(os.path.join(meta, f)))


def is_dirty(root):
    try:
        out = subprocess.run(["git", "status", "--porcelain"], cwd=root,
                             capture_output=True, text=True, check=True)
    except (OSError, subprocess.CalledProcessError) as e:
        raise StageError("cannot read git status: %s" % e)
    return out.stdout.strip()


def stage(root, staging_area, files, keep_revision=False):
    """Rebuilds staging_area/<folder> from files ((src, rel) pairs).

    Returns (target, preserved names, uploaded) where uploaded tells whether
    a mod.io file id was carried over.
    """
    folder = os.path.basename(os.path.normpath(root))
    if not os.path.isdir(staging_area):
        raise StageError("staging area not found: %s (start the game once)"
                         % staging_area)
    target = os.path.join(staging_area, folder)
    keep = preserved_files(target)
    uploaded = any(os.path.basename(p) == "mod.io_fileid.txt" for p in keep)

    if uploaded and not keep_revision:
        old = revision(os.path.join(target, "mod.json"))
        new = revision(os.path.join(root, "mod.json"))
        if new <= old:
            raise StageError(
                "mod.json revision %d is not above the uploaded %d: raise it "
                "(or pass --keep-revision for a metadata-only update)"
                % (new, old))

    # build beside staging_area, not inside it: the game scans that folder
    # live and would try to validate a half-copied mod
    parent = os.path.dirname(os.path.normpath(staging_area))
    tmp = os.path.join(parent, ".stage_new_" + folder)
    old_tmp = os.path.join(parent, ".stage_old_" + folder)
    for leftover in (tmp, old_tmp):
        if os.path.exists(leftover):
            shutil.rmtree(leftover)
    try:
        for src, rel in files:
            dst = os.path.join(tmp, rel)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copy2(src, dst)
        for p in keep:
            dst = os.path.join(tmp, "_metadata", os.path.basename(p))
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copy2(p, dst)
        if os.path.exists(target):
            os.rename(target, old_tmp)
        os.rename(tmp, target)
    except BaseException:
        # put the previous copy back so the file id is never lost
        if os.path.exists(old_tmp) and not os.path.exists(target):
            os.rename(old_tmp, target)
        if os.path.exists(tmp):
            shutil.rmtree(tmp)
        raise
    if os.path.exists(old_tmp):
        shutil.rmtree(old_tmp)
    return target, [os.path.basename(p) for p in keep], uploaded


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--allow-dirty", action="store_true",
                    help="stage uncommitted changes")
    ap.add_argument("--keep-revision", action="store_true",
                    help="do not require a higher mod.json revision")
    ap.add_argument("--staging-area", default=DEFAULT_STAGING_AREA,
                    help=argparse.SUPPRESS)
    args = ap.parse_args(argv)
    try:
        dirty = is_dirty(ROOT)
        if dirty and not args.allow_dirty:
            raise StageError("uncommitted changes (commit first, or pass "
                             "--allow-dirty):\n" + dirty)
        package.preflight()
        target, kept, uploaded = stage(ROOT, args.staging_area,
                                       list(package.files_to_pack()),
                                       args.keep_revision)
    except StageError as e:
        sys.exit("stage: %s" % e)
    print("staged: " + target)
    if kept:
        print("kept from the game: " + ", ".join(kept))
    if uploaded:
        print("In game: MOD hub > My mods > this mod > Revalidate, write the "
              "change log, then Update.")
    else:
        print("No mod.io file id: the next upload creates a NEW mod.io page. "
              "If this mod is already on mod.io, stop and restore "
              "_metadata/mod.io_fileid.txt first.")


if __name__ == "__main__":
    main()
