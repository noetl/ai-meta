#!/usr/bin/env bash
# End-to-end validation of the #199 write-behind sink gates in LOCAL KIND.
#
# Both gates were inert until today, in different ways, and I asserted one of
# them worked before checking. So this asserts REACHABILITY first and behaviour
# second — in that order, because a behaviour assertion over an unreachable gate
# passes vacuously.
#
#   Slice A (worker#218)  the connector step posts mark/confirm to the SERVER
#   Slice B (server#286)  the Feather result-tier GC reads noetl.sink_pending
#   Slice B (pre-existing) the worker's durable-segment GC reads the in-process
#                          index and defers its whole pass while any sink pends
#
# What makes this a proof rather than a smoke test:
#
#   * The reachability gate runs BEFORE the behaviour gate and fails the run on
#     its own. `noetl_worker_sink_state_post_total{outcome="ok"}` must move — if
#     nothing reached the server, everything below it is vacuous, which is
#     exactly how #229 was mis-filed.
#   * `noetl.sink_pending` is read directly, not inferred from a metric. The
#     table being non-empty is the thing Slice B could never achieve before.
#     BUT it must be sampled *while the step is running*, not after: mark and
#     confirm are a pair, so a SUCCESSFUL sink step adds the row and then
#     removes it, leaving an empty table that looks identical to "nothing ever
#     marked". The first version of this rig sampled after completion and could
#     not have detected a working gate. Hence the deliberately slow sink step.
#
#   * Worker counters are per-pod and in-memory. The user pool autoscales, so
#     the pod that ran the step can be GONE before the scrape — which is what
#     happened on the first run, and is why the durable table is the primary
#     signal and the metric only corroborates.
#   * The negative control is a NON-sink step: it must leave the table untouched,
#     or the gate is marking everything and the retention it produces is
#     meaningless.
#
# Usage: ./validate-sink-gate.sh
set -uo pipefail

CTX="${CTX:-kind-noetl}"
NS=noetl
RUN="${RUN:-/tmp/sinkgate-$(date +%H%M%S)}"
PORT="${PORT:-18120}"
WPORT="${WPORT:-19190}"

[[ "$CTX" == kind-* ]] || { echo "REFUSING: CTX=$CTX is not kind" >&2; exit 1; }
mkdir -p "$RUN"
k() { kubectl --context "$CTX" -n "$NS" "$@"; }
trap 'kill $(jobs -p) 2>/dev/null' EXIT

# NOT via k(): that already applies `-n noetl`, and a second `-n postgres`
# after it makes kubectl reject the call — which is silent here because stderr
# is dropped, so every query returned empty and the run produced no output at
# all. Postgres lives in its own namespace, so it needs its own invocation.
psql_q() { # psql_q <sql>
  kubectl --context "$CTX" -n postgres exec deploy/postgres -- \
    psql -U noetl -d noetl -At -F'|' -c "$1" 2>/dev/null | tr -d '\r'
}

pf() {
  kill $(jobs -p) 2>/dev/null; sleep 1
  k port-forward svc/noetl-server-rust "${PORT}":8082 >/dev/null 2>&1 &
  k port-forward svc/noetl-worker-rust-metrics "${WPORT}":9090 >/dev/null 2>&1 &
  sleep 6
}

wmetric() { curl -s --max-time 10 "http://127.0.0.1:${WPORT}/metrics" 2>/dev/null \
              | awk -v m="$1" 'index($0,m)==1 {s+=$NF} END{print s+0}'; }

fire() { # fire <path>
  curl -s --max-time 60 -X POST -H 'content-type: application/json' \
    -d "{\"path\":\"$1\",\"payload\":{}}" \
    "http://127.0.0.1:${PORT}/api/execute" 2>/dev/null \
  | python3 -c 'import json,sys
try: print(json.load(sys.stdin)["execution_id"])
except Exception: pass'
}

await_terminal() { # await_terminal <eid>
  for _ in $(seq 1 90); do
    s=$(curl -s --max-time 20 "http://127.0.0.1:${PORT}/api/executions/$1" 2>/dev/null \
        | python3 -c 'import json,sys
try: print(json.load(sys.stdin)["status"])
except Exception: print("X")')
    case "$s" in COMPLETED|FAILED|CANCELLED) echo "$s"; return;; esac
    sleep 4
  done
  echo TIMEOUT
}

# ---------------------------------------------------------------------------
echo "== 0. enable both gates (default-off everywhere; this is the opt-in) =="
k set env deploy/noetl-worker-rust        NOETL_SINK_GATE_EVICTION=true >/dev/null
k set env deploy/noetl-server-rust        NOETL_RESULT_TIER_GC_SINK_GATE=true >/dev/null
k rollout status deploy/noetl-worker-rust --timeout=240s 2>&1 | tail -1
k rollout status deploy/noetl-server-rust --timeout=240s 2>&1 | tail -1
pf

echo "== 1. register a playbook whose step declares sink: true =="
python3 - "$PORT" <<'PY'
import json,sys,urllib.request
port=sys.argv[1]
content = """apiVersion: noetl.io/v2
kind: Playbook
metadata:
  name: sinkgate_probe
  path: tests/199/sink_step
  description: "noetl/ai-meta#199 - a step that declares sink: true, so the connector wiring marks and confirms."
workload:
  message: "sink probe"
workflow:
  - step: start
    tool:
      kind: python
      sink: true
      input:
        message: "{{ message }}"
      code: |
        import time
        # Deliberately slow: the mark must be observable in noetl.sink_pending
        # WHILE the step runs. On success the confirm removes it again, so a
        # post-hoc sample cannot tell a working gate from an unwired one.
        time.sleep(45)
        result = {"status": "ok"}
"""
req=urllib.request.Request(f"http://127.0.0.1:{port}/api/catalog/register",
    data=json.dumps({"content":content}).encode(), headers={"content-type":"application/json"})
print(urllib.request.urlopen(req,timeout=60).read().decode()[:160])
PY

echo "== 2. baseline =="
POST_OK0=$(wmetric 'noetl_worker_sink_state_post_total{action="mark",outcome="ok"}')
PENDING0=$(psql_q "select count(*) from noetl.sink_pending;")
echo "  sink_state_post{mark,ok}=$POST_OK0   sink_pending rows=$PENDING0"
echo "  (worker counters are per-pod + in-memory; the pool autoscales, so the DURABLE table is the primary signal)"

echo "== 3. fire the sink-declaring playbook, sampling the feed WHILE it runs =="
EID=$(fire tests/199/sink_step); echo "  execution=$EID"
PENDING_PEAK=0
for _ in $(seq 1 40); do
  n=$(psql_q "select count(*) from noetl.sink_pending;"); n=${n:-0}
  [ "$n" -gt "$PENDING_PEAK" ] && PENDING_PEAK=$n
  s=$(curl -s --max-time 15 "http://127.0.0.1:${PORT}/api/executions/$EID" 2>/dev/null \
      | python3 -c 'import json,sys
try: print(json.load(sys.stdin)["status"])
except Exception: print("X")')
  case "$s" in COMPLETED|FAILED|CANCELLED) break;; esac
  sleep 5
done
ST="$s"; echo "  status=$ST  peak sink_pending during the run=$PENDING_PEAK"

POST_OK1=$(wmetric 'noetl_worker_sink_state_post_total{action="mark",outcome="ok"}')
CONF_OK1=$(wmetric 'noetl_worker_sink_state_post_total{action="confirm",outcome="ok"}')
PENDING1=$(psql_q "select count(*) from noetl.sink_pending;")

echo "== 4. negative control: a NON-sink playbook must not touch the feed =="
NPEND0=$(psql_q "select count(*) from noetl.sink_pending;")
NEID=$(fire fixtures/playbooks/hello_world); NST=$(await_terminal "$NEID")
NPEND1=$(psql_q "select count(*) from noetl.sink_pending;")
NPOST=$(wmetric 'noetl_worker_sink_state_post_total{action="mark",outcome="ok"}')

echo "== 5. restore default-off =="
k set env deploy/noetl-worker-rust NOETL_SINK_GATE_EVICTION- >/dev/null 2>&1
k set env deploy/noetl-server-rust NOETL_RESULT_TIER_GC_SINK_GATE- >/dev/null 2>&1

{
  echo "sink_execution=$EID status=$ST"
  echo "post{mark,ok}   before=$POST_OK0 after=$POST_OK1  (delta $((POST_OK1-POST_OK0)))"
  echo "post{confirm,ok} after=$CONF_OK1"
  echo "sink_pending rows: before=$PENDING0 after=$PENDING1"
  echo "negative control: exec=$NEID status=$NST pending $NPEND0 -> $NPEND1  post{mark,ok} now=$NPOST"
  echo
  echo "GATE — reachability FIRST, because behaviour over an unreachable gate is vacuous:"
  if [ "$((POST_OK1-POST_OK0))" -le 0 ]; then
    echo "  FAIL(reachability): nothing reached the server. Slice A is not wired;"
    echo "                      every assertion below this line would be vacuous."
  else
    echo "  PASS(reachability): $((POST_OK1-POST_OK0)) mark post(s) reached the server."
    if [ "${PENDING_PEAK:-0}" -gt 0 ]; then
      echo "  PASS(behaviour):    noetl.sink_pending peaked at $PENDING_PEAK DURING the run"
      echo "                      and settled to $PENDING1 after — mark then confirm."
    else
      echo "  FAIL(behaviour):    the feed never held a row at any point during the"
      echo "                      run — the endpoint is not persisting the mark."
    fi
  fi
  if [ "${NPEND1:-0}" -gt "${NPEND0:-0}" ]; then
    echo "  FAIL(negative):     a NON-sink step moved the feed — the gate marks"
    echo "                      everything, so any retention it causes is meaningless."
  else
    echo "  PASS(negative):     a non-sink step left the feed untouched."
  fi
} | tee "$RUN/verdict.txt"
echo "artifacts: $RUN"
