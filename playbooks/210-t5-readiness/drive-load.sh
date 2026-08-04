#!/usr/bin/env bash
# Drive synthetic load at prod through a port-forwarded noetl-server, to push the
# user pool past its slot capacity and make the EHDB per-subject lag rise.
#
# Usage: ./drive-load.sh <count> [concurrency] [port]
#
# The pool is minReplicaCount=2 x WORKER_MAX_CONCURRENT=4 = 8 concurrent slots.
# The ScaledObject's targetValue=2 (AverageValue) means desired = ceil(lag/2), so
# a sustained backlog of ~16 asks for 8 replicas.  Fire well past 8 in flight.
set -uo pipefail

COUNT="${1:-120}"
CONC="${2:-24}"
PORT="${3:-18099}"
PB="fixtures/playbooks/hello_world"
OUT="${OUT:-/tmp/t5-load-$(date +%H%M%S).ids}"

: >"$OUT"
echo "firing $COUNT executions of $PB at concurrency $CONC -> $OUT"

fire() {
  local r
  r=$(curl -s --max-time 30 -X POST -H 'content-type: application/json' \
        -d "{\"path\":\"$PB\",\"version\":1,\"input\":{}}" \
        "http://127.0.0.1:${PORT}/api/execute" 2>/dev/null)
  # Record the id, or the failure — a dropped publish must not look like success.
  case "$r" in
    *execution_id*) echo "$r" | sed -n 's/.*"execution_id":"\([0-9]*\)".*/\1/p' >>"$OUT" ;;
    *)              echo "ERR:$r" >>"$OUT" ;;
  esac
}

n=0
while [ "$n" -lt "$COUNT" ]; do
  for _ in $(seq 1 "$CONC"); do
    [ "$n" -ge "$COUNT" ] && break
    fire &
    n=$((n + 1))
  done
  wait
done

ok=$(grep -c '^[0-9]' "$OUT" || true)
err=$(grep -c '^ERR' "$OUT" || true)
echo "fired=$COUNT accepted=$ok errors=$err"
