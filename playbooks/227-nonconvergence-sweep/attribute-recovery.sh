#!/usr/bin/env bash
# noetl/ai-meta#209 — settle WHO recovers the unsealed tail.
#
# The question this answers, which three SIGKILL runs could not:
#
#   The engine recovers a real captured active part 18/18 in a test, the
#   deployed writer reports `recovered_active_records = 0` after a hard kill,
#   and the records survive anyway (a new sealed part covering exactly the
#   missing range appears on restart). Either `recover_active_parts` does not
#   run in the deployed binary, or something else replays the tail.
#
#   A counter reading 0 cannot distinguish "did not run" from "ran and found
#   nothing". worker#219/#220 log the count at engine open on all three L0
#   engines, so the log CAN.
#
# Verdict logic:
#   log line present, count > 0  -> recover_active_parts ran and did the work.
#                                   #209 closes with attribution; the metric was
#                                   the only thing broken.
#   log line present, count == 0  -> the path ran and found nothing, yet records
#                                   survive => SOMETHING ELSE replays the tail.
#                                   ehdb#313's description must be corrected to
#                                   "torn-tail truncation + sequence
#                                   reconciliation, not replay".
#   log line absent               -> the deployed binary lacks the instrumentation
#                                   (wrong image) — inconclusive, do not guess.
#
# Usage: ./attribute-recovery.sh <worker-image-ref>
set -uo pipefail

CTX="${CTX:-kind-noetl}"
NS=noetl
IMG="${1:?usage: attribute-recovery.sh <worker-image-ref>}"
PORT="${PORT:-18130}"
CMD_PORT="${CMD_PORT:-19132}"

[[ "$CTX" == kind-* ]] || { echo "REFUSING: CTX=$CTX is not kind" >&2; exit 1; }
k() { kubectl --context "$CTX" -n "$NS" "$@"; }
trap 'kill $(jobs -p) 2>/dev/null' EXIT

echo "== deploy $IMG to the writer =="
k set image sts/noetl-cmdbus-writer noetl-worker="$IMG" >/dev/null
k rollout status sts/noetl-cmdbus-writer --timeout=300s 2>&1 | tail -1

echo "== confirm the instrumentation is actually in this image =="
k logs noetl-cmdbus-writer-0 2>&1 | grep -c "recovered_active_records" | sed 's/^/   log lines mentioning the counter: /'
if ! k logs noetl-cmdbus-writer-0 2>&1 | grep -q "recovered_active_records"; then
  echo "VERDICT: INCONCLUSIVE — this image has no startup instrumentation." >&2
  echo "         Do not infer anything from the metric alone; get the right image." >&2
  exit 2
fi

k port-forward svc/noetl-server-rust "${PORT}":8082 >/dev/null 2>&1 &
sleep 6

echo "== build an unsealed tail (verified on disk, not assumed) =="
for _ in $(seq 1 12); do
  curl -s -m 25 -X POST -H 'content-type: application/json' \
    -d '{"path":"fixtures/playbooks/hello_world","payload":{}}' \
    "http://127.0.0.1:${PORT}/api/execute" >/dev/null &
done
wait; sleep 5
BYTES=$(k exec noetl-cmdbus-writer-0 -- sh -c \
  'wc -c < /data/cmdbus/parts/d1_event_log/shard-0/part-000000.active' 2>/dev/null | tr -d ' \r')
echo "   active part: ${BYTES:-0} bytes"
if [ "${BYTES:-0}" -lt 100 ]; then
  echo "VERDICT: INCONCLUSIVE — no unsealed tail to lose; nothing would be recovered." >&2
  exit 2
fi

echo "== hard kill (kubelet SIGKILL, no SIGTERM, no hook) =="
PRE=$(k get pod noetl-cmdbus-writer-0 -o jsonpath='{.status.containerStatuses[0].state.running.startedAt}')
k delete pod noetl-cmdbus-writer-0 --force --grace-period=0 >/dev/null 2>&1
k wait --for=condition=Ready pod/noetl-cmdbus-writer-0 --timeout=240s >/dev/null 2>&1
POST=$(k get pod noetl-cmdbus-writer-0 -o jsonpath='{.status.containerStatuses[0].state.running.startedAt}')
[ "$PRE" = "$POST" ] && { echo "VERDICT: INCONCLUSIVE — the kill did not land." >&2; exit 2; }
echo "   kill landed ($PRE -> $POST)"

echo
echo "== THE ANSWER — the writer's own words =="
k logs noetl-cmdbus-writer-0 2>&1 | grep "recovered_active_records" | head -4
echo
COUNT=$(k logs noetl-cmdbus-writer-0 2>&1 \
  | grep -o 'recovered_active_records[=[:space:]]*[0-9]\+' | head -1 \
  | grep -o '[0-9]\+$')
echo "== VERDICT =="
if [ -z "${COUNT:-}" ]; then
  echo "  INCONCLUSIVE — the line is there but the count could not be parsed."
elif [ "$COUNT" -gt 0 ]; then
  echo "  recover_active_parts RAN and recovered $COUNT records."
  echo "  => #209 closes with attribution. The metric was the only broken part."
else
  echo "  recover_active_parts RAN and recovered 0 — yet the records survive."
  echo "  => SOMETHING ELSE replays the tail. ehdb#313's value is the torn-tail"
  echo "     truncation + sequence reconciliation, NOT the replay, and its"
  echo "     description must be corrected."
fi
echo
echo "  corroborate with the sealed part that appears post-restart:"
k exec noetl-cmdbus-writer-0 -- sh -c 'ls -t /data/cmdbus/parts/d1_event_log/shard-0/*.eslog 2>/dev/null | head -2'
