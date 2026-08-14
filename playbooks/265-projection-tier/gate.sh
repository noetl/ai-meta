#!/usr/bin/env bash
# Kind gate for noetl/ai-meta#265 — is the EHDB projection tier (tier 2) holding
# the incumbent's read model, and does its `primary` flag reach a serve decision?
#
# The claims under test, in order of consequence:
#
#   1. The projection tier holds what `noetl.projection_snapshot` holds — same
#      version, same checksum, same applied_count — and the comparator can say so
#      about a NON-EMPTY authoritative side.
#   2. `NOETL_EHDB_PROJECTION=primary` reaches `primary_serve::decide` and the
#      verdict is observable (`served_primary`), rather than being inert and
#      silent the way the four unwired tiers are (ai-meta#259).
#   3. Divergence DEMOTES: an unreachable tier service produces
#      `no_durable_service` and the incumbent answers. Nothing fails.
#   4. The comparator discriminates — three mutations, each caught as ITSELF.
#
# Design notes, several learned expensively:
#
#   * Every assertion is behaviour-level, against the HTTP surface of BUILT
#     images in kind. Nothing asserts on source.
#   * A failed fetch is a FAILURE, never a zero that reads as a pass. `field()`
#     fails loud on absent, and NOT via `jq -e` — `-e` exits non-zero when the
#     last output is `false`, which is exactly `holds` on a divergent verdict.
#   * §1.1 of the design note is the trap this gate is shaped around: the wrong
#     authoritative table (`noetl.projection`) is EMPTY, so a comparator pointed
#     at it reports perfect parity forever. Section 3 therefore asserts a
#     non-zero `authoritative_version` BEFORE scoring any parity verdict. A
#     match against nothing is not a pass.
#   * Metric ABSENCE is the default (prometheus prunes empty families), so
#     section 5 asserts the pinned series are PRESENT at 0 as well as asserting
#     the served one moved.
#
# Usage: gate.sh <arm>
#   arm ∈ { shadow, primary, demoted, corrupt, drop, bypass }
set -uo pipefail

SERVER="${SERVER:-http://localhost:8082}"
PROBE="${PROBE:-tests/gate_fast_probe}"
NS=noetl
ARM="${1:-shadow}"
# The probe's authoritative event count. Overridable, because a different probe
# has a different one and a stale constant would make the settle loop either
# never finish or finish early.
EXPECT_EVENTS="${EXPECT_EVENTS:-13}"

PASS=0
FAIL=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); }
info() { printf '        %s\n' "$1"; }

k() { kubectl --context kind-noetl -n "$NS" "$@"; }

field() {
  local json="$1" path="$2" v
  if ! v=$(printf '%s' "$json" | jq -r "$path" 2>/dev/null); then
    printf '__ABSENT__'; return
  fi
  if [ "$v" = "null" ]; then printf '__ABSENT__'; else printf '%s' "$v"; fi
}
eq() {
  local label="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then ok "$label ($got)"; else bad "$label — got '$got', want '$want'"; fi
}
gt0() {
  local label="$1" got="$2"
  if [ "$got" != "__ABSENT__" ] && [ "${got:-0}" -gt 0 ] 2>/dev/null; then
    ok "$label ($got)"
  else
    bad "$label — got '$got', want > 0"
  fi
}

# Sum one metric series across EVERY worker replica.
#
# Summing rather than sampling one pod: the server's relay resolves through a
# Service, so which replica handled the append is not ours to choose. A gate
# that read one pod would report 0 whenever the relay happened to pick another,
# and that zero would be indistinguishable from "the serve decision never ran".
#
# Returns `__ABSENT__` when the series appears on NO replica — which is a
# different fact from 0 and must not be collapsed into it.
metric_sum() {
  local needle="$1" total=0 seen=0 ip v
  local wp; wp=$(k get pod -l app=noetl-cmdbus-writer -o name 2>/dev/null | head -1)
  [ -n "$wp" ] || { printf '__ABSENT__'; return; }
  for ip in "${PODIP[@]}"; do
    # Scraped FROM the writer pod rather than by exec'ing into each worker: the
    # writer is one known container, and the proven pattern from the #257 gate.
    v=$(k exec "$wp" -- sh -c "wget -q -O - -T 15 'http://$ip:9090/metrics' 2>/dev/null" 2>/dev/null \
        | grep -F "$needle" | awk '{print $NF}' | head -1 | tr -d '\r')
    if [ -n "$v" ]; then
      seen=1
      total=$(awk -v a="$total" -v b="$v" 'BEGIN{printf "%d", a+b}')
    fi
  done
  [ "$seen" = "1" ] && printf '%s' "$total" || printf '__ABSENT__'
}

echo
echo "=== ai-meta#265 projection-tier gate — arm: $ARM ==="
echo

# ---------------------------------------------------------------------------
# 0. Harness + topology.
# ---------------------------------------------------------------------------
echo "-- 0. harness + topology --"
health=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$SERVER/api/health")
eq "server answers /api/health" "$health" "200"
[ "$health" = "200" ] || { echo; echo "ABORT: server unreachable."; exit 2; }

PODIP=()
while IFS= read -r ip; do
  [ -n "$ip" ] && PODIP+=("$ip")
done < <(k get pods -l app=noetl-worker-rust \
    -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.status.podIP}{"\n"}{end}')
N=${#PODIP[@]}
info "worker replicas: $N (${PODIP[*]:-none})"
if [ "$N" -ge 2 ]; then
  ok "more than one replica is running ($N)"
else
  bad "only $N replica(s) — a single-replica run cannot show the tier is ONE store"
  echo; echo "ABORT: the premise of this gate is N>1."; exit 2
fi

th=$(k exec "$(k get pod -l app=noetl-cmdbus-writer -o name | head -1)" -- \
       sh -c 'nc -z 127.0.0.1 9110 && echo open || echo shut' 2>/dev/null | tr -d '\r')
if [ "$ARM" = "demoted" ]; then
  info "writer tier service state: ${th:-unknown} (irrelevant — this arm points elsewhere)"
else
  eq "writer tier service listening on :9110" "${th:-unknown}" "open"
fi

# ---------------------------------------------------------------------------
# 1. In-binary comparator controls, BEFORE anything else.
#
# A comparator that cannot detect divergence reports zero divergence, and so
# does a healthy platform. Everything below is void without this.
# ---------------------------------------------------------------------------
echo
echo "-- 1. projection comparator controls (before) --"
st=$(curl -s --max-time 15 "$SERVER/api/ehdb/projection-parity/self-test")
eq "controls_ok" "$(field "$st" '.controls_ok')" "true"
eq "controls unexpected" "$(field "$st" '[.controls[]? | select(.expected == false)] | length')" "0"
gt0 "controls expected > 0" "$(field "$st" '[.controls[]? | select(.expected == true)] | length')"
# The suite must cover every divergence kind, or "all controls passed" is a
# statement about a shorter list than it appears to be.
gt0 "controls cover >= 8 kinds" "$(field "$st" '.controls | length')"

# ---------------------------------------------------------------------------
# 2. Drive one execution and let the snapshot settle.
# ---------------------------------------------------------------------------
echo
echo "-- 2. drive one execution of $PROBE --"
if [ -n "${EXEC_ID:-}" ]; then
  exec_id="$EXEC_ID"
  info "reusing execution $exec_id (no new run) — the mutation arms measure a RE-READ"
else
  run=$(curl -s --max-time 60 -X POST "$SERVER/api/execute" \
          -H 'content-type: application/json' -d "{\"path\":\"$PROBE\"}")
  exec_id=$(field "$run" '.execution_id')
  if [ "$exec_id" = "__ABSENT__" ] || [ -z "$exec_id" ]; then
    bad "execute returned no execution_id"; info "body: $(printf '%s' "$run" | head -c 400)"
    echo; echo "ABORT: nothing to compare."; exit 2
  fi
fi
ok "execution_id=$exec_id"

# ---------------------------------------------------------------------------
# 2b. Make the incumbent write its snapshot — and say why this is needed.
#
# MEASURED THIS SESSION, and it changes what "the projection tier mirrors"
# means: a 13-event execution completes and `noetl.projection_snapshot` gets
# NO ROW. The orchestrator's self-write is gated on
# `total == Some(cache.applied_count)` — a throttled consistency COUNT having
# run in the same pass — and on a short execution it never coincides. The rows
# that do exist in kind came from the background reconcile poller revisiting
# long-lived executions.
#
# So the gate drives `POST /api/internal/projection/advance`. That is NOT a test
# hook: it is the endpoint the `system/projector` playbook calls in production,
# and a real call site of the very chokepoint the mirror sits inside
# (`events::advance_snapshot` -> `orch_snapshot::save`).
#
# The consequence is worth stating rather than working around: the projection
# tier can only ever hold what the incumbent writes, and the incumbent writes
# SPARSELY. That is a coverage fact a prod soak has to account for.
# ---------------------------------------------------------------------------
if [ -z "${EXEC_ID:-}" ]; then
  TOKSEC=$(k get deploy noetl-server-rust -o json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
for e in d['spec']['template']['spec']['containers'][0].get('env',[]):
    if e['name']=='NOETL_INTERNAL_API_TOKEN':
        r=e['valueFrom']['secretKeyRef']; print(r['name'], r['key'])
" 2>/dev/null)
  if [ -n "$TOKSEC" ]; then
    TN=$(printf '%s' "$TOKSEC" | awk '{print $1}'); TK=$(printf '%s' "$TOKSEC" | awk '{print $2}')
    TOK=$(k get secret "$TN" -o jsonpath="{.data.$TK}" | base64 -d)
    # Retried, because `projection_advance` is idempotent by construction (a
    # monotonic upsert) and because a run started right after `deploy.sh arm`
    # can reach a server that answers /api/health before its internal route is
    # warm. That produced a whole arm of failures whose actual cause was one
    # unretried call — the gate reporting a harness state as a platform finding.
    n=0
    for _ in $(seq 1 10); do
      adv=$(curl -s --max-time 60 -X POST "$SERVER/api/internal/projection/advance" \
              -H "Authorization: Bearer $TOK" -H 'content-type: application/json' \
              -d "{\"execution_ids\":[$exec_id]}")
      n=$(field "$adv" '.advanced | length')
      [ "$n" = "1" ] && break
      sleep 3
    done
    n=$(field "$adv" '.advanced | length')
    f=$(field "$adv" '.failed | length')
    info "projection/advance: advanced=$n failed=$f"
    eq "the incumbent wrote its snapshot" "$n" "1"
    eq "no advance failures" "$f" "0"
  else
    bad "could not resolve NOETL_INTERNAL_API_TOKEN — cannot drive the incumbent write"
  fi
else
  info "reusing $exec_id: its snapshot was written by the arm that created it"
fi

# Settle on the AUTHORITATIVE snapshot version, not on `noetl.execution.status`
# (a frozen Python-era column no Rust path writes — ai-meta#235) and not on a
# wall-clock sleep. The orchestrator upserts the snapshot on each trigger, so a
# comparison taken mid-flight compares against a revision that is about to move.
# In the `demoted` arm the tier read fails by design, so the comparator returns
# no report and this loop would spin to its limit and then fail section 3 on an
# absent field — a harness artefact reported as a finding about the platform.
if [ "$ARM" = "demoted" ]; then
  info "skipping the settle loop: this arm makes the tier read fail by design"
  sleep 20
fi
prev=-1; stable=0
[ "$ARM" = "demoted" ] && stable=99
for _ in $(seq 1 60); do
  [ "$stable" -ge 4 ] && break
  sleep 2
  v=$(curl -s --max-time 15 "$SERVER/api/ehdb/projection-parity/executions/$exec_id" \
      | jq -r '.result.report.authoritative_version // 0' 2>/dev/null)
  v=${v:-0}
  if [ "$v" -gt 0 ] && [ "$v" = "$prev" ]; then
    stable=$((stable+1)); [ "$stable" -ge 4 ] && break
  else
    stable=0
  fi
  prev="$v"
done
info "authoritative snapshot version settled at: $prev (stable for ${stable} polls)"

# ---------------------------------------------------------------------------
# 3. The verdict — and the guard that keeps it from being vacuous.
# ---------------------------------------------------------------------------
echo
echo "-- 3. cross-store verdict --"
# One sample of a read that crosses server -> relay -> Service -> writer is a
# flake in BOTH directions: the first run of this gate got `tier_unavailable` on
# an execution that reads `match` a second later, because the relay landed on a
# replica mid-rollout. Retry to a TERMINAL verdict (match / divergent) and
# report how many attempts it took, so a slow path is visible rather than
# silently smoothed over.
attempts=0
for attempts in $(seq 1 15); do
  rep=$(curl -s --max-time 30 "$SERVER/api/ehdb/projection-parity/executions/$exec_id")
  o=$(field "$rep" '.result.outcome')
  case "$o" in match|divergent) break ;; esac
  sleep 3
done
info "verdict settled after $attempts attempt(s)"
outcome=$(field "$rep" '.result.outcome')
auth_v=$(field "$rep" '.result.report.authoritative_version')
tier_v=$(field "$rep" '.result.report.tier_version')
holds=$(field "$rep" '.result.report.holds')
kinds=$(field "$rep" '.result.report.divergences | map(.kind) | unique | join(",")')
recs=$(field "$rep" '.result.report.tier_records')
age=$(field "$rep" '.result.snapshot_age_seconds')
src=$(field "$rep" '.result.tier_source')
info "outcome=$outcome auth_version=$auth_v tier_version=$tier_v records=$recs holds=$holds kinds='${kinds}'"
info "snapshot_age_seconds=$age tier_source=$src"

# THE ANTI-VACUITY GUARD (design note §1.1). The wrong table is empty; a
# comparator pointed at it agrees with itself forever. Before scoring anything,
# prove the authoritative side is real.
#
# In the `demoted` arm there is deliberately no report, so the guard moves to the
# field that survives: `snapshot_age_seconds` is populated from the incumbent row
# BEFORE the relay is attempted, so its presence proves the authoritative side
# was read even though nothing could be compared to it.
if [ "$ARM" = "demoted" ]; then
  if [ "$age" = "__ABSENT__" ]; then
    bad "no snapshot_age_seconds — the incumbent row was never read, so this arm \
proves nothing about the tier"
  else
    ok "authoritative side WAS read (snapshot_age_seconds=$age) — the failure is the tier's"
  fi
else
  gt0 "authoritative side is NON-EMPTY (version > 0)" "$auth_v"
  # The read must have resolved through the tier service. `local` here would mean
  # one replica's fragment answered, and at N>1 that verdict is about a fragment.
  eq "tier read resolved through the SERVICE" "$src" "service"
fi

case "$ARM" in
  shadow|primary)
    eq "parity outcome" "$outcome" "match"
    eq "report holds" "$holds" "true"
    eq "tier version == authoritative version" "$tier_v" "$auth_v"
    gt0 "tier holds records" "$recs"
    if [ "$kinds" = "" ] || [ "$kinds" = "__ABSENT__" ]; then
      ok "no divergence kinds"
    else
      bad "unexpected divergence kinds: $kinds"
    fi
    ;;
  demoted)
    # The tier service is unreachable, so the mirror could not land. The verdict
    # must say so — and must NOT be `match`.
    if [ "$outcome" = "match" ]; then
      bad "a tier that cannot be written still reports match — the comparator is not measuring"
    else
      ok "verdict is not 'match' with the service unreachable ($outcome)"
    fi
    ;;
  corrupt)
    eq "parity outcome" "$outcome" "divergent"
    eq "report holds" "$holds" "false"
    # The DISCRIMINATING assertion. Same versions, different content: the kind
    # must be `checksum`. `stale_version` here would mean the comparator noticed
    # only that something was off, and would send an operator to the relay
    # instead of to the store.
    if printf '%s' "$kinds" | grep -q checksum; then
      ok "the corruption is reported as 'checksum' ($kinds)"
    else
      bad "content corruption not reported as checksum — kinds='$kinds'"
    fi
    if printf '%s' "$kinds" | grep -q stale_version; then
      bad "reported stale_version too — the versions were NOT changed by this mutation"
    else
      ok "not misreported as stale_version"
    fi
    ;;
  drop)
    eq "parity outcome" "$outcome" "divergent"
    if printf '%s' "$kinds" | grep -q missing_execution; then
      ok "an emptied store is reported as 'missing_execution' ($kinds)"
    else
      bad "emptied store not reported as missing_execution — kinds='$kinds'"
    fi
    eq "tier holds no records" "$recs" "0"
    ;;
  bypass)
    # A fresh execution with the projection mirror disarmed.
    if [ "$outcome" = "match" ]; then
      bad "the mirror is disarmed and the comparator still says match"
    else
      ok "a disarmed mirror produces a non-match verdict ($outcome / $kinds)"
    fi
    ;;
esac

# ---------------------------------------------------------------------------
# 4. The serve decision — is `primary` reaching `decide`, and is it observable?
#
# This is the ai-meta#259 question. The four unwired tiers accept `primary` and
# change nothing a caller can see; the point of A2 is that this one does not.
# ---------------------------------------------------------------------------
echo
echo "-- 4. serve decision --"
served=$(metric_sum 'noetl_ehdb_projection_ops_total{operation="mirror",outcome="served_primary"}')
unavail=$(metric_sum 'noetl_ehdb_projection_ops_total{operation="mirror",outcome="primary_unavailable"}')
matz=$(metric_sum 'noetl_ehdb_projection_ops_total{operation="mirror",outcome="materialized"}')
info "served_primary=$served primary_unavailable=$unavail materialized=$matz"

# The PIN check, in every arm. Metric absence is the default — prometheus-style
# families render nothing until something increments them, so "absent" and "this
# build has no serve path" are the same bytes. The series must EXIST.
if [ "$served" = "__ABSENT__" ]; then
  bad "noetl_ehdb_projection_ops_total{outcome=\"served_primary\"} is ABSENT on every replica \
— it must be pinned at 0 so a demoted tier and a build without the serve path read differently"
else
  ok "the served_primary series is present (pinned), value=$served"
fi

case "$ARM" in
  shadow)
    eq "shadow does not serve" "$served" "0"
    gt0 "shadow DID materialize (the positive control for this arm)" "$matz"
    ;;
  primary)
    gt0 "primary SERVED (served_primary > 0)" "$served"
    ;;
  demoted)
    # The safety property: unreachable service ⇒ the incumbent answers, and the
    # tier says so rather than going quiet.
    gt0 "demote is recorded (primary_unavailable > 0)" "$unavail"
    ;;
esac

# The tier's own store gauges, per tier (#265 A1). An operator flipping this tier
# asks "does the store hold anything" — and must be able to ask it about the
# PROJECTION store specifically, not about whichever store was appended last.
pb=$(k exec "$(k get pod -l app=noetl-cmdbus-writer -o name | head -1)" -- \
       sh -c 'wget -q -O- http://127.0.0.1:9090/metrics 2>/dev/null | grep -F "noetl_ehdb_tier_service_store_sequence{tier=" ' \
     2>/dev/null | tr -d '\r')
if printf '%s' "$pb" | grep -q 'tier="projection"' && printf '%s' "$pb" | grep -q 'tier="eventlog"'; then
  ok "writer reports store gauges for BOTH tiers separately"
  info "$(printf '%s' "$pb" | tr '\n' ' ')"
else
  bad "writer store gauges are not per-tier: '$(printf '%s' "$pb" | tr '\n' ' ')'"
fi

# ---------------------------------------------------------------------------
# 5. Tier isolation — the event log must be unaffected by everything above.
#
# The projection tier is new; the event-log tier is PRIMARY IN PROD. If arming,
# corrupting or emptying tier 2 moved tier 1's verdict, the per-tier separation
# is fiction and none of this is safe to ship.
# ---------------------------------------------------------------------------
echo
echo "-- 5. event-log tier unaffected --"
# NOTE the different envelope: the event-log comparator answers FLAT
# (`.outcome`, `.report`), the projection one nests under `.result`. Reading the
# projection shape here returned `__ABSENT__` and scored it as "the verdict
# moved" — a harness bug reported as the finding this section exists to catch,
# which is the worst way to be wrong.
# SETTLE FIRST. Read mid-flight this reported `divergent auth=4 ehdb=5` — the
# execution was still emitting, and the tier was AHEAD of the log because the
# mirror is fast. That is a harness artefact, and reporting it as "the tiers are
# not separate" would be the worst possible way to be wrong here.
#
# Stability alone is not enough (the #257 gate learned this: a count sat at 6
# for two polls against an execution that went on to write 14), so require a
# plausible floor AND a quiet window.
elprev=-1; elstable=0
for _ in $(seq 1 45); do
  elc=$(curl -s --max-time 20 "$SERVER/api/ehdb/parity/executions/$exec_id" \
        | jq -r '.report.authoritative_count // 0' 2>/dev/null)
  elc=${elc:-0}
  # Floor is the probe's OWN event count, not a round number. A floor of 10
  # against a 13-event probe let the loop settle at 11 while the execution was
  # still writing, and the comparison then read `auth=11 ehdb=12` — the tier one
  # ahead of the log, which is the mirror being fast, not a divergence. The
  # #257 gate recorded the same trap at 6-vs-14 and it is easy to reintroduce by
  # picking a floor that "looks safe".
  if [ "$elc" -ge "$EXPECT_EVENTS" ] && [ "$elc" = "$elprev" ]; then
    elstable=$((elstable+1)); [ "$elstable" -ge 6 ] && break
  else
    elstable=0
  fi
  elprev="$elc"
  sleep 2
done
info "event-log settled at $elprev authoritative event(s)"
elrep=$(curl -s --max-time 30 "$SERVER/api/ehdb/parity/executions/$exec_id")
el_outcome=$(field "$elrep" '.outcome')
el_holds=$(field "$elrep" '.report.holds')
el_auth=$(field "$elrep" '.report.authoritative_count')
el_ehdb=$(field "$elrep" '.report.ehdb_count')
info "event-log outcome=$el_outcome holds=$el_holds auth=$el_auth ehdb=$el_ehdb"
# Positive control: a `match` against an empty pair is not evidence.
gt0 "the event-log comparison is over a NON-EMPTY log" "$el_auth"
if [ "$ARM" = "demoted" ]; then
  info "skipped: this arm points every tier read at a black hole"
elif [ "$el_outcome" = "match" ]; then
  ok "the event-log tier still matches while tier 2 is $ARM"
else
  bad "the event-log tier's verdict moved to '$el_outcome' — the tiers are NOT separate"
fi

# ---------------------------------------------------------------------------
# 6. Controls again, after.
#
# A control suite that passed before the drive and fails after it means the
# comparator changed under load, and every verdict above is void.
# ---------------------------------------------------------------------------
echo
echo "-- 6. projection comparator controls (after) --"
st2=$(curl -s --max-time 15 "$SERVER/api/ehdb/projection-parity/self-test")
eq "controls_ok (after)" "$(field "$st2" '.controls_ok')" "true"
eq "controls unexpected (after)" "$(field "$st2" '[.controls[]? | select(.expected == false)] | length')" "0"

echo
echo "=== arm '$ARM': $PASS passed, $FAIL failed ==="
echo "EXEC_ID=$exec_id"
[ "$FAIL" -eq 0 ]
