#!/usr/bin/env bash
# Seed release notes from merged dev PRs. Only bot authors are filtered;
# label-based filtering is deliberately absent (a dependencies PR can fix
# a user-visible crash — humans prune, automation doesn't hide).
set -euo pipefail
repo="${1:?usage: seed-notes.sh <owner/repo> <since (ISO date or empty)>}"
since="${2:-}"
if [ -z "$since" ]; then
  since=$(date -u -d '7 days ago' +%F)
fi

prs=$(gh pr list --repo "$repo" --state merged --base dev --limit 200 \
  --search "merged:>=$since" \
  --json number,title,author \
  --jq '[.[] | select(.author.is_bot | not)]')

section() { # $1=header $2=jq-filter
  local body
  body=$(echo "$prs" | jq -r "$2 | \"- \(.title) (#\(.number))\"")
  [ -n "$body" ] && printf '## %s\n%s\n\n' "$1" "$body"
}

section "Features" '.[] | select(.title | test("^feat"; "i"))'
section "Fixes"    '.[] | select(.title | test("^fix"; "i"))'
section "Other"    '.[] | select(.title | test("^(feat|fix)"; "i") | not)'
