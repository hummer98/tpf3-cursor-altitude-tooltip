"""Tests for tools/release.py: python3 -m unittest discover -s tests

The flow tests run real git in a throwaway repository (and a bare one as
its remote); the checks, the zip and gh are stand-ins, so nothing leaves
the temporary directory. RepositoryTest pins this repository's own
VERSION, mod.json revision and CHANGELOG.md to each other.
"""
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "tools"))
import release  # noqa: E402

FOLDER = "hummer_cursor_altitude_tooltip_1"

CHANGELOG = """# Changelog

Intro.

## [Unreleased]

### Added
- New thing.

### Fixed
- Old bug.

## [0.1.0] - 2026-01-01

### Added
- First.
"""

MOD_JSON = '{\n\t"modId": "m_x",\n\t"revision": %d,\n\t"visible": true\n}\n'


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


class VersionTest(unittest.TestCase):
    def test_bump_levels(self):
        self.assertEqual(release.bump("0.9.0", "patch"), "0.9.1")
        self.assertEqual(release.bump("0.9.3", "minor"), "0.10.0")
        self.assertEqual(release.bump("0.9.3", "major"), "1.0.0")
        self.assertEqual(release.bump("0.9.3", "1.2.3"), "1.2.3")

    def test_bump_refuses_a_part_above_99(self):
        with self.assertRaisesRegex(release.ReleaseError, "above 99"):
            release.bump("0.9.99", "patch")
        with self.assertRaisesRegex(release.ReleaseError, "above 99"):
            release.bump("0.99.0", "minor")

    def test_version_format(self):
        self.assertEqual(release.parse_version("10.99.0"), (10, 99, 0))
        for bad in ("1", "1.2", "1.2.3.4", "v1.2.3", "1.2.3-rc.1", "01.2.3",
                    "1.02.3", "1.100.0", "1000.0.0", "", None, "next"):
            with self.assertRaises(release.ReleaseError, msg=repr(bad)):
                release.parse_version(bad)
        with self.assertRaises(release.ReleaseError):
            release.bump("0.9.0", "pach")

    def test_revision_follows_the_version(self):
        self.assertEqual(release.revision_of("1.0.0"), 10000)
        self.assertEqual(release.revision_of("1.2.3"), 10203)
        self.assertEqual(release.revision_of("0.9.0"), 900)
        self.assertEqual(release.revision_of("0.0.1"), 1)
        # the order of the versions is the order of the revisions
        order = ["0.9.99", "0.10.0", "0.99.99", "1.0.0", "1.0.1", "1.1.0",
                 "2.0.0"]
        revs = [release.revision_of(v) for v in order]
        self.assertEqual(revs, sorted(revs))
        self.assertEqual(len(set(revs)), len(revs))

    def test_revision_rewritten_in_place(self):
        # tabs, key order and the other keys stay as they are
        self.assertEqual(release.revision_text(MOD_JSON % 1, "1.0.0"),
                         MOD_JSON % 10000)
        with self.assertRaisesRegex(release.ReleaseError, "exactly one"):
            release.revision_text('{"modId": "m"}', "1.0.0")
        with self.assertRaisesRegex(release.ReleaseError, "exactly one"):
            release.revision_text('{"revision": 1, "x": {"revision": 2}}',
                                  "1.0.0")

    def test_version_file_format(self):
        with tempfile.TemporaryDirectory() as root:
            for text, want in (("1.0.0\n", "1.0.0"), ("  1.2.3  \n\n",
                                                      "1.2.3")):
                write(os.path.join(root, "VERSION"), text)
                self.assertEqual(release.read_version(root), want)
            for bad in ("", "1.0.0\n1.0.1\n", "v1.0.0\n", "1.0\n"):
                write(os.path.join(root, "VERSION"), bad)
                with self.assertRaises(release.ReleaseError, msg=repr(bad)):
                    release.read_version(root)
            os.remove(os.path.join(root, "VERSION"))
            with self.assertRaisesRegex(release.ReleaseError, "VERSION"):
                release.read_version(root)

    def test_github_repo_from_the_remote_url(self):
        for url in ("https://github.com/hummer98/tpf3-cursor-altitude-tooltip.git",
                    "https://github.com/hummer98/tpf3-cursor-altitude-tooltip",
                    "git@github.com:hummer98/tpf3-cursor-altitude-tooltip.git",
                    "ssh://git@github.com/hummer98/tpf3-cursor-altitude-tooltip/"):
            self.assertEqual(release.github_repo(url),
                             "hummer98/tpf3-cursor-altitude-tooltip", url)
        for url in ("/home/x/local/mods/m_1", "", None,
                    "https://gitlab.com/a/b.git"):
            self.assertIsNone(release.github_repo(url), url)


class ChangelogTest(unittest.TestCase):
    def test_section_bodies(self):
        self.assertEqual(release.section(CHANGELOG, "0.1.0"),
                         "### Added\n- First.")
        self.assertEqual(release.section(CHANGELOG, "Unreleased"),
                         "### Added\n- New thing.\n\n### Fixed\n- Old bug.")
        self.assertIsNone(release.section(CHANGELOG, "9.9.9"))

    def test_cut_moves_unreleased_into_the_version(self):
        out = release.cut_changelog(CHANGELOG, "0.2.0", "2026-11-18")
        self.assertIn("## [Unreleased]\n\n## [0.2.0] - 2026-11-18\n\n"
                      "### Added\n- New thing.", out)
        self.assertEqual(release.section(out, "Unreleased"), "")
        self.assertEqual(release.section(out, "0.2.0"),
                         "### Added\n- New thing.\n\n### Fixed\n- Old bug.")
        self.assertEqual(release.section(out, "0.1.0"), "### Added\n- First.")
        self.assertTrue(out.startswith("# Changelog\n\nIntro.\n\n"))

    def test_cut_refuses_an_empty_unreleased(self):
        once = release.cut_changelog(CHANGELOG, "0.2.0", "2026-11-18")
        with self.assertRaisesRegex(release.ReleaseError, "empty"):
            release.cut_changelog(once, "0.2.1", "2026-11-19")
        only_headings = CHANGELOG.replace("- New thing.\n", "").replace(
            "- Old bug.\n", "")
        with self.assertRaisesRegex(release.ReleaseError, "empty"):
            release.cut_changelog(only_headings, "0.2.0", "2026-11-18")

    def test_cut_refuses_a_missing_unreleased_or_a_repeated_version(self):
        with self.assertRaisesRegex(release.ReleaseError, "no ## \\[Unrel"):
            release.cut_changelog("# Changelog\n", "0.2.0", "2026-11-18")
        with self.assertRaisesRegex(release.ReleaseError, "already has"):
            release.cut_changelog(CHANGELOG, "0.1.0", "2026-11-18")

    def test_notes_put_each_item_on_one_line(self):
        body = ("### Added\n- First thing, wrapped\n  onto two lines.\n"
                "- Second.\n  - A nested item\n    wrapped.\n\n### Fixed\n"
                "- Third\n\tby tab.\n")
        self.assertEqual(release.unwrap(body),
                         "### Added\n- First thing, wrapped onto two lines.\n"
                         "- Second.\n  - A nested item wrapped.\n\n"
                         "### Fixed\n- Third by tab.")
        self.assertEqual(release.unwrap(""), "")

    def test_released_versions_newest_first(self):
        text = CHANGELOG.replace("## [0.1.0]", "## [0.2.0] - 2026-02-01\n\n"
                                 "- B.\n\n## [0.1.0]")
        self.assertEqual(release.released_versions(text), ["0.2.0", "0.1.0"])
        self.assertEqual(release.released_versions("## [Unreleased]\n"), [])


class ConsistencyTest(unittest.TestCase):
    """VERSION, mod.json's revision and the changelog must agree."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = self.tmp.name

    def tree(self, version, revision, changelog):
        write(os.path.join(self.root, "VERSION"), version + "\n")
        write(os.path.join(self.root, "mod.json"), MOD_JSON % revision)
        write(os.path.join(self.root, "CHANGELOG.md"), changelog)
        return release.consistency(self.root)

    def test_agreeing_trees(self):
        # before the first release: no version section to compare yet
        self.assertEqual(self.tree("1.0.0", 10000,
                                   "## [Unreleased]\n\n- First.\n"), [])
        self.assertEqual(self.tree("0.1.0", 100, CHANGELOG), [])

    def test_a_revision_other_than_the_versions(self):
        problems = self.tree("1.0.0", 1, "## [Unreleased]\n")
        self.assertEqual(len(problems), 1)
        self.assertIn("revision 1 is not 10000", problems[0])

    def test_a_version_bumped_by_hand(self):
        problems = self.tree("0.2.0", 200, CHANGELOG)
        self.assertEqual(len(problems), 1)
        self.assertIn("newest section is [0.1.0] but VERSION is 0.2.0",
                      problems[0])

    def test_a_changelog_without_unreleased(self):
        problems = self.tree("0.1.0", 100, "## [0.1.0] - 2026-01-01\n")
        self.assertEqual(len(problems), 1)
        self.assertIn("no ## [Unreleased]", problems[0])
        os.remove(os.path.join(self.root, "CHANGELOG.md"))
        self.assertIn("CHANGELOG.md", release.consistency(self.root)[0])

    def test_unreadable_revision(self):
        write(os.path.join(self.root, "VERSION"), "1.0.0\n")
        for text in ('{"revision": "10000"}', '{"revision": true}', "[1]",
                     "{"):
            write(os.path.join(self.root, "mod.json"), text)
            with self.assertRaises(release.ReleaseError, msg=text):
                release.consistency(self.root)


REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


class RepositoryTest(unittest.TestCase):
    """This repository's own files (also run in the middle of a cut, with
    the version section just written and Unreleased empty)."""

    def test_version_revision_and_changelog_agree(self):
        self.assertEqual(release.consistency(REPO), [])

    def test_changelog_has_entries_to_release_or_the_versions_section(self):
        text = read(os.path.join(REPO, "CHANGELOG.md"))
        self.assertTrue(release.has_entries(release.section(text,
                                                            "Unreleased"))
                        or release.section(text, release.read_version(REPO)))


class FlowTest(unittest.TestCase):
    """cut / github_only on a real throwaway git repository."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        base = self.tmp.name
        gitconfig = os.path.join(base, "gitconfig")
        write(gitconfig, "")
        env = mock.patch.dict(os.environ, {
            "GIT_CONFIG_GLOBAL": gitconfig, "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
            "GIT_COMMITTER_NAME": "Test",
            "GIT_COMMITTER_EMAIL": "test@example.com"})
        env.start()
        self.addCleanup(env.stop)
        self.root = os.path.join(base, FOLDER)
        write(os.path.join(self.root, release.VERSION_FILE), "0.9.0\n")
        write(os.path.join(self.root, release.CHANGELOG),
              CHANGELOG.replace("## [0.1.0] - 2026-01-01\n\n### Added\n"
                                "- First.\n", ""))
        write(os.path.join(self.root, "mod.json"), MOD_JSON % 900)
        self.git("init", "-q", "-b", "master")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "start")
        self.lines, self.cmds, self.built = [], [], []
        self.which = lambda name: "/usr/bin/gh"

    def tearDown(self):
        self.tmp.cleanup()

    def git(self, *args, root=None):
        return subprocess.run(["git"] + list(args), cwd=root or self.root,
                              check=True, capture_output=True,
                              text=True).stdout

    def rel(self, checks=None):
        def run(cmd, root):
            self.cmds.append(cmd)
            if cmd[0] == "git":  # the push goes to the bare remote for real
                return subprocess.run(cmd, cwd=root, check=True,
                                      capture_output=True, text=True)
            return None

        def build(root, out):
            self.built.append(out)
        return release.Release(self.root, out=self.lines.append,
                               checks=checks or (lambda root: ["tests OK"]),
                               build=build, run=run, which=self.which)

    def tags(self):
        return self.git("tag", "--list").split()

    def output(self):
        return "\n".join(self.lines)

    def test_first_release_without_a_remote_stops_after_the_tag(self):
        self.assertEqual(self.rel().cut("0.9.0", "2026-11-18"), "0.9.0")
        self.assertEqual(self.tags(), ["v0.9.0"])
        self.assertEqual(self.git("log", "-1", "--format=%s"),
                         "Release v0.9.0\n")
        self.assertEqual(self.git("status", "--porcelain"), "")
        cl = read(os.path.join(self.root, release.CHANGELOG))
        self.assertIn("## [0.9.0] - 2026-11-18", cl)
        self.assertEqual(read(os.path.join(self.root, "mod.json")),
                         MOD_JSON % 900, "same version, same revision")
        self.assertEqual(release.consistency(self.root), [])
        # the tag is annotated and on the release commit
        self.assertEqual(self.git("cat-file", "-t", "v0.9.0"), "tag\n")
        self.assertEqual(self.git("rev-parse", "v0.9.0^{commit}"),
                         self.git("rev-parse", "HEAD"))
        self.assertEqual(self.cmds, [], "no push, no gh")
        self.assertEqual(len(self.built), 1)
        self.assertTrue(self.built[0].endswith(
            os.path.join("dist", "m_x-v0.9.0.zip")))
        out = self.output()
        self.assertIn("stopped before GitHub (no git remote 'github')", out)
        self.assertIn("gh release create v0.9.0", out)
        self.assertIn("git push github refs/tags/v0.9.0", out)

    def test_patch_after_a_release(self):
        self.rel().cut("0.9.0", "2026-11-18")
        path = os.path.join(self.root, release.CHANGELOG)
        write(path, read(path).replace(
            "## [Unreleased]\n", "## [Unreleased]\n\n### Fixed\n- A bug.\n"))
        self.git("commit", "-q", "-am", "fix")
        self.assertEqual(self.rel().cut("patch", "2026-11-20"), "0.9.1")
        self.assertEqual(sorted(self.tags()), ["v0.9.0", "v0.9.1"])
        self.assertEqual(release.read_version(self.root), "0.9.1")
        self.assertEqual(read(os.path.join(self.root, "mod.json")),
                         MOD_JSON % 901)
        self.assertEqual(release.consistency(self.root), [])
        self.assertEqual(self.git("show", "--name-only", "--format=",
                                  "HEAD").split(),
                         ["CHANGELOG.md", "VERSION", "mod.json"])
        with self.assertRaisesRegex(release.ReleaseError, "empty"):
            self.rel().cut("patch", "2026-11-21")

    def test_refusals_change_nothing(self):
        head = self.git("rev-parse", "HEAD")
        write(os.path.join(self.root, "x.txt"), "dirty")
        with self.assertRaisesRegex(release.ReleaseError, "uncommitted"):
            self.rel().cut("patch")
        os.remove(os.path.join(self.root, "x.txt"))
        with self.assertRaisesRegex(release.ReleaseError, "below"):
            self.rel().cut("0.8.0")
        self.git("tag", "v1.0.0")
        with self.assertRaisesRegex(release.ReleaseError, "newest tag"):
            self.rel().cut("0.9.0")
        with self.assertRaisesRegex(release.ReleaseError, "already exists"):
            self.rel().cut("1.0.0")
        self.assertEqual(self.git("rev-parse", "HEAD"), head)
        self.assertEqual(self.tags(), ["v1.0.0"])

    def test_failed_checks_put_every_file_back(self):
        def failing(root):
            raise release.ReleaseError("tests failed")
        before = {rel: read(os.path.join(self.root, rel)) for rel in
                  [release.VERSION_FILE, release.CHANGELOG, "mod.json"]}
        with self.assertRaisesRegex(release.ReleaseError, "tests failed"):
            self.rel(checks=failing).cut("1.0.0", "2026-11-18")
        for rel, text in before.items():
            self.assertEqual(read(os.path.join(self.root, rel)), text, rel)
        self.assertEqual(self.git("status", "--porcelain"), "")
        self.assertEqual(self.tags(), [])
        self.assertEqual(self.git("log", "--format=%s"), "start\n")

    def test_only_on_the_release_branch_and_a_real_date(self):
        self.git("checkout", "-q", "-b", "feature")
        with self.assertRaisesRegex(release.ReleaseError,
                                    "on branch feature, not master"):
            self.rel().cut("0.9.0", "2026-11-18")
        self.assertEqual(self.rel().cut("0.9.0", "2026-11-18", dry_run=True,
                                        want_branch="feature"), "0.9.0")
        self.git("checkout", "-q", "--detach")
        with self.assertRaisesRegex(release.ReleaseError, "detached"):
            self.rel().cut("0.9.0", "2026-11-18")
        self.git("checkout", "-q", "master")
        for bad in ("2026-13-45", "18.11.2026", "2026-1-1"):
            with self.assertRaisesRegex(release.ReleaseError, "--date"):
                self.rel().cut("0.9.0", bad)
        self.assertEqual(self.tags(), [])

    def test_unreleased_found_at_a_line_start_only(self):
        text = ("# Changelog\n\nWrite under ## [Unreleased] as you go.\n\n"
                "## [Unreleased]\n\n- New.\n")
        out = release.cut_changelog(text, "1.0.0", "2026-11-18")
        self.assertIn("Write under ## [Unreleased] as you go.", out)
        self.assertEqual(release.section(out, "1.0.0"), "- New.")

    def test_dry_run_writes_nothing(self):
        head = self.git("rev-parse", "HEAD")
        self.assertEqual(self.rel().cut("minor", "2026-11-18", dry_run=True),
                         "0.10.0")
        self.assertEqual(self.git("rev-parse", "HEAD"), head)
        self.assertEqual(self.git("status", "--porcelain"), "")
        self.assertEqual(self.tags(), [])
        self.assertEqual(self.built, [])
        out = self.output()
        self.assertIn("dry run: nothing written", out)
        self.assertIn("notes:\n### Added\n- New thing.", out)

    def add_remote(self, name="github"):
        bare = os.path.join(self.tmp.name, name + ".git")
        self.git("init", "-q", "--bare", bare, root=self.tmp.name)
        self.git("remote", "add", name, bare)
        return bare

    def test_with_a_remote_pushes_and_creates_the_release(self):
        bare = self.add_remote()
        self.rel().cut("0.9.0", "2026-11-18")
        self.assertEqual([c[:3] for c in self.cmds], [
            ["git", "push", "github"], ["git", "push", "github"],
            ["gh", "release", "create"]])
        # only the new tag, never --tags
        self.assertEqual(self.cmds[1][3], "refs/tags/v0.9.0")
        # a bare path is no GitHub URL: gh is given no --repo
        self.assertNotIn("--repo", self.cmds[2])
        gh = self.cmds[2]
        self.assertEqual(gh[3], "v0.9.0")
        self.assertTrue(gh[4].endswith("m_x-v0.9.0.zip"))
        self.assertIn("--verify-tag", gh)
        self.assertEqual(gh[gh.index("--notes") + 1],
                         "### Added\n- New thing.\n\n### Fixed\n- Old bug.")
        self.assertEqual(gh[gh.index("--title") + 1],
                         "Cursor Altitude Tooltip v0.9.0")
        self.assertEqual(self.git("tag", "--list", root=bare).split(),
                         ["v0.9.0"])
        self.assertEqual(self.git("rev-parse", "master", root=bare),
                         self.git("rev-parse", "HEAD"))

    def test_wrapped_items_go_to_github_on_one_line(self):
        self.add_remote()
        path = os.path.join(self.root, release.CHANGELOG)
        write(path, read(path).replace("- New thing.",
                                       "- New thing,\n  wrapped."))
        self.git("commit", "-q", "-am", "wrap")
        self.rel().cut("0.9.0", "2026-11-18")
        gh = self.cmds[2]
        self.assertEqual(gh[gh.index("--notes") + 1],
                         "### Added\n- New thing, wrapped.\n\n### Fixed\n"
                         "- Old bug.")
        # the file itself keeps its wrapping
        self.assertIn("- New thing,\n  wrapped.", read(path))

    def test_a_failed_push_after_the_tag_says_how_to_go_on(self):
        self.add_remote()

        def failing(cmd, root):
            raise release.ReleaseError("git push github failed: rejected")
        rel = self.rel()
        rel.run = failing
        with self.assertRaisesRegex(release.ReleaseError,
                                    "(?s)rejected.*committed and tagged.*"
                                    "--github-only"):
            rel.cut("0.9.0", "2026-11-18")
        self.assertEqual(self.tags(), ["v0.9.0"])

    def test_origin_is_not_the_default_remote(self):
        # origin of the development copy is the game's checkout, not GitHub
        origin = self.add_remote("origin")
        self.rel().cut("0.9.0", "2026-11-18")
        self.assertEqual(self.cmds, [])
        self.assertIn("no git remote 'github'", self.output())
        self.assertEqual(self.git("tag", "--list", root=origin), "")

    def test_gh_gets_the_repository_of_a_github_remote(self):
        steps = release.github_steps(
            "1.0.0", "notes", "dist/m-v1.0.0.zip", "github", "master",
            release.github_repo("https://github.com/o/r.git"))
        gh = steps[-1]
        self.assertEqual(gh[gh.index("--repo") + 1], "o/r")
        self.assertEqual(steps[0], ["git", "push", "github",
                                    "HEAD:refs/heads/master"])

    def test_local_only_and_missing_gh(self):
        self.add_remote()
        self.rel().cut("0.9.0", "2026-11-18", local_only=True)
        self.assertEqual(self.cmds, [])
        self.assertIn("stopped before GitHub (--local-only)", self.output())
        self.which = lambda name: None
        with self.assertRaisesRegex(release.ReleaseError, "gh is not"):
            self.rel().github_only()

    def test_github_only_for_the_tag_at_head(self):
        with self.assertRaisesRegex(release.ReleaseError, "no tag v0.9.0"):
            self.rel().github_only()
        self.rel().cut("0.9.0", "2026-11-18")
        # no remote yet: rebuilds the zip and lists what it did not do
        self.built.clear()
        self.rel().github_only()
        self.assertEqual(self.cmds, [])
        self.assertEqual(len(self.built), 1)
        self.assertIn("stopped before GitHub (no git remote 'github')",
                      self.output())
        bare = self.add_remote()
        self.rel().github_only(dry_run=True)
        self.assertEqual(self.cmds, [])
        self.assertIn("would then run", self.output())
        self.assertTrue(self.output().endswith(
            "notes:\n### Added\n- New thing.\n\n### Fixed\n- Old bug."))
        # a detached checkout of the tag: only the tag goes up
        self.git("checkout", "-q", "--detach", "v0.9.0")
        self.rel().github_only()
        self.assertEqual([c[:2] + c[3:4] for c in self.cmds],
                         [["git", "push", "refs/tags/v0.9.0"],
                          ["gh", "release", "v0.9.0"]])
        self.assertEqual(self.git("tag", "--list", root=bare).split(),
                         ["v0.9.0"])
        self.git("checkout", "-q", "master")
        write(os.path.join(self.root, "y.txt"), "y")
        self.git("add", "y.txt")
        self.git("commit", "-q", "-m", "after")
        with self.assertRaisesRegex(release.ReleaseError, "HEAD is not at"):
            self.rel().github_only()


def copy_head(repo, dest):
    """Writes repo's HEAD commit (not its working tree) into dest.

    The release tools run these tests in the middle of a cut, after the
    changelog and the version file are rewritten: a copy of the working
    tree would then have an empty Unreleased section and fail the cut it
    tries. What must hold is that the committed state can be cut.
    git archive honours export-ignore in .gitattributes: a path marked so
    would be missing from the copy."""
    os.makedirs(dest)
    archive = subprocess.Popen(["git", "archive", "--format=tar", "HEAD"],
                               cwd=repo, stdout=subprocess.PIPE)
    try:
        subprocess.run(["tar", "-x", "-C", dest], stdin=archive.stdout,
                       check=True, capture_output=True)
    finally:
        archive.stdout.close()
        if archive.wait() != 0:
            raise subprocess.CalledProcessError(archive.returncode,
                                                "git archive HEAD")


@unittest.skipUnless(shutil.which("git"), "needs git")
class CopyHeadTest(unittest.TestCase):
    def test_copies_the_commit_not_a_changelog_rewritten_mid_release(self):
        # a cut rewrites CHANGELOG.md before it runs the tests; the copy
        # must still hold the committed Unreleased entries
        with tempfile.TemporaryDirectory() as base:
            repo = os.path.join(base, "repo")
            cl = "## [Unreleased]\n### Added\n- a thing\n"
            write(os.path.join(repo, "CHANGELOG.md"), cl)
            env = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull,
                       GIT_CONFIG_NOSYSTEM="1", GIT_AUTHOR_NAME="Test",
                       GIT_AUTHOR_EMAIL="test@example.com",
                       GIT_COMMITTER_NAME="Test",
                       GIT_COMMITTER_EMAIL="test@example.com")
            for cmd in (["init", "-q", "-b", "master"], ["add", "-A"],
                        ["commit", "-q", "-m", "c"]):
                subprocess.run(["git"] + cmd, cwd=repo, check=True,
                               capture_output=True, env=env)
            write(os.path.join(repo, "CHANGELOG.md"),
                  "## [Unreleased]\n\n## [0.9.0] - 2026-11-19\n")
            write(os.path.join(repo, "untracked.txt"), "x")
            dest = os.path.join(base, "copy")
            copy_head(repo, dest)
            self.assertEqual(read(os.path.join(dest, "CHANGELOG.md")), cl)
            self.assertEqual(sorted(os.listdir(dest)), ["CHANGELOG.md"])


@unittest.skipUnless(shutil.which("luajit") and shutil.which("git")
                     and os.path.exists(os.path.join(REPO, ".git")),
                     "needs luajit and a git checkout")
class RealTreeTest(unittest.TestCase):
    """A release cut on a copy of this repository with the real Lua tests:
    the version, the revision and the changelog must still agree once a
    version's section exists. Before the first release the current version
    is cut; after it (the changelog has its section) a patch with a stand-in
    entry. Whether it is released is read from the changelog, not the tags:
    a copy pulled without tags (the one in local/mods) must pass too."""

    def test_cutting_the_current_version_keeps_the_tree_consistent(self):
        if subprocess.run(["git", "cat-file", "-e", "HEAD:VERSION"],
                          cwd=REPO, capture_output=True).returncode != 0:
            # the commit that brings in VERSION runs these tests before it
            # exists in HEAD; every later commit has it
            self.skipTest("HEAD has no VERSION yet")
        with tempfile.TemporaryDirectory() as base:
            root = os.path.join(base, "repo")
            copy_head(REPO, root)
            gitconfig = os.path.join(base, "gitconfig")
            write(gitconfig, "")
            env = dict(os.environ, GIT_CONFIG_GLOBAL=gitconfig,
                       GIT_CONFIG_NOSYSTEM="1", GIT_AUTHOR_NAME="Test",
                       GIT_AUTHOR_EMAIL="test@example.com",
                       GIT_COMMITTER_NAME="Test",
                       GIT_COMMITTER_EMAIL="test@example.com")
            with mock.patch.dict(os.environ, env):
                for cmd in (["init", "-q", "-b", "master"], ["add", "-A"],
                            ["commit", "-q", "-m", "copy"]):
                    subprocess.run(["git"] + cmd, cwd=root, check=True,
                                   capture_output=True)
                version = release.read_version(root)
                cl_path = os.path.join(root, release.CHANGELOG)
                cl = read(cl_path)
                if release.section(cl, version) is not None:
                    write(cl_path, cl.replace(
                        release.UNRELEASED,
                        release.UNRELEASED + "\n\n- Stand-in entry.", 1))
                    subprocess.run(["git", "commit", "-q", "-am", "entry"],
                                   cwd=root, check=True, capture_output=True)
                    spec = "patch"
                    want = release.bump(version, "patch")
                else:
                    spec = want = version

                def lua_tests(r):
                    # not the tool tests: they would run this test again
                    p = subprocess.run(["luajit", "tests/run.lua"], cwd=r,
                                       capture_output=True, text=True)
                    if p.returncode != 0:
                        raise release.ReleaseError(p.stdout + p.stderr)
                    problems = release.consistency(r)
                    if problems:
                        raise release.ReleaseError("\n".join(problems))
                    return []
                lines = []
                rel = release.Release(root, out=lines.append,
                                      checks=lua_tests,
                                      build=lambda r, o: None,
                                      run=lambda c, r: None)
                self.assertEqual(rel.cut(spec, "2026-11-18"), want)
                self.assertEqual(subprocess.run(
                    ["git", "tag", "--list"], cwd=root, capture_output=True,
                    text=True).stdout.split(), ["v" + want])
                self.assertEqual(release.consistency(root), [])
                self.assertEqual(release.read_revision(root),
                                 release.revision_of(want))


if __name__ == "__main__":
    unittest.main()
