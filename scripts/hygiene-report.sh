#!/usr/bin/env bash
# Read-only hygiene report for this checkout: local main against origin/main, every branch
# with ahead/behind and its pull request, the worktrees, and the size of untracked and
# ignored clutter. Changes nothing: no fetch, no checkout, no tag, no prune, no delete.
# gh is optional; without it the PR column reads "gh missing".
# Usage: bash scripts/hygiene-report.sh   (HYGIENE_BASE overrides origin/main)
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
BASE="${HYGIENE_BASE:-origin/main}"
git rev-parse --verify --quiet "$BASE^{commit}" >/dev/null || { echo "ref $BASE not found (git fetch origin)"; exit 1; }

echo "== main vs $BASE"
if git rev-parse --verify --quiet refs/heads/main >/dev/null; then
  read -r behind ahead < <(git rev-list --left-right --count "$BASE...refs/heads/main")
  echo "main $(git rev-parse --short refs/heads/main): behind $behind, ahead $ahead ($BASE $(git rev-parse --short "$BASE"))"
else
  echo "main: no local branch"
fi

echo "== branches (behind/ahead of $BASE)"
prs=""
if command -v gh >/dev/null 2>&1; then
  prs="$(gh pr list --state all --limit 300 --json number,state,headRefName \
    --jq '.[] | "\(.headRefName)\t#\(.number) \(.state)"' 2>/dev/null || true)"
  [ -n "$prs" ] || prs="__gh_failed__"
fi
git for-each-ref --format='%(refname)' refs/heads refs/remotes/origin \
  | sed -e 's#^refs/heads/##' -e 's#^refs/remotes/origin/##' \
  | grep -vx 'HEAD' | sort -u \
  | while IFS= read -r b; do
      loc="$(git rev-parse --verify --quiet --short "refs/heads/$b" || echo -)"
      rem="$(git rev-parse --verify --quiet --short "refs/remotes/origin/$b" || echo -)"
      if [ "$loc" != "-" ]; then tip="refs/heads/$b"; else tip="refs/remotes/origin/$b"; fi
      read -r behind ahead < <(git rev-list --left-right --count "$BASE...$tip")
      if [ -z "$prs" ]; then pr="gh missing"
      elif [ "$prs" = "__gh_failed__" ]; then pr="gh failed"
      else pr="$(printf '%s\n' "$prs" | awk -F'\t' -v b="$b" '$1 == b { printf "%s%s", sep, $2; sep = ", " }')"
           [ -n "$pr" ] || pr="no PR"
      fi
      printf '%-50s local %-8s origin %-8s behind %4s ahead %4s  %s\n' "$b" "$loc" "$rem" "$behind" "$ahead" "$pr"
    done

echo "== worktrees"
git worktree list

echo "== untracked and ignored clutter (KB)"
{
  git ls-files --others --exclude-standard --directory | awk '{ print $0 "\tuntracked" }'
  git ls-files --others --ignored --exclude-standard --directory | awk '{ print $0 "\tignored" }'
} | while IFS=$'\t' read -r p kind; do
      [ -e "$p" ] || continue
      printf '%10s  %-9s %s\n' "$(du -sk "$p" | cut -f1)" "$kind" "$p"
    done
