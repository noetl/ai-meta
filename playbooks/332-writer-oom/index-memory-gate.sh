#!/usr/bin/env bash
# Does the sealed-segment index BACKFILL stay bounded at production scale?
#
# RED  = the replay-based build shipped in worker v6.1.4. It holds the whole
#        segment in the reference-runtime cache; RSS was measured at ~2.8x
#        record bytes for this workload.
# GREEN= the streaming build. One line at a time; only distinct ids retained.
#
# ⚠ The arms differ ONLY by the container image. Same pod, same emptyDir, same
# store, same limits — the image field is mutable and emptyDir survives a
# container restart, so neither arm ever rebuilds the fixture.
#
# Vacuity guard: a build that indexes NOTHING would also use little memory, so
# both arms must produce the SAME index content, and it must be non-empty.
set -uo pipefail
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$1"; }
POD=mem-writer
kx(){ kubectl --context kind-noetl -n noetl "$@"; }

arm(){ # $1=label $2=image -> echoes "peakKB seconds nids"
  local label="$1" img="$2"
  kx exec $POD -c w -- sh -c 'rm -f /data/eventbus/tier/*.idx /data/eventbus/tier/*.idx.tmp' >/dev/null 2>&1
  kx set image pod/$POD w="$img" >/dev/null 2>&1
  # wait for the container to actually be the new image AND restarted
  local t0=$SECONDS
  for i in $(seq 1 90); do
    local cur ready
    cur=$(kx get pod $POD -o jsonpath='{.status.containerStatuses[0].image}' 2>/dev/null)
    ready=$(kx get pod $POD -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)
    case "$cur" in *"${img##*:}") [ "$ready" = "true" ] && break;; esac
    sleep 2
  done
  # poll for the index to appear, tracking peak RSS
  local peak=0 secs=0
  for i in $(seq 1 240); do
    local hwm n
    hwm=$(kx exec $POD -c w -- sh -c 'grep VmHWM /proc/1/status 2>/dev/null | tr -dc 0-9' 2>/dev/null)
    [ -n "$hwm" ] && [ "$hwm" -gt "$peak" ] 2>/dev/null && peak=$hwm
    n=$(kx exec $POD -c w -- sh -c 'ls /data/eventbus/tier/*.idx 2>/dev/null | wc -l' 2>/dev/null | tr -dc 0-9)
    if [ "${n:-0}" -ge 1 ]; then secs=$((SECONDS-t0)); break; fi
    sleep 2
  done
  local ids
  ids=$(kx exec $POD -c w -- sh -c 'cat /data/eventbus/tier/eventlog.jsonl.1.idx 2>/dev/null | sort | wc -l' 2>/dev/null | tr -dc 0-9)
  kx exec $POD -c w -- sh -c 'cat /data/eventbus/tier/eventlog.jsonl.1.idx 2>/dev/null | sort' > "/tmp/idx.$label" 2>/dev/null
  echo "${peak:-0} ${secs:-0} ${ids:-0}"
}

SEGB=$(kubectl --context kind-noetl -n noetl exec $POD -c w -- sh -c 'stat -c %s /data/eventbus/tier/eventlog.jsonl.1' 2>/dev/null)
echo "== sealed segment: $SEGB bytes ($((SEGB/1024/1024)) MiB) =="

echo
echo "== RED — replay-based build (what v6.1.4 ships) =="
R=$(arm red localhost/noetl-worker-rust:idxred)
R_PEAK=$(echo $R|awk '{print $1}'); R_SEC=$(echo $R|awk '{print $2}'); R_IDS=$(echo $R|awk '{print $3}')
echo "  peak RSS: $((R_PEAK/1024)) MiB   indexed in ${R_SEC}s   ids=$R_IDS"

echo
echo "== GREEN — streaming build =="
G=$(arm green localhost/noetl-worker-rust:idxfix2)
G_PEAK=$(echo $G|awk '{print $1}'); G_SEC=$(echo $G|awk '{print $2}'); G_IDS=$(echo $G|awk '{print $3}')
echo "  peak RSS: $((G_PEAK/1024)) MiB   indexed in ${G_SEC}s   ids=$G_IDS"

echo
echo "== VERDICT =="
echo "  segment $((SEGB/1024/1024)) MiB | RED $((R_PEAK/1024)) MiB | GREEN $((G_PEAK/1024)) MiB"
[ "${G_IDS:-0}" -gt 0 ] && ok "GREEN produced a NON-EMPTY index ($G_IDS ids) — low memory is not from indexing nothing" \
                        || no "GREEN index is empty; its memory number is vacuous"
if diff -q /tmp/idx.red /tmp/idx.green >/dev/null 2>&1 && [ "${R_IDS:-0}" -gt 0 ]; then
  ok "RED and GREEN produced IDENTICAL index content ($R_IDS ids) — same answer, different cost"
else
  no "RED and GREEN indexes differ (red=$R_IDS green=$G_IDS) — not a like-for-like comparison"
fi
# the property: streaming peak must be a small fraction of the segment, replay must not be
if [ "${G_PEAK:-0}" -lt $((SEGB/1024/2)) ]; then
  ok "GREEN peak RSS ($((G_PEAK/1024)) MiB) is below HALF the segment size — it does not hold the segment"
else
  no "GREEN peak RSS ($((G_PEAK/1024)) MiB) scales with the segment — streaming is not bounded"
fi
if [ "${R_PEAK:-0}" -gt "${G_PEAK:-0}" ] 2>/dev/null && [ $((R_PEAK-G_PEAK)) -gt 262144 ]; then
  ok "RED peak exceeds GREEN by $(((R_PEAK-G_PEAK)/1024)) MiB — the gate can SEE the regression it guards"
else
  no "RED and GREEN peaks are within noise — this gate could not detect a replay regression"
fi

echo
echo "== residual: what the index does and does NOT make fast =="
# An execution NOT in the sealed segment -> the index rules that segment out.
# An execution that IS in it -> the segment must still be opened and replayed.
probe(){ kubectl --context kind-noetl -n noetl exec $POD -c w -- /app/ehdb-selfcheck tier-load \
    --addr 127.0.0.1:9110 --tier eventlog --read-only true --timeout-ms 2000 \
    --execution-id "$1" 2>/dev/null | tail -1; }
ACTIVE_ID=$(kubectl --context kind-noetl -n noetl exec $POD -c w -- sh -c \
  'tail -1 /data/eventbus/tier/eventlog.jsonl 2>/dev/null' 2>/dev/null \
  | grep -o '"subject":"noetl\.event\.exec\.[^"]*"' | sed 's/.*exec\.//;s/"//')
SEALED_ID=$(head -1 /tmp/idx.green 2>/dev/null)
echo "  active-segment execution : ${ACTIVE_ID:-?}"
echo "    $(probe "${ACTIVE_ID:-none}")"
echo "  sealed-segment execution : ${SEALED_ID:-?}"
echo "    $(probe "${SEALED_ID:-none}")"

echo
echo "RESULT: $PASS pass / $FAIL fail"
[ "$FAIL" -eq 0 ]
