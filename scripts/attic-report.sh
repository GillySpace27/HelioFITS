#!/bin/bash
# List build-attic/: the zipped build outputs that ship.sh, lsclean.sh and
# build-universal.sh keep instead of deleting. Per-entry and total sizes.
# Read-only: it never prunes. Pruning is Gilly's decision.
#   scripts/attic-report.sh            (ATTIC=<dir> overrides the folder, for tests)
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
ATTIC="${ATTIC:-build-attic}"
if [ ! -d "$ATTIC" ]; then
    echo "$ATTIC/ does not exist yet: nothing kept so far"
    exit 0
fi
count=0
while IFS= read -r entry; do
    printf '%10s KB  %s\n' "$(du -sk "$entry" | awk '{print $1}')" "$entry"
    count=$((count + 1))
done < <(find "$ATTIC" -mindepth 1 -maxdepth 1 | sort)
printf '%10s KB  total, %d entries in %s/\n' "$(du -sk "$ATTIC" | awk '{print $1}')" "$count" "$ATTIC"
