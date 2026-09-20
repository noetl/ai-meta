#!/usr/bin/env bash
# M5 E3/E4/E6 kind gate — the two-writer race, asserted.
#
# ⚠ Every assertion here is about what the STORE did, read back from the arm's
# own JSON, never from the harness's belief about which arm should have won.
# The arms report `held_epoch` and `election_rounds`; the gate checks the race
# actually happened BEFORE checking its outcome, because a lease nobody
# contended for would let both arms write and read as "no split brain".
set -uo pipefail
K="kubectl --context kind-noetl -n noetl"
SD="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ✅ %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$1"; }
chk(){ if [ "$2" = "$3" ]; then ok "$1 ($2)"; else no "$1: expected [$3] got [$2]"; fi; }

jqf(){ python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('$1'))"; }

armjson(){ kubectl --context kind-noetl -n noetl logs "$1" 2>/dev/null | grep '^{"appends"' | head -1; }

echo "== reset =="
kubectl --context kind-noetl -n noetl delete pod ehdb-m5-writer-a ehdb-m5-writer-b ehdb-m5-writer-c --ignore-not-found --wait=true >/dev/null 2>&1
kubectl --context kind-noetl -n noetl delete lease ehdb-shard-00000000 --ignore-not-found >/dev/null 2>&1
# ⚠ The PVC too. It carries the marker and segment from the previous run, so a
# gate starting dirty begins with the marker already raised — a different and
# weaker experiment than the one these assertions describe.
kubectl --context kind-noetl -n noetl delete pvc ehdb-m5-shared --ignore-not-found --wait=true >/dev/null 2>&1
sleep 3
kubectl --context kind-noetl -n noetl apply -f "$SD/m5-race.yaml" >/dev/null

echo "== arm A (expect: wins the lease, epoch>=1, writes served) =="
for i in $(seq 1 60); do
  ph=$(kubectl --context kind-noetl -n noetl get pod ehdb-m5-writer-a -o jsonpath='{.status.phase}' 2>/dev/null)
  A=$(armjson ehdb-m5-writer-a); [ -n "$A" ] && break
  [ "$ph" = "Failed" ] && break
  sleep 3
done
[ -z "${A:-}" ] && { echo "arm A produced no verdict (phase=$ph)"; kubectl --context kind-noetl -n noetl logs ehdb-m5-writer-a 2>&1|tail -20; exit 1; }
echo "$A" | python3 -m json.tool | head -30

A_EPOCH=$(echo "$A"|jqf held_epoch); A_SERVED=$(echo "$A"|jqf served)
A_FENCED=$(echo "$A"|jqf fenced_stale); A_ROUNDS=$(echo "$A"|jqf election_rounds)
A_ERR=$(echo "$A"|jqf errored)

# ⚠ Checked BEFORE arm B runs, not after: if arm A is no longer holding, arm B
# would ACQUIRE the lease rather than lose it, and its writes would correctly
# succeed — a green "no fencing refusal" that says nothing about fencing.
HOLDER_NOW=$(kubectl --context kind-noetl -n noetl get lease ehdb-shard-00000000 -o jsonpath='{.spec.holderIdentity}' 2>/dev/null)
if [ "$HOLDER_NOW" != "ehdb-m5-writer-a" ]; then
  no "arm A is not holding the lease when arm B starts (holder=$HOLDER_NOW) — aborting, the race would be vacuous"
  exit 1
fi
ok "arm A still holds the lease as arm B starts"

echo "== arm B (expect: loses the lease, epoch 0, writes REFUSED) =="
kubectl --context kind-noetl -n noetl apply -f "$SD/m5-race-b.yaml" >/dev/null
for i in $(seq 1 60); do
  B=$(armjson ehdb-m5-writer-b); [ -n "$B" ] && break
  sleep 3
done
[ -z "${B:-}" ] && { echo "arm B produced no verdict"; kubectl --context kind-noetl -n noetl logs ehdb-m5-writer-b 2>&1|tail -20; exit 1; }
echo "$B" | python3 -m json.tool | head -30
B_EPOCH=$(echo "$B"|jqf held_epoch); B_SERVED=$(echo "$B"|jqf served)
B_FENCED=$(echo "$B"|jqf fenced_stale); B_ROUNDS=$(echo "$B"|jqf election_rounds)
B_ERR=$(echo "$B"|jqf errored)

echo
echo "== the race actually happened (checked BEFORE its outcome) =="
[ "$A_ROUNDS" -gt 0 ] && ok "arm A completed $A_ROUNDS election round(s)" || no "arm A never completed an election round — nothing below is about fencing"
[ "$B_ROUNDS" -gt 0 ] && ok "arm B completed $B_ROUNDS election round(s)" || no "arm B never completed an election round"
LEASE=$(kubectl --context kind-noetl -n noetl get lease ehdb-shard-00000000 -o jsonpath='{.spec.holderIdentity}' 2>/dev/null)
chk "the lease is held by arm A" "$LEASE" "ehdb-m5-writer-a"
[ "$A_EPOCH" -ge 1 ] && ok "arm A holds a real epoch ($A_EPOCH)" || no "arm A epoch is $A_EPOCH — it did not win"
chk "arm B holds NO epoch" "$B_EPOCH" "0"

echo
echo "== E3 — the stale writer is refused, the elected one proceeds =="
chk "arm A served its appends" "$A_SERVED" "3"
chk "arm A was never fenced" "$A_FENCED" "0"
chk "arm B was fenced on every append" "$B_FENCED" "3"
chk "arm B wrote NOTHING (no split brain)" "$B_SERVED" "0"
chk "arm B did not merely error" "$B_ERR" "0"
echo "$B" | grep -q "stale_epoch" && ok "the refusal carries the store's own stale_epoch text" || no "no stale_epoch in arm B's detail"

echo
echo "== E4 — the fencing counters are present and readable =="
for m in ehdb_fencing_writes_checked_total ehdb_fencing_stale_observed_total \
         ehdb_fencing_stale_refused_total ehdb_fencing_epoch_advances_total \
         ehdb_fencing_enforcing ehdb_fencing_active; do
  V=$(kubectl --context kind-noetl -n noetl logs ehdb-m5-writer-b 2>/dev/null | grep "^$m " | tail -1)
  [ -n "$V" ] && ok "present: $V" || no "ABSENT: $m — absent reads the same as zero"
done
# ⚠ Two counters, two vantage points, and they are SUPPOSED to disagree here.
#
# The first gate run read `writes_checked 0` on a refused arm and that WAS the
# finding: the publish the decorator guards had been skipped, so the ledger was
# never consulted and the stale writer was served. After the fix the same 0 is
# correct for the opposite reason — the precheck refuses before the append, so
# the decorator legitimately never runs on this arm. What separates the two
# readings is `precheck_*`, asserted below, plus `served=0` above.
#
# On the ELECTED arm the decorator does run (it publishes), so its counter must
# be non-zero there. Asserting that is what keeps this from being satisfied by a
# decorator that never runs at all.
CHECKED_A=$(kubectl --context kind-noetl -n noetl logs ehdb-m5-writer-a 2>/dev/null | grep "^ehdb_fencing_writes_checked_total " | tail -1 | awk '{print $2}')
[ "${CHECKED_A:-0}" -ge 1 ] && ok "the DECORATOR ran on the elected arm (writes_checked=$CHECKED_A)" || no "writes_checked=${CHECKED_A:-absent} on the elected arm — the decorator is not on the path at all"
CHECKED_B=$(kubectl --context kind-noetl -n noetl logs ehdb-m5-writer-b 2>/dev/null | grep "^ehdb_fencing_writes_checked_total " | tail -1 | awk '{print $2}')
chk "the decorator never ran on the refused arm (refused before the append)" "${CHECKED_B:-absent}" "0"

PCW=$(kubectl --context kind-noetl -n noetl logs ehdb-m5-writer-b 2>/dev/null | grep "^ehdb_fencing_precheck_writes_total " | tail -1 | awk '{print $2}')
PCS=$(kubectl --context kind-noetl -n noetl logs ehdb-m5-writer-b 2>/dev/null | grep "^ehdb_fencing_precheck_stale_total " | tail -1 | awk '{print $2}')
[ "${PCW:-0}" -ge 3 ] && ok "the precheck saw every append (precheck_writes=$PCW)" || no "precheck_writes=${PCW:-absent}"
[ "${PCS:-0}" -ge 3 ] && ok "the precheck found them stale (precheck_stale=$PCS)" || no "precheck_stale=${PCS:-absent}"

REFUSED=$(kubectl --context kind-noetl -n noetl logs ehdb-m5-writer-b 2>/dev/null | grep "^ehdb_fencing_stale_refused_total " | tail -1 | awk '{print $2}')
[ "${REFUSED:-0}" -ge 3 ] && ok "arm B's refused counter moved to $REFUSED" || no "refused counter is ${REFUSED:-absent}, expected >=3"
A_REFUSED=$(kubectl --context kind-noetl -n noetl logs ehdb-m5-writer-a 2>/dev/null | grep "^ehdb_fencing_stale_refused_total " | tail -1 | awk '{print $2}')
chk "arm A's refused counter stayed at 0 (present, not absent)" "${A_REFUSED:-absent}" "0"

echo
echo "== ⭐ NEGATIVE CONTROL — the same race under SHADOW must be SERVED =="
# Identical to arm B in every respect but NOETL_EHDB_FENCING. Without this, the
# refusals above are equally explained by a broken store, a missing volume, or a
# backend that never worked — all of which also produce "arm B wrote nothing".
kubectl --context kind-noetl -n noetl apply -f "$SD/m5-race-c.yaml" >/dev/null
C=""
for i in $(seq 1 60); do C=$(armjson ehdb-m5-writer-c); [ -n "$C" ] && break; sleep 3; done
if [ -z "$C" ]; then no "shadow control produced no verdict"; else
  C_EPOCH=$(echo "$C"|jqf held_epoch); C_SERVED=$(echo "$C"|jqf served); C_FENCED=$(echo "$C"|jqf fenced_stale)
  chk "the shadow arm is equally stale (epoch 0)" "$C_EPOCH" "0"
  chk "the shadow arm's writes are SERVED" "$C_SERVED" "3"
  chk "the shadow arm refuses nothing" "$C_FENCED" "0"
  CS=$(kubectl --context kind-noetl -n noetl logs ehdb-m5-writer-c 2>/dev/null | grep "^ehdb_fencing_precheck_stale_total " | tail -1 | awk '{print $2}')
  CR=$(kubectl --context kind-noetl -n noetl logs ehdb-m5-writer-c 2>/dev/null | grep "^ehdb_fencing_stale_refused_total " | tail -1 | awk '{print $2}')
  # The point of a shadow period: it must COUNT what enforce would have refused.
  [ "${CS:-0}" -ge 3 ] && ok "shadow COUNTED the stale writes it let through ($CS)" || no "shadow counted ${CS:-absent} — a shadow period that reports 0 makes enforce look free"
  chk "shadow refused nothing (counter present at 0)" "${CR:-absent}" "0"
  CE=$(kubectl --context kind-noetl -n noetl logs ehdb-m5-writer-c 2>/dev/null | grep "^ehdb_fencing_enforcing " | tail -1 | awk '{print $2}')
  chk "the ONLY difference is the mode gauge" "$CE" "0"
fi

echo
echo "== the winner never stopped winning =="
PH=$(kubectl --context kind-noetl -n noetl logs ehdb-m5-writer-a 2>/dev/null | grep "posthold" | head -1)
if [ -n "$PH" ]; then
  STILL=$(echo "$PH" | python3 -c "import json,sys;print(json.load(sys.stdin)['still_held'])")
  chk "arm A still held its token after the hold" "$STILL" "True"
else
  echo "  (post-hold line not yet printed — arm A is still holding, which is itself the assertion)"
  H2=$(kubectl --context kind-noetl -n noetl get lease ehdb-shard-00000000 -o jsonpath='{.spec.holderIdentity}' 2>/dev/null)
  chk "the lease is STILL held by arm A after arm B ran" "$H2" "ehdb-m5-writer-a"
fi

echo
echo "== E6 — failover: the epoch is MONOTONIC across a holder change =="
# Kill the holder. The lease is 15s; the next acquirer must come back with a
# HIGHER epoch, never a reused one — a reused epoch would let the old holder's
# in-flight writes through after it has been superseded.
kubectl --context kind-noetl -n noetl delete pod ehdb-m5-writer-a --wait=true >/dev/null 2>&1
kubectl --context kind-noetl -n noetl delete pod ehdb-m5-writer-b --wait=true >/dev/null 2>&1
sleep 20   # let the 15s lease expire with margin
kubectl --context kind-noetl -n noetl apply -f "$SD/m5-race-b.yaml" >/dev/null
C=""
for i in $(seq 1 60); do C=$(armjson ehdb-m5-writer-b); [ -n "$C" ] && break; sleep 3; done
if [ -z "$C" ]; then no "failover arm produced no verdict"; else
  echo "$C" | python3 -m json.tool | head -22
  C_EPOCH=$(echo "$C"|jqf held_epoch); C_SERVED=$(echo "$C"|jqf served); C_FENCED=$(echo "$C"|jqf fenced_stale)
  if [ "$C_EPOCH" -gt "$A_EPOCH" ]; then ok "epoch advanced across the holder change ($A_EPOCH -> $C_EPOCH)"
  else no "epoch did NOT advance: A held $A_EPOCH, the new holder holds $C_EPOCH"; fi
  chk "the new holder's writes are served" "$C_SERVED" "3"
  chk "the new holder is not fenced" "$C_FENCED" "0"
  T=$(kubectl --context kind-noetl -n noetl get lease ehdb-shard-00000000 -o jsonpath='{.spec.leaseTransitions}' 2>/dev/null)
  [ "${T:-0}" -ge 2 ] && ok "the lease recorded the transition (leaseTransitions=$T)" || no "leaseTransitions=${T:-absent}, expected >=2"
fi

echo
echo "RESULT: $PASS pass / $FAIL fail"
[ "$FAIL" -eq 0 ]
