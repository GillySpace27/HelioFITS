#!/usr/bin/env python3
"""Typed confirmation for release steps that need Gilly's yes (HF-21).

A gate step (submit, release, gh release create) calls require_confirm with the
--confirm text it was given and the exact text it expects, which names the action,
the version and the build, so a yes for build N cannot carry to build N+1.
append_state_log writes one tab-separated line per attempt; it never truncates.
"""
import datetime
import os
import sys

LOG_ENV = "HELIOFITS_STATE_LOG"   # tests point this at a temp file
DEFAULT_LOG = "~/.claude/runbooks/state/ship-heliofits.log"


def expected_text(action, version, build):
    return f"{action} {version} build {build}"


def require_confirm(given, expected):
    """Return None when `given` equals `expected`; otherwise exit 3 with the text to type."""
    if given != expected:
        print(f'refused: type --confirm "{expected}"', file=sys.stderr)
        sys.exit(3)


def append_state_log(action, version, build, result):
    """Append '<UTC ISO 8601>\\t<action>\\t<version>\\t<build>\\t<result>' to the state log."""
    path = os.path.expanduser(os.environ.get(LOG_ENV) or DEFAULT_LOG)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    now = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
    with open(path, "a", encoding="utf-8") as f:
        f.write(f"{now}\t{action}\t{version}\t{build}\t{result}\n")
