#!/usr/bin/env bash
# Sustained-concurrency soak of the EHDB-only events path in LOCAL KIND.
#
# The gate is PAIRED EVIDENCE, never an execution count. Two of the five defects
# the NATS deletion produced (playbooks/211-t3-events-migration/EHDB-ONLY-RESULT.md
# #3 and #5) completed executions green while the entire CQRS publish path was
# inert or the WAL chain was never built. A green run proves nothing on its own.
#
# Pass condition, all of which must hold:
#   published == projected                    (server /metrics, both counters)
#   all three group cursors advanced by that same delta, ending at lag 0
#   ehdb_events_cursor_errors == 0
#   ehdb_l0_out_of_order_appends == 0
#   0 dup execution ids, 0 publish errors
#   every SSE subscriber saw every frame
#
# Usage: ./soak.sh <rounds> <execs-per-round> [concurrency]
set -uo pipefail

CTX="${CTX:-kind-noetl}"
NS=noetl
ROUNDS="${1:-6}"
PER="${2:-60}"
CONC="${3:-30}"
PB="fixtures/playbooks/hello_world"
RUN="${RUN:-/tmp/ehdb-soak-$(date +%H%M%S)}"
SRV_PORT="${SRV_PORT:-18099}"
CMD_PORT="${CMD_PORT:-19102}"   # writer :9102 command-bus lag + L0 integrity
EVT_PORT="${EVT_PORT:-19106}"   # writer :9106 events per-group lag + cursors
SSE_PORT="${SSE_PORT:-19105}"   # writer :9105 SSE broadcast face
KV_PORT="${KV_PORT:-19107}"     # writer :9107 KV face
WAL_PORT="${WAL_PORT:-19108}"   # writer :9108 WAL fan-out face

[[ "$CTX" == kind-* ]] || { echo "REFUSING: CTX=$CTX is not kind" >&2; exit 1; }
mkdir -p "$RUN"
# Single-instance lock: two soaks against one cluster read each other's
# in-flight commands as failures (the 210 README's false-failure trap).
mkdir /tmp/ehdb-soak.lock 2>/dev/null || { echo "another soak is running" >&2; exit 1; }
trap 'rm -rf /tmp/ehdb-soak.lock; kill $(jobs -p) 2>/dev/null' EXIT

k() { kubectl --context "$CTX" -n "$NS" "$@"; }

echo "== port-forwards =="
k port-forward svc/noetl-server-rust "${SRV_PORT}":8082      >/dev/null 2>&1 &
k port-forward svc/noetl-cmdbus-writer "${CMD_PORT}":9102    >/dev/null 2>&1 &
k port-forward svc/noetl-cmdbus-writer "${EVT_PORT}":9106    >/dev/null 2>&1 &
k port-forward svc/noetl-cmdbus-writer "${SSE_PORT}":9105    >/dev/null 2>&1 &
k port-forward svc/noetl-cmdbus-writer "${KV_PORT}":9107     >/dev/null 2>&1 &
k port-forward svc/noetl-cmdbus-writer "${WAL_PORT}":9108    >/dev/null 2>&1 &
sleep 6

metric() { # metric <url> <exact-metric-name-prefix>
  curl -s --max-time 10 "$1" 2>/dev/null | awk -v m="$2" '$1==m {print $2; found=1} END{if(!found) print "NA"}'
}
metric_sum() { # sum every series in a family (labels vary)
  curl -s --max-time 10 "$1" 2>/dev/null \
    | awk -v m="$2" 'index($1,m)==1 {s+=$NF; f=1} END{if(f) print s; else print "NA"}'
}
srv() { echo "http://127.0.0.1:${SRV_PORT}/metrics"; }
evt() { echo "http://127.0.0.1:${EVT_PORT}/metrics"; }
cmd() { echo "http://127.0.0.1:${CMD_PORT}/metrics"; }

group_committed() { metric "$(evt)" "ehdb_events_group_committed{group=\"$1\"}"; }
group_lag()       { metric "$(evt)" "ehdb_events_group_lag{group=\"$1\"}"; }
# NOT `GROUPS`: that is a bash special variable holding the current user's
# group IDs, and assigning to it is silently dropped (or an error). The first
# run of this soak snapshotted `committed_399` / `lag_400` — real-looking
# metric names built from Unix gids — and every lag read came back NA, so the
# per-round drain wait degenerated to "sum of zero NAs == 0" and never waited.
MAT_GROUPS=(noetl_materializer noetl_result_materializer noetl_state_materializer)

snapshot() { # snapshot <label>
  local tag="$1" f="$RUN/snap-$1.txt"
  {
    echo "published $(metric_sum "$(srv)" 'noetl_ehdb_events_published_total')"
    echo "publish_errors $(metric_sum "$(srv)" 'noetl_ehdb_events_publish_errors_total')"
    echo "projected $(metric "$(srv)" 'noetl_events_projected_total')"
    echo "cursor_errors $(metric "$(evt)" 'ehdb_events_cursor_errors')"
    echo "out_of_order $(metric "$(cmd)" 'ehdb_l0_out_of_order_appends')"
    echo "l0_appends $(metric "$(cmd)" 'ehdb_l0_appends')"
    for g in "${MAT_GROUPS[@]}"; do
      echo "committed_$g $(group_committed "$g")"
      echo "lag_$g $(group_lag "$g")"
    done
  } | tee "$f"
}

fire() {
  local r
  r=$(curl -s --max-time 60 -X POST -H 'content-type: application/json' \
        -d "{\"path\":\"$PB\",\"version\":1,\"input\":{}}" \
        "http://127.0.0.1:${SRV_PORT}/api/execute" 2>/dev/null)
  case "$r" in
    *execution_id*) echo "$r" | sed -n 's/.*"execution_id":"\([0-9]*\)".*/\1/p' >>"$RUN/ids" ;;
    *)              echo "ERR:$r" >>"$RUN/ids" ;;
  esac
}

# --- SSE subscribers: live, for the whole soak, counting frames -------------
# Three concurrent subscribers, because the SSE face is a *broadcast* — every
# subscriber must see every frame, with no competing-consumer behaviour. One
# subscriber cannot tell fan-out from a queue.
echo "== SSE subscribers (3, live for the whole run) =="
for i in 1 2 3; do
  ( curl -sN --max-time 100000 "http://127.0.0.1:${SSE_PORT}/feed" \
      > "$RUN/sse-$i.raw" 2>/dev/null ) &
done
sleep 3

# NOTE: do NOT "probe" :9107 or :9108 with curl. Those faces speak the
# ehdb-feed wire protocol (4-byte BE length + JSON), not HTTP, and
# `ehdb_feed::serve` (the :9108 WAL face) handshakes inside its accept loop —
# so ONE malformed frame permanently kills the face for the life of the
# process, silently. An HTTP probe here is exactly such a frame. It cost this
# soak a dead WAL face and an hour of diagnosis; the worker-side fix only makes
# it loud, it does not make it survivable.
#
# :9108 is exercised by its real client — the off-server state-builder WAL
# drain (NOETL_STATE_BUILDER_SHADOW=true). :9107 is exercised by
# ./kv-exercise.py, which speaks the actual protocol.
echo "== KV face under load (:9107), real wire protocol =="
if python3 "$(dirname "$0")/kv-exercise.py" "127.0.0.1:${KV_PORT}" 400 20 >>"$RUN/faces.txt" 2>&1; then
  echo "kv_exercise=PASS" | tee -a "$RUN/faces.txt"
else
  echo "kv_exercise=FAIL" | tee -a "$RUN/faces.txt"
fi
echo "== WAL fan-out face (:9108): connection count from its real client =="
k exec deploy/noetl-cmdbus-writer -- sh -c \
  "netstat -tn 2>/dev/null | grep -c ':9108.*ESTABLISHED'" 2>/dev/null \
  | sed 's/^/wal_established_conns=/' | tee -a "$RUN/faces.txt" || true

: >"$RUN/ids"
NA_READS=0
echo "== BEFORE =="; snapshot before

TOTAL=0
for r in $(seq 1 "$ROUNDS"); do
  echo "== round $r/$ROUNDS : $PER execs @ concurrency $CONC =="
  n=0
  while [ "$n" -lt "$PER" ]; do
    # Collect THIS batch's pids and wait only on them. A bare `wait` also waits
    # on the port-forward and SSE-subscriber background jobs, which never exit —
    # the first run of this soak fired batch 1, then blocked forever on `wait`
    # while reporting no error at all.
    batch=()
    for _ in $(seq 1 "$CONC"); do
      [ "$n" -ge "$PER" ] && break
      fire &
      batch+=($!)
      n=$((n + 1))
    done
    for pid in "${batch[@]}"; do wait "$pid" 2>/dev/null; done
  done
  TOTAL=$((TOTAL + PER))
  # Drain to terminal state. Lag 0 means the BUS drained, not that playbooks
  # finished — so poll all three group lags AND the command-bus shard lag.
  for _ in $(seq 1 120); do
    q=0
    for g in "${MAT_GROUPS[@]}"; do
      v=$(group_lag "$g")
      # An unreadable lag is NOT a drained lag. Coercing NA to 0 is how the
      # first run of this soak "drained" instantly without waiting for
      # anything — the same shape as trusting a green execution count.
      if [ "$v" = "NA" ]; then q=$(( q + 1 )); NA_READS=$(( NA_READS + 1 ));
      else q=$(( q + ${v%.*} )); fi
    done
    s=$(metric "$(cmd)" 'ehdb_feed_shard_lag{shard="0"}'); [ "$s" = "NA" ] && s=0
    q=$(( q + ${s%.*} ))
    [ "$q" -eq 0 ] && break
    sleep 2
  done
  echo "  drained (residual lag=$q)"
  snapshot "round$r" >/dev/null
done

sleep 5
echo "== AFTER =="; snapshot after

# --- verdict ---------------------------------------------------------------
kill $(jobs -p) 2>/dev/null; sleep 1
g() { awk -v k="$1" '$1==k{print $2}' "$RUN/snap-$2.txt"; }
delta() { local a b; a=$(g "$1" before); b=$(g "$1" after); \
          [ "$a" = "NA" ] || [ "$b" = "NA" ] && { echo NA; return; }; echo $(( ${b%.*} - ${a%.*} )); }

ACC=$(grep -c '^[0-9]' "$RUN/ids" || true)
ERRS=$(grep -c '^ERR' "$RUN/ids" || true)
DUPS=$(grep '^[0-9]' "$RUN/ids" | sort | uniq -d | wc -l | tr -d ' ')
D_PUB=$(delta published); D_PROJ=$(delta projected)

{
  echo "fired=$TOTAL accepted=$ACC errors=$ERRS dup_ids=$DUPS"
  echo "published_delta=$D_PUB projected_delta=$D_PROJ"
  echo "publish_errors=$(g publish_errors after)"
  echo "cursor_errors=$(g cursor_errors after)"
  echo "out_of_order_appends=$(g out_of_order after)"
  echo "unreadable_lag_reads=$NA_READS   (non-zero => a gate was polled blind)"
  echo "l0_appends_delta=$(delta l0_appends)"
  for gr in "${MAT_GROUPS[@]}"; do
    echo "group=$gr committed_delta=$(delta "committed_$gr") final_lag=$(g "lag_$gr" after)"
  done
  for i in 1 2 3; do
    echo "sse_subscriber_$i frames=$(grep -c '^data:' "$RUN/sse-$i.raw" 2>/dev/null || echo 0)"
  done
  cat "$RUN/faces.txt" 2>/dev/null
} | tee "$RUN/verdict.txt"

echo
echo "artifacts: $RUN"
