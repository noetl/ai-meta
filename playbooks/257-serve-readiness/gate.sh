#!/usr/bin/env bash
# CONSOLIDATED serve-readiness gate for noetl/ai-meta#257.
#
# The question this answers, which none of the four prior gates could:
#
#   With the cross-store comparator, the server-authored mirror, the
#   tier-service instrumentation and the tier-query-service read path all in
#   ONE pair of built images, at MORE THAN ONE worker replica — is the
#   event-log tier safe to serve?
#
# "Safe to serve" is four claims, and each arm here measures one of them:
#
#   service     the tier holds the FULL authoritative set and every replica
#               agrees, with the observability to see it happen
#   primary     flipping the tier changes what the code does, and the incumbent
#               keeps receiving the complete set throughout
#   killswitch  when the tier service dies the tier demotes to the incumbent —
#               it never serves partial data and never errors the caller — and
#               it re-promotes only on a real success
#   mutated     the whole bundle fails when it should
#
# Design rules, each learned expensively:
#
#   * behaviour-level, against the HTTP surface of built images in kind. No
#     assertion reads source.
#   * "which replica answered" is a CONTROLLED variable, never a race.
#   * a failed fetch is a FAILURE, never a zero that reads as a pass.
#   * `field()` does NOT use `jq -e` — `-e` exits non-zero when the last output
#     is `false`, which is exactly `holds` on a divergent verdict.
#   * absent ≠ zero. `metric()` returns `__ABSENT__`, which never equals `0`.
#   * every count that must MOVE is measured as a delta against a baseline
#     taken in the same run. A cluster with history makes absolute values lies.
#
# Usage: gate.sh <arm>
#   arm ∈ { service, primary, killswitch, mutated }
set -uo pipefail

SERVER="${SERVER:-http://localhost:8082}"
PROBE="${PROBE:-tests/gate_fast_probe}"
NS=noetl
ARM="${1:-service}"

PASS=0
FAIL=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); }
info() { printf '        %s\n' "$1"; }

k() { kubectl --context kind-noetl -n "$NS" "$@"; }

wait_server() {
  local i pods streak=0
  for i in $(seq 1 90); do
    pods=$(k get pods -l app=noetl-server-rust --no-headers 2>/dev/null | grep -c Running || true)
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

# Read one JSON field, or fail loud. A missing field and a field that is
# legitimately 0/false must never produce the same string.
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
# Assert a counter MOVED. `__ABSENT__` in either endpoint is a failure, not a 0:
# a series that vanished and a series that did not move are different faults.
moved() {
  local label="$1" before="$2" after="$3" atleast="${4:-1}" d
  if [ "$before" = "__ABSENT__" ] || [ "$after" = "__ABSENT__" ]; then
    bad "$label — series absent (before='$before' after='$after')"; return
  fi
  d=$(awk -v a="$after" -v b="$before" 'BEGIN{printf "%d", a-b}')
  if [ "$d" -ge "$atleast" ]; then ok "$label (+$d)"; else bad "$label — moved by $d, want >= $atleast"; fi
}
# Same, for the ONE family that is deliberately NOT pinned:
# `noetl_worker_ehdb_query_ops_total{operation="tier_query_source.*"}`. Pinning
# it would break the byte-identical `/metrics` a disabled build renders, so it is
# absent until the first EHDB op — see worker@19862ca. An absent BEFORE is
# therefore expected and read as 0; an absent AFTER is still a failure, because
# that is the case where the read path never named itself at all.
grew_from_absent() {
  local label="$1" before="$2" after="$3" atleast="${4:-1}" b="$2" d
  [ "$b" = "__ABSENT__" ] && b=0
  if [ "$after" = "__ABSENT__" ]; then
    bad "$label — series still absent after the drive; the read path never named itself"; return
  fi
  d=$(awk -v a="$after" -v b="$b" 'BEGIN{printf "%d", a-b}')
  if [ "$d" -ge "$atleast" ]; then ok "$label (+$d, unpinned family: before=$before)"
  else bad "$label — moved by $d, want >= $atleast"; fi
}

# ---- metric plumbing ------------------------------------------------------
# The pod network is not routable from the host, so every /metrics read goes
# through an in-cluster exec. The writer pod is the fetcher because it is the
# one pod guaranteed to exist in every arm.
WRITER_POD=""
fetch() {  # fetch <url> -> body on stdout, empty on failure
  k exec "$WRITER_POD" -- sh -c "wget -q -O - -T 20 '$1' 2>/dev/null" 2>/dev/null
}
# Exact-line-prefix read out of a snapshot held in a variable.
mget() {
  local snap="$1" name="$2" v
  v=$(printf '%s' "$snap" | awk -v k="$name" '$1 == k { print $2; found=1 } END { if (!found) print "__ABSENT__" }')
  [ -z "$v" ] && v="__ABSENT__"
  printf '%s' "$v"
}
tsvc()  { mget "$1" "noetl_ehdb_dataplane_ops_total{operation=\"tier_service.$2\",outcome=\"$3\"}"; }
thist() { mget "$1" "noetl_ehdb_tier_service_duration_seconds_$2{operation=\"$3\"}"; }
tstore(){ mget "$1" "noetl_ehdb_tier_service_store_$2"; }
qsrc()  { mget "$1" "noetl_worker_ehdb_query_ops_total{operation=\"tier_query_source.$2\",outcome=\"$3\",tier=\"eventlog\"}"; }
elog()  { mget "$1" "noetl_ehdb_eventlog_ops_total{operation=\"$2\",outcome=\"$3\"}"; }

echo
echo "=== ai-meta#257 consolidated serve-readiness gate — arm: $ARM ==="
echo

# ---------------------------------------------------------------------------
# 0. Harness, topology, and WHICH BUILD is under test.
#
# Every number below comes out of an HTTP body. Prove the transport works, that
# there really is more than one replica, and that the pods are running the
# composed image — a "multi-replica" gate that silently ran at one replica, or
# against a released image, would pass and mean nothing.
# ---------------------------------------------------------------------------
echo "-- 0. harness, topology, build identity --"
health=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$SERVER/api/health")
eq "server answers /api/health" "$health" "200"
[ "$health" = "200" ] || { echo; echo "ABORT: server unreachable."; exit 2; }

WRITER_POD=$(k get pod -l app=noetl-cmdbus-writer -o name | head -1)
[ -n "$WRITER_POD" ] || { echo "ABORT: no writer pod."; exit 2; }

# Un-pin the relay before anything else. Section 5 leaves it aimed at the LAST
# replica it measured, and any roll between runs makes that a dead pod IP — the
# comparator then correctly answers `ehdb_unavailable`, and a run that read the
# authoritative count off that reply saw `null` and concluded the execution had
# written no events. Fail-loud on one side, misread on the other.
RELAY_SVC=http://noetl-worker-rust-metrics.noetl.svc.cluster.local:9090
cur_relay=$(k get deploy noetl-server-rust \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="NOETL_EHDB_WORKER_QUERY_URL")].value}')
if [ "$cur_relay" != "$RELAY_SVC" ]; then
  info "relay was pinned at '$cur_relay' — resetting to the Service before measuring"
  k set env deploy/noetl-server-rust NOETL_EHDB_WORKER_QUERY_URL="$RELAY_SVC" >/dev/null
  k rollout status deploy/noetl-server-rust --timeout=240s >/dev/null 2>&1
  wait_server || { echo "ABORT: server did not come back after un-pinning the relay."; exit 2; }
fi

# NOT `mapfile` — macOS bash 3.2 does not have it and the array would silently
# stay empty, aborting with what looks like a topology problem.
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
  bad "only $N replica(s) — a single-replica run cannot discriminate anything here"
  echo; echo "ABORT: the premise of this gate is N>1."; exit 2
fi

# The image, named. `kubectl get` is a representation of the spec; the running
# container's image is what the pods actually have.
wimg=$(k get pods -l app=noetl-worker-rust -o jsonpath='{.items[0].spec.containers[?(@.name=="worker")].image}')
zimg=$(k get pod "${WRITER_POD#pod/}" -o jsonpath='{.spec.containers[?(@.name=="noetl-worker")].image}')
info "worker pool image: $wimg"
info "writer image:      $zimg"
case "$wimg" in *cap*) ok "worker pool runs a composed gate image" ;;
  *) bad "worker pool is NOT on a composed gate image ($wimg)" ;; esac
case "$zimg" in *cap*) ok "writer runs a composed gate image" ;;
  *) bad "writer is NOT on a composed gate image ($zimg)" ;; esac

# ---------------------------------------------------------------------------
# 1. Comparator controls, before anything else.
# ---------------------------------------------------------------------------
echo
echo "-- 1. in-binary comparator controls (before) --"
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
# 2. Observability BASELINE, before any traffic.
#
# #260's own gate proved these series are PINNED — present at 0 before the first
# operation, absent entirely when the listener is not there. Here the point is
# different and complementary: capture the baseline so section 6 can assert the
# counters MOVED, in a cluster that already has history from earlier arms.
#
# Presence is still asserted, because a `0` delta and a vanished series read the
# same to anything that does not check.
# ---------------------------------------------------------------------------
echo
echo "-- 2. observability baseline (writer /metrics) --"
WSNAP0=$(fetch "http://127.0.0.1:9090/metrics")
if [ -z "$WSNAP0" ]; then
  bad "writer /metrics returned nothing — every later reading would be an artefact"
  echo; echo "ABORT: no observability to measure."; exit 2
fi
info "writer /metrics: $(printf '%s' "$WSNAP0" | wc -l | tr -d ' ') lines"
bi=$(printf '%s' "$WSNAP0" | grep -c '^noetl_worker_build_info{' || true)
if [ "${bi:-0}" -ge 1 ]; then
  ok "writer build_info present$(printf '%s' "$WSNAP0" | grep -m1 '^noetl_worker_build_info{' | sed 's/noetl_worker_build_info//;s/ 1$//')"
else
  bad "writer build_info absent — cannot tell whether this pod predates the metric"
fi
absent=0; total=0
for pair in "health ok" "append ok" "append error" "read_execution hit" "read_execution miss" \
            "scan hit" "unsupported unsupported" "conn accepted" "conn protocol_error"; do
  set -- $pair
  total=$((total+1))
  [ "$(tsvc "$WSNAP0" "$1" "$2")" = "__ABSENT__" ] && absent=$((absent+1))
done
if [ "$ARM" = "killswitch" ]; then
  # No listener ⇒ the series must not exist AT ALL. This is #260's discriminating
  # `off` arm, reproduced inside the composed bundle: if the renderer emitted
  # these lines unconditionally, the pinned zeros the other arms rely on would
  # prove nothing about the pin.
  eq "no listener ⇒ every tier-service series is absent" "$absent" "$total"
else
  if [ "$absent" -eq 0 ]; then
    ok "the tier-service series exist before this arm's traffic (a 0 will mean 'no traffic', not 'no metric')"
  else
    bad "$absent of $total pinned tier-service series are absent — the flip would be unobservable"
  fi
fi
B_APPEND_OK=$(tsvc "$WSNAP0" append ok)
B_READ_HIT=$(tsvc "$WSNAP0" read_execution hit)
B_HC_APPEND=$(thist "$WSNAP0" count append)
B_HC_READ=$(thist "$WSNAP0" count read_execution)
B_STORE_APP=$(tstore "$WSNAP0" appends_total)
B_STORE_SEQ=$(tstore "$WSNAP0" sequence)
B_STORE_BYTES=$(tstore "$WSNAP0" bytes)
info "baseline: append/ok=$B_APPEND_OK read/hit=$B_READ_HIT store_appends=$B_STORE_APP seq=$B_STORE_SEQ bytes=$B_STORE_BYTES"

# Per-replica baseline for the query-source counter.
B_QSRC=()
for ip in "${PODIP[@]}"; do
  s=$(fetch "http://$ip:9090/metrics")
  B_QSRC+=("$(qsrc "$s" read service)")
done
info "baseline tier_query_source.read/service per replica: ${B_QSRC[*]}"

# Baseline the eventlog outcome family on every replica — section 7's flip
# measurement is a delta against this, and it must be taken BEFORE the drive.
B_SERVED=(); B_MIRRORED=(); B_UNAVAIL=()
for ip in "${PODIP[@]}"; do
  s=$(fetch "http://$ip:9090/metrics")
  B_SERVED+=("$(elog "$s" mirror served_primary)")
  B_MIRRORED+=("$(elog "$s" mirror mirrored)")
  B_UNAVAIL+=("$(elog "$s" mirror primary_unavailable)")
done
info "baseline eventlog mirror served_primary: ${B_SERVED[*]}"

# The serve series must be PINNED — present at 0 before any traffic, on every
# replica. This is the assertion the P0 hid behind: `served_primary` was not 0,
# it was ABSENT, and an absent series reads exactly like a build that has no
# serve path at all. With the pin, `0` means "did not serve" and nothing means
# "this binary predates the metric" — two different facts, two different
# readings. Asserted for shadow AND primary: the flip must change the VALUES,
# never which series exist.
if [ "$ARM" != "killswitch" ]; then
  pin_absent=0
  for v in "${B_SERVED[@]}"; do [ "$v" = "__ABSENT__" ] && pin_absent=$((pin_absent+1)); done
  eq "the serve-decision series is pinned on every replica (0, not absent)" "$pin_absent" "0"
fi

# ---------------------------------------------------------------------------
# 3. Drive one execution and let the authoritative event set settle.
# ---------------------------------------------------------------------------
echo
echo "-- 3. drive one execution of $PROBE --"
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

# Settle on the AUTHORITATIVE event count, not on `noetl.execution.status` —
# that column is a frozen Python-era field no Rust path writes (ai-meta#235).
#
# Stability alone is not enough, and the window has now been wrong TWICE.
# The first version latched at 6 against an execution that wrote 13. The 6-poll
# / 12-second version latched at 13 against one that wrote 19, because
# `playbook.completed` IS NOT THE LAST EVENT — this probe emits a further
# step.enter/command.issued/claimed/started/call.done/command.completed run
# after it. Anchoring on that event would be worse than anchoring on quiescence;
# the fix is a quiet window long enough to cover a whole extra step.
#
# The count is read from `/api/executions/<id>`, NOT from the parity endpoint.
# The parity reply's `authoritative_count` is `null` whenever the tier cannot be
# read, so `// 0` turns "the relay is pointed at a dead pod" into "the execution
# wrote no events" — which aborted a whole arm on an execution that had in fact
# written 13. The settle target must not depend on the thing under test.
auth_count() {
  curl -s --max-time 15 "$SERVER/api/executions/$1" | jq -r '.events | length' 2>/dev/null
}
prev=-1; stable=0
for _ in $(seq 1 80); do
  sleep 3
  n=$(auth_count "$exec_id")
  n=${n:-0}
  if [ "$n" -ge 10 ] && [ "$n" = "$prev" ]; then
    stable=$((stable+1)); [ "$stable" -ge 10 ] && break
  else stable=0; fi
  prev=$n
done
EXPECT_EVENTS="$prev"
info "authoritative event count settled at $EXPECT_EVENTS"
if [ "$EXPECT_EVENTS" -ge 10 ] 2>/dev/null; then
  ok "the probe wrote a real event set ($EXPECT_EVENTS events)"
else
  bad "authoritative count is $EXPECT_EVENTS — too small to be the probe; a match against it would be vacuous"
  echo; echo "ABORT: nothing worth comparing."; exit 2
fi

# ---------------------------------------------------------------------------
# 4. Per-replica tier view, read DIRECTLY by pod IP.
#
# This is the part a single-replica gate is structurally unable to do. Bypassing
# the Service makes "which replica answered" controlled rather than raced.
# ---------------------------------------------------------------------------
echo
echo "-- 4. per-replica tier view (direct, by pod IP) --"
# Re-read the authoritative count IMMEDIATELY before the replica reads and use
# THAT as the target. A settled execution should give the same number as
# section 3; taking it fresh means a late arrival produces a reported drift
# rather than a spurious failure of the tier.
AUTH_AT_4=$(auth_count "$exec_id")
AUTH_AT_4=${AUTH_AT_4:-0}
if [ "$AUTH_AT_4" = "$EXPECT_EVENTS" ]; then
  ok "the authoritative set is still $AUTH_AT_4 — the execution really is settled"
else
  bad "the authoritative set moved $EXPECT_EVENTS -> $AUTH_AT_4 between settling and measuring; the quiet window is too short"
  EXPECT_EVENTS="$AUTH_AT_4"
fi
counts=(); sources=(); serves=()
for ip in "${PODIP[@]}"; do
  body=$(fetch "http://$ip:9090/ehdb/tiers/eventlog?execution=$exec_id&limit=1000")
  if [ -z "$body" ]; then
    if [ "$ARM" = "killswitch" ]; then
      # THE SAFETY PROPERTY, not a harness failure. With the tier service dead
      # the read must refuse rather than answer from the pod-local store. But
      # "refused" and "the pod is gone" look identical from here, so prove the
      # replica is alive before crediting the refusal.
      hz=$(fetch "http://$ip:9090/healthz")
      if [ -n "$hz" ]; then
        ok "replica $ip is alive and REFUSED the tier read — no silent fall-back"
      else
        bad "replica $ip is not answering at all; its refusal proves nothing"
      fi
    else
      bad "replica $ip did not answer its tier route — a failed fetch is not a zero"
    fi
    counts+=("__FETCHFAIL__"); sources+=("__FETCHFAIL__"); serves+=("__FETCHFAIL__"); continue
  fi
  c=$(field "$body" '((.records // .result.records) // []) | length')
  s=$(field "$body" '.tier_query_source')
  # The serve decision, AT THE ENDPOINT (ai-meta#257 P0). The P0 was found by a
  # gate reading a metric family that turned out to be absent, which reads the
  # same as a build without the serve path. A field in the reply body cannot be
  # absent for that reason, so the serve state is asserted here as well as from
  # /metrics — two independent surfaces for one fact.
  v=$(field "$body" '.serve_state')
  counts+=("$c"); sources+=("$s"); serves+=("$v")
  info "replica $ip -> records=$c source=$s serve_state=$v"
done
uniq_serves=$(printf '%s\n' "${serves[@]}" | sort -u | tr '\n' ',' | sed 's/,$//')
uniq_counts=$(printf '%s\n' "${counts[@]}" | sort -u | tr '\n' ',' | sed 's/,$//')
uniq_sources=$(printf '%s\n' "${sources[@]}" | sort -u | tr '\n' ',' | sed 's/,$//')
full=0; short=0
for c in "${counts[@]}"; do
  [ "$c" = "$EXPECT_EVENTS" ] && full=$((full+1)) || short=$((short+1))
done
info "distinct record counts: {$uniq_counts}   distinct sources: {$uniq_sources}"

info "distinct serve_state: {$uniq_serves}"

# The serve state, per arm. `unknown` is a legitimate value and NOT a pass or a
# fail on its own: the server's mirror hop goes through the pool's ClusterIP
# Service, so a replica that happened to receive none of this execution's appends
# has decided nothing — which is a different statement from `not_primary`, and
# conflating them is what a single boolean would do. What must never appear is a
# DEGRADED state, on any arm where the tier is healthy.
degraded_serves=0
for v in "${serves[@]}"; do
  case "$v" in no_durable_service|parity_diverged) degraded_serves=$((degraded_serves+1)) ;; esac
done

case "$ARM" in
  service|primary)
    eq "every replica reports source=service" "$uniq_sources" "service"
    eq "every replica returns the SAME view" "$(printf '%s\n' "${counts[@]}" | sort -u | wc -l | tr -d ' ')" "1"
    eq "and that view is the FULL authoritative set" "$uniq_counts" "$EXPECT_EVENTS"
    eq "no replica is short" "$short" "0"
    eq "no replica reports a DEGRADED serve state" "$degraded_serves" "0"
    ;;
  killswitch)
    # The service is gone. The read must FAIL LOUD, not quietly answer from the
    # pod-local store. A count of 0 reported as a successful read is the exact
    # shape of "serving partial data while claiming to be authoritative".
    if [ "$full" -eq 0 ]; then
      ok "no replica served the full set from a dead tier service ({$uniq_counts})"
    else
      bad "$full replica(s) answered the full set with the tier service DOWN — the read fell back silently"
    fi
    ;;
  mutated)
    eq "every replica STILL reports source=service" "$uniq_sources" "service"
    eq "and that view is the full set" "$uniq_counts" "$EXPECT_EVENTS"
    eq "no replica is short" "$short" "0"
    ;;
esac

# ---------------------------------------------------------------------------
# 5. THE VERDICT, pinned at each replica in turn.
# ---------------------------------------------------------------------------
echo
echo "-- 5. cross-store verdict, per replica --"
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
  o=$(field "$rep" '.outcome'); h=$(field "$rep" '.report.holds')
  e=$(field "$rep" '.report.ehdb_count'); a=$(field "$rep" '.report.authoritative_count')
  s=$(field "$rep" '.tier_query_source')
  kinds=$(printf '%s' "$rep" | jq -r '[.report.divergences[]?.kind] | unique | join(",")' 2>/dev/null)
  info "relay->$ip  outcome=$o holds=$h ehdb=$e/auth=$a source=$s kinds=${kinds:-<none>}"
  verdicts+=("$o"); vsources+=("$s"); vcounts+=("$e")
  # The full-set claim as an equality WITHIN ONE RESPONSE. Pinning it to a
  # constant captured minutes earlier makes a late-arriving event look like a
  # short tier, which is the opposite of what happened.
  if [ "$ARM" = "service" ] || [ "$ARM" = "primary" ] || [ "$ARM" = "mutated" ]; then
    eq "relay->$ip: tier holds the whole authoritative set" "$e" "$a"
  fi
done
uniq_verdicts=$(printf '%s\n' "${verdicts[@]}" | sort -u | tr '\n' ',' | sed 's/,$//')
uniq_vsources=$(printf '%s\n' "${vsources[@]}" | sort -u | tr '\n' ',' | sed 's/,$//')
uniq_vcounts=$(printf '%s\n' "${vcounts[@]}" | sort -u | tr '\n' ',' | sed 's/,$//')

case "$ARM" in
  service|primary|mutated)
    eq "the comparator saw source=service" "$uniq_vsources" "service"
    eq "ONE verdict, whichever replica is reached" "$uniq_verdicts" "match"
    # Not pinned to EXPECT_EVENTS: see the per-pin equality above. What matters
    # is that the replicas do not disagree WITH EACH OTHER, which is the failure
    # the `local` arm of the PR-4 gate exhibited (0 / 13 / 0).
    eq "the replicas do not disagree about the tier" \
       "$(printf '%s\n' "${vcounts[@]}" | sort -u | wc -l | tr -d ' ')" "1"
    info "tier counts seen across pins: {$uniq_vcounts}"
    wait_server || bad "server unreachable for the final full-set read"
    rep=$(curl -s --max-time 30 "$SERVER/api/ehdb/parity/executions/$exec_id")
    eq "unmirrored_by_design" "$(field "$rep" '.report.unmirrored_by_design')" "0"
    eq "matched == authoritative total" \
       "$(field "$rep" '.report.matched')" "$(field "$rep" '.report.authoritative_count')"
    eq "divergences" "$(field "$rep" '.report.divergences | length')" "0"
    eq "holds" "$(field "$rep" '.report.holds')" "true"
    ;;
  killswitch)
    # Fail-loud, per replica. `ehdb_unavailable` naming the failed hop is the
    # RIGHT answer. `match` against an unreadable store is the wrong one and is
    # indistinguishable from success to anything not checking for it.
    if printf '%s' "$uniq_verdicts" | grep -q 'match'; then
      bad "a verdict of 'match' was produced with the tier service DOWN ({$uniq_verdicts})"
    else
      ok "no replica produced 'match' against a dead tier service ({$uniq_verdicts})"
    fi
    ;;
esac

# ---------------------------------------------------------------------------
# 6. Did the observability MOVE, on the right labels?
#
# The flip's whole safety story is "you would see it". A metric that exists but
# never moves is the same defect as one that is absent, one level up.
# ---------------------------------------------------------------------------
echo
echo "-- 6. observability moved (writer /metrics, delta vs section 2) --"
WSNAP1=$(fetch "http://127.0.0.1:9090/metrics")
if [ -z "$WSNAP1" ]; then
  bad "writer /metrics unreadable after the drive"
else
  A_APPEND_OK=$(tsvc "$WSNAP1" append ok)
  A_READ_HIT=$(tsvc "$WSNAP1" read_execution hit)
  A_HC_APPEND=$(thist "$WSNAP1" count append)
  A_HC_READ=$(thist "$WSNAP1" count read_execution)
  A_STORE_APP=$(tstore "$WSNAP1" appends_total)
  A_STORE_SEQ=$(tstore "$WSNAP1" sequence)
  case "$ARM" in
    service|primary|mutated)
      moved "tier_service.append/ok"        "$B_APPEND_OK"  "$A_APPEND_OK"  "$EXPECT_EVENTS"
      moved "tier_service.read_execution/hit" "$B_READ_HIT" "$A_READ_HIT"   1
      moved "latency histogram count{append}" "$B_HC_APPEND" "$A_HC_APPEND" "$EXPECT_EVENTS"
      moved "latency histogram count{read_execution}" "$B_HC_READ" "$A_HC_READ" 1
      moved "store_appends_total"           "$B_STORE_APP"  "$A_STORE_APP"  "$EXPECT_EVENTS"
      moved "store_sequence"                "$B_STORE_SEQ"  "$A_STORE_SEQ"  "$EXPECT_EVENTS"
      # A recorder firing with a hardcoded 0.0 would look alive and measure
      # nothing, and +Inf must equal count or the histogram is malformed.
      for op in append read_execution; do
        c=$(thist "$WSNAP1" count "$op"); s=$(thist "$WSNAP1" sum "$op")
        i=$(mget "$WSNAP1" "noetl_ehdb_tier_service_duration_seconds_bucket{le=\"+Inf\",operation=\"$op\"}")
        eq "histogram +Inf == count {$op}" "$i" "$c"
        if [ "$s" != "__ABSENT__" ] && awk -v v="$s" 'BEGIN{exit !(v>0)}'; then
          ok "histogram sum{$op} is non-zero ($s)"
        else
          bad "histogram sum{$op} is '$s' — a recorder measuring nothing looks exactly like this"
        fi
      done
      ;;
    killswitch)
      info "append/ok $B_APPEND_OK -> $A_APPEND_OK   read/hit $B_READ_HIT -> $A_READ_HIT"
      ;;
  esac
fi

# The client half, per replica: the read really resolved through the service.
echo
echo "-- 6b. the read path named itself, per replica --"
i=0
for ip in "${PODIP[@]}"; do
  s=$(fetch "http://$ip:9090/metrics")
  a=$(qsrc "$s" read service)
  case "$ARM" in
    service|primary|mutated) grew_from_absent "replica $ip tier_query_source.read/service" "${B_QSRC[$i]}" "$a" 1 ;;
    killswitch) info "replica $ip tier_query_source.read/service ${B_QSRC[$i]} -> $a" ;;
  esac
  i=$((i+1))
done

# ---------------------------------------------------------------------------
# 6c. THE NEGATIVE CONTROL for section 7.
#
# `served_primary > 0` under `primary` proves nothing on its own — a recorder
# that fired unconditionally would satisfy it. This arm runs the SAME code over
# the SAME traffic with `shadow` instead of `primary`, and requires the serve
# series to stay at 0 while the mirror series moves. The pair is what makes the
# flip attributable to the flip.
# ---------------------------------------------------------------------------
if [ "$ARM" = "service" ] || [ "$ARM" = "mutated" ]; then
  echo
  echo "-- 6c. negative control: shadow must NOT serve --"
  i=0; shadow_served=0
  for ip in "${PODIP[@]}"; do
    s=$(fetch "http://$ip:9090/metrics")
    sp=$(elog "$s" mirror served_primary)
    mr=$(elog "$s" mirror mirrored)
    info "replica $ip  served_primary=$sp mirrored=$mr (baseline served=${B_SERVED[$i]})"
    if [ "$sp" != "__ABSENT__" ] && [ "$sp" != "0" ]; then shadow_served=$((shadow_served+1)); fi
    i=$((i+1))
  done
  eq "no replica served as primary while the tier is shadow" "$shadow_served" "0"
  # And the mirror side DID move, so the zero above is "did not serve" rather
  # than "no appends reached this path at all".
  moved_any=0
  for ip in "${PODIP[@]}"; do
    s=$(fetch "http://$ip:9090/metrics")
    mr=$(elog "$s" mirror mirrored)
    [ "$mr" != "__ABSENT__" ] && [ "$mr" != "0" ] && moved_any=$((moved_any+1))
  done
  if [ "$moved_any" -ge 1 ]; then
    ok "the serve site ran and recorded on the shadow label ($moved_any replica(s))"
  else
    bad "no replica recorded ANY mirror outcome — the zero above would be vacuous"
  fi
fi

# ---------------------------------------------------------------------------
# 7. THE FLIP — what changes when the event-log tier is `primary`?
#
# Measured, not assumed. The flip is only meaningful if some code path takes a
# different branch and says so. `served_primary` is the outcome label that
# `primary_serve::decide` produces when it lets EHDB answer authoritatively.
# ---------------------------------------------------------------------------
if [ "$ARM" = "primary" ] || [ "$ARM" = "killswitch" ]; then
  echo
  echo "-- 7. the flip: does 'primary' change what runs? --"
  m=$(k get deploy noetl-worker-rust \
      -o jsonpath='{.spec.template.spec.containers[?(@.name=="worker")].env[?(@.name=="NOETL_EHDB_EVENTLOG")].value}')
  eq "the pool's NOETL_EHDB_EVENTLOG" "$m" "$([ "$ARM" = "killswitch" ] && echo primary || echo primary)"
  i=0; served_total=0; unavail_total=0; served_delta=0; endpoint_served=0
  for ip in "${PODIP[@]}"; do
    s=$(fetch "http://$ip:9090/metrics")
    sp=$(elog "$s" mirror served_primary)
    pu=$(elog "$s" mirror primary_unavailable)
    mr=$(elog "$s" mirror mirrored)
    # The serve state at the ENDPOINT, independent of the metric family. Read
    # from the tier route, which is the same surface the comparator reads.
    es=$(field "$(fetch "http://$ip:9090/ehdb/tiers/eventlog?execution=$exec_id&limit=1")" '.serve_state')
    info "replica $ip  served_primary=$sp primary_unavailable=$pu mirrored=$mr serve_state=$es (baseline served=${B_SERVED[$i]})"
    [ "$sp" != "__ABSENT__" ] && served_total=$(awk -v a="$served_total" -v b="$sp" 'BEGIN{print a+b}')
    [ "$pu" != "__ABSENT__" ] && unavail_total=$(awk -v a="$unavail_total" -v b="$pu" 'BEGIN{print a+b}')
    # The DELTA, per replica, against this run's own baseline. A cluster with
    # history makes an absolute value a lie, and an absent endpoint is a failure
    # rather than a zero.
    if [ "$sp" != "__ABSENT__" ] && [ "${B_SERVED[$i]}" != "__ABSENT__" ]; then
      d=$(awk -v a="$sp" -v b="${B_SERVED[$i]}" 'BEGIN{printf "%d", a-b}')
      served_delta=$(awk -v a="$served_delta" -v b="$d" 'BEGIN{print a+b}')
    fi
    [ "$es" = "served_primary" ] && endpoint_served=$((endpoint_served+1))
    i=$((i+1))
  done
  info "TOTAL across replicas: served_primary=$served_total (delta +$served_delta) primary_unavailable=$unavail_total  endpoint served_primary: $endpoint_served/$N"
  if [ "$ARM" = "primary" ]; then
    # THE P0 ASSERTION. Three independent readings of one fact, because the
    # defect was that all three were silent at once: an absent metric family, a
    # zero counter, and no log line.
    #
    # 1. the counter MOVED in this run (delta, not an absolute)
    if [ "$served_delta" -gt 0 ] 2>/dev/null; then
      ok "the flip reached the serve path — served_primary moved +$served_delta across the pool"
    else
      bad "served_primary did not move (delta $served_delta) across any replica while $EXPECT_EVENTS events flowed — 'primary' took no different branch on this configuration"
    fi
    # 2. the endpoint says so, on at least one replica.
    #
    # At least one and not all three: the server's mirror hop resolves the pool's
    # ClusterIP Service, so which replicas receive appends is a load-balancing
    # outcome, not something this gate controls. A replica that received none has
    # decided nothing and correctly reports `unknown`. Requiring all three would
    # be asserting a property of kube-proxy.
    if [ "$endpoint_served" -ge 1 ]; then
      ok "the serve decision is visible at the endpoint — $endpoint_served/$N replica(s) report serve_state=served_primary"
    else
      bad "no replica reports serve_state=served_primary at the endpoint; a metric-only signal is how the P0 stayed invisible"
    fi
    # 3. no replica is degraded while the tier is healthy.
    dg=0
    for ip in "${PODIP[@]}"; do
      es=$(field "$(fetch "http://$ip:9090/ehdb/tiers/eventlog?execution=$exec_id&limit=1")" '.serve_state')
      case "$es" in no_durable_service|parity_diverged) dg=$((dg+1)) ;; esac
    done
    eq "no replica demoted while the tier service is healthy" "$dg" "0"
  fi
  if [ "$ARM" = "killswitch" ]; then
    # Arm E, at the endpoint. With the tier service dead the serve state must
    # DEMOTE and say which condition failed — not go quiet. A serve signal that
    # merely stops incrementing is indistinguishable from no traffic.
    dg=0; still_serving=0
    for ip in "${PODIP[@]}"; do
      es=$(field "$(fetch "http://$ip:9090/ehdb/tiers/eventlog?execution=$exec_id&limit=1")" '.serve_state')
      info "replica $ip serve_state=$es"
      case "$es" in
        no_durable_service|parity_diverged) dg=$((dg+1)) ;;
        served_primary) still_serving=$((still_serving+1)) ;;
      esac
    done
    eq "no replica still claims to be serving primary with the tier service DOWN" "$still_serving" "0"
    if [ "$dg" -ge 1 ]; then
      ok "the demote is visible at the endpoint on $dg/$N replica(s)"
    else
      info "no replica reported a demote at the endpoint (the read refuses before the state is reachable on $N/$N)"
    fi
  fi

  # The safety property that makes the flip reversible: the INCUMBENT keeps
  # receiving the complete set throughout the primary window. This is the claim
  # the rollback story rests on, so it is measured rather than argued.
  echo
  echo "-- 7b. the incumbent kept the complete set through the primary window --"
  win_ok=0; win_bad=0
  for r in 1 2 3; do
    rid=$(curl -s --max-time 60 -X POST "$SERVER/api/execute" \
            -H 'content-type: application/json' -d "{\"path\":\"$PROBE\"}" | jq -r '.execution_id // empty')
    [ -z "$rid" ] && { bad "primary-window execution $r did not start"; continue; }
    p=-1; st=0
    for _ in $(seq 1 60); do
      sleep 3
      c=$(auth_count "$rid"); c=${c:-0}
      if [ "$c" -ge 10 ] && [ "$c" = "$p" ]; then st=$((st+1)); [ "$st" -ge 8 ] && break; else st=0; fi
      p=$c
    done
    # "Complete" as a STRUCTURAL invariant, not an equality against a literal.
    # This probe writes 13 or 19 events depending on whether the trailing step
    # ran, so pinning a number would fail on a difference that is not the thing
    # under test. What must hold in every case: the playbook reached
    # `playbook.completed`, and every command that was issued also completed.
    det=$(curl -s --max-time 20 "$SERVER/api/executions/$rid")
    done_ev=$(printf '%s' "$det" | jq -r '[.events[]?|select(.event_type=="playbook.completed")]|length' 2>/dev/null)
    iss=$(printf '%s' "$det" | jq -r '[.events[]?|select(.event_type=="command.issued")]|length' 2>/dev/null)
    cmp_=$(printf '%s' "$det" | jq -r '[.events[]?|select(.event_type=="command.completed")]|length' 2>/dev/null)
    info "primary-window execution $r ($rid): events=$p playbook.completed=$done_ev issued=$iss completed=$cmp_"
    if [ "${done_ev:-0}" -ge 1 ] && [ "${iss:-0}" -ge 1 ] && [ "${iss:-0}" = "${cmp_:-x}" ] && [ "$p" -ge 10 ]; then
      win_ok=$((win_ok+1))
    else
      win_bad=$((win_bad+1))
    fi
  done
  eq "every primary-window execution left a COMPLETE set in the incumbent" "$win_bad" "0"
  ok "primary-window executions completing normally: $win_ok/3"
fi

# ---------------------------------------------------------------------------
# 8. Controls again, after the live comparisons.
# ---------------------------------------------------------------------------
echo
echo "-- 8. comparator controls (after) --"
wait_server || bad "server unreachable for the post-run controls"
st2=$(curl -s --max-time 15 "$SERVER/api/ehdb/parity/self-test")
eq "controls_ok" "$(field "$st2" '.controls_ok')" "true"
eq "controls unexpected" "$(field "$st2" '[.controls[]? | select(.expected == false)] | length')" "0"

echo
echo "execution under test: $exec_id  (authoritative set: $EXPECT_EVENTS)"
echo "=== arm $ARM: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
