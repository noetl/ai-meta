#!/usr/bin/env bash
# figma_fetch.sh — Figma REST API helper that reads the PAT from GCP Secret
# Manager without exposing the token in stdout/stderr.
#
# Token: project secret `figma-access-token` (`figd_...`).
# Never echoes the token. Token leaves only as an HTTP `X-Figma-Token`
# header on the curl request.
#
# Usage:
#   figma_fetch.sh file       <file_key> [--depth N]
#   figma_fetch.sh nodes      <file_key> <node_ids_csv> [--depth N]
#   figma_fetch.sh images     <file_key> <node_ids_csv> [--format png|svg|pdf|jpg] [--scale 1|2|3|4]
#   figma_fetch.sh styles     <file_key>
#   figma_fetch.sh components <file_key>
#   figma_fetch.sh variables  <file_key>       # local variables (design tokens)
#
# Examples:
#   figma_fetch.sh file BSbpbRHzFGF2LmJl7Ekemb --depth 2
#   figma_fetch.sh nodes BSbpbRHzFGF2LmJl7Ekemb '9:4440,334:33438'
#   figma_fetch.sh images BSbpbRHzFGF2LmJl7Ekemb '9:4440' --format png --scale 2

set -euo pipefail

PROJECT="${FIGMA_GCP_PROJECT:-noetl-demo-19700101}"
SECRET="${FIGMA_SECRET_NAME:-figma-access-token}"
BASE="https://api.figma.com/v1"

err() { printf "%s\n" "$*" >&2; }

usage() {
  err "Usage: $0 {file|nodes|images|styles|components|variables} <file_key> [args...]"
  err "Run with no args for the full block of subcommands."
  err ""
  err "    figma_fetch.sh file       <file_key> [--depth N]"
  err "    figma_fetch.sh nodes      <file_key> <node_ids_csv> [--depth N]"
  err "    figma_fetch.sh images     <file_key> <node_ids_csv> [--format png|svg|pdf|jpg] [--scale 1|2|3|4]"
  err "    figma_fetch.sh styles     <file_key>"
  err "    figma_fetch.sh components <file_key>"
  err "    figma_fetch.sh variables  <file_key>"
  exit 2
}

[[ $# -lt 1 ]] && usage

# Read token. Use `2>/dev/null` so any gcloud error doesn't leak partials.
TOKEN="$(gcloud secrets versions access latest --secret="$SECRET" --project="$PROJECT" 2>/dev/null)"
if [[ -z "$TOKEN" ]]; then
  err "ERROR: failed to read secret $SECRET from project $PROJECT"
  err "Check existence + IAM:"
  err "  gcloud secrets describe $SECRET --project=$PROJECT"
  exit 1
fi

cmd="$1"; shift

case "$cmd" in
  file)
    [[ $# -lt 1 ]] && usage
    key="$1"; shift
    depth=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --depth) depth="$2"; shift 2 ;;
        *) err "unknown flag: $1"; exit 2 ;;
      esac
    done
    if [[ -n "$depth" ]]; then
      curl -sS -H "X-Figma-Token: $TOKEN" -G "$BASE/files/$key" --data-urlencode "depth=$depth"
    else
      curl -sS -H "X-Figma-Token: $TOKEN" "$BASE/files/$key"
    fi
    ;;
  nodes)
    [[ $# -lt 2 ]] && usage
    key="$1"; ids="$2"; shift 2
    depth=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --depth) depth="$2"; shift 2 ;;
        *) err "unknown flag: $1"; exit 2 ;;
      esac
    done
    args=(-G "$BASE/files/$key/nodes" --data-urlencode "ids=$ids")
    [[ -n "$depth" ]] && args+=(--data-urlencode "depth=$depth")
    curl -sS -H "X-Figma-Token: $TOKEN" "${args[@]}"
    ;;
  images)
    [[ $# -lt 2 ]] && usage
    key="$1"; ids="$2"; shift 2
    fmt="png"; scale="2"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --format) fmt="$2"; shift 2 ;;
        --scale)  scale="$2"; shift 2 ;;
        *) err "unknown flag: $1"; exit 2 ;;
      esac
    done
    curl -sS -H "X-Figma-Token: $TOKEN" -G "$BASE/images/$key" \
      --data-urlencode "ids=$ids" \
      --data-urlencode "format=$fmt" \
      --data-urlencode "scale=$scale"
    ;;
  styles)
    [[ $# -lt 1 ]] && usage
    key="$1"
    curl -sS -H "X-Figma-Token: $TOKEN" "$BASE/files/$key/styles"
    ;;
  components)
    [[ $# -lt 1 ]] && usage
    key="$1"
    curl -sS -H "X-Figma-Token: $TOKEN" "$BASE/files/$key/components"
    ;;
  variables)
    [[ $# -lt 1 ]] && usage
    key="$1"
    curl -sS -H "X-Figma-Token: $TOKEN" "$BASE/files/$key/variables/local"
    ;;
  *)
    usage
    ;;
esac
