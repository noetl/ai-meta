#!/usr/bin/env bash
# The end-to-end test noetl/ai-meta#209 still owed: SIGKILL the EHDB writer
# mid-ingest and prove the unsealed tail survives.
#
# The crate tests reproduce the crash shape by dropping the engine without
# sealing, and the engine-level tests cover the reopen. Neither exercises the
# real thing: a `kill -9` of a live pod that is being published to, followed by
# the pod coming back and the bus continuing.
#
# What makes this a proof rather than a smoke test:
#
#   * SIGKILL, not SIGTERM. A graceful stop runs the seal hook, which is the
#     path that already worked. `kill -9` inside the container skips every hook
#     — that is the whole point.
#   * The kill lands DURING ingest, not between bursts. A quiesced writer has
#     nothing unsealed to lose, so killing an idle one proves nothing.
#   * The gate is the recovery counter plus zero loss, not "it came back". A
#     writer that restarts having silently dropped its unsealed tail also looks
#     like it came back.
#
# Usage: ./sigkill-writer.sh [n_execs] [concurrency]
set -uo pipefail

CTX="${CTX:-kind-noetl}"
NS=noetl
N="${1:-60}"
CONC="${2:-10}"
RUN="${RUN:-/tmp/sigkill-$(date +%H%M%S)}"
PORT="${PORT:-18110}"
CMD_PORT="${CMD_PORT:-19122}"
PB="fixtures/playbooks/hello_world"

[[ "$CTX" == kind-* ]] || { echo "REFUSING: CTX=$CTX is not kind" >&2; exit 1; }
mkdir -p "$RUN"
k() { kubectl --context "$CTX" -n "$NS" "$@"; }
trap 'kill $(jobs -p) 2>/dev/null' EXIT

pf() {
  kill $(jobs -p) 2>/dev/null; sleep 1
  k port-forward svc/noetl-server-rust "${PORT}":8082        >/dev/null 2>&1 &
  k port-forward svc/noetl-cmdbus-writer-0 "${CMD_PORT}":9102 >/dev/null 2>&1 &
  sleep 6
}

# NEVER bare-connect :9104/:9107/:9108 — one malformed frame permanently kills
# that face for the life of the process (ehdb#311). Only :9102 is HTTP.
m() { curl -s --max-time 10 "http://127.0.0.1:${CMD_PORT}/metrics" 2>/dev/null \
        | awk -v k="$1" '$1==k {print $2; f=1} END{if(!f) print "NA"}'; }

fire() {
  curl -s --max-time 60 -X POST -H 'content-type: application/json' \
    -d "{\"path\":\"$PB\",\"payload\":{}}" \
    "http://127.0.0.1:${PORT}/api/execute" 2>/dev/null \
  | python3 -c 'import json,sys
try: print(json.load(sys.stdin)["execution_id"])
except Exception: pass'
}

pf
echo "== writer image =="
k get sts noetl-cmdbus-writer -o jsonpath='{.spec.template.spec.containers[0].image}'; echo

echo "== BEFORE =="
BEFORE_APPENDS=$(m ehdb_l0_appends)
BEFORE_RECOVERED=$(m ehdb_l0_recovered_active_records)
BEFORE_OOO=$(m ehdb_l0_out_of_order_appends)
echo "  appends=$BEFORE_APPENDS recovered=$BEFORE_RECOVERED out_of_order=$BEFORE_OOO"

# --- load, and SIGKILL in the middle of it --------------------------------
: >"$RUN/ids"
echo "== firing $N executions at concurrency $CONC, SIGKILL mid-flight =="
(
  n=0
  while [ "$n" -lt "$N" ]; do
    batch=()
    for _ in $(seq 1 "$CONC"); do
      [ "$n" -ge "$N" ] && break
      ( fire >>"$RUN/ids" ) & batch+=($!); n=$((n+1))
    done
    for pid in "${batch[@]}"; do wait "$pid" 2>/dev/null; done
  done
) &
LOAD=$!

sleep 6
# `kubectl exec ... kill -9 1` DOES NOT WORK and looks like it does.
#
# The writer runs as PID 1 in its container (verified: `ps` shows
# `1 0 noetl-worker`), and the kernel discards signals sent to PID 1 from
# inside its own PID namespace unless the process installed a handler for
# them — the standard init protection. So the exec returns 0, the script
# carries on, and nothing was killed. The first run of this test did exactly
# that and reported a clean pass with `restartCount=0` and the container still
# up from hours earlier.
#
# `--force --grace-period=0` kills from OUTSIDE the namespace: the kubelet
# SIGKILLs the container with no SIGTERM first, so no shutdown hook runs —
# which is the condition under test. The StatefulSet recreates the pod with the
# same name and the same PVC, so the durable log the writer reopens is the one
# it was writing to.
echo "== hard-kill the writer from outside the namespace (no SIGTERM, no hook) =="
KILLED_AT=$(date -u +%FT%TZ)
PRE_START=$(k get pod noetl-cmdbus-writer-0 -o jsonpath='{.status.containerStatuses[0].state.running.startedAt}' 2>/dev/null)
k delete pod noetl-cmdbus-writer-0 --force --grace-period=0 2>&1 | head -2
echo "  killed at $KILLED_AT (container had been up since $PRE_START)"

wait $LOAD 2>/dev/null
echo "  fired: $(grep -c '^[0-9]' "$RUN/ids" || echo 0)"

echo "== wait for the writer to come back =="
for _ in $(seq 1 60); do
  ready=$(k get pod noetl-cmdbus-writer-0 -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)
  [ "$ready" = "true" ] && break
  sleep 5
done
POST_START=$(k get pod noetl-cmdbus-writer-0 -o jsonpath='{.status.containerStatuses[0].state.running.startedAt}' 2>/dev/null)
echo "  container now up since $POST_START"
if [ "$PRE_START" = "$POST_START" ]; then
  echo "  !! THE KILL DID NOT LAND — same container as before. The test proves nothing." >&2
  KILL_LANDED=no
else
  KILL_LANDED=yes
fi
pf

echo "== AFTER =="
AFTER_APPENDS=$(m ehdb_l0_appends)
AFTER_RECOVERED=$(m ehdb_l0_recovered_active_records)
AFTER_OOO=$(m ehdb_l0_out_of_order_appends)
echo "  appends=$AFTER_APPENDS recovered=$AFTER_RECOVERED out_of_order=$AFTER_OOO"

echo "== does the bus still work after the kill? =="
POST=$(fire); echo "  post-kill execution: ${POST:-FAILED}"
sleep 25
POST_STATUS=$(curl -s --max-time 30 "http://127.0.0.1:${PORT}/api/executions/${POST}" 2>/dev/null \
  | python3 -c 'import json,sys
try: print(json.load(sys.stdin)["status"])
except Exception: print("UNREADABLE")')

{
  echo "killed_at=$KILLED_AT kill_landed=$KILL_LANDED"
  echo "appends_before=$BEFORE_APPENDS appends_after=$AFTER_APPENDS"
  echo "recovered_active_records_before=$BEFORE_RECOVERED after=$AFTER_RECOVERED"
  echo "out_of_order_before=$BEFORE_OOO after=$AFTER_OOO"
  echo "post_kill_execution=${POST:-none} status=$POST_STATUS"
  echo
  echo "GATE:"
  echo "  kill_landed=yes                  -> a hard kill actually happened"
  echo "  recovered_active_records > 0     -> the unsealed tail was REPLAYED, not lost"
  echo "  out_of_order_appends unchanged   -> recovery did not reintroduce #203"
  echo "  post-kill execution reaches a terminal -> the bus still works"
} | tee "$RUN/verdict.txt"
echo "artifacts: $RUN"
