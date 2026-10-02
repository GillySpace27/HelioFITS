#!/usr/bin/env python3
"""Weekly public-facts watch for HelioFITS. Reads public endpoints only; posts nothing.

Usage:
  python3 scripts/watch.py [--check store landing assets cfitsio] [--landing-url URL ...]
                           [--assets-file PATH] [--selftest]

Each check prints one line:
  ok <check>: <detail>
  FAIL <check>: <reason>    (exit status 1)
  WARN <check>: <reason>    (advisory; exit status unaffected)

store    iTunes lookup for the app id against the newest v<VER>-build.<N> tag.
landing  gilly.space/heliofits and /HelioFITS, following HTTP redirects,
         meta refresh and the site's 404 lowercase rule, must end at a 200
         page that names the App Store id.
assets   every '<tag> <asset-name>' line in scripts/watch-expected-assets.txt
         must still be listed on that GitHub release.
cfitsio  advisory: HEASARC lists a CFITSIO newer than HelioFITSCore/CFITSIO.stamp.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP_ID = "6790952544"
GH_REPO = "GillySpace27/HelioFITS"
LOOKUP_URL = "https://itunes.apple.com/lookup?id=" + APP_ID
LANDING_URLS = ["https://gilly.space/heliofits", "https://gilly.space/HelioFITS"]
LANDING_NEEDLE = "id" + APP_ID
TAG_LAG_DAYS = 14  # estimated: how long a tag may lead the live store version
EXPECTED_ASSETS = os.path.join(REPO_ROOT, "scripts", "watch-expected-assets.txt")
CFITSIO_STAMP = os.path.join(REPO_ROOT, "HelioFITSCore", "CFITSIO.stamp")
HEASARC_URL = "https://heasarc.gsfc.nasa.gov/FTP/software/fitsio/c/"
LOWERCASE_404_MARK = "location.pathname.toLowerCase()"
TAG_RE = re.compile(r"v([0-9][0-9.]*)-build\.([0-9]+)")
UA = "HelioFITS-watch (+https://github.com/GillySpace27/HelioFITS)"
TIMEOUT = 30
MAX_HOPS = 5


class Fail(Exception):
    pass


class Warn(Exception):
    pass


def fetch(url, headers=None):
    """GET url following HTTP redirects. Returns (status, final_url, text); 4xx/5xx do not raise."""
    h = {"User-Agent": UA}
    h.update(headers or {})
    req = urllib.request.Request(url, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            return r.status, r.geturl(), r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.geturl(), e.read().decode("utf-8", "replace")


def norm_version(v):
    """'1.4.0' -> (1, 4); '1.4' -> (1, 4). Trailing zeros dropped so 1.4 == 1.4.0."""
    parts = [int(x) for x in re.findall(r"[0-9]+", v)]
    while len(parts) > 1 and parts[-1] == 0:
        parts.pop()
    return tuple(parts)


def store_verdict(live, tag_name, tag_ver, age_days):
    """Return a detail string, or raise Fail. Pure: no network."""
    detail = "live %s; newest tag %s, %.0f days old" % (live, tag_name, age_days)
    lv, tv = norm_version(live), norm_version(tag_ver)
    if lv == tv:
        return detail
    if lv > tv:
        raise Fail("store version %s has no tag; %s" % (live, detail))
    if age_days > TAG_LAG_DAYS:
        raise Fail("newest tag has led the store for more than %d days: %s" % (TAG_LAG_DAYS, detail))
    return detail + "; tag ahead of the store, inside the %d-day threshold" % TAG_LAG_DAYS


def newest_tag():
    """(name, version, unix time) of the v*-build.N tag with the highest N, or None."""
    out = subprocess.run(
        ["git", "-C", REPO_ROOT, "for-each-ref", "--format=%(refname:short) %(creatordate:unix)", "refs/tags"],
        capture_output=True, text=True, check=True).stdout
    best = None
    for line in out.splitlines():
        name, _, ts = line.rpartition(" ")
        m = TAG_RE.fullmatch(name)
        if m and (best is None or int(m.group(2)) > best[0]):
            best = (int(m.group(2)), name, m.group(1), int(ts))
    return None if best is None else best[1:]


def check_store(args):
    status, _, body = fetch(LOOKUP_URL)
    if status != 200:
        raise Fail("iTunes lookup HTTP %d for %s" % (status, LOOKUP_URL))
    data = json.loads(body)
    if not data.get("resultCount"):
        raise Fail("iTunes lookup returned no result for id %s (endpoint shape unverified; "
                   "try %s&entity=macSoftware by hand)" % (APP_ID, LOOKUP_URL))
    app = data["results"][0]
    live = str(app.get("version", ""))
    tag = newest_tag()
    if tag is None:
        raise Fail("no v<VER>-build.<N> tag found (CI checkout needs fetch-depth: 0)")
    name, ver, ts = tag
    detail = store_verdict(live, name, ver, (time.time() - ts) / 86400.0)
    return detail + "; released %s" % app.get("currentVersionReleaseDate", "unknown")


def meta_refresh_target(body):
    """URL from a <meta http-equiv="refresh" content="0; url=..."> tag, or None."""
    for tag in re.findall(r"<meta\b[^>]*>", body, re.I):
        if re.search(r"http-equiv\s*=\s*[\"']?refresh", tag, re.I):
            m = re.search(r"url\s*=\s*([^\"'>\s;]+)", tag, re.I)
            if m:
                return m.group(1)
    return None


def next_hop(status, final_url, body):
    """The URL a browser would go to next, or None when this page is the destination."""
    if status == 200:
        target = meta_refresh_target(body)
        return urllib.parse.urljoin(final_url, target) if target else None
    parts = urllib.parse.urlsplit(final_url)
    if status == 404 and LOWERCASE_404_MARK in body and parts.path != parts.path.lower():
        return urllib.parse.urlunsplit(parts._replace(path=parts.path.lower()))
    return None


def check_landing(args):
    notes = []
    for start in args.landing_url or LANDING_URLS:
        url, trail = start, []
        for _ in range(MAX_HOPS):
            status, final, body = fetch(url)
            trail.append("%s %d" % (final, status))
            nxt = next_hop(status, final, body)
            if nxt is None:
                break
            url = nxt
        else:
            raise Fail("%s: more than %d hops: %s" % (start, MAX_HOPS, " -> ".join(trail)))
        if status != 200 or LANDING_NEEDLE not in body:
            raise Fail("%s: final %s status %d, %s: %s" % (
                start, final, status,
                "page lacks " + LANDING_NEEDLE if status == 200 else "not 200",
                " -> ".join(trail)))
        notes.append("%s -> %s" % (start, final))
    return "; ".join(notes)


def parse_assets(text):
    """'<tag> <asset>' pairs from the expected-assets file; '#' starts a comment."""
    pairs = []
    for n, raw in enumerate(text.splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        fields = line.split()
        if len(fields) != 2 or not TAG_RE.fullmatch(fields[0]):
            raise Fail("line %d: expected '<v VER-build.N tag> <asset-name>', got %r" % (n, raw))
        pairs.append((fields[0], fields[1]))
    return pairs


def check_assets(args):
    with open(args.assets_file) as f:
        pairs = parse_assets(f.read())
    if not pairs:
        raise Fail("%s lists no assets" % args.assets_file)
    headers = {"Accept": "application/vnd.github+json"}
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = "Bearer " + token
    listed, problems = {}, []
    for tag, asset in pairs:
        if tag not in listed:
            url = "https://api.github.com/repos/%s/releases/tags/%s" % (GH_REPO, urllib.parse.quote(tag))
            status, _, body = fetch(url, headers)
            listed[tag] = [a["name"] for a in json.loads(body).get("assets", [])] if status == 200 else None
            if status != 200:
                problems.append("%s: release lookup HTTP %d" % (tag, status))
        if listed[tag] is not None and asset not in listed[tag]:
            problems.append("%s: asset %s not listed" % (tag, asset))
    if problems:
        raise Fail("; ".join(problems))
    return "%d assets present on %d releases" % (len(pairs), len(listed))


def check_cfitsio(args):
    if not os.path.exists(CFITSIO_STAMP):
        raise Warn("stamp absent")
    stamp = {}
    with open(CFITSIO_STAMP) as f:
        for line in f:
            k, sep, v = line.strip().partition("=")
            if sep:
                stamp[k] = v
    pinned = stamp.get("cfitsio_version")
    if not pinned:
        raise Warn("stamp has no cfitsio_version line")
    try:
        status, _, body = fetch(HEASARC_URL)
    except (urllib.error.URLError, OSError) as e:
        raise Warn("HEASARC unreachable (%s); stamp pins %s" % (e, pinned))
    if status != 200:
        raise Warn("HEASARC listing HTTP %d; stamp pins %s" % (status, pinned))
    seen = re.findall(r"cfitsio-([0-9]+(?:\.[0-9]+)+)\.tar\.gz", body)
    if not seen:
        raise Warn("no cfitsio-<ver>.tar.gz names on %s (page changed?); stamp pins %s" % (HEASARC_URL, pinned))
    newest = max(seen, key=norm_version)
    if norm_version(newest) > norm_version(pinned):
        raise Warn("HEASARC lists %s, stamp pins %s" % (newest, pinned))
    return "stamp %s, newest on HEASARC %s" % (pinned, newest)


CHECKS = {"store": check_store, "landing": check_landing, "assets": check_assets, "cfitsio": check_cfitsio}


def selftest():
    assert norm_version("1.4.0") == norm_version("1.4") == (1, 4)
    assert norm_version("1.3.10") > norm_version("1.3.9")
    assert store_verdict("1.4.0", "v1.4.0-build.10", "1.4.0", 40).startswith("live 1.4.0")
    assert "inside" in store_verdict("1.3.1", "v1.4.0-build.10", "1.4.0", 3)
    for live, ver, age in (("1.3.1", "1.4.0", 15), ("1.5", "1.4.0", 1)):
        try:
            store_verdict(live, "v%s-build.10" % ver, ver, age)
        except Fail:
            pass
        else:
            raise AssertionError("store_verdict(%s, %s, %s) did not fail" % (live, ver, age))
    assert meta_refresh_target('<meta http-equiv="refresh" content="0; url=/heliofits/">') == "/heliofits/"
    assert meta_refresh_target('<meta charset="utf-8">') is None
    assert next_hop(200, "https://gilly.space/x/", '<meta http-equiv="refresh" content="0;url=/heliofits/">') \
        == "https://gilly.space/heliofits/"
    page404 = "<script>if (x) location.replace(" + LOWERCASE_404_MARK + ")</script>"
    assert next_hop(404, "https://gilly.space/HelioFITS", page404) == "https://gilly.space/heliofits"
    assert next_hop(404, "https://gilly.space/heliofits", page404) is None
    assert next_hop(404, "https://gilly.space/Nope", "plain 404") is None
    assert next_hop(200, "https://gilly.space/heliofits/", "<a href='https://apps.apple.com/app/id6790952544'>") is None
    assert parse_assets("# c\nv1.3.1-build.8 HelioFITS-1.3.1-b8.zip  # note\n\n") == \
        [("v1.3.1-build.8", "HelioFITS-1.3.1-b8.zip")]
    try:
        parse_assets("HelioFITS-1.3.1-b8.zip\n")
    except Fail:
        pass
    else:
        raise AssertionError("parse_assets accepted a line without a tag")
    print("selftest ok")


def main(argv=None):
    p = argparse.ArgumentParser(description="HelioFITS public-facts watch (read-only).")
    p.add_argument("--check", nargs="+", action="extend", choices=sorted(CHECKS),
                   help="checks to run (default: all)")
    p.add_argument("--landing-url", action="append", help="override the landing URLs (repeatable)")
    p.add_argument("--assets-file", default=EXPECTED_ASSETS, help="expected-assets list")
    p.add_argument("--selftest", action="store_true", help="run the offline asserts and exit")
    args = p.parse_args(argv)
    if args.selftest:
        selftest()
        return 0
    status = 0
    for name in args.check or ["store", "landing", "assets", "cfitsio"]:
        try:
            print("ok %s: %s" % (name, CHECKS[name](args)))
        except Warn as e:
            print("WARN %s: %s" % (name, e))
        except Fail as e:
            print("FAIL %s: %s" % (name, e))
            status = 1
        except (urllib.error.URLError, OSError, ValueError, KeyError, subprocess.CalledProcessError) as e:
            print("FAIL %s: %s: %s" % (name, type(e).__name__, e))
            status = 1
    sys.stdout.flush()
    return status


if __name__ == "__main__":
    sys.exit(main())
