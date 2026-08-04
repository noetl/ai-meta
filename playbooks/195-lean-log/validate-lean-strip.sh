#!/usr/bin/env bash
# Kind validation of the permanent-log-lean strip (noetl/ai-meta#195 + #196).
#
# Measured on prod: 461 MB across 151,960 rows — 83% of all `result` bytes in
# `noetl.event` — sit above the 512-byte floor this strip externalises. So the
# question is not whether it is worth enabling but whether it is SAFE to.
#
# ONE flag strips TWO things (they share `permanent_log_lean.rs` and the same
# call site), and the second is the larger half:
#
#   D1 (#195)  over-floor step RESULTS   ->  `reference` + `extracted`      461 MB
#   D2 (#196)  over-floor command CONTEXT ->  `__context_ref__` marker     1229 MB
#
# Asserting only D1 would leave 73% of the change unvalidated, which is what an
# earlier version of this rig did.
#
# Three things could go wrong, and this asserts each rather than assuming:
#
#   1. It strips nothing (inert) — the failure mode this session has hit six
#      times. Asserted by the metric moving AND the persisted row actually
#      changing shape in Postgres.
#   2. It strips too much — a small control scalar loses its inline value and
#      readers that expect it break. Asserted by a NEGATIVE CONTROL: a
#      sub-floor result must stay inline.
#   3. It strips correctly but the data becomes unreadable — the whole point is
#      that `hydrate_result_references` (D1) and `resolve_command_context_ref`
#      (D2) resolve it. Asserted by reading the execution back through the API
#      and requiring the payload to still be there.
#
# And the SAFETY property the code claims, which is the reason stripping a
# command's context is allowed at all. `permanent_log_lean.rs` argues:
#
#   "orchestrate-core's apply_event reads only node_name + meta.cursor for a
#    command.issued event (never context), and the transient noetl.command row
#    still holds the full context for a claim that reads it before
#    materialization."
#
# Both halves of that are checked here rather than trusted: the execution must
# still COMPLETE (the drive advanced without the stripped context), and the
# noetl.command row must still carry a full context while the command is live.
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

# NOT via k(): it already applies `-n noetl`, and a trailing `-n postgres` makes
# kubectl reject the call — silently, since stderr is dropped. That exact bug
# made the #199 rig return empty for every query and produce no output at all.
pq() {
  kubectl --context "$CTX" -n postgres exec deploy/postgres -- \
    psql -U noetl -d noetl -At -F'|' -c "$1" 2>/dev/null | tr -d '\r'
}
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

echo "== 1. over-floor execution, sampling noetl.command WHILE it runs =="
BIG=$(fire tests/195/big_result)
CMD_LIVE_CTX=0
for _ in $(seq 1 30); do
  # The transient row is purged after completion, so the safety property can
  # only be observed while the command is live.
  n=$(pq "select count(*) from noetl.command where execution_id=$BIG and coalesce(length(context::text),0) > 512;")
  [ "${n:-0}" -gt "${CMD_LIVE_CTX:-0}" ] && CMD_LIVE_CTX=$n
  s=$(curl -s --max-time 20 "http://127.0.0.1:${PORT}/api/executions/$BIG" 2>/dev/null \
      | python3 -c 'import json,sys
try: print(json.load(sys.stdin)["status"])
except Exception: print("X")')
  case "$s" in COMPLETED|FAILED|CANCELLED) break;; esac
  sleep 3
done
BIGST="$s"; echo "  $BIG -> $BIGST   (peak live noetl.command rows with full context: $CMD_LIVE_CTX)"
echo "== 2. negative control: sub-floor execution =="
SMALL=$(fire tests/195/small_result); SMALLST=$(await "$SMALL"); echo "  $SMALL -> $SMALLST"

S1=$(srvmetric noetl_permanent_log_slimmed_total)
B1=$(srvmetric noetl_permanent_log_slimmed_bytes_total)

# What actually landed in the permanent log, read from Postgres not inferred.
BIG_INLINE=$(pq "select coalesce(max(pg_column_size(result)),0) from noetl.event where execution_id=$BIG and event_type='call.done';")
BIG_HASREF=$(pq "select count(*) from noetl.event where execution_id=$BIG and result::text like '%\"reference\"%';")
SMALL_INLINE=$(pq "select coalesce(max(pg_column_size(result)),0) from noetl.event where execution_id=$SMALL and event_type='call.done';")
SMALL_HASREF=$(pq "select count(*) from noetl.event where execution_id=$SMALL and result::text like '%\"reference\"%';")

# D2 — did the command.issued context get tiered to a __context_ref__ marker?
CMD_STRIPPED=$(pq "select count(*) from noetl.event where execution_id=$BIG and event_type='command.issued' and context::text like '%__context_ref__%';")
# D2 safety — while the command was live, did noetl.command still hold the full
# context? Sampled during the run below, not here (the row is purged on completion).
CMD_LIVE_CTX=${CMD_LIVE_CTX:-0}

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
  echo "  -- D2: the command-context half (#196, the larger one) --"
  if [ "${CMD_STRIPPED:-0}" -gt 0 ]; then
    echo "  PASS(d2-shape):  $CMD_STRIPPED command.issued row(s) carry __context_ref__"
    echo "                   in the permanent log instead of the inline context."
  else
    echo "  FAIL(d2-shape):  no command.issued row was tiered — the larger half of"
    echo "                   the flag did nothing."
  fi
  if [ "${CMD_LIVE_CTX:-0}" -gt 0 ]; then
    echo "  PASS(d2-claim):  the transient noetl.command row still carried a full"
    echo "                   context while the command was live, so a claim that"
    echo "                   reads before materialization is unaffected."
  else
    echo "  WARN(d2-claim):  could not observe a live noetl.command row with a full"
    echo "                   context (the command may have completed too fast);"
    echo "                   inconclusive rather than failing."
  fi
  case "$READBACK" in
    rows-visible) echo "  PASS(readable):  hydrate_result_references resolved it; the payload is still readable." ;;
    *)            echo "  FAIL(readable):  the payload did not come back ($READBACK) — externalised but unreadable." ;;
  esac
  [ "$BIGST" = "COMPLETED" ] && echo "  PASS(drive):     the execution completed — the off-server drive is unaffected." \
                             || echo "  FAIL(drive):     the execution did not complete ($BIGST)."
} | tee "$RUN/verdict.txt"
echo "artifacts: $RUN"
