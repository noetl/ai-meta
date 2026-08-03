#!/usr/bin/env bash
# Precise measurement of the HARD-KILL unsealed-tail loss (noetl/ai-meta#209).
#
# Why the mid-burst version cannot measure this: it samples the tip, then issues
# the delete, and the log keeps growing in between. The first run produced
# `reopened_tip (8053) > tip_at_kill (8048)` — the sample was already stale, so
# the arithmetic could not resolve a loss smaller than the sampling window's
# growth, and reported a meaningless 0.
#
# So: quiesce first, sample a STABLE tip, then SIGKILL with no traffic in
# flight. Loss = stable tip - reopened tip, with no ambiguity about what was
# appended when.
#
# Usage: ./hard-kill-measure.sh [burst]
set -uo pipefail

CTX="${CTX:-kind-noetl}"
NS=noetl
BURST="${1:-200}"
PB="fixtures/playbooks/hello_world"
RUN="${RUN:-/tmp/ehdb-hardkill-$(date +%H%M%S)}"
SRV_PORT="${SRV_PORT:-18099}"
CMD_PORT="${CMD_PORT:-19102}"

[[ "$CTX" == kind-* ]] || { echo "REFUSING: CTX=$CTX is not kind" >&2; exit 1; }
mkdir -p "$RUN"
k() { kubectl --context "$CTX" -n "$NS" "$@"; }
trap 'kill $(jobs -p) 2>/dev/null' EXIT

pf() {
  pkill -f "port-forward svc/noetl-cmdbus-writer ${CMD_PORT}" 2>/dev/null
  sleep 1
  k port-forward svc/noetl-cmdbus-writer "${CMD_PORT}":9102 >/dev/null 2>&1 &
  for _ in $(seq 1 40); do
    [ "$(metric 'ehdb_l0_appends')" != "NA" ] && return 0
    sleep 2
  done
  return 1
}
metric() {
  curl -s --max-time 10 "http://127.0.0.1:${CMD_PORT}/metrics" 2>/dev/null \
    | awk -v m="$1" '$1 !~ /^#/ && (index($1,m"{")==1 || $1==m) {print $NF; f=1} END{if(!f) print "NA"}'
}
metric_label() {
  curl -s --max-time 10 "http://127.0.0.1:${CMD_PORT}/metrics" 2>/dev/null \
    | awk -v m="$1" -v l="$2" '$1 !~ /^#/ && index($1,m"{")==1 {
        if (match($1, l"=\"[^\"]*\"")) { print substr($1, RSTART+length(l)+2, RLENGTH-length(l)-3); f=1 }
      } END{if(!f) print "NA"}'
}
tip() {
  local c l
  c=$(metric 'ehdb_feed_shard_committed'); l=$(metric 'ehdb_feed_shard_lag')
  { [ "$c" = "NA" ] || [ "$l" = "NA" ]; } && { echo NA; return; }
  echo $(( ${c%.*} + ${l%.*} ))
}

k port-forward svc/noetl-server-rust "${SRV_PORT}":8082 >/dev/null 2>&1 &
pf || { echo "cannot read the writer" >&2; exit 1; }

echo "== 1. burst of $BURST to put records in the active part =="
: >"$RUN/ids"
n=0
while [ "$n" -lt "$BURST" ]; do
  batch=()
  for _ in $(seq 1 25); do
    [ "$n" -ge "$BURST" ] && break
    ( curl -s --max-time 60 -X POST -H 'content-type: application/json' \
        -d "{\"path\":\"$PB\",\"version\":1,\"input\":{}}" \
        "http://127.0.0.1:${SRV_PORT}/api/execute" >>"$RUN/ids" 2>/dev/null ) &
    batch+=($!); n=$((n + 1))
  done
  for pid in "${batch[@]}"; do wait "$pid" 2>/dev/null; done
done

echo "== 2. quiesce: wait for the bus to go idle so the tip stops moving =="
prev=-1; stable=0
for _ in $(seq 1 90); do
  t=$(tip)
  if [ "$t" = "$prev" ]; then
    stable=$((stable + 1)); [ "$stable" -ge 4 ] && break
  else
    stable=0
  fi
  prev="$t"; sleep 2
done
TIP_STABLE=$(tip)
LAG_STABLE=$(metric 'ehdb_feed_shard_lag')
echo "  stable tip=$TIP_STABLE (lag=$LAG_STABLE) after $stable consecutive identical reads"

echo "== 3. SIGKILL the writer (no traffic in flight) =="
POD=$(k get pods -l app=noetl-cmdbus-writer -o jsonpath='{.items[0].metadata.name}')
k delete pod "$POD" --grace-period=0 --force --wait=false 2>/dev/null
k wait --for=delete pod/"$POD" --timeout=90s 2>/dev/null
k rollout status deployment/noetl-cmdbus-writer --timeout=180s
pf || { echo "cannot read the writer after restart" >&2; exit 1; }
sleep 5

REOPENED_TIP=$(metric 'ehdb_feed_shard_resume_tip')
RESUME_STORED=$(metric 'ehdb_feed_shard_resume_stored')
CLAMPED=$(metric_label 'ehdb_feed_shard_resume_stored' 'clamped')
ORIGIN=$(metric_label 'ehdb_feed_shard_resume_from' 'origin')
REPLAY=$(metric 'ehdb_feed_shard_resume_replay_records')

LOSS="NA"
if [ "$TIP_STABLE" != "NA" ] && [ "$REOPENED_TIP" != "NA" ]; then
  LOSS=$(( ${TIP_STABLE%.*} - ${REOPENED_TIP%.*} ))
fi

{
  echo "mode=hard-kill (quiesced, SIGKILL, grace-period=0)"
  echo "burst=$BURST"
  echo "stable_tip_before_kill=$TIP_STABLE  (lag=$LAG_STABLE)"
  echo "reopened_tip=$REOPENED_TIP"
  echo "resumed_from_cursor=$RESUME_STORED  clamped=$CLAMPED  origin=$ORIGIN"
  echo "replay_records=$REPLAY"
  echo "UNSEALED_TAIL_LOST=$LOSS   (bound: seal_max_records=1024 per shard)"
} | tee "$RUN/verdict.txt"
echo; echo "artifacts: $RUN"
