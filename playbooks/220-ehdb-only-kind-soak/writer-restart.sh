#!/usr/bin/env bash
# Writer-restart behaviour under load — the two halves of noetl/ai-meta#209.
#
#   ./writer-restart.sh graceful   -> SIGTERM.  Expect 0 loss, clean seal, cursor resume.
#   ./writer-restart.sh hard       -> SIGKILL.  MEASURE the loss; expect <= seal_max_records.
#
# Both drive load ACROSS the restart, because a restart on an idle writer proves
# nothing: the whole failure mode is records that were acked in the window around
# the seal.
#
# The measurement that matters is not "did executions complete" — the control
# plane's orphaned-command guardrail (noetl/ai-meta#171) re-issues lost commands
# ~30s later, so executions complete either way and the loss is invisible from
# there. It is the writer's own tip vs what the reopened engine can see.
set -uo pipefail

MODE="${1:-graceful}"
CTX="${CTX:-kind-noetl}"
NS=noetl
PER="${PER:-120}"
CONC="${CONC:-30}"
PB="fixtures/playbooks/hello_world"
RUN="${RUN:-/tmp/ehdb-restart-$MODE-$(date +%H%M%S)}"
SRV_PORT="${SRV_PORT:-18099}"
CMD_PORT="${CMD_PORT:-19102}"

[[ "$CTX" == kind-* ]] || { echo "REFUSING: CTX=$CTX is not kind" >&2; exit 1; }
mkdir -p "$RUN"
k() { kubectl --context "$CTX" -n "$NS" "$@"; }
trap 'kill $(jobs -p) 2>/dev/null' EXIT

k port-forward svc/noetl-server-rust "${SRV_PORT}":8082   >/dev/null 2>&1 &
k port-forward svc/noetl-cmdbus-writer "${CMD_PORT}":9102 >/dev/null 2>&1 &
sleep 5
cmd() { echo "http://127.0.0.1:${CMD_PORT}/metrics"; }
# Prefix match on the metric NAME, not exact match on name+labels: the resume
# family carries extra labels that vary (`origin="persisted"`, `clamped="false"`),
# so an exact match silently reads NA — and an NA that looks like a pass is the
# whole failure mode this rig exists to avoid.
metric() {
  curl -s --max-time 10 "$1" 2>/dev/null \
    | awk -v m="$2" '$1 !~ /^#/ && (index($1,m"{")==1 || $1==m) {print $NF; f=1} END{if(!f) print "NA"}'
}
# The label value of a resume series (e.g. origin=persisted, clamped=false).
metric_label() {
  curl -s --max-time 10 "$1" 2>/dev/null \
    | awk -v m="$2" -v l="$3" '$1 !~ /^#/ && index($1,m"{")==1 {
        if (match($1, l"=\"[^\"]*\"")) { v=substr($1, RSTART+length(l)+2, RLENGTH-length(l)-3); print v; f=1 }
      } END{if(!f) print "NA"}'
}

# Resume facts the writer publishes about its own restart — this is how we read
# the loss without guessing. `stored` is the cursor the replacement resumed from,
# `tip` is what the reopened log actually has.
resume_facts() {
  for f in from tip stored replay_records; do
    echo "resume_$f $(metric "$(cmd)" "ehdb_feed_shard_resume_${f}")"
  done
  echo "l0_appends $(metric "$(cmd)" 'ehdb_l0_appends')"
  echo "out_of_order $(metric "$(cmd)" 'ehdb_l0_out_of_order_appends')"
  echo "committed $(metric "$(cmd)" 'ehdb_feed_shard_committed')"
  echo "resume_origin $(metric_label "$(cmd)" 'ehdb_feed_shard_resume_from' 'origin')"
  echo "resume_clamped $(metric_label "$(cmd)" 'ehdb_feed_shard_resume_stored' 'clamped')"
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

: >"$RUN/ids"
echo "== pre-restart facts =="; resume_facts | tee "$RUN/pre.txt"
PRE_APPENDS=$(awk '$1=="l0_appends"{print $2}' "$RUN/pre.txt")

echo "== driving $PER execs @ $CONC, restarting the writer MID-BURST ($MODE) =="
(
  n=0
  while [ "$n" -lt "$PER" ]; do
    for _ in $(seq 1 "$CONC"); do
      [ "$n" -ge "$PER" ] && break
      fire &
      n=$((n + 1))
    done
    wait
  done
) &
LOAD=$!

# Restart once the burst is genuinely in flight.
sleep 6
POD=$(k get pods -l app=noetl-cmdbus-writer -o jsonpath='{.items[0].metadata.name}')
echo "  writer pod: $POD"
# The pre-kill log TIP, which is what a restart can lose. NOT `ehdb_l0_appends`:
# that is a per-process append counter that resets with the pod, so differencing
# it against a global cursor compares two different things and produces a
# meaningless (usually negative, therefore "0") answer.
#   tip = committed + lag
COMMITTED_AT_KILL=$(metric "$(cmd)" 'ehdb_feed_shard_committed')
LAG_AT_KILL=$(metric "$(cmd)" 'ehdb_feed_shard_lag')
APPENDS_AT_KILL=$(metric "$(cmd)" 'ehdb_l0_appends')
TIP_AT_KILL="NA"
if [ "$COMMITTED_AT_KILL" != "NA" ] && [ "$LAG_AT_KILL" != "NA" ]; then
  TIP_AT_KILL=$(( ${COMMITTED_AT_KILL%.*} + ${LAG_AT_KILL%.*} ))
fi
echo "  tip at kill: $TIP_AT_KILL (committed=$COMMITTED_AT_KILL + lag=$LAG_AT_KILL), process appends=$APPENDS_AT_KILL"
echo "$TIP_AT_KILL" > "$RUN/tip_at_kill"

case "$MODE" in
  graceful)
    # Ordinary SIGTERM — what a rollout or scale-down sends. This is the path
    # the #209 fix sequences: stop ingest -> quiesce -> cursor -> seal.
    echo "  sending SIGTERM (kubectl delete pod, graceful)"
    k delete pod "$POD" --grace-period=30 --wait=false
    ;;
  hard)
    # SIGKILL — OOM / node loss. Nothing seals. This MEASURES the residual
    # exposure that the L0 active-part replay would have to close.
    echo "  sending SIGKILL (grace-period=0)"
    k delete pod "$POD" --grace-period=0 --force --wait=false 2>/dev/null
    ;;
  *) echo "unknown mode $MODE" >&2; exit 1 ;;
esac

k wait --for=delete pod/"$POD" --timeout=90s 2>/dev/null
k rollout status deployment/noetl-cmdbus-writer --timeout=180s

# The port-forward died with the pod. `kill %2` is unreliable in a
# non-interactive shell and the replacement needs time to bind, so kill by
# pattern and then POLL until the endpoint answers. Reading NA here because the
# forward was not up yet would silently zero the loss measurement — the one
# number this whole script exists to produce.
pkill -f "port-forward svc/noetl-cmdbus-writer ${CMD_PORT}" 2>/dev/null
sleep 2
k port-forward svc/noetl-cmdbus-writer "${CMD_PORT}":9102 >/dev/null 2>&1 &
for _ in $(seq 1 40); do
  if [ "$(metric "$(cmd)" 'ehdb_l0_appends')" != "NA" ]; then break; fi
  sleep 2
done
if [ "$(metric "$(cmd)" 'ehdb_l0_appends')" = "NA" ]; then
  echo "FATAL: writer :9102 unreadable after restart — refusing to report a loss number" >&2
fi

wait $LOAD 2>/dev/null
sleep 10

echo "== post-restart facts =="; resume_facts | tee "$RUN/post.txt"

POST_TIP=$(awk '$1=="resume_tip"{print $2}' "$RUN/post.txt")
POST_STORED=$(awk '$1=="resume_stored"{print $2}' "$RUN/post.txt")
ACC=$(grep -c '^[0-9]' "$RUN/ids" || true)
ERRS=$(grep -c '^ERR' "$RUN/ids" || true)

# The loss: the log tip the dying incarnation had reached, minus the tip the
# reopened engine can actually see from its durable manifest. Anything in an
# unsealed active part is invisible to the reopen by construction, so this
# difference IS the unsealed tail.
#
# `resume_clamped` is ehdb's own corroborating verdict: true means the stored
# cursor outran the reopened log and had to be clamped down to its tip, which
# only happens when records were lost.
LOSS="NA"
if [ "$TIP_AT_KILL" != "NA" ] && [ "$POST_TIP" != "NA" ]; then
  LOSS=$(( ${TIP_AT_KILL%.*} - ${POST_TIP%.*} ))
  [ "$LOSS" -lt 0 ] && LOSS=0
fi

{
  echo "mode=$MODE"
  echo "fired=$PER accepted=$ACC publish_errors=$ERRS"
  echo "tip_at_kill=$TIP_AT_KILL (committed=$COMMITTED_AT_KILL lag=$LAG_AT_KILL)"
  echo "reopened_tip=$POST_TIP resumed_from_cursor=$POST_STORED"
  echo "UNSEALED_TAIL_LOST=$LOSS   (bound: seal_max_records=1024)"
  echo "out_of_order_appends=$(awk '$1=="out_of_order"{print $2}' "$RUN/post.txt")"
  echo "resume_origin=$(awk '$1=="resume_origin"{print $2}' "$RUN/post.txt")   (persisted => the cursor survived)"
  echo "resume_clamped=$(awk '$1=="resume_clamped"{print $2}' "$RUN/post.txt")   (true => stored cursor outran the log, i.e. tail was lost)"
} | tee "$RUN/verdict.txt"

echo; echo "artifacts: $RUN"
