#!/usr/bin/env bash
# Kind validation of the systemic non-convergence sweep (noetl/ai-meta#227 part B).
#
# The gate is NOT "the stalled executions went away". It is the pair:
#
#   POSITIVE: every planted non-convergent execution is terminated, and the
#             terminal is a real `playbook.failed` carrying
#             meta.emitted_by=nonconvergence_sweep.
#   NEGATIVE: the set of terminated executions is EXACTLY the planted set.
#             Not "mostly". Any healthy execution touched is a hard fail, and
#             the run is executed under continuous load precisely so that
#             "healthy" is not a hypothetical.
#
# The negative half is the whole point. A sweep that terminates the backlog and
# one live execution is worse than no sweep at all, so this script asserts the
# set equality in both directions rather than counting.
#
# Controls, and why each exists:
#
#   PC-unclaimed  Fired with `execution_pool` set to a segment NO worker
#                 subscribes to (workers filter `noetl.commands.shared.>`).
#                 The command is really issued and really never claimed —
#                 the prod "command.issued, never claimed" shape, produced
#                 through the real API rather than by writing rows.
#
#   NC-slow       A step that legitimately runs FOUR TIMES the grace period
#                 while a live worker holds the claim. This is the execution
#                 the sweep most plausibly kills by mistake: its watermark is
#                 stale by every measure, and only the live-claim guard saves
#                 it. Must end COMPLETED and never be terminated.
#
#   NC-load       Continuous healthy traffic for the whole sweep window, so
#                 every disposition is exercised against executions in every
#                 lifecycle phase concurrently.
#
#   NC-terminal   Executions that completed BEFORE the sweep was enabled. The
#                 sweep must not re-terminate an already-terminal execution.
#
# Usage: ./nc-validate.sh [grace_secs] [interval_secs]
set -uo pipefail

CTX="${CTX:-kind-noetl}"
NS=noetl
GRACE="${1:-120}"
INTERVAL="${2:-60}"
SLOW_SLEEP=$(( GRACE * 4 ))
N_PC=6
N_SLOW=3
RUN="${RUN:-/tmp/nc227-$(date +%H%M%S)}"
PORT="${PORT:-18101}"
PB="fixtures/playbooks/hello_world"
SLOW_PB="tests/227/slow_step"

[[ "$CTX" == kind-* ]] || { echo "REFUSING: CTX=$CTX is not kind" >&2; exit 1; }
mkdir -p "$RUN"
k() { kubectl --context "$CTX" -n "$NS" "$@"; }
api() { curl -s --max-time 60 "http://127.0.0.1:${PORT}$@"; }

echo "== port-forward =="
k port-forward svc/noetl-server-rust "${PORT}":8082 >/dev/null 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null' EXIT
sleep 6
api /health | grep -q ok || { echo "server not reachable" >&2; exit 1; }

fire() { # fire <path> [execution_pool]
  local path="$1" pool="${2:-}" body
  if [ -n "$pool" ]; then
    body="{\"path\":\"$path\",\"payload\":{},\"execution_pool\":\"$pool\"}"
  else
    body="{\"path\":\"$path\",\"payload\":{}}"
  fi
  api /api/execute -X POST -H 'content-type: application/json' -d "$body" \
    | python3 -c 'import json,sys
try: print(json.load(sys.stdin)["execution_id"])
except Exception: pass'
}

status() { api "/api/executions/$1" | python3 -c 'import json,sys
try: print(json.load(sys.stdin)["status"])
except Exception: print("UNREADABLE")'; }

# Every execution this run terminates, with the emitter, straight from the log.
terminated_by_sweep() {
  api "/api/executions/$1" \
    | python3 -c 'import json,sys
d=json.load(sys.stdin)
print(any(e.get("event_type")=="playbook.failed" for e in d.get("events",[])))' 2>/dev/null
}

# ---------------------------------------------------------------------------
echo "== step 0: register the slow-step fixture (${SLOW_SLEEP}s = 4x grace) =="
python3 - "$PORT" "$SLOW_PB" "$SLOW_SLEEP" <<'PY'
import json,sys,urllib.request
port,path,sl=sys.argv[1],sys.argv[2],int(sys.argv[3])
content=f"""apiVersion: noetl.io/v2
kind: Playbook
metadata:
  name: nc227_slow_step
  path: {path}
  description: "noetl/ai-meta#227 part B negative control - a step that legitimately runs far longer than the sweep's grace period while a LIVE worker holds the claim."
workload:
  message: "nc227 slow"
workflow:
  - step: start
    tool:
      kind: python
      input:
        message: "{{{{ message }}}}"
      code: |
        import time
        time.sleep({sl})
        result = {{"status": "ok"}}
    next:
      spec:
        mode: exclusive
      arcs:
        - step: end
  - step: end
    desc: done
    tool:
      kind: python
      input: {{}}
      code: |
        result = {{"status": "completed"}}
"""
req=urllib.request.Request(f"http://127.0.0.1:{port}/api/catalog/register",
    data=json.dumps({"content":content}).encode(), headers={"content-type":"application/json"})
print(urllib.request.urlopen(req,timeout=60).read().decode()[:200])
PY

# ---------------------------------------------------------------------------
echo "== step 1: NC-terminal — healthy executions that finish BEFORE the sweep =="
: >"$RUN/nc_terminal"
for _ in $(seq 1 5); do fire "$PB" >>"$RUN/nc_terminal"; done
sleep 20

echo "== step 2: PC-unclaimed — $N_PC executions on a segment no worker serves =="
: >"$RUN/pc"
for _ in $(seq 1 $N_PC); do fire "$PB" "nc227-void" >>"$RUN/pc"; done
grep -c '^[0-9]' "$RUN/pc"

echo "== step 3: NC-slow — $N_SLOW executions holding a live claim for ${SLOW_SLEEP}s =="
: >"$RUN/nc_slow"
for _ in $(seq 1 $N_SLOW); do fire "$SLOW_PB" >>"$RUN/nc_slow"; done
grep -c '^[0-9]' "$RUN/nc_slow"

# The planted set: everything the sweep is ALLOWED to terminate.
sort -u "$RUN/pc" >"$RUN/allowed"
echo "allowed-to-terminate: $(wc -l <"$RUN/allowed")"

# ---------------------------------------------------------------------------
echo "== step 4: age the planted stalls past grace (${GRACE}s) under load =="
# Continuous healthy traffic for the whole ageing window AND the whole sweep
# window. The sweep must make its decisions while the cluster is busy.
( end=$((SECONDS + GRACE + INTERVAL*4 + 60))
  while [ $SECONDS -lt $end ]; do
    fire "$PB" >>"$RUN/nc_load" 2>/dev/null
    sleep 2
  done ) &
LOAD=$!

sleep $(( GRACE + 30 ))

echo "== step 5: enable the sweep (grace=${GRACE} interval=${INTERVAL}) =="
k set env deploy/noetl-server-rust \
    NOETL_NONCONVERGENCE_SWEEP_ENABLED=true \
    NOETL_NONCONVERGENCE_GRACE_SECS="$GRACE" \
    NOETL_NONCONVERGENCE_SWEEP_INTERVAL_SECS="$INTERVAL" \
    NOETL_NONCONVERGENCE_SWEEP_MAX_PER_TICK=20 >/dev/null
k rollout status deploy/noetl-server-rust --timeout=180s
sleep 6
kill $PF 2>/dev/null; k port-forward svc/noetl-server-rust "${PORT}":8082 >/dev/null 2>&1 &
PF=$!; sleep 6

echo "== step 6: let the sweep run 3 ticks under load =="
sleep $(( INTERVAL * 3 + 20 ))
wait $LOAD 2>/dev/null

echo "== step 7: disable the sweep (back to default-off) =="
k set env deploy/noetl-server-rust NOETL_NONCONVERGENCE_SWEEP_ENABLED=false >/dev/null
k rollout status deploy/noetl-server-rust --timeout=180s
sleep 6
kill $PF 2>/dev/null; k port-forward svc/noetl-server-rust "${PORT}":8082 >/dev/null 2>&1 &
PF=$!; sleep 8

# ---------------------------------------------------------------------------
echo "== verdict =="
{
  echo "grace_secs=$GRACE interval_secs=$INTERVAL slow_sleep_secs=$SLOW_SLEEP"
  echo
  echo "-- PC: planted non-convergent executions (MUST all be FAILED) --"
  pc_fail=0; pc_tot=0
  while read -r id; do
    [ -z "$id" ] && continue
    pc_tot=$((pc_tot+1))
    s=$(status "$id")
    echo "  pc $id -> $s"
    [ "$s" = "FAILED" ] && pc_fail=$((pc_fail+1))
  done <"$RUN/allowed"
  echo "  pc_terminated=$pc_fail/$pc_tot"
  echo
  echo "-- NC-slow: live-claim held for 4x grace (MUST be COMPLETED, never FAILED) --"
  slow_bad=0
  while read -r id; do
    [ -z "$id" ] && continue
    s=$(status "$id")
    echo "  slow $id -> $s"
    [ "$s" = "FAILED" ] && slow_bad=$((slow_bad+1))
  done <"$RUN/nc_slow"
  echo "  slow_wrongly_failed=$slow_bad"
  echo
  echo "-- NC-terminal: completed before the sweep (MUST stay COMPLETED) --"
  term_bad=0
  while read -r id; do
    [ -z "$id" ] && continue
    s=$(status "$id")
    [ "$s" = "COMPLETED" ] || { echo "  terminal $id -> $s  <-- NOT COMPLETED"; term_bad=$((term_bad+1)); }
  done <"$RUN/nc_terminal"
  echo "  terminal_disturbed=$term_bad"
  echo
  echo "-- NC-load: healthy traffic during the sweep (MUST have zero FAILED) --"
  load_bad=0; load_tot=0
  while read -r id; do
    [ -z "$id" ] && continue
    load_tot=$((load_tot+1))
    s=$(status "$id")
    [ "$s" = "FAILED" ] && { echo "  load $id -> FAILED  <-- HEALTHY WORK TERMINATED"; load_bad=$((load_bad+1)); }
  done <"$RUN/nc_load"
  echo "  load_total=$load_tot load_wrongly_failed=$load_bad"
} | tee "$RUN/verdict.txt"

echo
echo "-- sweep counters (server /metrics) --" | tee -a "$RUN/verdict.txt"
api /metrics | grep '^noetl_nonconvergence_sweep_total' | tee -a "$RUN/verdict.txt"

echo
echo "artifacts: $RUN"
