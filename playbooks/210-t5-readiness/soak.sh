#!/usr/bin/env bash
# Soak the EHDB command bus + the newly-live autoscaler under repeated synthetic
# load, watching for the #203 / #208 failure classes.
#
# Usage: ./soak.sh <rounds> <execs-per-round> [port]
#
# Each round: fire a burst, wait for the bus to drain, then assert
#   - every accepted execution reached COMPLETED   (no loss)
#   - no duplicate execution ids                   (no dup)
#   - ehdb_l0_out_of_order_appends == 0            (the #203 detector, if exposed)
#   - lag returns to 0 on both subjects            (bus drains)
#   - the writer's resume facts stay sane
set -uo pipefail

ROUNDS="${1:-6}"
N="${2:-40}"
PORT="${3:-18099}"
export CLOUDSDK_CORE_ACCOUNT=shastaratech@gmail.com
CTX=gke_shastaratech-noetl-prod_us-central1_noetl-prod-autopilot
K() { kubectl --context "$CTX" -n noetl "$@"; }
DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Single-instance lock.  Two soaks against the same cluster interleave their
# bursts, so one instance's drain check passes while the other's commands are
# still in flight — and it then reads those as NOT-COMPLETED.  That is a
# measurement artifact that looks exactly like delivery loss, which is the one
# thing this script exists to detect.  Refuse to run twice.
LOCK=/tmp/t5-soak.lock
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "another soak is running (lock: $LOCK).  Remove it if that is stale." >&2
  exit 1
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

scrape() {
  K exec t5-lagprobe -- curl -s --max-time 8 \
    http://noetl-cmdbus-writer-0.noetl.svc.cluster.local:9102/metrics 2>/dev/null
}

total_ok=0 total_fired=0 total_err=0 total_dup=0 worst_ooo=0
for r in $(seq 1 "$ROUNDS"); do
  echo "================ round $r/$ROUNDS  $(date -u '+%H:%M:%S UTC') ================"
  ids="/tmp/t5-soak-r${r}.ids"
  OUT="$ids" "$DIR/drive-load.sh" "$N" 20 "$PORT" | tail -1

  # Drain: wait for both subjects to read 0, bounded.
  for _ in $(seq 1 60); do
    m=$(scrape)
    sh=$(echo "$m" | sed -n 's/^ehdb_feed_subject_lag{subject="commands.shared.shard.0"} \([0-9]*\)$/\1/p')
    sy=$(echo "$m" | sed -n 's/^ehdb_feed_subject_lag{subject="commands.system.shard.0"} \([0-9]*\)$/\1/p')
    [ "${sh:-1}" = "0" ] && [ "${sy:-1}" = "0" ] && break
    sleep 10
  done

  m=$(scrape)
  ooo=$(echo "$m" | sed -n 's/^ehdb_l0_out_of_order_appends \([0-9]*\)$/\1/p')
  apnd=$(echo "$m" | sed -n 's/^ehdb_l0_appends \([0-9]*\)$/\1/p')
  replay=$(echo "$m" | sed -n 's/^ehdb_feed_shard_resume_replay_records{shard="0"} \([0-9]*\)$/\1/p')
  [ -n "${ooo:-}" ] && [ "$ooo" -gt "$worst_ooo" ] && worst_ooo=$ooo

  uniq="/tmp/t5-soak-r${r}.uniq"
  python3 - "$ids" "$uniq" <<'PY'
import sys
raw=[l.strip() for l in open(sys.argv[1]) if l.strip()]
ok=[x for x in raw if not x.startswith('ERR')]
u=sorted(set(ok))
open(sys.argv[2],'w').write("\n".join(u)+"\n")
print(f"  accepted={len(ok)} unique={len(u)} dup={len(ok)-len(u)} publish_errors={len(raw)-len(ok)}")
PY
  # NB: `grep -c` exits 1 on zero matches, so `|| echo 0` would append a SECOND
  # line and break the arithmetic below.  Count with awk, which always exits 0.
  err=$(awk '/^ERR/{n++} END{print n+0}' "$ids")
  acc=$(awk '/^[0-9]/{n++} END{print n+0}' "$ids")
  uni=$(awk 'NF{n++} END{print n+0}' "$uniq")
  dup=$((acc - uni))

  # Poll to a terminal state rather than sampling once: lag hitting 0 means the
  # bus drained, not that the last playbook finished its final step.  Only a
  # value that is still non-terminal after the retries counts as a miss.
  ok=0; notok=0
  for attempt in 1 2 3 4 5 6; do
    pending=""
    ok=0
    while read -r eid; do
      [ -z "$eid" ] && continue
      s=$(curl -s --max-time 15 "http://127.0.0.1:${PORT}/api/executions/$eid/status" \
          | sed -n 's/.*"status":"\([A-Z_]*\)".*/\1/p')
      case "$s" in
        COMPLETED) ok=$((ok+1)) ;;
        FAILED|ERROR) echo "  FAILED $eid" ;;
        *) pending="$pending $eid" ;;
      esac
    done < "$uniq"
    [ -z "$pending" ] && break
    [ "$attempt" -lt 6 ] && sleep 15
  done
  notok=0
  for eid in $pending; do
    notok=$((notok+1))
    s=$(curl -s --max-time 15 "http://127.0.0.1:${PORT}/api/executions/$eid/status" \
        | sed -n 's/.*"status":"\([A-Z_]*\)".*/\1/p')
    echo "  NOT-COMPLETED $eid -> ${s:-<empty>}"
  done

  reps=$(K get deploy noetl-worker-rust -o jsonpath='{.spec.replicas}')
  echo "  completed=$ok not_completed=$notok dup=$dup publish_errors=$err"
  echo "  out_of_order_appends=${ooo:-<not exposed>} appends=${apnd:-?} resume_replay=${replay:-?} replicas=$reps"

  total_ok=$((total_ok+ok)); total_fired=$((total_fired+N))
  total_err=$((total_err+err)); total_dup=$((total_dup+dup))
done

echo
echo "================ SOAK SUMMARY ================"
echo "rounds=$ROUNDS per_round=$N"
echo "fired=$total_fired completed=$total_ok"
echo "publish_errors=$total_err duplicate_ids=$total_dup"
echo "max out_of_order_appends observed=${worst_ooo}"
