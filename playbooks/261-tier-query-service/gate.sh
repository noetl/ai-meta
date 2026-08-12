#!/usr/bin/env bash
# Kind gate for noetl/ai-meta#257 PR 4 — does a tier read resolve to ONE store
# when there is more than one worker replica?
#
# The claim under test:
#
#   With N>1 worker replicas the EHDB event-log tier is N disjoint pod-local
#   stores. Under `NOETL_EHDB_TIER_QUERY_SOURCE=local` a read answers from
#   whichever replica it lands on — a fragment, in a body shaped exactly like
#   the whole. Under `=service` every replica answers from the writer's single
#   durable store, so the answer is the same whichever replica is hit, and the
#   cross-store comparator returns a full-set match from any of them.
#
# Design notes, because several of these were learned the expensive way:
#
#   * Every assertion is behaviour-level, against the HTTP surface of built
#     images in kind. Nothing asserts on source.
#   * "Which replica answered" is a CONTROLLED variable, not a race. The gate
#     reads each replica's pod IP directly and pins the server's relay at one
#     pod at a time. Relying on the headless Service to spread the load would
#     make a pass or a fail an artefact of DNS ordering.
#   * A failed fetch is a FAILURE, never a zero that reads as a pass. `field()`
#     fails loud on absent, and NOT via `jq -e` — `-e` exits non-zero when the
#     last output is `false`, which is exactly `holds` on a divergent verdict.
#   * The `local` arm is the discriminating half. If it ALSO produced one
#     consistent full-set view, the flag would not be what produced the result
#     in the `service` arm and this gate would prove nothing.
#
# Usage: gate.sh <arm>
#   arm ∈ { local, service, mutated }
set -uo pipefail

SERVER="${SERVER:-http://localhost:8082}"
PROBE="${PROBE:-tests/gate_fast_probe}"
NS=noetl
ARM="${1:-service}"
EXPECT_EVENTS="${EXPECT_EVENTS:-13}"

PASS=0
FAIL=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); }
info() { printf '        %s\n' "$1"; }

k() { kubectl --context kind-noetl -n "$NS" "$@"; }

# Wait until the server ANSWERS. `kubectl rollout status` returning is not the
# same as the endpoint serving — the first run of this gate read an empty body
# from every relay repoint for exactly that reason, and empty bodies then made
# every section-4 assertion fail on '' rather than on a measurement.
wait_server() {
  local i pods streak=0
  for i in $(seq 1 90); do
    # A 200 alone is not enough: the OLD pod answers 200 while it is
    # terminating, so a single probe can pass and the very next request then
    # lands in the gap. Require the replica set to be back down to one Running
    # pod AND three consecutive good answers.
    pods=$(k get pods -l app=noetl-server-rust --no-headers 2>/dev/null | grep -c Running)
    if [ "${pods:-0}" -eq 1 ] \
       && [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$SERVER/api/health")" = "200" ]; then
      streak=$((streak+1)); [ "$streak" -ge 3 ] && return 0
    else
      streak=0
    fi
    sleep 2
  done
  return 1
}

# Read one field, or fail the gate. Never emits a default: a missing field and a
# field that is legitimately 0/false must not produce the same string.
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

echo
echo "=== ai-meta#257 PR 4 gate — arm: $ARM ==="
echo

# ---------------------------------------------------------------------------
# 0. Harness reachability + the replica set under test.
#
# Every number below comes out of an HTTP body. Prove the transport works and
# that there really is more than one replica before trusting anything either
# carries — a "multi-replica" gate that silently ran at one replica would pass
# both arms and mean nothing.
# ---------------------------------------------------------------------------
echo "-- 0. harness + topology --"
health=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$SERVER/api/health")
eq "server answers /api/health" "$health" "200"
[ "$health" = "200" ] || { echo; echo "ABORT: server unreachable."; exit 2; }

# NOT `mapfile` — this runs under macOS's bash 3.2, where mapfile does not
# exist and the array would silently stay empty, giving N=0 and an abort that
# looks like a topology problem rather than a shell one.
PODIP=()
while IFS= read -r ip; do
  [ -n "$ip" ] && PODIP+=("$ip")
done < <(k get pods -l app=noetl-worker-rust \
    -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.status.podIP}{"\n"}{end}')
N=${#PODIP[@]}
info "worker replicas: $N (${PODIP[*]})"
if [ "$N" -ge 2 ]; then
  ok "more than one replica is running ($N) — the condition this gate exists for"
else
  bad "only $N replica(s) — a single-replica run cannot discriminate the arms"
  echo; echo "ABORT: the premise of this gate is N>1."; exit 2
fi

# Writer tier service reachable? Under `local` it is deliberately unused, but it
# must be UP in both arms or the arms differ in two things instead of one.
th=$(k exec "$(k get pod -l app=noetl-cmdbus-writer -o name | head -1)" -- \
       sh -c 'nc -z 127.0.0.1 9110 && echo open || echo shut' 2>/dev/null | tr -d '\r')
eq "writer tier service listening on :9110" "${th:-unknown}" "open"

# ---------------------------------------------------------------------------
# 1. In-binary comparator controls, before anything else.
# ---------------------------------------------------------------------------
echo
echo "-- 1. comparator controls (before) --"
st=$(curl -s --max-time 15 "$SERVER/api/ehdb/parity/self-test")
eq "controls_ok" "$(field "$st" '.controls_ok')" "true"
eq "controls unexpected" "$(field "$st" '[.controls[]? | select(.expected == false)] | length')" "0"
expected=$(field "$st" '[.controls[]? | select(.expected == true)] | length')
if [ "$expected" != "__ABSENT__" ] && [ "$expected" -gt 0 ] 2>/dev/null; then
  ok "controls expected > 0 ($expected)"
else
  bad "controls expected is '$expected' — a suite that never ran proves nothing"
fi

# ---------------------------------------------------------------------------
# 2. Drive one execution and let the authoritative event set settle.
# ---------------------------------------------------------------------------
echo
echo "-- 2. drive one execution of $PROBE --"
# `EXEC_ID` reuses an execution already written. The mutation arm NEEDS this:
# it measures a re-read of the SAME execution after the stores were rearranged
# underneath it, and driving a fresh one would refill the very store the
# mutation just emptied.
if [ -n "${EXEC_ID:-}" ]; then
  run="{\"execution_id\":\"$EXEC_ID\"}"
  info "reusing execution $EXEC_ID (no new run)"
else
  run=$(curl -s --max-time 60 -X POST "$SERVER/api/execute" \
          -H 'content-type: application/json' -d "{\"path\":\"$PROBE\"}")
fi
exec_id=$(field "$run" '.execution_id')
if [ "$exec_id" = "__ABSENT__" ] || [ -z "$exec_id" ]; then
  bad "execute returned no execution_id"; info "body: $(printf '%s' "$run" | head -c 400)"
  echo; echo "ABORT: nothing to compare."; exit 2
fi
ok "execution_id=$exec_id"

# Settle on the authoritative event count, not on `noetl.execution.status` —
# that column is a frozen Python-era field no Rust path writes (ai-meta#235).
#
# Stability alone is NOT enough, and the first run of this gate proved it: the
# count sat at 6 for two polls mid-flight and the harness declared it settled,
# against an execution that went on to write 14. So require a long quiet window
# AND a plausible floor. A comparison run mid-flight compares a partial log.
prev=-1; stable=0
for _ in $(seq 1 90); do
  sleep 2
  n=$(curl -s --max-time 15 "$SERVER/api/ehdb/parity/executions/$exec_id" \
      | jq -r '.report.authoritative_count // 0' 2>/dev/null)
  n=${n:-0}
  if [ "$n" -ge 10 ] && [ "$n" = "$prev" ]; then
    stable=$((stable+1)); [ "$stable" -ge 6 ] && break
  else stable=0; fi
  prev=$n
done
# The expected set is DERIVED, not hardcoded. #258 measured 13 on one replica;
# this cluster writes 14 at three. Pinning the literal would make the gate fail
# on a difference that is not the thing under test — what matters is that the
# tier holds all of whatever the authoritative log holds.
EXPECT_EVENTS="$prev"
info "authoritative event count settled at $EXPECT_EVENTS"
if [ "$EXPECT_EVENTS" -ge 10 ] 2>/dev/null; then
  ok "the probe wrote a real event set ($EXPECT_EVENTS events)"
else
  bad "authoritative count is $EXPECT_EVENTS — too small to be the probe; a match against it would be vacuous"
  echo; echo "ABORT: nothing worth comparing."; exit 2
fi

# ---------------------------------------------------------------------------
# 3. THE MEASUREMENT — ask every replica the same question, directly.
#
# This is the part the single-replica #258 gate structurally could not do. Each
# worker's tier route is read by POD IP, bypassing the Service, so "which
# replica answered" is controlled rather than raced.
#
# `local`   ⇒ the replicas must DISAGREE, and at least one must hold fewer than
#             the full set. That is the fragmentation, measured.
# `service` ⇒ every replica must return the SAME full set, because they are all
#             reading one store.
# ---------------------------------------------------------------------------
echo
echo "-- 3. per-replica tier view (direct, by pod IP) --"
counts=(); sources=(); httpcodes=()
probe_pod=$(k get pod -l app=noetl-cmdbus-writer -o name | head -1)
for ip in "${PODIP[@]}"; do
  # curl from inside the cluster: the pod network is not routable from the host.
  body=$(k exec "$probe_pod" -- sh -c \
      "wget -q -O - -T 15 'http://$ip:9090/ehdb/tiers/eventlog?execution=$exec_id&limit=1000' 2>/dev/null || echo '__FETCHFAIL__'")
  if [ "$body" = "__FETCHFAIL__" ] || [ -z "$body" ]; then
    bad "replica $ip did not answer its tier route — a failed fetch is not a zero"
    counts+=("__FETCHFAIL__"); sources+=("__FETCHFAIL__"); continue
  fi
  # Both reply shapes: `records` at the top level (service) or under `result`
  # (local, which goes through the worker's wrapping run_query).
  c=$(field "$body" '((.records // .result.records) // []) | length')
  s=$(field "$body" '.tier_query_source')
  counts+=("$c"); sources+=("$s")
  info "replica $ip -> records=$c source=$s"
done

# The label must be present on every reply in BOTH arms. Its absence would make
# every later claim about which store answered a guess.
missing_label=0
for s in "${sources[@]}"; do [ "$s" = "__ABSENT__" ] && missing_label=1; done
if [ "$missing_label" -eq 0 ]; then
  ok "every replica named the store it answered from"
else
  bad "a replica returned no tier_query_source — the verdict is not attributable"
fi

uniq_counts=$(printf '%s\n' "${counts[@]}" | sort -u | tr '\n' ',' | sed 's/,$//')
uniq_sources=$(printf '%s\n' "${sources[@]}" | sort -u | tr '\n' ',' | sed 's/,$//')
full=0; short=0
for c in "${counts[@]}"; do
  [ "$c" = "$EXPECT_EVENTS" ] && full=$((full+1)) || short=$((short+1))
done
info "distinct record counts across replicas: {$uniq_counts}"
info "distinct sources across replicas:       {$uniq_sources}"

case "$ARM" in
  local)
    eq "every replica reports source=local" "$uniq_sources" "local"
    # The failure being demonstrated. With the mirror sending each batch to one
    # routed pod, the other replicas hold nothing for this execution.
    if [ "$short" -gt 0 ]; then
      ok "at least one replica holds an incomplete view ($short of $N short of $EXPECT_EVENTS)"
    else
      bad "every replica returned the full set under source=local — the pod-local store is not fragmented here, so this gate cannot discriminate"
    fi
    if [ "$(printf '%s\n' "${counts[@]}" | sort -u | wc -l | tr -d ' ')" -gt 1 ]; then
      ok "the replicas DISAGREE about the tier ({$uniq_counts}) — one read, N answers"
    else
      bad "all replicas agreed ({$uniq_counts}) under source=local"
    fi
    ;;
  service)
    eq "every replica reports source=service" "$uniq_sources" "service"
    eq "every replica returns the SAME view" "$(printf '%s\n' "${counts[@]}" | sort -u | wc -l | tr -d ' ')" "1"
    eq "and that view is the full set" "$uniq_counts" "$EXPECT_EVENTS"
    eq "no replica is short" "$short" "0"
    ;;
  mutated)
    # Pointed at a tier service whose store does not hold this execution while
    # the pod-local stores still do. A silent fall-back to local would return
    # the records anyway; the service path must return nothing.
    eq "every replica still reports source=service" "$uniq_sources" "service"
    if [ "$full" -eq 0 ]; then
      ok "no replica returned the local records ({$uniq_counts}) — the read really left the pod"
    else
      bad "$full replica(s) returned the full set from an EMPTY tier service — the read silently fell back to the pod-local store"
    fi
    ;;
esac

# ---------------------------------------------------------------------------
# 4. THE VERDICT, pinned at each replica in turn.
#
# The comparator is the acceptance instrument (#258). Pinning the relay at one
# pod at a time answers the question the flag exists for: does the verdict
# depend on which replica the server happens to reach?
# ---------------------------------------------------------------------------
echo
echo "-- 4. cross-store verdict, per replica --"
verdicts=(); vsources=(); vcounts=()
for ip in "${PODIP[@]}"; do
  k set env deploy/noetl-server-rust NOETL_EHDB_WORKER_QUERY_URL="http://$ip:9090" >/dev/null
  k rollout status deploy/noetl-server-rust --timeout=240s >/dev/null 2>&1
  if ! wait_server; then
    bad "server never came back after pinning the relay at $ip — a blank verdict is not a verdict"
    verdicts+=("__UNREACHABLE__"); vsources+=("__UNREACHABLE__"); vcounts+=("__UNREACHABLE__")
    continue
  fi
  rep=$(curl -s --max-time 30 "$SERVER/api/ehdb/parity/executions/$exec_id")
  o=$(field "$rep" '.outcome')
  h=$(field "$rep" '.report.holds')
  e=$(field "$rep" '.report.ehdb_count')
  a=$(field "$rep" '.report.authoritative_count')
  s=$(field "$rep" '.tier_query_source')
  kinds=$(printf '%s' "$rep" | jq -r '[.report.divergences[]?.kind] | unique | join(",")' 2>/dev/null)
  info "relay->$ip  outcome=$o holds=$h ehdb=$e/auth=$a source=$s kinds=${kinds:-<none>}"
  verdicts+=("$o"); vsources+=("$s"); vcounts+=("$e")
done

uniq_verdicts=$(printf '%s\n' "${verdicts[@]}" | sort -u | tr '\n' ',' | sed 's/,$//')
uniq_vsources=$(printf '%s\n' "${vsources[@]}" | sort -u | tr '\n' ',' | sed 's/,$//')
uniq_vcounts=$(printf '%s\n' "${vcounts[@]}" | sort -u | tr '\n' ',' | sed 's/,$//')

case "$ARM" in
  local)
    eq "the comparator saw source=local" "$uniq_vsources" "local"
    if [ "$(printf '%s\n' "${verdicts[@]}" | sort -u | wc -l | tr -d ' ')" -gt 1 ]; then
      ok "the VERDICT depends on which replica the relay reached ({$uniq_verdicts})"
    else
      bad "every replica produced the same verdict ({$uniq_verdicts}) under source=local — the arms do not differ"
    fi
    # Any non-`match` verdict is the hazard. Which one it is depends on whether
    # the routed replica held a partial set (`divergent`) or nothing at all
    # (`missing_execution`, still `divergent`) or could not answer — asserting on
    # one specific label would make the gate brittle about the wrong thing.
    nonmatch=0
    for v in "${verdicts[@]}"; do [ "$v" != "match" ] && nonmatch=$((nonmatch+1)); done
    if [ "$nonmatch" -gt 0 ]; then
      ok "$nonmatch of $N replicas produced a NON-match verdict — the hazard, measured"
    else
      bad "every replica produced 'match' under source=local; a fragmented tier should fail the comparison somewhere"
    fi
    ;;
  service)
    eq "the comparator saw source=service" "$uniq_vsources" "service"
    eq "one verdict, whichever replica is reached" "$uniq_verdicts" "match"
    eq "one tier count, whichever replica is reached" "$uniq_vcounts" "$EXPECT_EVENTS"
    # The full-set claim, stated as the equality it is.
    wait_server || bad "server unreachable for the final full-set read"
    rep=$(curl -s --max-time 30 "$SERVER/api/ehdb/parity/executions/$exec_id")
    eq "unmirrored_by_design" "$(field "$rep" '.report.unmirrored_by_design')" "0"
    eq "matched == authoritative total" \
       "$(field "$rep" '.report.matched')" "$(field "$rep" '.report.authoritative_count')"
    eq "divergences" "$(field "$rep" '.report.divergences | length')" "0"
    eq "holds" "$(field "$rep" '.report.holds')" "true"
    ;;
  mutated)
    eq "the comparator saw source=service" "$uniq_vsources" "service"
    if printf '%s' "$uniq_verdicts" | grep -qv '^match$'; then
      ok "the verdict changed when the service store did ({$uniq_verdicts})"
    else
      bad "verdict stayed 'match' against an EMPTY tier service — the comparator is not reading the service"
    fi
    ;;
esac

# ---------------------------------------------------------------------------
# 5. Controls again, after the live comparisons.
# ---------------------------------------------------------------------------
echo
echo "-- 5. comparator controls (after) --"
wait_server || bad "server unreachable for the post-run controls"
st2=$(curl -s --max-time 15 "$SERVER/api/ehdb/parity/self-test")
eq "controls_ok" "$(field "$st2" '.controls_ok')" "true"
eq "controls unexpected" "$(field "$st2" '[.controls[]? | select(.expected == false)] | length')" "0"

echo
echo "execution under test: $exec_id"
echo "=== arm $ARM: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
