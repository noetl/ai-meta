#!/usr/bin/env bash
# Kind validation of the permanent-log-lean strip (noetl/ai-meta#195 + #196).
#
# Measured on prod: 461 MB across 151,960 rows — 83% of all `result` bytes in
# `noetl.event` — sit above the 512-byte floor this strip externalises. So the
# question is not whether it is worth enabling but whether it is SAFE to.
#
# The strip rewrites an over-floor inline business result into the same
# `reference` + `extracted` shape a large result already carries. Three things
# could go wrong, and this asserts each rather than assuming:
#
#   1. It strips nothing (inert) — the failure mode this session has hit six
#      times. Asserted by the metric moving AND the persisted row actually
#      changing shape in Postgres.
#   2. It strips too much — a small control scalar loses its inline value and
#      readers that expect it break. Asserted by a NEGATIVE CONTROL: a
#      sub-floor result must stay inline.
#   3. It strips correctly but the data becomes unreadable — the whole point is
#      that `hydrate_result_references` resolves it. Asserted by reading the
#      execution back through the API and requiring the payload to still be
#      there.
#
# The off-server drive is expected to be structurally immune (it reads the WAL,
# not `noetl.event` — `dispatch_offserver_stateless_drive` does zero event
# reads), so an execution completing normally is a check on that claim, not a
# formality.
#
# Enables the flag, exercises it, RESTORES DEFAULT-OFF at the end.
# Usage: ./validate-lean-strip.sh
set -uo pipefail

CTX="${CTX:-kind-noetl}"
NS=noetl
PORT="${PORT:-18140}"
RUN="${RUN:-/tmp/leanstrip-$(date +%H%M%S)}"

[[ "$CTX" == kind-* ]] || { echo "REFUSING: CTX=$CTX is not kind" >&2; exit 1; }
mkdir -p "$RUN"
k() { kubectl --context "$CTX" -n "$NS" "$@"; }
trap 'kill $(jobs -p) 2>/dev/null' EXIT

pq() { k exec deploy/postgres -n postgres -- psql -U noetl -d noetl -At -F'|' -c "$1" 2>/dev/null; }
srvmetric() { curl -s --max-time 10 "http://127.0.0.1:${PORT}/metrics" 2>/dev/null \
                | awk -v m="$1" '$1==m {print $2; f=1} END{if(!f) print 0}'; }

fire() { curl -s --max-time 60 -X POST -H 'content-type: application/json' \
           -d "{\"path\":\"$1\",\"payload\":{}}" \
           "http://127.0.0.1:${PORT}/api/execute" 2>/dev/null \
         | python3 -c 'import json,sys
try: print(json.load(sys.stdin)["execution_id"])
except Exception: pass'; }

await() { for _ in $(seq 1 60); do
    s=$(curl -s --max-time 20 "http://127.0.0.1:${PORT}/api/executions/$1" 2>/dev/null \
        | python3 -c 'import json,sys
try: print(json.load(sys.stdin)["status"])
except Exception: print("X")')
    case "$s" in COMPLETED|FAILED|CANCELLED) echo "$s"; return;; esac; sleep 4
  done; echo TIMEOUT; }

echo "== register two playbooks: one OVER the 512B floor, one UNDER =="
k port-forward svc/noetl-server-rust "${PORT}":8082 >/dev/null 2>&1 &
sleep 6
python3 - "$PORT" <<'PY'
import json,sys,urllib.request
port=sys.argv[1]
def reg(path,code,desc):
    c=f"""apiVersion: noetl.io/v2
kind: Playbook
metadata:
  name: {path.split('/')[-1]}
  path: {path}
  description: "{desc}"
workload: {{}}
workflow:
  - step: start
    tool:
      kind: python
      input: {{}}
      code: |
{code}
"""
    r=urllib.request.Request(f"http://127.0.0.1:{port}/api/catalog/register",
        data=json.dumps({"content":c}).encode(),headers={"content-type":"application/json"})
    print(urllib.request.urlopen(r,timeout=60).read().decode()[:120])
# ~8 KB of business-shaped rows -> well over the 512-byte floor
reg("tests/195/big_result",
    '        rows = [{"id": i, "name": "row-%04d" % i, "note": "x"*60} for i in range(80)]\n'
    '        result = {"status": "ok", "rows": rows}',
    "noetl/ai-meta#195 - an over-floor business rowset, must be externalised to a reference")
# a control scalar -> under the floor, must stay inline
reg("tests/195/small_result",
    '        result = {"status": "ok", "n": 1}',
    "noetl/ai-meta#195 negative control - a sub-floor control scalar, must stay inline")
PY

echo "== enable the strip (default-off; this is the opt-in) =="
k set env deploy/noetl-server-rust NOETL_PERMANENT_LOG_LEAN=true >/dev/null
k rollout status deploy/noetl-server-rust --timeout=240s 2>&1 | tail -1
kill $(jobs -p) 2>/dev/null; sleep 1
k port-forward svc/noetl-server-rust "${PORT}":8082 >/dev/null 2>&1 &
sleep 6

S0=$(srvmetric noetl_permanent_log_slimmed_total)
B0=$(srvmetric noetl_permanent_log_slimmed_bytes_total)
echo "  baseline slimmed=$S0 bytes=$B0"

echo "== 1. over-floor execution =="
BIG=$(fire tests/195/big_result); BIGST=$(await "$BIG"); echo "  $BIG -> $BIGST"
echo "== 2. negative control: sub-floor execution =="
SMALL=$(fire tests/195/small_result); SMALLST=$(await "$SMALL"); echo "  $SMALL -> $SMALLST"

S1=$(srvmetric noetl_permanent_log_slimmed_total)
B1=$(srvmetric noetl_permanent_log_slimmed_bytes_total)

# What actually landed in the permanent log, read from Postgres not inferred.
BIG_INLINE=$(pq "select coalesce(max(pg_column_size(result)),0) from noetl.event where execution_id=$BIG and event_type='call.done';")
BIG_HASREF=$(pq "select count(*) from noetl.event where execution_id=$BIG and result::text like '%\"reference\"%';")
SMALL_INLINE=$(pq "select coalesce(max(pg_column_size(result)),0) from noetl.event where execution_id=$SMALL and event_type='call.done';")
SMALL_HASREF=$(pq "select count(*) from noetl.event where execution_id=$SMALL and result::text like '%\"reference\"%';")

# Can a reader still get the data back?
READBACK=$(curl -s --max-time 30 "http://127.0.0.1:${PORT}/api/executions/${BIG}" 2>/dev/null \
  | python3 -c 'import json,sys
d=json.load(sys.stdin); t=json.dumps(d)
print("rows-visible" if "row-0000" in t else ("reference-only" if "reference" in t else "neither"))' 2>/dev/null)

echo "== restore default-off =="
k set env deploy/noetl-server-rust NOETL_PERMANENT_LOG_LEAN- >/dev/null 2>&1
k rollout status deploy/noetl-server-rust --timeout=240s 2>&1 | tail -1

{
  echo "over-floor  exec=$BIG status=$BIGST  persisted call.done result bytes=$BIG_INLINE  reference rows=$BIG_HASREF"
  echo "sub-floor   exec=$SMALL status=$SMALLST persisted call.done result bytes=$SMALL_INLINE reference rows=$SMALL_HASREF"
  echo "slimmed_total $S0 -> $S1   slimmed_bytes $B0 -> $B1"
  echo "readback of the over-floor execution through the API: $READBACK"
  echo
  echo "GATE:"
  if [ "$((S1-S0))" -le 0 ]; then
    echo "  FAIL(inert):     the strip counted nothing — it did not run."
  else
    echo "  PASS(effect):    slimmed $((S1-S0)) row(s), $((B1-B0)) bytes."
  fi
  if [ "${BIG_HASREF:-0}" -gt 0 ]; then
    echo "  PASS(shape):     the over-floor row carries a reference in the permanent log."
  else
    echo "  FAIL(shape):     the over-floor row has no reference — nothing was externalised."
  fi
  if [ "${SMALL_HASREF:-0}" -eq 0 ]; then
    echo "  PASS(negative):  the sub-floor control scalar stayed inline."
  else
    echo "  FAIL(negative):  a sub-floor result was stripped — the floor is not holding."
  fi
  case "$READBACK" in
    rows-visible) echo "  PASS(readable):  hydrate_result_references resolved it; the payload is still readable." ;;
    *)            echo "  FAIL(readable):  the payload did not come back ($READBACK) — externalised but unreadable." ;;
  esac
  [ "$BIGST" = "COMPLETED" ] && echo "  PASS(drive):     the execution completed — the off-server drive is unaffected." \
                             || echo "  FAIL(drive):     the execution did not complete ($BIGST)."
} | tee "$RUN/verdict.txt"
echo "artifacts: $RUN"
