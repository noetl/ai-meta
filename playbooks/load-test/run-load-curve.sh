#!/usr/bin/env bash
# In-cluster load curve for NoETL (noetl/ai-meta#317, #318).
#
# Measures the SYSTEM, not the harness. Three artifacts burned earlier runs and
# each has a countermeasure here:
#
#   1. Fixed `sleep` instead of waiting for the Job -> pods that had not started
#      produced "0 ok / 0 err", which reads as a stall. Now: wait for Job
#      COMPLETION.
#   2. Autopilot takes ~60-90s to provision nodes. A run measured from apply-time
#      counts scheduling as latency, and a short run can end before pods start.
#      Now: the window opens only once ALL generators are Running, and
#      scheduling time is reported separately.
#   3. `grep -c error` over server logs matched the word inside EventEnvelope
#      payloads and reported 771 phantom errors. Now: generators emit
#      `R|ok|<centis>` and results are parsed on '|' only.
#
# Every parse runs a POSITIVE CONTROL first, so a real zero is distinguishable
# from a pattern that stopped matching.
#
# Usage:
#   ./run-load-curve.sh                    # default curve 1 2 4 6 8 10, 90s each
#   ./run-load-curve.sh --levels "2 6" --duration 120
#   ./run-load-curve.sh --repeat 2         # repeat the curve, for stability
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CTX="${PROD_CTX:-gke_shastaratech-noetl-prod_us-central1_noetl-prod-autopilot}"
NS=noetl
LEVELS="1 2 4 6 8 10"
DURATION=90
SLEEP_BETWEEN=1
REPEAT=1

while [ $# -gt 0 ]; do
  case "$1" in
    --levels) LEVELS="$2"; shift 2 ;;
    --duration) DURATION="$2"; shift 2 ;;
    --repeat) REPEAT="$2"; shift 2 ;;
    --sleep) SLEEP_BETWEEN="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

k() { kubectl --context "$CTX" -n "$NS" "$@"; }

# ── positive control ─────────────────────────────────────────────────────────
# Prove the parser matches a known-good sample BEFORE trusting any real zero.
parse_control() {
  local sample; sample=$'R|ok|123\nR|err|3000\nSUMMARY|submitted=2|ok=1|err=1'
  local n_ok n_err n_sub
  n_ok=$(printf '%s\n' "$sample" | awk -F'|' '$1=="R" && $2=="ok"' | wc -l | tr -d ' ')
  n_err=$(printf '%s\n' "$sample" | awk -F'|' '$1=="R" && $2=="err"' | wc -l | tr -d ' ')
  n_sub=$(printf '%s\n' "$sample" | awk -F'|' '$1=="SUMMARY"{split($2,a,"=");s+=a[2]} END{print s+0}')
  if [ "$n_ok" = "1" ] && [ "$n_err" = "1" ] && [ "$n_sub" = "2" ]; then
    echo "  parser control: PASS (ok=1 err=1 submitted=2 from a known sample)"
    return 0
  fi
  echo "  parser control: FAIL (ok=$n_ok err=$n_err submitted=$n_sub) — ABORTING;" >&2
  echo "  a zero from this parser would be meaningless." >&2
  return 1
}

IMG="$(k get deploy noetl-server-rust -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)"
[ -z "$IMG" ] && { echo "cannot resolve generator image" >&2; exit 1; }

cleanup() { k delete job -l app=noetl-loadgen --ignore-not-found --wait=true >/dev/null 2>&1; }
trap cleanup EXIT

parse_control || exit 1
echo "  image: ${IMG##*/}"
echo "  levels: $LEVELS   duration: ${DURATION}s   repeat: $REPEAT"
printf "\n  %-5s %-5s %-6s %-5s %-5s %-8s %-8s %-9s %s\n" \
  rep conc submit ok err p50ms p95ms rate/s sched
echo "  ---------------------------------------------------------------------------"

for rep in $(seq 1 "$REPEAT"); do
for conc in $LEVELS; do
  name="noetl-loadgen-c${conc}r${rep}"
  k delete job "$name" --ignore-not-found --wait=true >/dev/null 2>&1
  sed -e "s|IMGPLACEHOLDER|$IMG|" -e "s|NAMEPLACEHOLDER|$name|" \
      -e "s|PARPLACEHOLDER|$conc|g" -e "s|DURPLACEHOLDER|$DURATION|" \
      -e "s|SLEEPPLACEHOLDER|$SLEEP_BETWEEN|" "$HERE/loadgen-job.yaml" | k apply -f - >/dev/null 2>&1

  # (2) window opens only when ALL generators are Running.
  sched_start=$(date +%s); running=0
  for _ in $(seq 1 40); do
    running=$(k get pods -l app=noetl-loadgen --field-selector=status.phase=Running --no-headers 2>/dev/null | grep -c "$name" || true)
    [ "$running" -ge "$conc" ] && break
    sleep 5
  done
  sched=$(( $(date +%s) - sched_start ))
  if [ "$running" -lt "$conc" ]; then
    printf "  %-5s %-5s %s\n" "$rep" "$conc" "SKIP — only $running/$conc generators scheduled in ${sched}s"
    k delete job "$name" --ignore-not-found --wait=true >/dev/null 2>&1
    continue
  fi

  # (1) wait for the Job to COMPLETE, never a fixed sleep.
  k wait --for=condition=complete "job/$name" --timeout=$((DURATION + 300))s >/dev/null 2>&1
  logs=$(for p in $(k get pods -l app=noetl-loadgen -o name 2>/dev/null | grep "$name"); do k logs "$p" 2>/dev/null; done)

  ok=$(printf '%s\n' "$logs"  | awk -F'|' '$1=="R" && $2=="ok"'  | wc -l | tr -d ' ')
  err=$(printf '%s\n' "$logs" | awk -F'|' '$1=="R" && $2=="err"' | wc -l | tr -d ' ')
  sub=$(printf '%s\n' "$logs" | awk -F'|' '$1=="SUMMARY"{split($2,a,"=");s+=a[2]} END{print s+0}')
  # (3) latency from the R| lines; centiseconds -> ms.
  read -r p50 p95 <<<"$(printf '%s\n' "$logs" | awk -F'|' '$1=="R"{print $3*10}' | sort -n | awk '
    {v[NR]=$1} END{ if(NR==0){print "-","-"} else {
      i50=int(NR*0.50); if(i50<1)i50=1; i95=int(NR*0.95); if(i95<1)i95=1; print v[i50], v[i95]} }')"
  rate=$(awk -v o="$ok" -v d="$DURATION" 'BEGIN{printf "%.2f", (d>0? o/d : 0)}')

  # cross-check: R| lines must reconcile with the pods' own SUMMARY counts.
  tot=$((ok + err)); flag=""
  [ "$sub" != "$tot" ] && flag="  ⚠ submitted=$sub != ok+err=$tot"
  printf "  %-5s %-5s %-6s %-5s %-5s %-8s %-8s %-9s %ss%s\n" \
    "$rep" "$conc" "$sub" "$ok" "$err" "$p50" "$p95" "$rate" "$sched" "$flag"

  k delete job "$name" --ignore-not-found --wait=true >/dev/null 2>&1
  sleep 10
done
done

echo
echo "  cleanup: jobs=$(k get jobs -l app=noetl-loadgen --no-headers 2>/dev/null | wc -l | tr -d ' ') pods=$(k get pods -l app=noetl-loadgen --no-headers 2>/dev/null | wc -l | tr -d ' ')"
