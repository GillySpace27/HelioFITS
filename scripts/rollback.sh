#!/bin/bash
# Prepare a rebuild of a known-good release. The App Store cannot re-serve an
# old binary, so rolling back means shipping the good source again under a new
# build number (and a marketing version above the last approved one).
# This script only prepares: it adds a git worktree at the good tag and prints
# the commands. It pushes, uploads, tags and submits nothing.
# See RELEASING.md "Rolling back".
#
#   scripts/rollback.sh <good-tag>        e.g. scripts/rollback.sh v1.4.0-build.10
#
# Exit 0 prepared; 1 unknown tag or worktree path taken; 2 usage error.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

if [ $# -ne 1 ]; then
    echo "usage: scripts/rollback.sh <good-tag>   (a v<VER>-build.<N> tag)" >&2
    exit 2
fi
TAG="$1"
if ! [[ "$TAG" =~ ^v([0-9][0-9.]*)-build\.([0-9]+)$ ]]; then
    echo "not a release tag: $TAG (expected v<VER>-build.<N>)" >&2
    exit 2
fi
if ! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    echo "no such tag: $TAG (run git fetch --tags, then retry)" >&2
    exit 1
fi

# Newest release tag by build number; the next free build is one past it.
MAX=0; NEWEST_VER=""
while IFS= read -r t; do
    if [[ "$t" =~ ^v([0-9][0-9.]*)-build\.([0-9]+)$ ]] && [ "${BASH_REMATCH[2]}" -gt "$MAX" ]; then
        MAX="${BASH_REMATCH[2]}"; NEWEST_VER="${BASH_REMATCH[1]}"
    fi
done < <(git tag -l 'v*-build.*')
NEXT=$((MAX + 1))
# Marketing version one patch above the newest tag (estimate; Gilly picks the real one).
IFS=. read -r MA MI PA <<<"$NEWEST_VER"
NEXT_VER="${MA:-0}.${MI:-0}.$(( ${PA:-0} + 1 ))"

WT=".claude/worktrees/rollback-$TAG"
if [ -e "$WT" ]; then
    echo "worktree path already exists: $WT (left as is; inspect it, or roll back to another tag)" >&2
    exit 1
fi
mkdir -p .claude/worktrees
git worktree add --detach "$WT" "$TAG" >/dev/null
echo "worktree:    $WT (detached at $TAG, $(git -C "$WT" rev-parse --short HEAD))"
echo "newest tag:  v$NEWEST_VER-build.$MAX"
echo "next build:  $NEXT"
echo "next version (suggested): $NEXT_VER"
echo
echo "# 1. Branch and bump (RELEASING.md step 2; HF-10 replaces this block with scripts/bump-version.sh)"
echo "cd $WT"
echo "git switch -c rollback/$TAG-b$NEXT"
echo "sed -i '' 's/MARKETING_VERSION = [0-9.]*;/MARKETING_VERSION = $NEXT_VER;/g' HelioFITS.xcodeproj/project.pbxproj"
echo "sed -i '' 's/CURRENT_PROJECT_VERSION = [0-9]*;/CURRENT_PROJECT_VERSION = $NEXT;/g' HelioFITS.xcodeproj/project.pbxproj"
echo "grep -oE \"MARKETING_VERSION = [0-9.]+;|CURRENT_PROJECT_VERSION = [0-9]+;\" HelioFITS.xcodeproj/project.pbxproj | sort | uniq -c   # expect 10 of each"
echo
echo "# 2. Test, changelog, tag locally (RELEASING.md steps 3 to 5; HF-21 replaces this block with scripts/release.py)"
echo "# CHANGELOG.md: a [$NEXT_VER] section that says it restores $TAG"
echo "git tag -a v$NEXT_VER-build.$NEXT -m \"$NEXT_VER (build $NEXT): restores $TAG\""
echo
echo "# 3. Gated, each needs Gilly's yes for this release:"
echo "#    pause the phased release in App Store Connect (if one is running)"
echo "#    git push origin rollback/$TAG-b$NEXT v$NEXT_VER-build.$NEXT"
echo "#    archive and upload (RELEASING.md Channel A), then submit; expedited review only for a critical regression"
echo "#    the direct channel's previous zip stays on its GitHub release; hand out /releases, never /releases/latest"
