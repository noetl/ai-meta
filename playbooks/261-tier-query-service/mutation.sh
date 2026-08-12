#!/usr/bin/env bash
# The mutation arm for ai-meta#257 PR 4: prove the read really leaves the pod.
#
# The `service` arm shows every replica returning the same full set. On its own
# that is consistent with two different worlds:
#
#   (a) the read resolves through the writer's tier service, as configured; or
#   (b) the read silently falls back to the pod-local store, and the pod-local
#       stores happen to agree.
#
# In the `service` arm (b) is not idle speculation — it is what the code did
# before this change, and the pod-local stores are all EMPTY there, so a
# fall-back would return 0 everywhere and be caught. But 0-everywhere is also
# what a broken service returns, so the arm alone cannot separate them.
#
# This constructs the state that does: **the pod-local store holds the records
# and the service store does not.** Then:
#
#   read resolves through the service  ⇒ 0 records, verdict changes.  ✅
#   read falls back to pod-local       ⇒ 13 records, verdict "match". ❌
#
# Crucially it does this WITHOUT restarting a worker. A `kubectl set env` flip
# would roll the pods, and the pod-local store lives on the container filesystem
# — it would be wiped by the very act of setting up the test, and the mutation
# would then be measuring an empty store against an empty store.
#
# Usage: mutation.sh <execution_id>
set -uo pipefail

NS=noetl
EXEC_ID="${1:?usage: mutation.sh <execution_id>}"
TIER_DIR="${TIER_DIR:-/data/eventbus/tier}"
LOCAL_LOG="${LOCAL_LOG:-/tmp/ehdb/ref.jsonl}"

k() { kubectl --context kind-noetl -n "$NS" "$@"; }

writer=$(k get pod -l app=noetl-cmdbus-writer -o jsonpath='{.items[0].metadata.name}')
[ -n "$writer" ] || { echo "no writer pod" >&2; exit 2; }

echo "-- 1. the writer's tier store, before --"
before=$(k exec "$writer" -- sh -c "wc -l < $TIER_DIR/eventlog.jsonl" 2>/dev/null | tr -d ' \r')
echo "   $TIER_DIR/eventlog.jsonl: ${before:-0} records"
if [ "${before:-0}" -lt 1 ]; then
  echo "ABORT: the service store is already empty; there is nothing to move and the" >&2
  echo "       mutation would prove nothing. Run the 'service' arm first." >&2
  exit 2
fi

echo "-- 2. seed every replica's POD-LOCAL store with those records --"
# The whole point: after this, a fall-back to local would find the data.
k exec "$writer" -- sh -c "cat $TIER_DIR/eventlog.jsonl" > /tmp/pr4-tier-seed.jsonl
seeded=0
for pod in $(k get pods -l app=noetl-worker-rust -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{"\n"}{end}'); do
  k exec "$pod" -c worker -- sh -c "mkdir -p $(dirname $LOCAL_LOG)" 2>/dev/null
  k cp /tmp/pr4-tier-seed.jsonl "$NS/$pod:$LOCAL_LOG" -c worker 2>/dev/null \
    && { echo "   seeded $pod:$LOCAL_LOG"; seeded=$((seeded+1)); } \
    || echo "   FAILED to seed $pod"
done
if [ "$seeded" -lt 1 ]; then
  echo "ABORT: seeded no replica; the mutation cannot discriminate." >&2
  exit 2
fi

echo "-- 3. empty the SERVICE store (no restart, no env change) --"
k exec "$writer" -- sh -c ": > $TIER_DIR/eventlog.jsonl"
after=$(k exec "$writer" -- sh -c "wc -l < $TIER_DIR/eventlog.jsonl" 2>/dev/null | tr -d ' \r')
echo "   $TIER_DIR/eventlog.jsonl: ${after:-?} records"
[ "${after:-1}" -eq 0 ] || { echo "ABORT: failed to empty the service store" >&2; exit 2; }

echo
echo "state now: pod-local stores HOLD execution $EXEC_ID; the tier service does NOT."
echo "a read that still returns records is reading the wrong store."
