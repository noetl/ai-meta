#!/usr/bin/env bash
# Does CPU-BOUND tier work starve the runtime and stop the service responding?
#
# ⚠ This gate deliberately differs from deaf-service-kind-gate.sh. That one
# saturates with ZERO-CPU holders to isolate the accept/permit ORDERING. A cheap
# fixture cannot detect starvation, and an expensive one cannot isolate
# ordering — different fixtures for different failures. Here the load is
# expensive ON PURPOSE: concurrent reads of a 973 MiB / 83,000-record segment,
# on a pod with cpu limit 2 (prod's limit), which is what production actually
# does.
#
# RED  = store work runs on the tokio runtime (v6.1.6). Tokio sizes its runtime
#        to available parallelism, so 2 CPUs = 2 runtime threads; a few
#        concurrent replays occupy them all and nothing else on the runtime runs.
# GREEN= store work runs on the blocking pool.
#
# The probe is the CATALOG tier, which is empty: cost ~0. If it cannot be
# answered, that is starvation, not work.
set -uo pipefail
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$1"; }
POD=mem-writer
kx(){ kubectl --context kind-noetl -n noetl "$@"; }

probe(){ kx exec $POD -c w -- /app/ehdb-selfcheck tier-load --addr 127.0.0.1:9110 \
          --tier catalog --read-only true --timeout-ms 2000 --execution-id 1 2>/dev/null | tail -1; }

arm(){ # $1=label $2=manifest
  local label="$1" man="$2"
  kx delete pod $POD --wait=true >/dev/null 2>&1
  kx apply -f "$man" >/dev/null 2>&1
  until [ "$(kx get pod $POD -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)" = "true" ]; do sleep 3; done
  sleep 22

  # rebuild the expensive fixture (emptyDir is fresh on every pod)
  kx exec $POD -c w -- /app/ehdb-selfcheck tier-load --addr 127.0.0.1:9110 \
     --tier eventlog --records 4150 --concurrency 4 --pad 3000 --execution-id tmpl >/dev/null 2>&1
  kx exec $POD -c w -- sh -c '
    cd /data/eventbus/tier; head -4150 eventlog.jsonl > /tmp/block; rm -f eventlog.jsonl.* *.idx
    for b in $(seq 1 20); do
      awk -v blk="$b" -v off="$(( (b-1)*4150 ))" "{ n=off+NR;
        sub(/\"sequence\":[0-9]+/, \"\\\"sequence\\\":\" n);
        sub(/\"transaction_id\":\"[^\"]*\"/, \"\\\"transaction_id\\\":\\\"ehdbel-t\" n \"\\\"\");
        sub(/noetl\.event\.exec\.[^\"]*/, \"noetl.event.exec.blk-\" blk); print }" /tmp/block
    done > eventlog.jsonl.1
    rm -f /tmp/block eventlog.jsonl' >/dev/null 2>&1
  local bytes; bytes=$(kx exec $POD -c w -- stat -c %s /data/eventbus/tier/eventlog.jsonl.1 2>/dev/null | tr -dc 0-9)
  kx exec $POD -c w -- sh -c 'kill 1' >/dev/null 2>&1 || true
  until [ "$(kx get pod $POD -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)" = "true" ]; do sleep 3; done
  sleep 25

  echo "  -- $label (segment ${bytes:-0} bytes, cpu limit 2) --"
  local idle; idle=$(probe); echo "     idle      : $idle"
  local i_ok; i_ok=$(echo "$idle" | python3 -c "import json,sys;print(json.load(sys.stdin).get('ok'))" 2>/dev/null)

  # CPU-BOUND saturation: concurrent replays of the big segment
  for i in 1 2 3 4 5 6 7 8; do
    kx exec $POD -c w -- /app/ehdb-selfcheck tier-load --addr 127.0.0.1:9110 \
       --tier eventlog --read-only true --timeout-ms 30000 --execution-id "blk-$i" >/dev/null 2>&1 &
  done
  sleep 8
  local sat; sat=$(probe); echo "     saturated : $sat"
  local s_ok s_err
  s_ok=$(echo "$sat" | python3 -c "import json,sys;print(json.load(sys.stdin).get('ok'))" 2>/dev/null)
  s_err=$(echo "$sat" | python3 -c "import json,sys;print(json.load(sys.stdin).get('error'))" 2>/dev/null)
  wait 2>/dev/null
  echo "$i_ok|$s_ok|$s_err|${bytes:-0}" > "/tmp/bp.$label"
}

echo "== RED — tier store work ON the tokio runtime (v6.1.6) =="
arm red "$BP_RED"
echo
echo "== GREEN — tier store work on the BLOCKING pool =="
arm green "$BP_GREEN"

R_I=$(cut -d'|' -f1 /tmp/bp.red);  R_S=$(cut -d'|' -f2 /tmp/bp.red);  R_E=$(cut -d'|' -f3 /tmp/bp.red);  R_B=$(cut -d'|' -f4 /tmp/bp.red)
G_I=$(cut -d'|' -f1 /tmp/bp.green); G_S=$(cut -d'|' -f2 /tmp/bp.green); G_E=$(cut -d'|' -f3 /tmp/bp.green); G_B=$(cut -d'|' -f4 /tmp/bp.green)
echo
echo "== VERDICT =="
echo "  RED  : idle=$R_I saturated=$R_S err='$R_E' segment=$R_B"
echo "  GREEN: idle=$G_I saturated=$G_S err='$G_E' segment=$G_B"
[ "${R_B:-0}" -gt 900000000 ] && [ "${G_B:-0}" -gt 900000000 ] \
  && ok "FIXTURE IS PROD-SIZED on both arms ($R_B / $G_B bytes) — the load is genuinely CPU-bound" \
  || no "fixture too small (red=$R_B green=$G_B); the load may not be CPU-bound at all"
[ "$R_I" = "True" ] && [ "$G_I" = "True" ] \
  && ok "POSITIVE CONTROL: the idle probe answers on BOTH arms" \
  || no "idle probe failed (red=$R_I green=$G_I) — the saturated result means nothing"
[ "$R_S" = "False" ] \
  && ok "RED starved: a cost-free request on an EMPTY tier got no answer ('$R_E')" \
  || no "RED did not starve — GREEN proves nothing"
[ "$G_S" = "True" ] \
  && ok "GREEN kept answering under identical CPU-bound saturation" \
  || no "GREEN starved too ('$G_E')"
echo
echo "RESULT: $PASS pass / $FAIL fail"
[ "$FAIL" -eq 0 ]
