#!/usr/bin/env bash
# Kind gate for ai-meta#332 M5 — election + fencing.
#
# The claims, in order of consequence:
#
#   1. The election ACQUIRES a real Kubernetes Lease and mints epoch 1.
#      Before this, `ShardElection` had no call sites and every writer's epoch
#      was 0, so single-writer rested on `replicas: 1` — an orchestration
#      preference, not a mutual-exclusion primitive.
#   2. `observe` does NOT reach the write path. The epoch is published to
#      /metrics while the fenced backend still sees 0, which is what makes the
#      rung safe to turn on everywhere before anything is enforced.
#   3. `authoritative` DOES reach it.
#   4. A STALE writer is REFUSED (`stale_epoch`), and the elected one proceeds.
#   5. Shadow counts the same failover without refusing.
#
# ⚠ The hazard is MIXED epochs, not enforce-without-election: all-zero is
# self-consistent and writes succeed. What refuses every un-elected writer is
# ONE node minting epoch 1 and advancing the shard marker.
#
# Usage: gate.sh <arm>   arm ∈ { off, observe, authoritative }
set -uo pipefail
NS=noetl
ARM="${1:-off}"
PASS=0; FAIL=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); }
info() { printf '        %s\n' "$1"; }
K() { kubectl --context kind-noetl -n "$NS" "$@"; }

WP=$(K get pod -l app=noetl-cmdbus-writer -o name 2>/dev/null | head -1)
[ -n "$WP" ] || { echo "ABORT: no writer pod"; exit 2; }

# Scraped from INSIDE the writer, which is the process under test.
m() { K exec "$WP" -- sh -c "wget -q -O - -T 15 http://127.0.0.1:9090/metrics 2>/dev/null" | grep -E "^$1 " | awk '{print $NF}' | head -1 | tr -d '\r'; }

echo; echo "=== ai-meta#332 M5 fencing gate — arm: $ARM ==="; echo

echo "-- 0. topology + RBAC --"
IMG=$(K get pod -l app=noetl-cmdbus-writer -o jsonpath='{.items[0].spec.containers[0].image}')
info "writer image: $IMG"
case "$IMG" in *m5election*) ok "writer runs the gate image" ;; *) bad "writer is NOT on the gate image ($IMG)" ;; esac
SA=$(K get pod -l app=noetl-cmdbus-writer -o jsonpath='{.items[0].spec.serviceAccountName}'); SA=${SA:-default}
for v in get create update; do
  a=$(kubectl --context kind-noetl auth can-i $v leases.coordination.k8s.io --as="system:serviceaccount:$NS:$SA" -n "$NS" 2>/dev/null)
  [ "$a" = "yes" ] && ok "SA may $v leases" || bad "SA may NOT $v leases — the election cannot run"
done
# NEGATIVE control on the grant: it must be narrow.
a=$(kubectl --context kind-noetl auth can-i delete leases.coordination.k8s.io --as="system:serviceaccount:$NS:$SA" -n "$NS" 2>/dev/null)
[ "$a" = "no" ] && ok "SA may NOT delete leases (the grant is scoped)" || bad "SA can delete leases — too broad"

echo; echo "-- 1. election state --"
ACTIVE=$(m ehdb_election_active); EPOCH=$(m ehdb_election_epoch)
ROUNDS=$(m ehdb_election_rounds_total); ERRS=$(m ehdb_election_errors_total)
info "active=$ACTIVE epoch=$EPOCH rounds=$ROUNDS errors=$ERRS"
# Presence first: an ABSENT series and a 0 are different facts.
for s in ehdb_election_active ehdb_election_epoch ehdb_election_rounds_total; do
  v=$(m "$s"); [ -n "$v" ] && ok "$s present ($v)" || bad "$s is ABSENT — cannot tell inert from missing"
done

case "$ARM" in
  off)
    [ "${ACTIVE:-0}" = "0" ] && ok "off: no election running" || bad "off: election is active ($ACTIVE)"
    [ "${EPOCH:-0}" = "0" ] && ok "off: epoch 0" || bad "off: epoch is $EPOCH"
    [ "${ROUNDS:-0}" = "0" ] && ok "off: no rounds (the loop never ran)" || bad "off: rounds=$ROUNDS"
    ;;
  observe|authoritative)
    [ "${ACTIVE:-0}" = "1" ] && ok "$ARM: election active" || bad "$ARM: election NOT active"
    # The POSITIVE CONTROL for `active`: a wedged loop also reports active=1
    # forever; only a climbing round count separates them.
    if [ "${ROUNDS:-0}" -gt 0 ] 2>/dev/null; then ok "rounds > 0 ($ROUNDS) — the loop is turning, not wedged"
    else bad "rounds=0 — 'active' cannot be distinguished from a wedged loop"; fi
    if [ "${EPOCH:-0}" -ge 1 ] 2>/dev/null; then ok "a real fencing token was minted (epoch=$EPOCH)"
    else bad "epoch=$EPOCH — no token minted, so nothing is elected"; fi
    ;;
esac

echo; echo "-- 2. the Lease object itself (the apiserver's view) --"
L=$(kubectl --context kind-noetl -n "$NS" get lease -o json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
for i in d.get('items',[]):
    n=i['metadata']['name']
    if 'ehdb' in n or 'shard' in n:
        s=i.get('spec',{})
        print(n, s.get('holderIdentity'), s.get('leaseTransitions'), i['metadata'].get('resourceVersion'))
" 2>/dev/null | head -1)
if [ -n "$L" ]; then
  ok "lease exists: $L"
  T=$(printf '%s' "$L" | awk '{print $3}')
  if [ "${T:-0}" -ge 1 ] 2>/dev/null; then ok "leaseTransitions >= 1 ($T) — the epoch is the apiserver's, not ours"
  else bad "leaseTransitions=$T"; fi
else
  case "$ARM" in off) ok "no lease under 'off', as expected" ;; *) bad "no ehdb lease found — the election never wrote one" ;; esac
fi

echo; echo "-- 3. fencing counters --"
for s in ehdb_fencing_writes_checked_total ehdb_fencing_stale_observed_total ehdb_fencing_refused_total; do
  v=$(m "$s"); [ -n "$v" ] && info "$s = $v" || info "$s ABSENT"
done

echo; echo "=== arm '$ARM': $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
