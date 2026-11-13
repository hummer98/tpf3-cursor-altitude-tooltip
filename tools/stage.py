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
- the staged copy has the mod.io file id: the mod is published, so staging
  without it would make the next upload a second mod.io page
  (--first-upload skips this, only for a mod not yet on mod.io);
- mod.json's revision is higher than the staged one, so players' copies
  are seen as outdated (--keep-revision allows the same revision, e.g. for
  a metadata-only update, never a lower one).

The new copy is built next to the staging area and swapped in with two
renames, so the game never sees a half-written folder (only, for a moment,
none). If a run dies between the renames, the old copy is left in
local/.stage_old_<folder>; the next run puts it back instead of deleting it.

Usage (from anywhere):
  python3 tools/stage.py [--allow-dirty] [--keep-revision] [--first-upload]
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
    try:
        with open(mod_json_path, encoding="utf-8") as f:
            rev = json.load(f).get("revision")
    except (OSError, ValueError, AttributeError) as e:
        raise StageError("%s: %s" % (mod_json_path, e))
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


def recover_interrupted(target, old_tmp):
    """A previous run died between its renames: old_tmp holds the last good
    copy, possibly the only mod.io file id. Never delete it blindly."""
    if not os.path.exists(old_tmp):
        return
    if os.path.lexists(target):
        raise StageError("%s is left over from an interrupted run and %s "
                         "also exists; check which one has "
                         "_metadata/mod.io_fileid.txt, keep it as the "
                         "staging copy and remove the other" % (old_tmp, target))
    os.rename(old_tmp, target)
    print("restored the staging copy from an interrupted run: " + target)


def stage(root, staging_area, files, keep_revision=False, first_upload=False):
    """Rebuilds staging_area/<folder> from files ((src, rel) pairs).

    Returns (target, preserved names, uploaded) where uploaded tells whether
    a mod.io file id was carried over.
    """
    folder = os.path.basename(os.path.normpath(root))
    if not os.path.isdir(staging_area):
        raise StageError("staging area not found: %s (start the game once)"
                         % staging_area)
    target = os.path.join(staging_area, folder)
    # build beside staging_area, not inside it: the game scans that folder
    # live and would try to validate a half-copied mod
    parent = os.path.dirname(os.path.normpath(staging_area))
    tmp = os.path.join(parent, ".stage_new_" + folder)
    old_tmp = os.path.join(parent, ".stage_old_" + folder)
    recover_interrupted(target, old_tmp)

    keep = preserved_files(target)
    uploaded = any(os.path.basename(p) == "mod.io_fileid.txt" for p in keep)
    if not uploaded and not first_upload:
        raise StageError(
            "%s has no _metadata/mod.io_fileid.txt; this mod is on mod.io, so "
            "the next upload would create a second page. Restore the file "
            "(or pass --first-upload for a mod not yet published)" % target)

    if uploaded:
        old = revision(os.path.join(target, "mod.json"))
        new = revision(os.path.join(root, "mod.json"))
        if new < old or (new == old and not keep_revision):
            raise StageError(
                "mod.json revision %d is not above the uploaded %d: raise it "
                "(or pass --keep-revision for a metadata-only update)"
                % (new, old))

    # the only thing removed unconditionally: a half-built copy, which never
    # holds anything the game wrote
    if os.path.exists(tmp):
        shutil.rmtree(tmp)
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
    ap.add_argument("--first-upload", action="store_true",
                    help="stage without a mod.io file id (mod not yet "
                    "published)")
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
                                       args.keep_revision, args.first_upload)
    except StageError as e:
        sys.exit("stage: %s" % e)
    print("staged: " + target)
    if kept:
        print("kept from the game: " + ", ".join(kept))
    if uploaded:
        print("In game: MOD hub > My mods > this mod > Revalidate, write the "
              "change log, then Update.")
    else:
        print("In game: MOD hub > My mods > this mod > Upload (first upload "
              "creates the mod.io page and its file id).")


if __name__ == "__main__":
    main()
