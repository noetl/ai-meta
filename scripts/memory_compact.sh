#!/usr/bin/env bash
set -euo pipefail

root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$root" ]; then
  echo "Run inside ai-meta repository."
  exit 1
fi

inbox="$root/memory/inbox"
archive="$root/memory/archive"
compactions="$root/memory/compactions"
current="$root/memory/current.md"
timeline="$root/memory/timeline.md"

mkdir -p "$inbox" "$archive" "$compactions"

tmp_files="$(mktemp)"
find "$inbox" -type f -name "*.md" | sort > "$tmp_files"

if [ ! -s "$tmp_files" ]; then
  rm -f "$tmp_files"
  echo "No inbox entries to compact."
  exit 0
fi

ts_iso="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
ts_file="$(date -u +"%Y%m%d-%H%M%S")"
month_key="$(date -u +"%Y-%m")"
comp_file="$compactions/${ts_file}.md"

{
  echo "# Compaction $ts_iso"
  echo
  echo "## Source Entries"
  while IFS= read -r file; do
    rel="${file#$root/}"
    title="$(sed -n 's/^# //p' "$file" | head -n 1)"
    if [ -z "$title" ]; then
      title="$(basename "$file")"
    fi
    echo "- \`$rel\` — $title"
  done < "$tmp_files"

  echo
  echo "## Consolidated Notes"
  while IFS= read -r file; do
    rel="${file#$root/}"
    title="$(sed -n 's/^# //p' "$file" | head -n 1)"
    if [ -z "$title" ]; then
      title="$(basename "$file")"
    fi

    echo
    echo "### $title"
    echo
    echo "- Source: \`$rel\`"
    body="$(sed '1{/^# /d;}' "$file" | head -n 16)"
    if [ -n "$body" ]; then
      printf "%s\n" "$body"
    else
      echo "_No body content._"
    fi
  done < "$tmp_files"
} > "$comp_file"

titles_tmp="$(mktemp)"
while IFS= read -r file; do
  title="$(sed -n 's/^# //p' "$file" | head -n 1)"
  if [ -z "$title" ]; then
    title="$(basename "$file")"
  fi
  printf -- "- %s\n" "$title" >> "$titles_tmp"
done < "$tmp_files"

if [ -f "$current" ]; then
  {
    echo
    echo "## Compaction $ts_iso"
    echo
    echo "- Source: \`memory/compactions/${ts_file}.md\`"
    echo "- Entries compacted:"
    cat "$titles_tmp"
  } >> "$current"
else
  {
    echo "# Current Memory"
    echo
    echo "## Compaction $ts_iso"
    echo
    echo "- Source: \`memory/compactions/${ts_file}.md\`"
    echo "- Entries compacted:"
    cat "$titles_tmp"
  } > "$current"
fi

if [ ! -f "$timeline" ]; then
  echo "# Memory Timeline" > "$timeline"
fi

if ! grep -q "^## $month_key$" "$timeline"; then
  {
    echo
    echo "## $month_key"
    echo
  } >> "$timeline"
fi

printf -- "- Compaction \`%s\` from inbox entries.\n" "$ts_file" >> "$timeline"

while IFS= read -r file; do
  rel="${file#$inbox/}"
  dest_dir="$archive/$(dirname "$rel")"
  mkdir -p "$dest_dir"
  mv "$file" "$dest_dir/"
done < "$tmp_files"

rm -f "$tmp_files" "$titles_tmp"
echo "Created $comp_file"
