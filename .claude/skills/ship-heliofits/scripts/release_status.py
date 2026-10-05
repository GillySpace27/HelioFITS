#!/usr/bin/env python3
"""Render the ship-heliofits progress tracker from VERIFIED state.

Checks git, GitHub and the App Store Connect API directly rather than
trusting what an earlier turn claimed to have done -- the same discipline
that caught the stale-libcfitsio.a bug in 1.3.0. The first five milestones
(preflight/version/tests/changelog/tag-created) are inherently about this
session's own actions and can't be re-derived from outside state, so they
are passed in by the caller; everything from "tag pushed" onward is checked
live.

The "version" milestone is the exception: it is read from Config/Version.xcconfig
(the one mac version source, HF-10), so --done version is ignored.

Usage: python3 release_status.py [<VERSION> <BUILD>] [--done preflight,tests,changelog]
  With no VERSION, follows the release Config/Version.xcconfig names, and derives
  preflight, tests and changelog from the tag and CHANGELOG.md (suite SU-5), so
  the Orrery registry needs neither a pinned version nor --done.
  python3 release_status.py 1.3.1 8 --done preflight,tests,changelog
"""
import sys, os, re, json, shutil, subprocess, argparse, datetime, tempfile

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
APP_ID = "6790952544"
ASC_API = os.path.join(os.path.dirname(os.path.abspath(__file__)), "asc_api.py")
# The repo root is four levels above this scripts/ folder. (REPO above stops at .claude/,
# which git tolerates as a cwd; this path must not depend on it.)
XCCONFIG = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                         "..", "..", "..", "..", "Config", "Version.xcconfig"))

MILESTONES = [
    ("preflight",   "Pre-flight (clean tree, library rebuilt if shim changed)"),
    ("version",     "Version bumped in all targets"),
    ("tests",       "Tests passing"),
    ("changelog",   "CHANGELOG.md written"),
    ("tag",         "Tagged"),
    ("tag_pushed",  "Tag pushed to origin"),
    ("gh_release",  "GitHub release published"),
    ("asc_version", "App Store version record created"),
    ("asc_build",   "Build attached to version"),
    ("asc_notes",   "What's New set"),
    ("asc_shots",   "Screenshots attached"),
    ("submitted",   "Submitted for Review"),
    ("released",    "Released to users"),
]

# What each step actually takes. A tracker that names a step without saying how
# to do it is a to-do list you have to translate every time; {V} and {B} are
# filled with the version and build.
#
# `shell` steps need a real session — the Orrery has no shell by design.
# `api` steps are ASC writes the Orrery itself can perform.
HOW = {
    "preflight":   ("shell", "./HelioFITSExtension/cfitsio/build-universal.sh   # only if fitsshim.c changed"),
    "version":     ("shell", "scripts/bump-version.sh {V} {B}   # edits Config/Version.xcconfig, then checks every mac target resolved it"),
    "tests":       ("shell", "pkill -x HelioFITS; xcodebuild test -project HelioFITS.xcodeproj -scheme HelioFITS -destination 'platform=macOS,arch=arm64' DEVELOPMENT_TEAM=UB45PPC2JS CODE_SIGN_IDENTITY=\"-\" CODE_SIGN_STYLE=Manual AD_HOC_CODE_SIGNING_ALLOWED=YES"),
    "changelog":   ("edit",  "Write the [{V}] section in CHANGELOG.md — long form, grouped Added/Changed/Fixed, issues linked."),
    "tag":         ("shell", "git tag -a v{V}-build.{B} -m \"{V} (build {B})\""),
    "tag_pushed":  ("shell", "git push && git push origin v{V}-build.{B}"),
    "gh_release":  ("shell", "./ship.sh   # then: gh release create v{V}-build.{B} build/HelioFITS-{V}-b{B}.zip --title \"HelioFITS {V} (build {B})\" --notes-file <notes>"),
    "asc_version": ("api",   "Create the {V} version record in App Store Connect."),
    "asc_build":   ("api",   "Attach build {B} to the {V} version record."),
    "asc_notes":   ("api",   "Set What's New — the SHORT form, one headline sentence per fix."),
    "asc_shots":   ("edit",  "Drag the shots from screenshots/{V}/ (make-screenshots.sh) into Media Manager "
                             "(App Store Connect ▸ the {V} version ▸ App Previews and Screenshots). "
                             "The API key is read-only for media, so this one is hands."),
    "submitted":   ("gate",  "Submit build {B} of {V} for App Review. Never without Gilly saying so, this run."),
    "released":    ("gate",  "Release {V} to users. Never without Gilly saying so, this run."),
}

def shots_verdict(states):
    """(ok, note) from the delivery state of every attached screenshot.

    Zero attached is a fail; anything still uploading is a fail; a count that
    is merely smaller than the local folder is NOT, because dropping a shot is
    a real editorial choice and a permanently red check gets ignored."""
    done = [x for x in states if x == "COMPLETE"]
    if not states:
        return False, None
    note = f"{len(done)} delivered"
    if len(done) != len(states):
        note += f", {len(states) - len(done)} not yet"
    return len(done) == len(states), note


def xcconfig_version(path=XCCONFIG):
    """(MARKETING_VERSION, CURRENT_PROJECT_VERSION) from Config/Version.xcconfig, or
    None when the file is missing or does not hold exactly one line of each."""
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except OSError:
        return None
    ver = re.findall(r"^MARKETING_VERSION = (\S+)$", text, re.M)
    build = re.findall(r"^CURRENT_PROJECT_VERSION = (\S+)$", text, re.M)
    if len(ver) != 1 or len(build) != 1:
        return None
    return ver[0], build[0]


def _selftest():
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "Version.xcconfig")
        assert xcconfig_version(p) is None
        with open(p, "w") as f:
            f.write("// comment\nMARKETING_VERSION = 1.4.1\nCURRENT_PROJECT_VERSION = 11\n")
        assert xcconfig_version(p) == ("1.4.1", "11")
        with open(p, "a") as f:
            f.write("MARKETING_VERSION = 9.9\n")
        assert xcconfig_version(p) is None
    assert shots_verdict([]) == (False, None)
    assert shots_verdict(["COMPLETE"] * 5) == (True, "5 delivered")
    assert shots_verdict(["COMPLETE", "AWAITING_UPLOAD"]) == (False, "1 delivered, 1 not yet")
    print("selftest ok")


def sh(cmd):
    """Run a command in the repo, returning "" if its binary is missing.

    launchd does not inherit a login shell's PATH. The Orrery agent runs with
    /usr/bin:/bin:/usr/sbin:/sbin, which has git but not gh (/opt/homebrew/bin),
    so `gh release view` raised FileNotFoundError straight out of check_live and
    killed the tracker before it could emit. The card then sat at a two-hour-old
    13/13 that looked finished rather than saying it had failed to check. One
    absent tool must cost one milestone, never the whole run. 2026-08-23."""
    try:
        return subprocess.run(cmd, cwd=REPO, capture_output=True, text=True).stdout.strip()
    except FileNotFoundError:
        MISSING.add(cmd[0])
        return ""


MISSING = set()   # binaries this run could not find, reported rather than hidden
TOOL_DIRS = ("/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin")


def find_tool(name):
    """Absolute path to a CLI, so launchd's bare PATH cannot hide it (2026-08-23).

    Falls back to the bare name; a missing binary is then recorded in MISSING."""
    found = shutil.which(name)
    if found:
        return found
    for d in TOOL_DIRS:
        p = os.path.join(d, name)
        if os.access(p, os.X_OK):
            return p
    return name


def target_release(xc):
    """(version, build) to follow when none is given: the xcconfig's pair (HF-10:
    scripts/bump-version.sh sets both before the tag), or ("", "") when unreadable."""
    return xc if xc else ("", "")


def derive_local(version, changelog_text, tag_exists):
    """Session-only milestones re-derived from outside state (suite SU-5).

    RELEASING.md tags (step 5) only after a clean tree, the tests and the changelog
    (steps 1, 3, 4), so an existing tag for this release counts for preflight and
    tests. The changelog milestone needs a "## [<version>]" heading."""
    numeric = bool(re.match(r"^[0-9][0-9.]*$", version or ""))
    heading = numeric and re.search(r"^## \[" + re.escape(version) + r"\]", changelog_text, re.M)
    return {"preflight": bool(tag_exists), "tests": bool(tag_exists), "changelog": bool(heading)}


def asc_get(path):
    out = subprocess.run([sys.executable, ASC_API, "GET", path], capture_output=True, text=True).stdout
    status_line, _, body = out.partition("\n")
    if not status_line.startswith("HTTP 200"):
        return None
    return json.loads(body)

def check_live(version, build):
    tag = f"v{version}-build.{build}"
    state = {}

    got = xcconfig_version()
    state["version"] = got == (version, build)
    if got is None:
        state["_notes"] = {**state.get("_notes", {}), "version": "Config/Version.xcconfig missing or malformed"}
    elif not state["version"]:
        state["_notes"] = {**state.get("_notes", {}), "version": "xcconfig says %s (%s)" % got}

    tags_local = sh(["git", "tag", "-l", tag])
    state["tag"] = tag in tags_local.splitlines()

    tags_remote = sh(["git", "ls-remote", "--tags", "origin", tag])
    state["tag_pushed"] = bool(tags_remote.strip())

    try:
        gh_out = subprocess.run([find_tool("gh"), "release", "view", tag, "--json", "url"],
                                 cwd=REPO, capture_output=True, text=True)
        state["gh_release"] = gh_out.returncode == 0
    except FileNotFoundError:
        MISSING.add("gh")
        state["gh_release"] = False

    versions = asc_get(f"/v1/apps/{APP_ID}/appStoreVersions"
                        f"?filter[versionString]={version}&filter[platform]=MAC_OS"
                        f"&fields[appStoreVersions]=versionString,appStoreState")
    v = None
    if versions and versions.get("data"):
        v = versions["data"][0]
    state["asc_version"] = v is not None
    version_id = v["id"] if v else None
    app_store_state = v["attributes"]["appStoreState"] if v else None

    state["asc_build"] = False
    if version_id:
        b = asc_get(f"/v1/appStoreVersions/{version_id}/build?fields[builds]=version")
        state["asc_build"] = bool(b and b.get("data"))

    state["asc_notes"] = False
    if version_id:
        locs = asc_get(f"/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations"
                        f"?filter[locale]=en-US&fields[appStoreVersionLocalizations]=whatsNew")
        if locs and locs.get("data"):
            wn = locs["data"][0]["attributes"].get("whatsNew")
            state["asc_notes"] = bool(wn and wn.strip())

    # Screenshots. Deliberately NOT compared against the local folder: Gilly
    # drops a shot on purpose sometimes, and a check that reads "5 of 6" forever
    # is a check you learn to ignore. What actually breaks a submission is zero
    # screenshots, or one stuck mid-upload, so those are the only failures.
    state["asc_shots"] = False
    if version_id:
        shots = []
        locs = asc_get(f"/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations"
                        f"?filter[locale]=en-US")
        for loc in (locs or {}).get("data", []):
            sets = asc_get(f"/v1/appStoreVersionLocalizations/{loc['id']}/appScreenshotSets")
            for st in (sets or {}).get("data", []):
                got = asc_get(f"/v1/appScreenshotSets/{st['id']}/appScreenshots")
                for d in (got or {}).get("data", []):
                    shots.append(d["attributes"].get("assetDeliveryState", {}).get("state"))
        ok, note = shots_verdict(shots)
        state["asc_shots"] = ok
        if note:
            state["_notes"] = {**state.get("_notes", {}), "asc_shots": note}

    submitted_states = {"WAITING_FOR_REVIEW", "IN_REVIEW", "PENDING_APPLE_RELEASE",
                         "PENDING_DEVELOPER_RELEASE", "READY_FOR_SALE", "PROCESSING_FOR_APP_STORE"}
    state["submitted"] = app_store_state in submitted_states
    state["released"] = app_store_state == "READY_FOR_SALE"
    state["_asc_state_raw"] = app_store_state
    if MISSING:
        state["_notes"] = {**state.get("_notes", {}),
                           "gh_release": f"{', '.join(sorted(MISSING))} not on PATH, so this is UNCHECKED, not undone"}
    state["_missing"] = sorted(MISSING)
    return state

def render(version, build, done_flags, live_state):
    combined = {**done_flags, **live_state}
    total = len(MILESTONES)
    done_count = sum(1 for key, _ in MILESTONES if combined.get(key))
    filled = round(20 * done_count / total)
    bar = "█" * filled + "░" * (20 - filled)

    GATED = {"submitted", "released"}
    lines = [f"HelioFITS {version} (build {build}) — release progress",
             f"[{bar}] {done_count}/{total}", ""]
    seen_incomplete = False
    for key, label in MILESTONES:
        ok = combined.get(key)
        if ok:
            mark = "✅"
        elif not seen_incomplete:
            mark = "▶"
            seen_incomplete = True
        else:
            mark = "⬜"
        suffix = "  (gated: needs your go-ahead)" if key in GATED else ""
        note = combined.get("_notes", {}).get(key)
        lines.append(f"{mark} {label}{suffix}" + (f"  ({note})" if note else ""))
        # Show the command for the NEXT step only: printing all twelve would
        # bury the one thing to do now.
        if mark == "▶" and key in HOW:
            kind, how = HOW[key]
            lines.append(f"      {kind}: {how.format(V=version, B=build)}")
    raw = combined.get("_asc_state_raw")
    if raw:
        lines.append("")
        lines.append(f"(App Store Connect appStoreState: {raw})")
    return "\n".join(lines)

FEED_PRODUCT = "heliofits"
APP_STORE_URL = "https://apps.apple.com/app/id" + APP_ID
CHANGELOG = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                          "..", "..", "..", "..", "CHANGELOG.md"))


def feed_notes(changelog_text, version, fallback):
    """One plain sentence for the family feed: the intro paragraph under `## [version]`, else `fallback`."""
    m = re.search(r"^## \[" + re.escape(version) + r"\][^\n]*\n(.*?)(?=^## |^### |\Z)", changelog_text, re.S | re.M)
    if m:
        for para in m.group(1).split("\n\n"):
            text = " ".join(para.split())
            if text and not text.startswith(("-", "*", "|", ">", "`", "#")):
                return text[:400].rstrip().replace(chr(0x2014), ";")
    return fallback


def record_release(live_state, version, build, changelog_text, today, site, run=subprocess.run):
    """Append this release to the HelioSoftware feed, only when App Store Connect says READY_FOR_SALE.

    Returns (ok, message). ok is False only when the writer failed or is missing; a release that is not
    live yet is (True, "record: skipped ..."). Never claims a version live before Apple does (SU-11)."""
    if not live_state.get("released"):
        raw = live_state.get("_asc_state_raw") or "unknown"
        return True, "record: skipped, App Store state is %s, not READY_FOR_SALE" % raw
    feed = os.path.join(site, "heliosoftware", "feed")
    tool = os.path.join(feed, "append_record.py")
    if not os.path.isfile(tool):
        return False, "record: %s not found; set SITE to the Website checkout" % tool
    notes = feed_notes(changelog_text, version, "HelioFITS %s (build %s)" % (version, build))
    with tempfile.TemporaryDirectory() as d:
        nf = os.path.join(d, "notes.txt")
        with open(nf, "w", encoding="utf-8") as f:
            f.write(notes + "\n")
        argv = [sys.executable, tool, "--product", FEED_PRODUCT, "--version", version, "--build", str(build),
                "--date", today, "--channel", "mac-app-store", "--url", APP_STORE_URL, "--notes-file", nf]
        r = run(argv, capture_output=True, text=True)
    if r.returncode == 3:
        return True, "record: HelioFITS %s build %s is already in the feed" % (version, build)
    if r.returncode != 0:
        return False, "record: writer failed (exit %d): %s" % (r.returncode, (r.stderr or "").strip()[-200:])
    r = run([sys.executable, os.path.join(feed, "build_feed.py")], capture_output=True, text=True)
    if r.returncode != 0:
        return False, "record: appended, but build_feed.py failed (exit %d): %s" % (r.returncode, (r.stderr or "").strip()[-200:])
    return True, ("record: appended HelioFITS %s build %s in %s; commit and push the Website is Gilly's step"
                  % (version, build, site))


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("version", nargs="?", default="")
    p.add_argument("build", nargs="?", default="")
    p.add_argument("--done", default="", help="comma-separated session-only milestones to mark done: preflight,version,tests,changelog")
    p.add_argument("--record", action="store_true",
                   help="append this release to the HelioSoftware feed in $SITE (default ~/vscode/Website), only if App Store Connect says READY_FOR_SALE")
    p.add_argument("--selftest", action="store_true", help="run the screenshot-verdict asserts and exit")
    p.add_argument("--emit", action="store_true",
                   help="also write a timestamped snapshot to ~/.claude/runbooks/state/ "
                        "for the dashboard. The snapshot is a CACHE, never truth: it records "
                        "checked_at so consumers can show its age and grey it out when stale.")
    args = p.parse_args()
    if args.selftest:
        _selftest()
        sys.exit(0)
    if args.record and not (args.version and args.build):
        p.error("--record needs <version> <build>")
    done_flags = {k: True for k in args.done.split(",") if k}
    if not args.version:
        args.version, args.build = target_release(xcconfig_version())
    live_state = check_live(args.version, args.build)
    try:
        with open(CHANGELOG, encoding="utf-8") as fh:
            changelog_text = fh.read()
    except OSError:
        changelog_text = ""
    for k, v in derive_local(args.version, changelog_text, live_state.get("tag")).items():
        done_flags[k] = done_flags.get(k, False) or v
    print(render(args.version, args.build, done_flags, live_state))

    if args.emit:
        combined = {**done_flags, **live_state}
        snap = {
            "name": "ship-heliofits",
            "title": f"HelioFITS {args.version} (build {args.build})",
            "checked_at": datetime.datetime.now(datetime.timezone.utc)
                            .isoformat(timespec="seconds"),
            "complete": sum(1 for k, _ in MILESTONES if combined.get(k)),
            "total": len(MILESTONES),
            "next": next((lb for k, lb in MILESTONES if not combined.get(k)), None),
            "external_state": combined.get("_asc_state_raw"),
            "external_label": "App Store Connect appStoreState",
            "milestones": [
                {"key": k, "label": lb, "done": bool(combined.get(k)),
                 "note": combined.get("_notes", {}).get(k),
                 "gated": k in ("submitted", "released"),
                 "how_kind": HOW.get(k, ("", ""))[0],
                 "how": HOW.get(k, ("", ""))[1].format(V=args.version, B=args.build)}
                for k, lb in MILESTONES
            ],
        }
        d = os.path.expanduser("~/.claude/runbooks/state")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "ship-heliofits.json"), "w") as f:
            json.dump(snap, f, indent=2)
        print(f"\n(snapshot written to {d}/ship-heliofits.json)")

    if args.record:
        site = os.environ.get("SITE", os.path.expanduser("~/vscode/Website"))
        try:
            with open(CHANGELOG, encoding="utf-8") as fh:
                changelog = fh.read()
        except OSError:
            changelog = ""
        today = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
        ok, msg = record_release(live_state, args.version, args.build, changelog, today, site)
        print(msg)
        if not ok:
            sys.exit(1)
