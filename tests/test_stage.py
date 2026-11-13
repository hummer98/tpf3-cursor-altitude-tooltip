"""Tests for tools/stage.py: python3 -m unittest discover -s tests"""
import json
import os
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "tools"))
import stage  # noqa: E402

FOLDER = "hummer_cursor_altitude_tooltip_1"


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


class StageTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        local = self.tmp.name
        self.root = os.path.join(local, "mods", FOLDER)
        self.area = os.path.join(local, "staging_area")
        self.target = os.path.join(self.area, FOLDER)
        os.makedirs(self.area)
        self.set_repo(revision=2, code="new")

    def tearDown(self):
        self.tmp.cleanup()

    def set_repo(self, revision, code):
        write(os.path.join(self.root, "mod.json"),
              json.dumps({"modId": "x", "revision": revision}))
        write(os.path.join(self.root, "content/gui/a.lua"), code)
        write(os.path.join(self.root, "_metadata/modinfo.json"), "{}")

    def files(self):
        return [(os.path.join(self.root, rel), rel) for rel in
                ("mod.json", "content/gui/a.lua", "_metadata/modinfo.json")]

    def set_staged(self, revision, fileid=True):
        write(os.path.join(self.target, "mod.json"),
              json.dumps({"modId": "x", "revision": revision}))
        write(os.path.join(self.target, "content/gui/a.lua"), "old")
        write(os.path.join(self.target, "content/gui/removed.lua"), "gone")
        if fileid:
            write(os.path.join(self.target, "_metadata/mod.io_fileid.txt"),
                  "6523060")

    def test_first_stage_creates_the_folder(self):
        target, kept, uploaded = stage.stage(self.root, self.area,
                                             self.files(), first_upload=True)
        self.assertEqual(target, self.target)
        self.assertEqual(read(os.path.join(target, "content/gui/a.lua")),
                         "new")
        self.assertEqual(kept, [])
        self.assertFalse(uploaded)

    def test_update_keeps_the_file_id_and_drops_stale_files(self):
        self.set_staged(revision=1)
        _, kept, uploaded = stage.stage(self.root, self.area, self.files())
        self.assertTrue(uploaded)
        self.assertEqual(kept, ["mod.io_fileid.txt"])
        self.assertEqual(read(os.path.join(
            self.target, "_metadata/mod.io_fileid.txt")), "6523060")
        self.assertEqual(read(os.path.join(self.target, "content/gui/a.lua")),
                         "new")
        self.assertFalse(os.path.exists(
            os.path.join(self.target, "content/gui/removed.lua")))
        # no temp folders left beside the staging area
        self.assertEqual(sorted(os.listdir(self.tmp.name)),
                         ["mods", "staging_area"])

    def test_same_revision_after_upload_is_refused_and_nothing_changes(self):
        self.set_staged(revision=2)
        with self.assertRaisesRegex(stage.StageError, "revision 2"):
            stage.stage(self.root, self.area, self.files())
        self.assertEqual(read(os.path.join(self.target, "content/gui/a.lua")),
                         "old")

    def test_keep_revision_allows_a_metadata_only_update(self):
        self.set_staged(revision=2)
        _, _, uploaded = stage.stage(self.root, self.area, self.files(),
                                     keep_revision=True)
        self.assertTrue(uploaded)
        self.assertTrue(os.path.exists(
            os.path.join(self.target, "_metadata/mod.io_fileid.txt")))

    def test_missing_file_id_is_refused_and_nothing_changes(self):
        self.set_staged(revision=1, fileid=False)
        with self.assertRaisesRegex(stage.StageError, "second page"):
            stage.stage(self.root, self.area, self.files())
        self.assertEqual(read(os.path.join(self.target, "content/gui/a.lua")),
                         "old")

    def test_first_upload_skips_the_file_id_and_revision_checks(self):
        self.set_staged(revision=5, fileid=False)
        _, kept, uploaded = stage.stage(self.root, self.area, self.files(),
                                        first_upload=True)
        self.assertFalse(uploaded)
        self.assertEqual(kept, [])

    def test_keep_revision_still_refuses_a_lower_revision(self):
        self.set_staged(revision=3)
        with self.assertRaisesRegex(stage.StageError, "revision 2"):
            stage.stage(self.root, self.area, self.files(),
                        keep_revision=True)

    def test_broken_staged_mod_json_is_a_stage_error(self):
        self.set_staged(revision=1)
        write(os.path.join(self.target, "mod.json"), "{broken")
        with self.assertRaises(stage.StageError):
            stage.stage(self.root, self.area, self.files())
        os.remove(os.path.join(self.target, "mod.json"))
        with self.assertRaises(stage.StageError):
            stage.stage(self.root, self.area, self.files())

    def test_missing_staging_area_is_an_error(self):
        os.rmdir(self.area)
        with self.assertRaisesRegex(stage.StageError, "staging area"):
            stage.stage(self.root, self.area, self.files())

    def test_non_integer_revision_is_an_error(self):
        self.set_staged(revision=1)
        write(os.path.join(self.root, "mod.json"), '{"revision": "2"}')
        with self.assertRaisesRegex(stage.StageError, "not an integer"):
            stage.stage(self.root, self.area, self.files())

    def test_copy_failure_leaves_the_staging_copy_untouched(self):
        self.set_staged(revision=1)
        with mock.patch.object(stage.shutil, "copy2",
                               side_effect=OSError("disk full")):
            with self.assertRaises(OSError):
                stage.stage(self.root, self.area, self.files())
        self.assertEqual(read(os.path.join(
            self.target, "_metadata/mod.io_fileid.txt")), "6523060")
        self.assertEqual(read(os.path.join(self.target, "content/gui/a.lua")),
                         "old")
        self.assertEqual(sorted(os.listdir(self.tmp.name)),
                         ["mods", "staging_area"])

    def test_swap_failure_restores_the_old_copy_with_its_file_id(self):
        self.set_staged(revision=1)
        real_rename = os.rename

        def failing_rename(src, dst):
            # fail moving the new copy into place (src is the temp build);
            # the restore of the old copy must still work
            if dst == self.target and ".stage_new_" in src:
                raise OSError("disk full")
            real_rename(src, dst)

        with mock.patch.object(stage.os, "rename", failing_rename):
            with self.assertRaises(OSError):
                stage.stage(self.root, self.area, self.files())
        self.assertEqual(read(os.path.join(
            self.target, "_metadata/mod.io_fileid.txt")), "6523060")
        self.assertEqual(read(os.path.join(self.target, "content/gui/a.lua")),
                         "old")
        self.assertEqual(sorted(os.listdir(self.tmp.name)),
                         ["mods", "staging_area"])

    def test_interrupted_run_is_restored_not_deleted(self):
        # killed between the renames: the only file id is in .stage_old_
        self.set_staged(revision=1)
        old_tmp = os.path.join(self.tmp.name, ".stage_old_" + FOLDER)
        os.rename(self.target, old_tmp)
        _, kept, uploaded = stage.stage(self.root, self.area, self.files())
        self.assertTrue(uploaded)
        self.assertEqual(kept, ["mod.io_fileid.txt"])
        self.assertEqual(read(os.path.join(
            self.target, "_metadata/mod.io_fileid.txt")), "6523060")
        self.assertFalse(os.path.exists(old_tmp))

    def test_interrupted_run_with_both_copies_present_stops(self):
        self.set_staged(revision=1)
        old_tmp = os.path.join(self.tmp.name, ".stage_old_" + FOLDER)
        write(os.path.join(old_tmp, "_metadata/mod.io_fileid.txt"), "6523060")
        with self.assertRaisesRegex(stage.StageError, "interrupted"):
            stage.stage(self.root, self.area, self.files())
        self.assertTrue(os.path.exists(
            os.path.join(old_tmp, "_metadata/mod.io_fileid.txt")))
        self.assertEqual(read(os.path.join(self.target, "content/gui/a.lua")),
                         "old")

    def test_leftover_half_build_is_cleared(self):
        write(os.path.join(self.tmp.name, ".stage_new_" + FOLDER, "junk"), "x")
        stage.stage(self.root, self.area, self.files(), first_upload=True)
        self.assertFalse(os.path.exists(
            os.path.join(self.target, "junk")))

    def test_main_refuses_a_dirty_tree_before_touching_staging(self):
        with mock.patch.object(stage, "is_dirty", return_value=" M x"), \
                mock.patch.object(stage.package, "preflight") as pre, \
                mock.patch.object(stage, "stage") as st:
            with self.assertRaises(SystemExit):
                stage.main(["--staging-area", self.area])
        pre.assert_not_called()
        st.assert_not_called()


if __name__ == "__main__":
    unittest.main()
