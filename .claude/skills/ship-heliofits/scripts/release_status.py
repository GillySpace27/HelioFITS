#!/usr/bin/env python3
"""Render the ship-heliofits progress tracker from VERIFIED state.

Checks git, GitHub and the App Store Connect API directly rather than
trusting what an earlier turn claimed to have done -- the same discipline
that caught the stale-libcfitsio.a bug in 1.3.0. The first five milestones
(preflight/version/tests/changelog/tag-created) are inherently about this
session's own actions and can't be re-derived from outside state, so they
are passed in by the caller; everything from "tag pushed" onward is checked
live.

Usage: python3 release_status.py <VERSION> <BUILD> [--done preflight,version,tests,changelog]
  python3 release_status.py 1.3.1 8 --done preflight,version,tests,changelog
"""
import sys, os, json, subprocess, argparse, datetime

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
APP_ID = "6790952544"
ASC_API = os.path.join(os.path.dirname(os.path.abspath(__file__)), "asc_api.py")

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
    "version":     ("shell", "sed -i '' 's/MARKETING_VERSION = [0-9.]*;/MARKETING_VERSION = {V};/g' HelioFITS.xcodeproj/project.pbxproj && "
                             "sed -i '' 's/CURRENT_PROJECT_VERSION = [0-9]*;/CURRENT_PROJECT_VERSION = {B};/g' HelioFITS.xcodeproj/project.pbxproj   # then verify 10 of each"),
    "tests":       ("shell", "pkill -x HelioFITS; xcodebuild test -project HelioFITS.xcodeproj -scheme HelioFITS -destination 'platform=macOS,arch=arm64' DEVELOPMENT_TEAM=UB45PPC2JS CODE_SIGN_IDENTITY=\"-\" CODE_SIGN_STYLE=Manual AD_HOC_CODE_SIGNING_ALLOWED=YES"),
    "changelog":   ("edit",  "Write the [{V}] section in CHANGELOG.md — long form, grouped Added/Changed/Fixed, issues linked."),
    "tag":         ("shell", "git tag -a v{V}-build.{B} -m \"{V} (build {B})\""),
    "tag_pushed":  ("shell", "git push && git push origin v{V}-build.{B}"),
    "gh_release":  ("shell", "./ship.sh   # then: gh release create v{V}-build.{B} build/HelioFITS-{V}-b{B}.zip --title \"HelioFITS {V} (build {B})\" --notes-file <notes>"),
    "asc_version": ("api",   "Create the {V} version record in App Store Connect."),
    "asc_build":   ("api",   "Attach build {B} to the {V} version record."),
    "asc_notes":   ("api",   "Set What's New — the SHORT form, one headline sentence per fix."),
    "submitted":   ("gate",  "Submit build {B} of {V} for App Review. Never without Gilly saying so, this run."),
    "released":    ("gate",  "Release {V} to users. Never without Gilly saying so, this run."),
}

def sh(cmd):
    return subprocess.run(cmd, cwd=REPO, capture_output=True, text=True).stdout.strip()

def asc_get(path):
    out = subprocess.run([sys.executable, ASC_API, "GET", path], capture_output=True, text=True).stdout
    status_line, _, body = out.partition("\n")
    if not status_line.startswith("HTTP 200"):
        return None
    return json.loads(body)

def check_live(version, build):
    tag = f"v{version}-build.{build}"
    state = {}

    tags_local = sh(["git", "tag", "-l", tag])
    state["tag"] = tag in tags_local.splitlines()

    tags_remote = sh(["git", "ls-remote", "--tags", "origin", tag])
    state["tag_pushed"] = bool(tags_remote.strip())

    gh_out = subprocess.run(["gh", "release", "view", tag, "--json", "url"],
                             cwd=REPO, capture_output=True, text=True)
    state["gh_release"] = gh_out.returncode == 0

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

    submitted_states = {"WAITING_FOR_REVIEW", "IN_REVIEW", "PENDING_APPLE_RELEASE",
                         "PENDING_DEVELOPER_RELEASE", "READY_FOR_SALE", "PROCESSING_FOR_APP_STORE"}
    state["submitted"] = app_store_state in submitted_states
    state["released"] = app_store_state == "READY_FOR_SALE"
    state["_asc_state_raw"] = app_store_state
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
        lines.append(f"{mark} {label}{suffix}")
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

if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("version")
    p.add_argument("build")
    p.add_argument("--done", default="", help="comma-separated session-only milestones to mark done: preflight,version,tests,changelog")
    p.add_argument("--emit", action="store_true",
                   help="also write a timestamped snapshot to ~/.claude/runbooks/state/ "
                        "for the dashboard. The snapshot is a CACHE, never truth: it records "
                        "checked_at so consumers can show its age and grey it out when stale.")
    args = p.parse_args()
    done_flags = {k: True for k in args.done.split(",") if k}
    live_state = check_live(args.version, args.build)
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
