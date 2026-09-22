#!/usr/bin/env bash
# Does a SATURATED tier service still ANSWER, or does it go deaf?
#
# Saturation here costs ZERO CPU: N clients connect and send nothing, so each
# sits in `read_frame` holding a permit. That isolates the ONE property under
# test — where the permit sits relative to accept() — from any CPU or memory
# effect. It is also exactly what a slow in-flight request does in production.
#
# RED  = permit acquired BEFORE listener.accept() (what prod runs). Once the
#        permits are held the loop never accepts; the kernel still completes the
#        handshake, so a caller hangs until its own timeout against a service
#        that looks alive and serves nothing.
# GREEN= accept first, bound the WORK, shed with an explicit answer.
#
# ⚠ Both arms run with THE SAME cap (4) so the verdict cannot be explained by
# one arm simply having more capacity.
set -uo pipefail
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$1"; }
POD=mem-writer
kx(){ kubectl --context kind-noetl -n noetl "$@"; }

probe(){ kx exec $POD -c w -- /app/ehdb-selfcheck tier-load --addr 127.0.0.1:9110 \
          --tier catalog --read-only true --timeout-ms 2000 --execution-id 1 2>/dev/null | tail -1; }

hold(){ # $1 = permit-holding idle connections, each its own long-lived exec
  # ⚠ One exec per holder ON PURPOSE. Backgrounding inside a single `sh -c`
  # loses the children when that exec session ends — an earlier version did
  # that and RED failed to go deaf, i.e. the gate proved nothing.
  for i in $(seq 1 "$1"); do
    kx exec $POD -c w -- sh -c 'sleep 40 | nc 127.0.0.1 9110' >/dev/null 2>&1 &
  done
  sleep 6
  local live; live=$(kx exec $POD -c w -- sh -c 'ps -o args | grep -c "[n]c 127.0.0.1 9110"' 2>/dev/null | tr -dc 0-9)
  echo "     holders actually connected: ${live:-0} (need > cap to saturate)"
  HOLDERS_LIVE=${live:-0}
}
release(){ kx exec $POD -c w -- sh -c 'pkill -f "nc 127.0.0.1" 2>/dev/null; true' >/dev/null 2>&1; wait 2>/dev/null; }

arm(){ # $1=label  $2=manifest
  local label="$1" man="$2"
  kx delete pod $POD --wait=true >/dev/null 2>&1
  kx apply -f "$man" >/dev/null 2>&1
  for i in $(seq 1 90); do
    [ "$(kx get pod $POD -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)" = "true" ] && break
    sleep 2
  done
  sleep 20
  local cap; cap=$(kx logs $POD -c w 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | grep -o "max_inflight=[0-9]*" | tail -1)
  echo "  -- $label ($cap) --"

  local idle; idle=$(probe)
  echo "     idle : $idle"
  local i_ok; i_ok=$(echo "$idle" | python3 -c "import json,sys;print(json.load(sys.stdin).get('ok'))" 2>/dev/null)

  hold 8
  local sat; sat=$(probe)
  echo "     under 8 idle permit-holders vs a cap of 4:"
  echo "     $sat"
  local s_ok s_err
  s_ok=$(echo "$sat" | python3 -c "import json,sys;print(json.load(sys.stdin).get('ok'))" 2>/dev/null)
  s_err=$(echo "$sat" | python3 -c "import json,sys;print(json.load(sys.stdin).get('error'))" 2>/dev/null)
  release
  echo "$i_ok|$s_ok|$s_err|${HOLDERS_LIVE:-0}" > "/tmp/dg.$label"
}

echo "== RED — permit BEFORE accept (what prod runs) =="
arm red "$SD_RED"
echo
echo "== GREEN — accept, then bound the work, shed with an answer =="
arm green "$SD_GREEN"

R_I=$(cut -d'|' -f1 /tmp/dg.red);  R_S=$(cut -d'|' -f2 /tmp/dg.red);  R_E=$(cut -d'|' -f3 /tmp/dg.red); R_H=$(cut -d'|' -f4 /tmp/dg.red)
G_I=$(cut -d'|' -f1 /tmp/dg.green); G_S=$(cut -d'|' -f2 /tmp/dg.green); G_E=$(cut -d'|' -f3 /tmp/dg.green); G_H=$(cut -d'|' -f4 /tmp/dg.green)
echo
echo "== VERDICT =="
echo "  RED  : idle=$R_I saturated=$R_S err='$R_E' holders=$R_H"
echo "  GREEN: idle=$G_I saturated=$G_S err='$G_E' holders=$G_H"
[ "${R_H:-0}" -gt 4 ] && [ "${G_H:-0}" -gt 4 ] \
  && ok "SATURATION REALLY HAPPENED: $R_H / $G_H holders exceed the cap of 4" \
  || no "saturation did not happen (red=$R_H green=$G_H holders) — neither arm was tested"
[ "$R_I" = "True" ] && [ "$G_I" = "True" ] \
  && ok "POSITIVE CONTROL: the idle probe answers on BOTH arms — it distinguishes serving from not" \
  || no "idle probe failed on an arm (red=$R_I green=$G_I) — the saturated result is meaningless"
[ "$R_S" = "False" ] \
  && ok "RED went DEAF under saturation ('$R_E') — the production failure, reproduced" \
  || no "RED did not go deaf; GREEN proves nothing"
[ "$G_S" = "True" ] \
  && ok "GREEN still ANSWERED under identical saturation at the SAME cap" \
  || no "GREEN went deaf too ('$G_E')"
echo
echo "RESULT: $PASS pass / $FAIL fail"
[ "$FAIL" -eq 0 ]
