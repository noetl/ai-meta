#!/usr/bin/env bash
# Sample the EHDB per-subject lag, the HPA, and the pool's replica count in one
# line per tick — the evidence that the user pool scales on ITS OWN backlog.
#
# Usage: ./watch-scale.sh <seconds> [interval]
set -uo pipefail

DUR="${1:-600}"
INT="${2:-10}"
export CLOUDSDK_CORE_ACCOUNT=shastaratech@gmail.com
CTX=gke_shastaratech-noetl-prod_us-central1_noetl-prod-autopilot
K() { kubectl --context "$CTX" -n noetl "$@"; }

# Long-lived scraper pod: spawning one curl pod per tick is far too slow on
# Autopilot (and would itself perturb the cluster).
POD=t5-lagprobe
K get pod "$POD" >/dev/null 2>&1 || \
  K run "$POD" --restart=Never --image=curlimages/curl:8.10.1 \
    --command -- sleep 100000 >/dev/null 2>&1
for _ in $(seq 1 60); do
  [ "$(K get pod $POD -o jsonpath='{.status.phase}' 2>/dev/null)" = "Running" ] && break
  sleep 2
done

scrape() {
  K exec "$POD" -- curl -s --max-time 5 \
    http://noetl-cmdbus-writer-0.noetl.svc.cluster.local:9102/metrics 2>/dev/null
}

printf '%-9s %-8s %-8s %-8s %-10s %-8s %s\n' \
  t shared system total replicas ready hpa
start=$(date +%s)
while [ $(( $(date +%s) - start )) -lt "$DUR" ]; do
  m=$(scrape)
  shared=$(echo "$m" | sed -n 's/^ehdb_feed_subject_lag{subject="commands.shared.shard.0"} \([0-9]*\)$/\1/p')
  system=$(echo "$m" | sed -n 's/^ehdb_feed_subject_lag{subject="commands.system.shard.0"} \([0-9]*\)$/\1/p')
  total=$(echo "$m"  | sed -n 's/^ehdb_feed_total_lag \([0-9]*\)$/\1/p')
  reps=$(K get deploy noetl-worker-rust -o jsonpath='{.spec.replicas}' 2>/dev/null)
  ready=$(K get deploy noetl-worker-rust -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  hpa=$(K get hpa -o jsonpath='{range .items[*]}{.spec.metrics[0].external.metric.name}|{.status.currentMetrics[0].external.current.averageValue}|desired={.status.desiredReplicas}{end}' 2>/dev/null)
  printf '%-9s %-8s %-8s %-8s %-10s %-8s %s\n' \
    "$(( $(date +%s) - start ))s" "${shared:--}" "${system:--}" "${total:--}" \
    "${reps:--}" "${ready:-0}" "${hpa:--}"
  sleep "$INT"
done
