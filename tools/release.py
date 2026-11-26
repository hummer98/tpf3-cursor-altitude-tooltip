#!/usr/bin/env python3
"""Cuts a release: version, changelog, commit, tag vX.Y.Z, GitHub release.

The version lives in VERSION (one line, MAJOR.MINOR.PATCH). mod.json's
revision is MAJOR * 10000 + MINOR * 100 + PATCH (1.0.0 -> 10000); this tool
writes both, and tests/test_release.py fails when they disagree. A release:

1. checks that the working tree is committed, the new version is above the
   current one and every existing vX.Y.Z tag (the current one itself is
   allowed while it has no tag: the first release), and that CHANGELOG.md's
   Unreleased section has entries;
2. writes VERSION and mod.json's revision, turns Unreleased into
   "## [X.Y.Z] - <date>" (a new, empty Unreleased above it), then runs the
   same checks as tools/package.py (the JSON files, the cover, the Lua
   tests, the tool tests); on a failure every file it wrote is put back
   and nothing is committed;
3. commits those files ("Release vX.Y.Z") and makes the annotated tag;
4. builds dist/<modId>-vX.Y.Z.zip (tools/package.py's zip);
5. with a remote (github by default: origin of the development copy is the
   game's local/mods checkout, not GitHub): pushes the branch and the tag,
   then `gh release create vX.Y.Z` with the changelog section as the notes
   and the zip attached. Without the remote, or with --local-only, it stops
   after the zip and says what it did not do; `--github-only` later does
   step 5 for the tag at HEAD (pushing the tag only).

Only the new tag is pushed, never --tags. Cut on master only (--branch to
change): a work branch's name would go to the public remote. Run it in a
checkout the game does not load: it rewrites files and the game must not
see them change while it runs.

The commit's author is git's own (user.name / user.email, or the
GIT_AUTHOR_* and GIT_COMMITTER_* variables); this tool sets none.
mod.io is updated separately, in game (tools/stage.py, docs/release.md).

Usage (from anywhere):
  python3 tools/release.py patch|minor|major|X.Y.Z [--date YYYY-MM-DD]
                           [--dry-run] [--local-only] [--remote NAME]
                           [--branch NAME]
  python3 tools/release.py --github-only [--dry-run] [--remote NAME]
"""
import argparse
import datetime
import json
import os
import re
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import package  # noqa: E402

ROOT = package.ROOT
# outside content/: the mod shows no version and logs only failures, so the
# game has no use for it; only mod.json's revision reaches it
VERSION_FILE = "VERSION"
MOD_JSON = "mod.json"
CHANGELOG = "CHANGELOG.md"
TITLE = "Cursor Altitude, Distance & Incline Tooltip"
DEFAULT_REMOTE = "github"
# no leading zeros, no suffix, minor and patch below 100, so the revision
# grows with the version (tools/stage.py wants a higher one per upload)
VERSION_RE = re.compile(r"^(0|[1-9]\d{0,2})\.(0|[1-9]\d?)\.(0|[1-9]\d?)$")
# rewritten in place, so mod.json keeps its tabs and key order
REVISION_RE = re.compile(r'("revision"\s*:\s*)(-?\d+)')
GITHUB_RE = re.compile(r"github\.com[:/]([\w.-]+/[\w.-]+?)(?:\.git)?/?$")
HEADING_RE = re.compile(r"^## \[([^\]]+)\]", re.M)
UNRELEASED = "## [Unreleased]"


class ReleaseError(Exception):
    pass


def parse_version(text):
    m = VERSION_RE.match(text or "")
    if not m:
        raise ReleaseError("%r is not MAJOR.MINOR.PATCH (minor and patch "
                           "below 100, no leading zeros)" % (text,))
    return tuple(int(g) for g in m.groups())


def fmt(v):
    return "%d.%d.%d" % v


def bump(current, spec):
    """The version after current (a string) for spec: patch, minor, major
    or an explicit MAJOR.MINOR.PATCH (checked against current elsewhere)."""
    a, b, c = parse_version(current)
    if spec == "patch":
        return fmt((a, b, c + 1)) if c < 99 else _overflow(spec)
    if spec == "minor":
        return fmt((a, b + 1, 0)) if b < 99 else _overflow(spec)
    if spec == "major":
        return fmt((a + 1, 0, 0))
    return fmt(parse_version(spec))


def _overflow(spec):
    raise ReleaseError("%s would go above 99: raise the next part instead"
                       % spec)


def revision_of(version):
    """mod.json's revision for a version: 1.0.0 -> 10000, 1.2.3 -> 10203."""
    a, b, c = parse_version(version)
    return a * 10000 + b * 100 + c


def read_version(root):
    try:
        with open(os.path.join(root, VERSION_FILE), encoding="utf-8") as f:
            text = f.read()
    except OSError as e:
        raise ReleaseError("%s: %s" % (VERSION_FILE, e))
    v = text.strip()
    if "\n" in v:
        raise ReleaseError("%s holds one line, X.Y.Z" % VERSION_FILE)
    parse_version(v)
    return v


def read_revision(root):
    try:
        with open(os.path.join(root, MOD_JSON), encoding="utf-8") as f:
            rev = json.load(f).get("revision")
    except (OSError, ValueError, AttributeError) as e:
        raise ReleaseError("%s: %s" % (MOD_JSON, e))
    if not isinstance(rev, int) or isinstance(rev, bool):
        raise ReleaseError("%s: revision is not an integer" % MOD_JSON)
    return rev


def revision_text(text, version):
    """mod.json's text with the revision of version; nothing else moves."""
    if len(REVISION_RE.findall(text)) != 1:
        raise ReleaseError('%s needs exactly one "revision"' % MOD_JSON)
    return REVISION_RE.sub(lambda m: m.group(1) + str(revision_of(version)),
                           text, count=1)


def _sections(text):
    """[(name, start of heading, start of body)] of the "## [..]" headings."""
    return [(m.group(1), m.start(), m.end()) for m in HEADING_RE.finditer(text)]


def section(text, name):
    """The body of "## [name]" up to the next "## [" heading, stripped;
    None when there is no such section."""
    secs = _sections(text)
    for i, (n, _, body) in enumerate(secs):
        if n == name:
            end = secs[i + 1][1] if i + 1 < len(secs) else len(text)
            # drop the rest of the heading line (" - 2026-11-18")
            nl = text.find("\n", body)
            start = end if nl < 0 or nl > end else nl + 1
            return text[start:end].strip()
    return None


def released_versions(text):
    """The versions of the "## [X.Y.Z]" headings, topmost (newest) first."""
    out = []
    for name, _, _ in _sections(text):
        try:
            parse_version(name)
        except ReleaseError:
            continue
        out.append(name)
    return out


def unwrap(body):
    """The changelog's list items on one line each: the file is wrapped at
    about 76 columns, and a GitHub release (like the mod.io change log)
    shows each line break as one. Headings, blank lines and new items stay
    where they are; an indented line continues the item above it."""
    out = []
    for line in body.splitlines():
        cont = (line[:1] in (" ", "\t") and line.strip() and out
                and out[-1].strip() and not out[-1].startswith("#")
                and not re.match(r"^(?:[-*+]|\d+\.)\s", line.strip()))
        if cont:
            out[-1] = out[-1].rstrip() + " " + line.strip()
        else:
            out.append(line)
    return "\n".join(out)


def has_entries(body):
    """Anything besides blank lines and "### Added" style headings."""
    return any(l.strip() and not l.lstrip().startswith("###")
               for l in (body or "").splitlines())


def cut_changelog(text, version, date):
    """Unreleased becomes "## [version] - date", with a new empty
    Unreleased above it."""
    body = section(text, "Unreleased")
    if body is None:
        raise ReleaseError("%s has no %s section" % (CHANGELOG, UNRELEASED))
    if not has_entries(body):
        raise ReleaseError("%s: the Unreleased section is empty; write what "
                           "changed first" % CHANGELOG)
    if section(text, version) is not None:
        raise ReleaseError("%s already has a [%s] section" % (CHANGELOG,
                                                              version))
    # at a line start, as section() reads it (not a mention in the intro)
    i = re.search(r"^" + re.escape(UNRELEASED) + r"[ \t]*$", text, re.M).start()
    head = text[:i]
    rest = text[i + len(UNRELEASED):]
    return head + UNRELEASED + "\n\n## [%s] - %s" % (version, date) + rest


def consistency(root):
    """What makes VERSION, mod.json and CHANGELOG.md disagree: a revision
    that is not the version's, or a newest changelog section other than the
    version (bumped by hand instead of by this tool). Empty when they
    agree; before the first release there is no section to compare."""
    version = read_version(root)
    problems = []
    rev = read_revision(root)
    if rev != revision_of(version):
        problems.append("%s revision %d is not %d, the revision of %s %s"
                        % (MOD_JSON, rev, revision_of(version), VERSION_FILE,
                           version))
    try:
        with open(os.path.join(root, CHANGELOG), encoding="utf-8") as f:
            cl = f.read()
    except OSError as e:
        return problems + ["%s: %s" % (CHANGELOG, e)]
    if section(cl, "Unreleased") is None:
        problems.append("%s has no %s section" % (CHANGELOG, UNRELEASED))
    released = released_versions(cl)
    if released and released[0] != version:
        problems.append("%s's newest section is [%s] but %s is %s"
                        % (CHANGELOG, released[0], VERSION_FILE, version))
    return problems


def git(root, *args, check=True):
    try:
        r = subprocess.run(["git"] + list(args), cwd=root,
                           capture_output=True, text=True)
    except OSError as e:
        raise ReleaseError("cannot run git: %s" % e)
    if check and r.returncode != 0:
        raise ReleaseError("git %s: %s" % (" ".join(args),
                                           (r.stderr or r.stdout).strip()))
    return r


def tag_versions(root):
    out = git(root, "tag", "--list", "v*").stdout.split()
    vs = []
    for t in out:
        try:
            vs.append(parse_version(t[1:]))
        except ReleaseError:
            pass
    return sorted(vs)


def remote_url(root, remote):
    r = git(root, "remote", "get-url", remote, check=False)
    return r.stdout.strip() if r.returncode == 0 else None


def github_repo(url):
    """owner/name of a GitHub remote URL; None for any other URL."""
    m = GITHUB_RE.search(url or "")
    return m.group(1) if m else None


def new_version(root, spec):
    """(current, new) after the checks on the version and the tags."""
    current = read_version(root)
    new = bump(current, spec)
    tags = tag_versions(root)
    if "v" + new in git(root, "tag", "--list", "v" + new).stdout.split():
        raise ReleaseError("tag v%s already exists" % new)
    if parse_version(new) < parse_version(current):
        raise ReleaseError("%s is below the current version %s"
                           % (new, current))
    if tags and parse_version(new) <= tags[-1]:
        raise ReleaseError("%s is not above the newest tag v%s"
                           % (new, fmt(tags[-1])))
    return current, new


def default_checks(root):
    """tools/package.py's checks (JSON files, cover, Lua tests, tool
    tests); returns the lines to print, raises ReleaseError."""
    try:
        return package.check(root)
    except package.PreflightError as e:
        raise ReleaseError(str(e))


def zip_path(root, version):
    """dist/<modId>-vX.Y.Z.zip: named by the modId, not the checkout's
    folder (a second checkout has another folder name)."""
    try:
        with open(os.path.join(root, MOD_JSON), encoding="utf-8") as f:
            mod_id = json.load(f).get("modId")
    except (OSError, ValueError, AttributeError) as e:
        raise ReleaseError("%s: %s" % (MOD_JSON, e))
    if not isinstance(mod_id, str) or not re.match(r"^\w+$", mod_id):
        raise ReleaseError("%s has no usable modId" % MOD_JSON)
    return os.path.join(root, "dist", "%s-v%s.zip" % (mod_id, version))


def default_build(root, out):
    os.makedirs(os.path.dirname(out), exist_ok=True)
    package.build(root, out)


def run_cmd(cmd, root):
    r = subprocess.run(cmd, cwd=root, capture_output=True, text=True)
    if r.returncode != 0:
        raise ReleaseError("%s failed: %s" % (" ".join(cmd[:3]),
                                              (r.stderr or r.stdout).strip()))
    return r


def github_steps(version, notes, asset, remote, branch, repo=None):
    """The commands of step 5, in order; branch None pushes the tag only.
    repo (owner/name) is given to gh, which would otherwise pick a
    repository from the remotes by itself."""
    tag = "v" + version
    push_branch = ([["git", "push", remote, "HEAD:refs/heads/" + branch]]
                   if branch else [])
    gh = ["gh", "release", "create", tag, asset, "--verify-tag"]
    if repo:
        gh += ["--repo", repo]
    return push_branch + [
        ["git", "push", remote, "refs/tags/" + tag],
        gh + ["--title", "%s %s" % (TITLE, tag), "--notes", notes],
    ]


def show(cmd):
    # the notes are long: show them apart, not inside the command line
    out = []
    skip = False
    for a in cmd:
        if skip:
            out.append("<notes>")
            skip = False
            continue
        out.append(a if re.match(r"^[\w./:@+=-]+$", a) else repr(a))
        skip = a == "--notes"
    return " ".join(out)


class Release:
    """One run; the hooks (checks, build, run, which) are for the tests."""

    def __init__(self, root=ROOT, out=print, checks=default_checks,
                 build=default_build, run=run_cmd, which=shutil.which):
        self.root, self.out = root, out
        self.checks, self.build = checks, build
        self.run, self.which = run, which

    def clean_tree(self):
        dirty = git(self.root, "status", "--porcelain").stdout.strip()
        if dirty:
            raise ReleaseError("uncommitted changes (commit or stash "
                               "first):\n" + dirty)

    def branch(self, want):
        """The checked-out branch, which must be want: a release cut on a
        work branch would push that branch's name to the public remote and
        leave its tag in the repository."""
        b = git(self.root, "symbolic-ref", "--short", "-q", "HEAD",
                check=False).stdout.strip()
        if not b:
            raise ReleaseError("HEAD is detached: check out %s first" % want)
        if b != want:
            raise ReleaseError("on branch %s, not %s: release from %s (or "
                               "pass --branch %s)" % (b, want, want, b))
        return b

    def github_ready(self, remote, local_only):
        """The remote's URL when step 5 will run; None when it stops after
        the zip. Raises when it would run but cannot (no gh)."""
        if local_only:
            return None
        url = remote_url(self.root, remote)
        if url and not self.which("gh"):
            raise ReleaseError("remote %s is set but gh is not installed: "
                               "install it or pass --local-only" % remote)
        return url

    def cut(self, spec, date=None, dry_run=False, local_only=False,
            remote=DEFAULT_REMOTE, want_branch="master"):
        self.clean_tree()
        branch = self.branch(want_branch)
        current, new = new_version(self.root, spec)
        date = date or datetime.date.today().isoformat()
        try:
            ok = (re.match(r"^\d{4}-\d{2}-\d{2}$", date)
                  and datetime.date.fromisoformat(date))
        except ValueError:
            ok = False
        if not ok:
            raise ReleaseError("--date wants a real YYYY-MM-DD, not %r"
                               % date)
        cl_path = os.path.join(self.root, CHANGELOG)
        mj_path = os.path.join(self.root, MOD_JSON)
        try:
            with open(cl_path, encoding="utf-8") as f:
                cl = f.read()
            with open(mj_path, encoding="utf-8") as f:
                mj = f.read()
        except OSError as e:
            raise ReleaseError(str(e))
        new_cl = cut_changelog(cl, new, date)
        new_mj = revision_text(mj, new)
        notes = unwrap(section(new_cl, new))
        url = self.github_ready(remote, local_only)
        tag = "v" + new
        asset = zip_path(self.root, new)
        self.out("release %s -> %s (revision %d) on %s (%s)"
                 % (current, new, revision_of(new), branch, date))
        if dry_run:
            self.out("dry run: nothing written. Would write %s, %s and %s, "
                     "run the tests, commit 'Release %s', tag %s, build %s"
                     % (VERSION_FILE, MOD_JSON, CHANGELOG, tag, tag,
                        os.path.relpath(asset, self.root)))
            self.report_github(new, notes, asset, remote, branch, url,
                               local_only, dry_run=True)
            self.out("notes:\n" + notes)
            return new

        written = [VERSION_FILE, MOD_JSON, CHANGELOG]
        try:
            with open(os.path.join(self.root, VERSION_FILE), "w",
                      encoding="utf-8") as f:
                f.write(new + "\n")
            with open(mj_path, "w", encoding="utf-8") as f:
                f.write(new_mj)
            with open(cl_path, "w", encoding="utf-8") as f:
                f.write(new_cl)
            for line in self.checks(self.root):
                self.out(line)
            git(self.root, "add", "--", *written)
            git(self.root, "commit", "-q", "-m", self.commit_message(new))
        except BaseException:
            # the tree was clean: putting the paths back loses nothing
            git(self.root, "reset", "-q", "--", *written, check=False)
            git(self.root, "checkout", "--", *written, check=False)
            raise
        try:
            git(self.root, "tag", "-a", tag, "-m", "%s %s" % (TITLE, tag))
        except ReleaseError as e:
            # committed already: say how to finish rather than cut again
            raise ReleaseError("%s\ncommitted 'Release %s' but not tagged: "
                               "git tag -a %s -m '%s %s', then python3 "
                               "tools/release.py --github-only"
                               % (e, tag, tag, TITLE, tag))
        self.out("committed and tagged " + tag)
        self.build(self.root, asset)
        self.out("built " + os.path.relpath(asset, self.root))
        self.report_github(new, notes, asset, remote, branch, url,
                           local_only)
        return new

    def commit_message(self, version):
        return ("Release v%s\n\nThe version, mod.json's revision and the "
                "changelog section move\ntogether, so tag v%s, the GitHub "
                "release and the mod.io upload\npoint at the same state."
                % (version, version))

    def report_github(self, version, notes, asset, remote, branch, url,
                      local_only, dry_run=False):
        steps = github_steps(version, notes, asset, remote, branch,
                             github_repo(url))
        if url is None:
            why = ("--local-only" if local_only
                   else "no git remote %r" % remote)
            self.out("stopped before GitHub (%s). Not done:" % why)
            for cmd in steps:
                self.out("  " + show(cmd))
            self.out("When the remote exists: python3 tools/release.py "
                     "--github-only (with HEAD at v%s)" % version)
            return
        if dry_run:
            self.out("would then run (remote %s = %s):" % (remote, url))
            for cmd in steps:
                self.out("  " + show(cmd))
            return
        for cmd in steps:
            self.out("+ " + show(cmd))
            try:
                r = self.run(cmd, self.root)
            except ReleaseError as e:
                # tagged already: cutting again would refuse the version
                raise ReleaseError(
                    "%s\nv%s is committed and tagged; fix the cause (a "
                    "GitHub master ahead of this one, a missing login), "
                    "then python3 tools/release.py --github-only with HEAD "
                    "at v%s (it pushes the tag and creates the release; "
                    "push the branch with git push %s HEAD:master)"
                    % (e, version, version, remote))
            if r is not None and getattr(r, "stdout", "").strip():
                self.out(r.stdout.strip())
        self.out("GitHub release v%s created" % version)

    def github_only(self, dry_run=False, remote=DEFAULT_REMOTE):
        """Step 5 for a release already cut: HEAD must be at the tag of the
        current version (a detached checkout of the tag is fine: only the
        tag is pushed, the branch goes up with plain git push). Without the
        remote it stops after rebuilding the zip."""
        self.clean_tree()
        branch = None
        version = read_version(self.root)
        tag = "v" + version
        r = git(self.root, "rev-parse", "-q", "--verify",
                "refs/tags/%s^{commit}" % tag, check=False)
        if r.returncode != 0:
            raise ReleaseError("no tag %s: cut the release first" % tag)
        head = git(self.root, "rev-parse", "HEAD").stdout.strip()
        if r.stdout.strip() != head:
            raise ReleaseError("HEAD is not at %s: check out the tagged "
                               "commit's branch state first" % tag)
        with open(os.path.join(self.root, CHANGELOG), encoding="utf-8") as f:
            notes = section(f.read(), version)
        if not notes:
            raise ReleaseError("%s has no [%s] section" % (CHANGELOG, version))
        notes = unwrap(notes)
        url = self.github_ready(remote, False)
        asset = zip_path(self.root, version)
        if not dry_run:
            self.build(self.root, asset)
            self.out("built " + os.path.relpath(asset, self.root))
        self.report_github(version, notes, asset, remote, branch, url, False,
                           dry_run=dry_run)
        if dry_run:
            # the text for the mod.io change log, as the release shows it
            self.out("notes:\n" + notes)
        return version


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("level", nargs="?",
                    help="patch, minor, major or MAJOR.MINOR.PATCH")
    ap.add_argument("--date", help="release date (default: today)")
    ap.add_argument("--dry-run", action="store_true",
                    help="check and show the plan, change nothing")
    ap.add_argument("--local-only", action="store_true",
                    help="stop after the tag and the zip even with a remote")
    ap.add_argument("--github-only", action="store_true",
                    help="push and create the GitHub release for the tag at "
                    "HEAD")
    ap.add_argument("--remote", default=DEFAULT_REMOTE,
                    help="the GitHub remote (default %s)" % DEFAULT_REMOTE)
    ap.add_argument("--branch", default="master",
                    help="the branch a release is cut on (default master)")
    args = ap.parse_args(argv)
    if bool(args.level) == bool(args.github_only):
        ap.error("give a level (patch, minor, major, X.Y.Z) or --github-only")
    rel = Release()
    try:
        if args.github_only:
            rel.github_only(args.dry_run, args.remote)
        else:
            rel.cut(args.level, args.date, args.dry_run, args.local_only,
                    args.remote, args.branch)
    except ReleaseError as e:
        sys.exit("release: %s" % e)


if __name__ == "__main__":
    main()
