#!/usr/bin/env python3
"""Release notes from the one source, CHANGELOG.md (HF-21).

  release-notes.py VERSION                      print the CHANGELOG section plus the install footer
  release-notes.py VERSION --check-whats-new    lint store/whats-new/VERSION.txt (App Store text)

Exit 1 on a missing section or file or a lint failure. The footer hands out the App Store
first and the releases page as the fallback; never /releases/latest, which skips pre-releases.
"""
import argparse
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP_STORE_URL = "https://apps.apple.com/app/id6790952544"   # APP_ID in release_status.py
RELEASES_URL = "https://github.com/GillySpace27/HelioFITS/releases"
EM_DASH = "—"
MAX_WHATS_NEW = 1000   # house limit from the HF-21 task file, not an Apple figure


def section(changelog, version):
    """The `## [version]` section without its heading line, or None."""
    m = re.search(r"^## \[" + re.escape(version) + r"\][^\n]*\n(.*?)(?=^## \[|\Z)", changelog, re.S | re.M)
    return m.group(1).strip("\n") if m else None


def footer():
    return (f"Get HelioFITS on the Mac App Store: {APP_STORE_URL}\n"
            f"Direct-download builds, when one is cut: {RELEASES_URL}")


def lint_whats_new(text):
    """A list of problems with an App Store What's New text; empty means it passes."""
    bad = []
    if not text.strip():
        bad.append("empty")
    if re.search(r"#\d+", text):
        bad.append("issue link (#123)")
    if "github.com" in text.lower():
        bad.append("github.com")
    if EM_DASH in text:
        bad.append("em dash")
    if len(text) > MAX_WHATS_NEW:
        bad.append(f"{len(text)} characters, over {MAX_WHATS_NEW}")
    return bad


def main(argv=None, root=ROOT):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("version")
    p.add_argument("--check-whats-new", action="store_true")
    args = p.parse_args(argv)
    if args.check_whats_new:
        path = os.path.join(root, "store", "whats-new", args.version + ".txt")
        try:
            with open(path, encoding="utf-8") as f:
                bad = lint_whats_new(f.read())
        except OSError:
            print(f"error: {path} not found", file=sys.stderr)
            return 1
        if bad:
            print("error: what's new: " + "; ".join(bad), file=sys.stderr)
            return 1
        print(f"ok: {path}")
        return 0
    try:
        with open(os.path.join(root, "CHANGELOG.md"), encoding="utf-8") as f:
            body = section(f.read(), args.version)
    except OSError:
        body = None
    if body is None:
        print(f"error: no section [{args.version}] in CHANGELOG.md", file=sys.stderr)
        return 1
    print(body + "\n\n" + footer())
    return 0


if __name__ == "__main__":
    sys.exit(main())
