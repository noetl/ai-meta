#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 2 ] || [ "$#" -gt 4 ]; then
  echo "Usage: $0 <title> <summary> [tags] [author]"
  exit 1
fi

title="$1"
summary="$2"
tags="${3:-none}"
author="${4:-$(git config user.name 2>/dev/null || echo 'unknown')}"

root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$root" ]; then
  echo "Run inside ai-meta repository."
  exit 1
fi

ts_iso="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
year="$(date -u +"%Y")"
month="$(date -u +"%m")"
stamp="$(date -u +"%Y%m%d-%H%M%S")"
slug="$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-60)"

if [ -z "$slug" ]; then
  slug="entry"
fi

dir="$root/memory/inbox/$year/$month"
mkdir -p "$dir"
file="$dir/${stamp}-${slug}.md"

cat > "$file" <<EOF
# $title
- Timestamp: $ts_iso
- Author: $author
- Tags: $tags

## Summary
$summary

## Actions
-

## Repos
-

## Related
-
EOF

echo "$file"
