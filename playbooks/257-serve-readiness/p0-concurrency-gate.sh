#!/usr/bin/env bash
# In-cluster behavioural arm for the ai-meta#261 P0 — the tier store's append
# path tearing under concurrent writers.
#
# The in-repo test (worker `tests/tier_store_concurrent_append.rs`) proves the
# CODE is safe.  This proves the **built image running in the cluster** is,
# against the writer's real `:9110` face over the real framed protocol.  Neither
# substitutes for the other: the test cannot see the deployed binary, and this
# cannot run in CI.
#
# It reproduces the shape that broke prod — MANY concurrent appends into ONE
# writer-fronted store through the tier service, the way the server-mirror relay
# drives it under NOETL_EHDB_EVENTLOG_MIRROR_SOURCE=server — then reads the whole
# log back.
#
# Design rules, inherited from gate.sh because each was learned expensively:
#   * behaviour-level, against a built image.  No assertion reads source.
#   * a failed fetch is a FAILURE, never a zero that reads as a pass.
#   * absent != zero.  A missing metric is reported as __ABSENT__.
#   * every count that must MOVE is a delta against a baseline from this run.
#   * positive control: assert the appends ACTUALLY happened, so "0 torn
#     records" cannot be satisfied by an empty store.
#
# PROD IS NOT TOUCHED.  Every kubectl call pins --context kind-noetl.
#
# Usage: p0-concurrency-gate.sh [clients] [appends-per-client]
set -uo pipefail

WK_IMG="${WK_IMG:-localhost/noetl-worker:p0conc}"
NS=noetl
WRITER_STS=noetl-cmdbus-writer
WRITER_POD=noetl-cmdbus-writer-0
WRITER_CTR=noetl-worker
CLIENTS="${1:-16}"
APPENDS="${2:-12}"
EXPECT=$((CLIENTS * APPENDS))

# A FRESH store.  The defect is a corrupt log; running against a directory that
# may already hold a torn line would measure the old corruption, not the fix.
# Unique per run so a re-run cannot inherit the previous one's state.
FRESH_DIR="/data/eventbus/ehdb-tier-p0-$(date +%s)"

PASS=0; FAIL=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); }
info() { printf '        %s\n' "$1"; }

k() { kubectl --context kind-noetl -n "$NS" "$@"; }

# Read one metric from the writer's /metrics.  __ABSENT__, never 0 — a metric
# family with no children is PRUNED by prometheus's registry, so absent and zero
# look identical unless you keep them distinct.
metric() {
  local name="$1" out
  # `grep -v '^#'` is load-bearing: the HELP line contains the metric name too,
  # and its last field is prose.  Without it this returned "(noetl/ai-meta#238)."
  # as the value of build_info — a confident wrong answer, not an error.
  out=$(k exec "$WRITER_POD" -c "$WRITER_CTR" -- \
        wget -qO- http://127.0.0.1:9090/metrics 2>/dev/null \
        | grep -v '^#' | grep -F "$name" | awk '{print $NF}' | head -1)
  [ -n "$out" ] && echo "$out" || echo "__ABSENT__"
}

echo "== ai-meta#261 P0: concurrent appends through the writer's real :9110 =="
echo "   image      $WK_IMG"
echo "   store      $FRESH_DIR   (fresh)"
echo "   load       $CLIENTS clients x $APPENDS appends = $EXPECT"
echo

echo "-- 0. load the image into the kind node --"
# `kind load docker-image` does not see podman's local store under this
# provider ("not present locally", for an image `podman images` lists).  Go
# through an archive, which is what deploy.sh does for the same reason.
tmp=$(mktemp -t kindloadXXXXXX).tar
podman save -o "$tmp" "$WK_IMG" || { bad "podman save $WK_IMG"; exit 1; }
kind load image-archive "$tmp" --name noetl 2>&1 | tail -2
rm -f "$tmp"
# Positive control on the load itself: `kind load` has reported success for an
# image the node did not end up with.
#
# ⚠ Capture FIRST, then grep.  `podman exec ... | grep -q` is wrong under
# `set -o pipefail`: grep exits at the first match and closes the pipe, podman
# takes SIGPIPE, and pipefail reports the whole pipeline as failed — so a
# PRESENT image reads as absent, intermittently, depending on whether podman
# finished writing before grep quit.  Observed here: two identical runs
# disagreed about the same image.
node_images=$(podman exec noetl-control-plane crictl images 2>&1)
tag="${WK_IMG##*:}"
match=$(printf '%s\n' "$node_images" | grep -F "$tag" || true)
if [ -n "$match" ]; then
  ok "image present in the kind node"
  printf '%s\n' "$match" | sed 's/^/        /'
else
  bad "image $WK_IMG NOT in the kind node — everything below would test the OLD binary"
  exit 1
fi

echo
echo "-- 1. arm the writer: new image, tier service on :9110, FRESH store --"
k set image "sts/$WRITER_STS" "$WRITER_CTR=$WK_IMG" >/dev/null
k set env "sts/$WRITER_STS" \
    NOETL_EHDB_ENABLED=true \
    NOETL_EHDB_TIER_SERVICE_BIND=0.0.0.0:9110 \
    NOETL_EHDB_TIER_SERVICE_DIR="$FRESH_DIR" >/dev/null
k rollout status "sts/$WRITER_STS" --timeout=300s || { bad "writer rollout"; exit 1; }

# Assert we are talking to the image we just built, not the one that was there.
running=$(k get pod "$WRITER_POD" -o jsonpath='{.spec.containers[0].image}')
if [ "$running" = "$WK_IMG" ]; then
  ok "writer's pod spec names $running"
else
  bad "writer is running $running, expected $WK_IMG"; exit 1
fi

# The image TAG is a representation — it is what the Deployment claims, and a
# claim can disagree with what is running.  `build_info` comes out of the
# process itself, so it answers "is this binary new enough to contain the fix"
# without going through the spec.  The writer was on 5.115.3 before this arm;
# anything still reporting that is the OLD binary and every result below would
# be about code that does not have the fix.
bi=$(metric 'noetl_worker_build_info')
biver=$(k exec "$WRITER_POD" -c "$WRITER_CTR" -- wget -qO- http://127.0.0.1:9090/metrics 2>/dev/null \
        | grep -v '^#' | grep -o 'noetl_worker_build_info{version="[^"]*"}' | head -1)
if [ "$bi" = "1" ] && [ -n "$biver" ]; then
  info "running process reports $biver"
  case "$biver" in
    *5.115.3*) bad "the writer is still the PRE-FIX binary — nothing below is meaningful"; exit 1 ;;
    *)         ok  "running process is not the pre-fix build" ;;
  esac
else
  bad "no build_info from the running process (got '$bi') — cannot confirm which binary is up"
  exit 1
fi

# The store must be EMPTY before the hammer, or the count assertions are lies.
pre=$(k exec "$WRITER_POD" -c "$WRITER_CTR" -- sh -c "wc -l < $FRESH_DIR/eventlog.jsonl 2>/dev/null || echo 0")
if [ "${pre//[^0-9]/}" = "0" ]; then
  ok "store starts empty ($FRESH_DIR)"
else
  bad "store already holds $pre lines — not a fresh store"; exit 1
fi

echo
echo "-- 2. tier service answers before we trust anything it says --"
health=$(k exec "$WRITER_POD" -c "$WRITER_CTR" -- \
         sh -c 'printf "\\x00\\x00\\x00\\x06health" | nc -w 3 127.0.0.1 9110 2>/dev/null | tail -c 20' 2>/dev/null || true)
case "$health" in
  *"tier-service"*) ok "tier service is up: $health" ;;
  *) info "raw health probe inconclusive ('$health') — the selfcheck below is the real check" ;;
esac

base_ok=$(metric 'tier_service.append",outcome="ok"')
base_err=$(metric 'tier_service.append",outcome="error"')
info "baseline append ok=$base_ok error=$base_err"

echo
echo "-- 3. THE HAMMER: $EXPECT concurrent appends through the framed protocol --"
out=$(k exec "$WRITER_POD" -c "$WRITER_CTR" -- \
      ./ehdb-selfcheck tier-concurrency \
        --addr 127.0.0.1:9110 --clients "$CLIENTS" --appends "$APPENDS" 2>&1)
rc=$?
echo "$out" | sed 's/^/        /'

# A failed fetch is a FAILURE, never a silent pass.
body=$(echo "$out" | grep -o '{.*}' | tail -1)
if [ -z "$body" ]; then
  bad "the probe produced no JSON — treat as failure, not as zero"
  exit 1
fi

fld() { echo "$body" | jq -r ".$1"; }   # NOT jq -e: -e exits non-zero on false

[ "$(fld ok)" = "true" ] \
  && ok "probe verdict ok=true" \
  || bad "probe verdict ok=$(fld ok)"

[ "$(fld appends_failed)" = "0" ] \
  && ok "zero appends failed (torn records make appends fail: the replay trips)" \
  || bad "appends_failed=$(fld appends_failed) — the store tore"

[ "$(fld unparseable_payloads)" = "0" ] \
  && ok "zero torn records — every payload deserialised" \
  || bad "unparseable_payloads=$(fld unparseable_payloads)"

# POSITIVE CONTROL.  Without these two, "zero torn records" is satisfiable by an
# empty log and the arm above would pass against a store that wrote nothing.
[ "$(fld mine_distinct)" = "$EXPECT" ] \
  && ok "count matches: $EXPECT distinct records from this run read back" \
  || bad "expected $EXPECT records, read back $(fld mine_distinct)"

[ "$(fld distinct_sequences)" = "$EXPECT" ] \
  && ok "sequences unique: $EXPECT distinct global_sequence values" \
  || bad "distinct_sequences=$(fld distinct_sequences) of $EXPECT — sequences collided"

echo
echo "-- 4. reads succeed: no ehdb_unavailable, no 502 --"
read_out=$(k exec "$WRITER_POD" -c "$WRITER_CTR" -- \
           ./ehdb-selfcheck tier-concurrency \
             --addr 127.0.0.1:9110 --clients 1 --appends 1 2>&1 | grep -o '{.*}' | tail -1)
if echo "$read_out" | grep -q '"reason":"the log did not read back"'; then
  bad "the log did not read back — this is the ehdb_unavailable shape"
elif [ -z "$read_out" ]; then
  bad "read-back probe produced no JSON"
else
  ok "the whole log reads back cleanly after the hammer"
fi

echo
echo "-- 5. the writer's own counters agree (delta against this run's baseline) --"
post_ok=$(metric 'tier_service.append",outcome="ok"')
post_err=$(metric 'tier_service.append",outcome="error"')
info "append ok: $base_ok -> $post_ok    error: $base_err -> $post_err"
if [ "$post_err" = "__ABSENT__" ] || [ "$post_err" = "$base_err" ]; then
  ok "append error count did not move (prod soak moved it to 302)"
else
  bad "append errors moved $base_err -> $post_err"
fi

echo
echo "== PASS $PASS   FAIL $FAIL =="
echo "store left at $FRESH_DIR on the writer PVC for inspection"
[ "$FAIL" -eq 0 ]
