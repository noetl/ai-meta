#!/usr/bin/env bash
# Kind gate for ai-meta#265 phase B1 — does the projection tier SERVE reads, and
# does a wrong snapshot demote to the incumbent instead of being served?
#
# Phase A's gate answered "does the tier hold the incumbent's read model". This
# one answers the two questions that decide whether it may ever serve:
#
#   1. With a healthy tier, a rebuild resolves its snapshot from the TIER and
#      produces the SAME state the incumbent path produces. Not "a state" — the
#      same one, compared by the digest the writer authored.
#   2. With a tier that is wrong — ahead of the event log, self-inconsistent,
#      behind the incumbent, or unreachable — the read DEMOTES and the answer
#      still equals the incumbent's. Serving a wrong snapshot is silent, so this
#      is the arm the whole design exists for.
#
# TWO-SIDED. Between the `serve` arms and the baseline the only variable that
# moves is NOETL_EHDB_PROJECTION_READ_SOURCE. Between a healthy arm and its
# mutation arm the only thing that moves is one record in the tier store. A
# verdict that changes is therefore attributable.
#
# WHY THE MUTATIONS APPEND RATHER THAN EDIT. Phase A learned this expensively: a
# `sed` over the tier store never matched, because `LocalJsonlTransactionLog`
# writes payloads as a JSON BYTE ARRAY. `sed` exited 0 and the gate scored
# `match` on an unmutated store. So these mutations go in through the tier's own
# append route — the shipped write path — and the read path's own rule (newest
# by version, then sequence) makes the crafted record the one it must judge.
# A mutation that lands is verifiable; a mutation that "ran" is not.
#
# Usage: gate-read.sh <arm> [execution_id]
#   arm ∈ { baseline, verify, tier, ahead, corrupt, behind, unavailable, load }
set -uo pipefail

SERVER="${SERVER:-http://localhost:8082}"
PROBE="${PROBE:-tests/gate_fast_probe}"
NS=noetl
ARM="${1:-baseline}"
EXEC_ID="${2:-${EXEC_ID:-}}"

PASS=0; FAIL=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); }
info() { printf '        %s\n' "$1"; }
k() { kubectl --context kind-noetl -n "$NS" "$@"; }
psql_() { kubectl --context kind-noetl -n postgres exec deploy/postgres -- \
            psql -U noetl -d noetl -At -c "$1" 2>/dev/null | tr -d '\r'; }

# `jq -r`, never `jq -e`: `-e` exits non-zero when the last output is `false` or
# `null`, so a legitimately-false field reads as absent. `__ABSENT__` is a
# distinct answer from `false` and from `0`.
field() {
  local json="$1" path="$2" v
  v=$(printf '%s' "$json" | jq -r "$path" 2>/dev/null) || { printf '__ABSENT__'; return; }
  [ "$v" = "null" ] && printf '__ABSENT__' || printf '%s' "$v"
}
eq()  { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1 — got '$2', want '$3'"; fi; }
ne()  { if [ "$2" != "$3" ]; then ok "$1 ($2)"; else bad "$1 — got '$2', must differ from '$3'"; fi; }
gt0() { if [ "$2" != "__ABSENT__" ] && [ "${2:-0}" -gt 0 ] 2>/dev/null; then ok "$1 ($2)"; else bad "$1 — got '$2', want > 0"; fi; }

# One server replica in kind, so the read metric is read directly rather than
# summed. Absence is preserved: prometheus prunes empty families, so a series
# that has never fired is ABSENT, and "absent" must not read as 0 — that is the
# difference between "this binary has no read path" and "the read path did not
# fire", which is the question every arm below is asking.
srv_metric() {
  local needle="$1" v
  v=$(curl -s --max-time 15 "$SERVER/metrics" | grep -F "$needle" | awk '{print $NF}' | head -1 | tr -d '\r')
  [ -n "$v" ] && printf '%s' "$v" || printf '__ABSENT__'
}
read_total() { srv_metric "noetl_ehdb_projection_read_total{outcome=\"$1\"}"; }
# Integer delta that treats __ABSENT__ as "no series", never as 0.
delta() {
  local before="$1" after="$2"
  [ "$after" = "__ABSENT__" ] && { printf '__ABSENT__'; return; }
  [ "$before" = "__ABSENT__" ] && before=0
  awk -v a="$before" -v b="$after" 'BEGIN{printf "%d", b-a}'
}

internal_token() {
  local spec tn tk
  spec=$(k get deploy noetl-server-rust -o json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
for e in d['spec']['template']['spec']['containers'][0].get('env',[]):
    if e['name']=='NOETL_INTERNAL_API_TOKEN':
        r=e['valueFrom']['secretKeyRef']; print(r['name'], r['key'])
" 2>/dev/null)
  [ -n "$spec" ] || return 1
  tn=$(printf '%s' "$spec" | awk '{print $1}'); tk=$(printf '%s' "$spec" | awk '{print $2}')
  k get secret "$tn" -o jsonpath="{.data.$tk}" | base64 -d
}

# Drive the projector's own endpoint. NOT a test hook: it is the route the
# `system/projector` playbook calls in production, and it goes
# rebuild_state -> orch_snapshot::save, so it exercises the READ under test and
# then the write. Retried because it is a monotonic upsert and therefore
# idempotent, and because a server that answers /api/health can still have a
# cold internal route.
advance() {
  local e="$1" tok body n
  tok=$(internal_token) || { printf '{}'; return; }
  for _ in $(seq 1 10); do
    body=$(curl -s --max-time 60 -X POST "$SERVER/api/internal/projection/advance" \
            -H "Authorization: Bearer $tok" -H 'content-type: application/json' \
            -d "{\"execution_ids\":[$e]}")
    n=$(field "$body" '.advanced | length')
    [ "$n" != "__ABSENT__" ] && [ "${n:-0}" -ge 1 ] && { printf '%s' "$body"; return; }
    sleep 3
  done
  printf '%s' "$body"
}

incumbent_row() { psql_ "SELECT version || '|' || checksum FROM noetl.projection_snapshot WHERE aggregate_id='$1';" | head -1; }
max_event_id()  { psql_ "SELECT COALESCE(MAX(event_id),0) FROM noetl.event WHERE execution_id=$1;" | head -1; }

# Append one crafted record to the projection tier through the shipped route.
#
# The read path chooses the newest by (version, global_sequence), so a crafted
# record with a version at or above the incumbent's becomes the record it must
# judge — without touching anything the mirror wrote, and without editing a
# store whose payload encoding already defeated one mutation attempt.
tier_append() {
  local e="$1" payload="$2" wp resp
  wp=$(k get pod -l app=noetl-cmdbus-writer -o name | head -1)
  resp=$(k exec "$wp" -- sh -c "wget -q -O - -T 20 --header='Content-Type: application/json' \
    --post-data='{\"execution_id\":\"$e\",\"records\":[$payload]}' \
    'http://noetl-worker-rust-metrics.noetl.svc.cluster.local:9090/ehdb/tiers/projection' 2>&1" 2>&1)
  printf '%s' "$resp"
}

# Verify a crafted record actually became the newest one the tier holds.
# THE GUARD PHASE A LACKED: a mutation that "ran" is not a mutation that landed,
# and a gate scoring a verdict against an unmutated store proves nothing.
tier_newest_version() {
  local e="$1" wp body
  wp=$(k get pod -l app=noetl-cmdbus-writer -o name | head -1)
  body=$(k exec "$wp" -- sh -c "wget -q -O - -T 20 \
    'http://noetl-worker-rust-metrics.noetl.svc.cluster.local:9090/ehdb/tiers/projection?execution=$e&limit=500' 2>/dev/null" 2>/dev/null)
  printf '%s' "$body" | python3 -c "
import json,sys
try: b=json.load(sys.stdin)
except Exception: print('__ABSENT__'); raise SystemExit
best=None
for r in b.get('records') or []:
    p=r.get('payload')
    try: p=json.loads(p) if isinstance(p,str) else p
    except Exception: continue
    v=p.get('version')
    if v is None: continue
    v=int(v)
    if best is None or v>best: best=v
print(best if best is not None else '__ABSENT__')
"
}

echo
echo "=== ai-meta#265 B1 read-serve gate — arm: $ARM ==="
echo

echo "-- 0. harness --"
health=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$SERVER/api/health")
eq "server answers /api/health" "$health" "200"
[ "$health" = "200" ] || { echo; echo "ABORT: server unreachable."; exit 2; }

mode=$(k get deploy noetl-server-rust -o json | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(next((e.get('value','') for e in d['spec']['template']['spec']['containers'][0].get('env',[])
            if e['name']=='NOETL_EHDB_PROJECTION_READ_SOURCE'), '<unset>'))")
info "NOETL_EHDB_PROJECTION_READ_SOURCE = $mode"

# The pinned-at-0 assertion. Absence is the default state of a labelled metric,
# so "served_tier is 0" only means anything once the series is known to EXIST.
pin=$(read_total served_tier)
if [ "$pin" = "__ABSENT__" ]; then
  bad "read series is ABSENT — this binary has no read path, or init_ehdb_projection_series did not run"
else
  ok "read series present (served_tier=$pin)"
fi

echo
echo "-- 1. projection comparator controls (before) --"
st=$(curl -s --max-time 15 "$SERVER/api/ehdb/projection-parity/self-test")
eq "controls_ok" "$(field "$st" '.controls_ok')" "true"
eq "controls unexpected" "$(field "$st" '[.controls[]? | select(.expected == false)] | length')" "0"
gt0 "controls expected > 0" "$(field "$st" '[.controls[]? | select(.expected == true)] | length')"

echo
echo "-- 2. an execution with a mirrored snapshot --"
if [ -n "$EXEC_ID" ]; then
  exec_id="$EXEC_ID"; info "reusing execution $exec_id"
else
  run=$(curl -s --max-time 60 -X POST "$SERVER/api/execute" \
          -H 'content-type: application/json' -d "{\"path\":\"$PROBE\"}")
  exec_id=$(field "$run" '.execution_id')
  [ "$exec_id" != "__ABSENT__" ] || { bad "execute returned no execution_id"; exit 2; }
  sleep 12
  adv=$(advance "$exec_id")
  gt0 "projection/advance wrote a snapshot" "$(field "$adv" '.advanced | length')"
fi
ok "execution_id=$exec_id"

inc0=$(incumbent_row "$exec_id")
[ -n "$inc0" ] || { bad "no incumbent snapshot row for $exec_id — nothing to compare"; exit 2; }
inc_version="${inc0%%|*}"; inc_checksum="${inc0##*|}"
info "incumbent: version=$inc_version checksum=${inc_checksum:0:16}…"
maxev=$(max_event_id "$exec_id")
info "event-log tip: max(event_id)=$maxev"
tv=$(tier_newest_version "$exec_id")
info "tier newest version: $tv"

before_served=$(read_total served_tier)
# Fault-class baselines, captured before the arm acts. Every fault assertion
# below is a DELTA against these — see the healthy arm for why an absolute
# would make an arm's verdict depend on which arms ran before it.
for r in version_ahead checksum divergent stale_version unreadable undeserialisable; do
  eval "FAULT_$r=\$(read_total \"$r\")"
done

case "$ARM" in

# --- baseline -------------------------------------------------------------
# The default mode must cost nothing. Not "little" — nothing: no relay call and
# no tier series moving. A tier that is off but still consulted is not a
# rollback, it is a slower version of being on.
baseline)
  echo
  echo "-- 3. baseline: reads stay on the incumbent --"
  b=$(read_total disabled)
  advance "$exec_id" >/dev/null
  a=$(read_total disabled)
  gt0 "reads counted as 'disabled'" "$(delta "$b" "$a")"
  eq "served_tier did not move" "$(delta "$before_served" "$(read_total served_tier)")" "0"
  eq "incumbent row unchanged in identity" "$(incumbent_row "$exec_id" | cut -d'|' -f1)" "$inc_version"
  ;;

# --- verify / tier: the healthy serve arms --------------------------------
verify|tier)
  echo
  echo "-- 3. healthy tier: the read is SERVED from the tier --"
  eq "tier holds this execution at the incumbent's version" "$tv" "$inc_version"
  adv=$(advance "$exec_id")
  d=$(delta "$before_served" "$(read_total served_tier)")
  gt0 "served_tier moved" "$d"
  # THE CORRECTNESS ASSERTION. `advance` rebuilds from whatever the read
  # resolved and re-saves; if the tier served a different state the digest
  # would change. Comparing the digest rather than the version is what makes
  # this about CONTENT — a version-only check passes a wrong body.
  after=$(incumbent_row "$exec_id")
  eq "state after a tier-served rebuild is byte-identical" "${after##*|}" "$inc_checksum"
  eq "version after a tier-served rebuild" "${after%%|*}" "$inc_version"
  # No fault-class demote may have occurred WHILE SERVING. Compared as a DELTA
  # across this arm, not as an absolute: these counters accumulate across arms,
  # and a mutation arm run earlier in the same session leaves them non-zero. An
  # absolute check would fail a healthy arm for a fault that happened minutes
  # ago — reporting arm order as a platform finding.
  for r in version_ahead checksum divergent stale_version unreadable; do
    eq "no new '$r' demote during the healthy arm" "$(delta "$(eval echo \$FAULT_$r)" "$(read_total "$r")")" "0"
  done
  ;;

# --- ahead: THE DANGEROUS CASE -------------------------------------------
# A record claiming a version above the event log's tip. Serving it would skip
# every event in between and return a state that never existed — and nothing
# downstream could detect it, because a rebuild has no second opinion.
ahead)
  echo
  echo "-- 3. mutation: a tier record AHEAD of the event log --"
  bogus=$((maxev + 100000))
  body='"{\"execution_id\":'"$exec_id"',\"version\":'"$bogus"',\"checksum\":\"MUTCHK\",\"applied_count\":999,\"snapshot\":{\"MUTATED\":true},\"updated_at\":\"2030-01-01T00:00:00Z\",\"mirror_source\":\"server\"}"'
  # The digest must describe the body, or this arm would be caught by the
  # CHECKSUM rule and prove nothing about the ahead rule. Computed here, over
  # the same bytes the writer digests.
  chk=$(python3 -c "
import hashlib,json
print(hashlib.sha256(json.dumps({'MUTATED':True},separators=(',',':')).encode()).hexdigest())")
  body=${body/MUTCHK/$chk}
  info "appending a record at version $bogus (event tip is $maxev)"
  tier_append "$exec_id" "$body" | head -c 200; echo
  landed=$(tier_newest_version "$exec_id")
  # THE MUTATION GUARD. Without it a no-op append produces a green arm.
  eq "the crafted record IS the tier's newest" "$landed" "$bogus"
  [ "$landed" = "$bogus" ] || { bad "mutation did not land — the verdict below would be meaningless"; exit 3; }

  b_ahead=$(read_total version_ahead); [ "$b_ahead" = "__ABSENT__" ] && b_ahead=0
  advance "$exec_id" >/dev/null
  gt0 "the read DEMOTED with reason 'version_ahead'" "$(delta "$b_ahead" "$(read_total version_ahead)")"
  eq  "served_tier did NOT move" "$(delta "$before_served" "$(read_total served_tier)")" "0"
  # The answer must still be the incumbent's. This is the assertion the arm
  # exists for: a demote that still served the bad snapshot would satisfy every
  # metric above.
  after=$(incumbent_row "$exec_id")
  eq "the state served is still the INCUMBENT's" "${after##*|}" "$inc_checksum"
  ne "the crafted snapshot did not become the incumbent" "${after%%|*}" "$bogus"
  ;;

# --- corrupt: a record that does not describe itself ----------------------
corrupt)
  echo
  echo "-- 3. mutation: a tier record whose checksum does not match its body --"
  body='"{\"execution_id\":'"$exec_id"',\"version\":'"$inc_version"',\"checksum\":\"deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef\",\"applied_count\":999,\"snapshot\":{\"MUTATED\":true},\"updated_at\":\"2030-01-01T00:00:00Z\",\"mirror_source\":\"server\"}"'
  info "appending a self-inconsistent record at the incumbent's version $inc_version"
  tier_append "$exec_id" "$body" | head -c 200; echo
  landed=$(tier_newest_version "$exec_id")
  eq "the crafted record is at the incumbent's version" "$landed" "$inc_version"

  b_chk=$(read_total checksum); [ "$b_chk" = "__ABSENT__" ] && b_chk=0
  advance "$exec_id" >/dev/null
  gt0 "the read DEMOTED with reason 'checksum'" "$(delta "$b_chk" "$(read_total checksum)")"
  eq  "served_tier did NOT move" "$(delta "$before_served" "$(read_total served_tier)")" "0"
  after=$(incumbent_row "$exec_id")
  eq "the state served is still the INCUMBENT's" "${after##*|}" "$inc_checksum"
  ;;

# --- behind: verify mode only --------------------------------------------
# Correct to serve (folding forward gives the same answer) and still refused in
# `verify` mode, because `verify`'s contract is agreement and a tier that is
# behind has not agreed. Reported as its own reason so an operator is sent to
# the mirror rather than to the store.
behind)
  echo
  echo "-- 3. the tier is BEHIND the incumbent --"
  gt0 "incumbent is ahead of the tier" "$(awk -v a="$inc_version" -v b="${tv:-0}" 'BEGIN{print (a>b)?1:0}')"
  b_st=$(read_total stale_version); [ "$b_st" = "__ABSENT__" ] && b_st=0
  advance "$exec_id" >/dev/null
  gt0 "the read DEMOTED with reason 'stale_version'" "$(delta "$b_st" "$(read_total stale_version)")"
  eq  "served_tier did NOT move" "$(delta "$before_served" "$(read_total served_tier)")" "0"
  ;;

# --- unavailable ----------------------------------------------------------
unavailable)
  echo
  echo "-- 3. the tier relay is unreachable --"
  b_un=$(read_total unavailable); [ "$b_un" = "__ABSENT__" ] && b_un=0
  advance "$exec_id" >/dev/null
  gt0 "the read DEMOTED with reason 'unavailable'" "$(delta "$b_un" "$(read_total unavailable)")"
  eq  "served_tier did NOT move" "$(delta "$before_served" "$(read_total served_tier)")" "0"
  after=$(incumbent_row "$exec_id")
  eq "the incumbent still answered" "${after##*|}" "$inc_checksum"
  ;;

# --- load -----------------------------------------------------------------
# Nothing lost, nothing duplicated, nothing reordered, under concurrent reads of
# the same execution. Concurrency is the point: `advance` reads and then writes
# the same row, so N of them racing is the shape that would surface a torn read.
load)
  echo
  echo "-- 3. concurrent reads: nothing lost, duplicated or reordered --"
  N="${LOAD_N:-24}"
  b_served=$(read_total served_tier); [ "$b_served" = "__ABSENT__" ] && b_served=0
  b_fault=0
  for r in version_ahead checksum divergent unreadable undeserialisable; do
    v=$(read_total "$r"); [ "$v" = "__ABSENT__" ] && v=0
    b_fault=$((b_fault + v))
  done
  tok=$(internal_token)
  for _ in $(seq 1 "$N"); do
    curl -s --max-time 60 -X POST "$SERVER/api/internal/projection/advance" \
      -H "Authorization: Bearer $tok" -H 'content-type: application/json' \
      -d "{\"execution_ids\":[$exec_id]}" >/dev/null &
  done
  wait
  a_fault=0
  for r in version_ahead checksum divergent unreadable undeserialisable; do
    v=$(read_total "$r"); [ "$v" = "__ABSENT__" ] && v=0
    a_fault=$((a_fault + v))
  done
  gt0 "served_tier moved under load" "$(delta "$b_served" "$(read_total served_tier)")"
  eq  "no fault-class demote under $N concurrent reads" "$((a_fault - b_fault))" "0"
  after=$(incumbent_row "$exec_id")
  eq "content identical after $N concurrent read+write passes" "${after##*|}" "$inc_checksum"
  eq "version identical after $N concurrent read+write passes" "${after%%|*}" "$inc_version"
  # Monotonicity in the tier: the store's versions must never descend.
  wp=$(k get pod -l app=noetl-cmdbus-writer -o name | head -1)
  mono=$(k exec "$wp" -- sh -c "wget -q -O - -T 20 'http://noetl-worker-rust-metrics.noetl.svc.cluster.local:9090/ehdb/tiers/projection?execution=$exec_id&limit=500' 2>/dev/null" 2>/dev/null | python3 -c "
import json,sys
b=json.load(sys.stdin)
rs=[]
for r in b.get('records') or []:
    p=r.get('payload')
    try: p=json.loads(p) if isinstance(p,str) else p
    except Exception: continue
    if p.get('version') is None: continue
    rs.append((int(r.get('global_sequence') or 0), int(p['version'])))
rs.sort()
vs=[v for _,v in rs]
print('ok' if all(vs[i]<=vs[i+1] for i in range(len(vs)-1)) else 'DESCENDS', len(vs))
")
  eq "tier versions never descend by store order" "$(printf '%s' "$mono" | awk '{print $1}')" "ok"
  info "tier records for this execution: $(printf '%s' "$mono" | awk '{print $2}')"
  ;;

*) echo "unknown arm: $ARM" >&2; exit 2 ;;
esac

# ---------------------------------------------------------------------------
# 4. Tier 1 must not have moved.
#
# The event-log tier is `primary` and serving in production. If arming,
# mutating or reading tier 2 moved tier 1's verdict, the per-tier separation is
# fiction and none of this is safe to ship — regardless of how the arm above
# scored.
# ---------------------------------------------------------------------------
echo
echo "-- 4. the event-log tier did not move --"
el=$(curl -s --max-time 30 "$SERVER/api/ehdb/parity/execution/$exec_id")
elo=$(field "$el" '.outcome')
[ "$elo" = "__ABSENT__" ] && elo=$(field "$el" '.result.outcome')
eq "event-log tier verdict" "$elo" "match"

echo
echo "-- 5. projection comparator controls (after) --"
st2=$(curl -s --max-time 15 "$SERVER/api/ehdb/projection-parity/self-test")
eq "controls_ok (after)" "$(field "$st2" '.controls_ok')" "true"
eq "controls unexpected (after)" "$(field "$st2" '[.controls[]? | select(.expected == false)] | length')" "0"

echo
echo "=== arm $ARM: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
