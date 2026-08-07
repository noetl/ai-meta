#!/usr/bin/env bash
# kind regression harness — run RELEASED images through the paths that have
# actually broken, and report pass/fail with evidence.
#
#   ./playbooks/kind-regression-harness.sh <server-tag> [worker-tag]
#   ./playbooks/kind-regression-harness.sh 3.79.2 5.108.1
#
# There is no PR CI on any Rust repo (noetl/ai-meta#232), so this is the only
# gate between a merge and production.  It deliberately runs the RELEASED
# image, not a local build: three separate defects in this codebase existed
# only in the released artefact or only against a real database.
#
# ---------------------------------------------------------------------------
# The two cases that exist because they were learned the expensive way
# ---------------------------------------------------------------------------
#
# C6 — A DESTRUCTIVE ENDPOINT MUST BE TESTED ON AN ENCUMBERED ROW.
#      The catalog delete endpoint was validated in kind against a freshly
#      registered entry and passed.  It then failed in production, because
#      `noetl.event` holds an FK onto `noetl.catalog` and every real entry has
#      execution history.  The pre-prod fixture had tested the only case that
#      could succeed.  C6 executes a playbook first, then deletes it.
#
# C7/C8 — WHEN A SCHEMA OBJECT IS OPTIONAL, EVERY READER IS PART OF THE
#      CHANGE'S SURFACE.  A soft-delete column the server cannot create (the
#      table is owned by another role) was added, and the readers referenced it
#      unconditionally.  Startup was fine; `execute-by-path` returned 500 for
#      every request.  Validating the new feature's degraded path was not
#      enough.  C7/C8 drive execute-by-path and list against whatever column
#      state the database is actually in.
#
# C11 — A CASE THAT CANNOT FAIL PROVES NOTHING, SO EVERY CASE NEEDS THE OTHER
#      ANSWER DEMONSTRATED.  Container gating (noetl/ai-meta#186: a step whose
#      terminal callback never arrives must not advance the DAG) is trivially
#      "passing" if the fixture could never reach the downstream step at all.
#      C11a asserts the gate holds with the callback path disabled; C11b is its
#      control, proving the same fixture DOES finish when the callback arrives.
#      Verified to fail in both directions before it was committed: C11a returns
#      TERMINATED (fail) if run with the callback path enabled, and its detector
#      returns ADVANCED_EARLY on a #186-shaped event stream.
#
# Exit code is the number of failed cases, so CI can gate on it.

set -uo pipefail

SERVER_TAG="${1:?usage: $0 <server-tag> [worker-tag]}"
WORKER_TAG="${2:-}"
CTX="kind-noetl"
NS="noetl"
API="http://localhost:8082"
TMP="$(mktemp -d)"
PASS=0; FAIL=0
KC() { kubectl --context "$CTX" -n "$NS" "$@"; }
PQ() { kubectl --context "$CTX" -n postgres exec deploy/postgres -- psql -U noetl -d noetl -At -c "$1" 2>/dev/null; }

ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %-46s %s\n' "$1" "${2:-}"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %-46s %s\n' "$1" "${2:-}"; }
info() { printf '        %s\n' "$1"; }

# --------------------------------------------------------------------------
# Load + deploy the released images
# --------------------------------------------------------------------------
load_image() {  # repo tag
  local repo="$1"
  local tag="$2"
  local tar="$TMP/${repo##*/}-${tag}.tar"
  crane manifest "ghcr.io/noetl/$repo:$tag" >/dev/null 2>&1 || { bad "image published: $repo:$tag" "not on ghcr"; return 1; }
  crane pull --platform linux/arm64 "ghcr.io/noetl/$repo:$tag" "$tar" >/dev/null 2>&1 || { bad "image pull: $repo:$tag" ""; return 1; }
  kind load image-archive "$tar" --name noetl >/dev/null 2>&1 || { bad "kind load: $repo:$tag" ""; return 1; }
  ok "image loaded" "$repo:$tag"
}

echo "== kind regression harness =="
echo "   server=$SERVER_TAG worker=${WORKER_TAG:-<unchanged>}"
echo

load_image server "$SERVER_TAG" || exit $FAIL
[ -n "$WORKER_TAG" ] && load_image worker "$WORKER_TAG"

SC=$(KC get deploy noetl-server-rust -o jsonpath='{.spec.template.spec.containers[0].name}')
KC set image deploy/noetl-server-rust "$SC=ghcr.io/noetl/server:$SERVER_TAG" >/dev/null 2>&1
if [ -n "$WORKER_TAG" ]; then
  for d in noetl-worker-rust noetl-worker-system-pool; do
    c=$(KC get deploy "$d" -o jsonpath='{.spec.template.spec.containers[0].name}' 2>/dev/null) || continue
    KC set image "deploy/$d" "$c=ghcr.io/noetl/worker:$WORKER_TAG" >/dev/null 2>&1
  done
fi

# --------------------------------------------------------------------------
# C1 — the server actually starts.
#
# Not a formality.  A startup DDL that failed on a table-ownership boundary
# crash-looped the server; the image was fine and every unit test passed.
# --------------------------------------------------------------------------
if timeout 400 kubectl --context "$CTX" -n "$NS" rollout status deploy/noetl-server-rust --timeout=380s >/dev/null 2>&1; then
  ok "C1 server rolls out (no crash-loop)"
else
  bad "C1 server rolls out (no crash-loop)" "$(KC get pods -l app=noetl-server-rust -o jsonpath='{.items[*].status.containerStatuses[*].state.waiting.reason}' 2>/dev/null)"
  KC logs deploy/noetl-server-rust --tail=15 2>/dev/null | tail -5 | sed 's/^/        /'
  echo; echo "== $PASS passed, $FAIL failed =="; exit $FAIL
fi
sleep 6

RUNNING=$(curl -s --max-time 10 "$API/metrics" 2>/dev/null | grep -o 'noetl_server_build_info{version="[^"]*"}' | sed 's/.*version="//;s/"}//')
[ "$RUNNING" = "$SERVER_TAG" ] && ok "C2 build_info matches the deployed tag" "$RUNNING" \
  || bad "C2 build_info matches the deployed tag" "got '${RUNNING:-none}' want '$SERVER_TAG'"

# --------------------------------------------------------------------------
# C3 — register -> execute -> COMPLETED, the core path.
# --------------------------------------------------------------------------
PROBE_PATH="tests/_harness_probe_$$"
cat > "$TMP/probe.yaml" <<YAML
apiVersion: noetl.io/v2
kind: Playbook
metadata:
  name: harness_probe
  path: $PROBE_PATH
  description: Harness probe. Safe to delete.
workload: {}
workflow:
- step: start
  tool:
    kind: python
    code: |
      result = {"status": "success", "harness": True}
YAML
REG=$(/usr/bin/python3 - "$TMP/probe.yaml" <<'PY'
import json,sys,urllib.request
c=open(sys.argv[1]).read()
r=urllib.request.Request('http://localhost:8082/api/catalog/register',
  data=json.dumps({"content":c,"resource_type":"Playbook"}).encode(),
  headers={'Content-Type':'application/json'},method='POST')
try: print(json.load(urllib.request.urlopen(r,timeout=60))['catalog_id'])
except Exception as e: print("ERR")
PY
)
[ "$REG" != "ERR" ] && ok "C3a register" "catalog_id=$REG" || bad "C3a register" ""

EXEC_STATUS=$(/usr/bin/python3 - "$PROBE_PATH" <<'PY'
import json,sys,time,urllib.request
def post(p,b):
    r=urllib.request.Request('http://localhost:8082'+p,data=json.dumps(b).encode(),
      headers={'Content-Type':'application/json'},method='POST')
    return json.load(urllib.request.urlopen(r,timeout=90))
try:
    eid=post('/api/execute',{'path':sys.argv[1],'payload':{}})['execution_id']
    for _ in range(45):
        try:
            d=json.load(urllib.request.urlopen(f'http://localhost:8082/api/executions/{eid}',timeout=30))
            if d.get('status') in ('COMPLETED','FAILED'): print(d['status']); break
        except Exception: pass
        time.sleep(2)
    else: print('TIMEOUT')
except Exception as e: print(f'ERR')
PY
)
[ "$EXEC_STATUS" = "COMPLETED" ] && ok "C3b execute-by-path -> COMPLETED" || bad "C3b execute-by-path -> COMPLETED" "got $EXEC_STATUS"

# --------------------------------------------------------------------------
# C4/C5 — list, and list with the archived opt-in.
# --------------------------------------------------------------------------
# ⚠ Parse strictly.  The first version of this check did
# `len(d.get('entries', d))`, so a 500 body — `{"error":..,"status":..}` —
# fell back to counting DICT KEYS and reported "2 entries", a PASS.  The
# harness said green while execute-by-path was returning 500.  An error
# response must never be parseable as data.
LIST_N=$(curl -s --max-time 90 -X POST "$API/api/catalog/list" -H 'Content-Type: application/json' -d '{}' \
  | /usr/bin/python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
except Exception:
    print('ERR'); raise SystemExit
if not isinstance(d,dict) or 'entries' not in d or not isinstance(d['entries'],list):
    print('ERR')          # anything that is not a real entries list is a failure
else:
    print(len(d['entries']))
" 2>/dev/null)
# A real catalog has more than a handful of rows; a tiny count means the query
# silently degraded rather than errored.
if [ "$LIST_N" = "ERR" ] || [ -z "$LIST_N" ]; then
  bad "C4 list" "non-list response (likely an error body)"
elif [ "$LIST_N" -lt "${HARNESS_MIN_CATALOG:-10}" ] 2>/dev/null; then
  bad "C4 list" "only $LIST_N entries (< ${HARNESS_MIN_CATALOG:-10}); set HARNESS_MIN_CATALOG if intentional"
else
  ok "C4 list" "$LIST_N entries"
fi

INC=$(curl -s -o /dev/null -w '%{http_code}' --max-time 90 -X POST "$API/api/catalog/list" \
  -H 'Content-Type: application/json' -d '{"include_archived":true}')
[ "$INC" = "200" ] && ok "C5 list include_archived" "HTTP 200" || bad "C5 list include_archived" "HTTP $INC"

RES=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 -X POST "$API/api/catalog/resource" \
  -H 'Content-Type: application/json' -d "{\"path\":\"$PROBE_PATH\"}")
[ "$RES" = "200" ] && ok "C5b resource-by-path (get_catalog_latest)" "HTTP 200" || bad "C5b resource-by-path (get_catalog_latest)" "HTTP $RES"

# --------------------------------------------------------------------------
# C6 — DESTRUCTIVE ENDPOINT ON AN ENCUMBERED ROW.
#
# The probe above has now been EXECUTED, so it carries event rows and the FK
# makes a hard delete impossible.  This is the case the original kind check
# missed.  Any 2xx (soft-archived) or 409 (refused with an explanation) is a
# pass; a 500 or a dead server is not.
# --------------------------------------------------------------------------
POD=$(KC get pods -l app=noetl-server-rust -o jsonpath='{.items[0].metadata.name}')
DEL_OUT=$(KC exec "$POD" -- sh -c "wget -q -O- --header='Content-Type: application/json' --header=\"Authorization: Bearer \$NOETL_INTERNAL_API_TOKEN\" --post-data='{\"path\":\"$PROBE_PATH\"}' http://127.0.0.1:8082/api/catalog/delete" </dev/null 2>&1)
case "$DEL_OUT" in
  *'"status":"success"'*) ok "C6 delete on an EXECUTED entry" "soft-archived / removed" ;;
  *409*)                  ok "C6 delete on an EXECUTED entry" "409 refused with explanation" ;;
  *500*)                  bad "C6 delete on an EXECUTED entry" "HTTP 500 — unhandled" ;;
  *)                      bad "C6 delete on an EXECUTED entry" "$(echo "$DEL_OUT" | head -1)" ;;
esac

# --------------------------------------------------------------------------
# C7 — OPTIONAL SCHEMA OBJECT: the hot paths must work in whichever state the
# database is in.  Reported with the column's actual presence so a pass is
# meaningful rather than incidental.
# --------------------------------------------------------------------------
HAS_COL=$(PQ "select count(*) from information_schema.columns where table_schema='noetl' and table_name='catalog' and column_name='archived_at'")
info "archived_at present in this database: ${HAS_COL:-unknown}"
if [ "$EXEC_STATUS" = "COMPLETED" ] && [ "$RES" = "200" ] && [ -n "$LIST_N" ]; then
  ok "C7 hot paths OK with archived_at=${HAS_COL:-?}" "execute+list+resource"
else
  bad "C7 hot paths OK with archived_at=${HAS_COL:-?}" "one of execute/list/resource failed"
fi

# --------------------------------------------------------------------------
# C8 — no 500 caused by a missing optional column anywhere in the server log.
# The prod incident showed up exactly here first.
# --------------------------------------------------------------------------
UNDEF=$(KC logs deploy/noetl-server-rust --tail=400 2>/dev/null | grep -c 'does not exist')
[ "${UNDEF:-0}" -eq 0 ] && ok "C8 no undefined-column errors in the log" \
  || bad "C8 no undefined-column errors in the log" "$UNDEF occurrence(s)"

# --------------------------------------------------------------------------
# C10 — A FAILING STEP MUST BE RECORDED AS AN ERROR SOMEWHERE.
#
# A playbook whose step raises currently reports `playbook.completed
# COMPLETED` (noetl/ai-meta#251), so the terminal status cannot be asserted --
# whether that is a defect is an open semantic decision.
#
# What CAN be asserted, and is not disputed, is that the failure is recorded at
# all: `command.completed` carries `status: error` and the result payload holds
# the exit code and traceback.  A regression that stopped recording it would
# make a broken playbook indistinguishable from a working one at EVERY level,
# and nothing else in this suite would notice.
#
# Deliberately does NOT assert `status == FAILED`.  Encoding a disputed
# semantic as a test would either fail permanently or freeze a decision nobody
# has made.
# --------------------------------------------------------------------------
FAIL_PATH="tests/_harness_fail_probe_$$"
cat > "$TMP/failprobe.yaml" <<YAML
apiVersion: noetl.io/v2
kind: Playbook
metadata:
  name: harness_fail_probe
  path: $FAIL_PATH
  description: Deliberately raises. Harness fixture for noetl/ai-meta#251.
workload: {}
workflow:
- step: start
  tool:
    kind: python
    code: |
      raise RuntimeError("deliberate harness failure")
YAML
ERR_RECORDED=$(/usr/bin/python3 - "$TMP/failprobe.yaml" <<'PYC10'
import json,sys,time,urllib.request
def post(p,b):
    r=urllib.request.Request('http://localhost:8082'+p,data=json.dumps(b).encode(),
      headers={'Content-Type':'application/json'},method='POST')
    return json.load(urllib.request.urlopen(r,timeout=90))
try:
    cid=post('/api/catalog/register',{'content':open(sys.argv[1]).read(),'resource_type':'Playbook'})['catalog_id']
    eid=post('/api/execute',{'catalog_id':int(cid),'payload':{}})['execution_id']
    d={}
    for _ in range(45):
        try:
            d=json.load(urllib.request.urlopen('http://localhost:8082/api/executions/'+str(eid),timeout=30))
            if d.get('status') in ('COMPLETED','FAILED'): break
        except Exception: pass
        time.sleep(2)
    recorded = any(
        (e.get('event_type')=='call.error')
        or (str(e.get('status','')).lower()=='error')
        or ('"error"' in json.dumps(e.get('result') or {}))
        for e in d.get('events',[])
    )
    print('YES' if recorded else 'NO')
except Exception:
    print('ERR')
PYC10
)
case "$ERR_RECORDED" in
  YES) ok "C10 a failing step is recorded as an error" "terminal status: see noetl/ai-meta#251" ;;
  NO)  bad "C10 a failing step is recorded as an error" "a raising step left NO error anywhere in the stream" ;;
  *)   bad "C10 a failing step is recorded as an error" "probe error" ;;
esac

# --------------------------------------------------------------------------
# C10b — THE CONTROL FOR C10.  The same predicate must say NO for a run with
# no failure, or C10 is vacuously true and proves nothing.
#
# This suite has already shipped one test that could not fail and one harness
# case that reported green off an error body.  A detector without its negative
# control is the same defect wearing a third costume.
# --------------------------------------------------------------------------
OK_PATH="tests/_harness_ok_probe_$$"
cat > "$TMP/okprobe.yaml" <<YAML
apiVersion: noetl.io/v2
kind: Playbook
metadata:
  name: harness_ok_probe
  path: $OK_PATH
  description: Succeeds. Negative control for C10.
workload: {}
workflow:
- step: start
  tool:
    kind: python
    code: |
      result = {"status": "success"}
YAML
OK_RECORDED=$(/usr/bin/python3 - "$TMP/okprobe.yaml" <<'PYC10B'
import json,sys,time,urllib.request
def post(p,b):
    r=urllib.request.Request('http://localhost:8082'+p,data=json.dumps(b).encode(),
      headers={'Content-Type':'application/json'},method='POST')
    return json.load(urllib.request.urlopen(r,timeout=90))
y=open(sys.argv[1]).read()
try:
    cid=post('/api/catalog/register',{'content':y,'resource_type':'Playbook'})['catalog_id']
    eid=post('/api/execute',{'catalog_id':int(cid),'payload':{}})['execution_id']
    d={}
    for _ in range(45):
        try:
            d=json.load(urllib.request.urlopen('http://localhost:8082/api/executions/'+str(eid),timeout=30))
            if d.get('status') in ('COMPLETED','FAILED'): break
        except Exception: pass
        time.sleep(2)
    recorded = any(
        (e.get('event_type')=='call.error')
        or (str(e.get('status','')).lower()=='error')
        or ('"error"' in json.dumps(e.get('result') or {}))
        for e in d.get('events',[])
    )
    print('YES' if recorded else 'NO')
except Exception:
    print('ERR')
PYC10B
)
case "$OK_RECORDED" in
  NO)  ok "C10b control: no error on a SUCCESSFUL run" "C10 discriminates" ;;
  YES) bad "C10b control: no error on a SUCCESSFUL run" "C10 is VACUOUS — it fires on success too" ;;
  *)   bad "C10b control: no error on a SUCCESSFUL run" "probe error" ;;
esac

# --------------------------------------------------------------------------
# C9 — a provider call still reaches its backend (credential + egress path).
# Skipped, not failed, when the provider is absent from this catalog.
# --------------------------------------------------------------------------
PROV=$(/usr/bin/python3 - <<'PY'
import json,time,urllib.request
def post(p,b):
    r=urllib.request.Request('http://localhost:8082'+p,data=json.dumps(b).encode(),
      headers={'Content-Type':'application/json'},method='POST')
    return json.load(urllib.request.urlopen(r,timeout=90))
try:
    eid=post('/api/execute',{'path':'automation/agents/mcp/duffel',
        'payload':{'method':'tools/list','tool':'','arguments':{}}})['execution_id']
    for _ in range(40):
        try:
            d=json.load(urllib.request.urlopen(f'http://localhost:8082/api/executions/{eid}',timeout=30))
            if d.get('status') in ('COMPLETED','FAILED'): print(d['status']); break
        except Exception: pass
        time.sleep(2)
    else: print('TIMEOUT')
except Exception: print('SKIP')
PY
)
case "$PROV" in
  COMPLETED) ok "C9 provider tools/list" "COMPLETED" ;;
  SKIP)      info "C9 provider tools/list — skipped (provider not in this catalog)" ;;
  *)         bad "C9 provider tools/list" "got $PROV" ;;
esac

# --------------------------------------------------------------------------
# C11 — CONTAINER GATING (the noetl/ai-meta#186 class).  A container step whose
# terminal callback never arrives must NOT advance the DAG.
#
# Opt-in (HARNESS_CONTAINER=1): it restarts the kind worker twice and takes
# ~4 minutes.  It also mutates worker env IN KIND ONLY and restores it after.
#
# Two-sided by construction, which is the whole point:
#
#   C11a  poll fallback OFF -> no terminal event can ever arrive.  The k8s Job
#         still SUCCEEDS, so the work is done; the assertion is that the DAG
#         nevertheless does not advance past the container step.
#   C11b  poll fallback ON  -> the same fixture must reach COMPLETED with 'end'
#         entering AFTER the container terminal.
#
# C11b is C11a's positive control: without it, "end did not enter" could mean
# the fixture can never reach 'end' at all, and C11a would be vacuous.
# --------------------------------------------------------------------------
if [ "${HARNESS_CONTAINER:-0}" = "1" ]; then
  CFIX="$(cd "$(dirname "$0")/.." && pwd)/repos/e2e/fixtures/playbooks/container_callback_happy_path/container_callback_happy_path.yaml"
  if [ ! -f "$CFIX" ]; then
    bad "C11 container gating" "fixture not found: $CFIX"
  else
    # --- C11a: callback can never arrive -------------------------------------
    KC set env deploy/noetl-worker-rust NOETL_CONTAINER_COMPLETION_POLL- NOETL_CONTAINER_POLL_INTERVAL_SECS- >/dev/null 2>&1
    kubectl --context kind-noetl -n noetl rollout status deploy/noetl-worker-rust --timeout=280s >/dev/null 2>&1
    GATE=$(/usr/bin/python3 - "$CFIX" <<'PYC11A'
import json,sys,time,urllib.request
def post(p,b):
    r=urllib.request.Request('http://localhost:8082'+p,data=json.dumps(b).encode(),
      headers={'Content-Type':'application/json'},method='POST')
    return json.load(urllib.request.urlopen(r,timeout=90))
try:
    cid=post('/api/catalog/register',{'content':open(sys.argv[1]).read(),'resource_type':'Playbook'})['catalog_id']
    eid=post('/api/execute',{'catalog_id':int(cid),'payload':{}})['execution_id']
    entered_container=False
    for i in range(30):
        try:
            evs=json.load(urllib.request.urlopen(
                f'http://localhost:8082/api/executions/{eid}',timeout=30)).get('events',[])
        except Exception:
            time.sleep(4); continue
        ent={e.get('node_name') for e in evs if e.get('event_type')=='step.enter'}
        term=[e for e in evs if e.get('node_name')=='dispatch_container'
              and e.get('event_type') in ('call.done','call.error')]
        if 'dispatch_container' in ent: entered_container=True
        # The bug: downstream advances while the container step is unterminated.
        if 'end' in ent and not term: print('ADVANCED_EARLY'); break
        if term: print('TERMINATED'); break          # poll leaked back on
        if entered_container and i>=18: print('GATED'); break
        time.sleep(4)
    else: print('NO_CONTAINER_STEP' if not entered_container else 'GATED')
except Exception as e: print('PROBE_ERROR:'+type(e).__name__+':'+str(e)[:90])
PYC11A
)
    case "$GATE" in
      GATED)          ok "C11a container gating (callback never arrives)" "'end' did not enter; Job succeeded anyway" ;;
      ADVANCED_EARLY) bad "C11a container gating (callback never arrives)" "DAG ADVANCED past an unterminated container step — #186 regression" ;;
      TERMINATED)     bad "C11a container gating (callback never arrives)" "a terminal event arrived with the poll disabled" ;;
      *)              bad "C11a container gating (callback never arrives)" "inconclusive: $GATE" ;;
    esac

    # --- C11b: the control — the same fixture MUST be able to finish ---------
    KC set env deploy/noetl-worker-rust NOETL_CONTAINER_COMPLETION_POLL=true NOETL_CONTAINER_POLL_INTERVAL_SECS=3 >/dev/null 2>&1
    kubectl --context kind-noetl -n noetl rollout status deploy/noetl-worker-rust --timeout=280s >/dev/null 2>&1
    DONE=$(/usr/bin/python3 - "$CFIX" <<'PYC11B'
import json,sys,time,urllib.request
def post(p,b):
    r=urllib.request.Request('http://localhost:8082'+p,data=json.dumps(b).encode(),
      headers={'Content-Type':'application/json'},method='POST')
    return json.load(urllib.request.urlopen(r,timeout=90))
try:
    cid=post('/api/catalog/register',{'content':open(sys.argv[1]).read(),'resource_type':'Playbook'})['catalog_id']
    eid=post('/api/execute',{'catalog_id':int(cid),'payload':{}})['execution_id']
    for _ in range(45):
        try:
            d=json.load(urllib.request.urlopen(f'http://localhost:8082/api/executions/{eid}',timeout=30))
        except Exception:
            time.sleep(4); continue
        if d.get('status') in ('COMPLETED','FAILED'):
            evs=d.get('events',[])
            ti=[i for i,e in enumerate(evs) if e.get('node_name')=='dispatch_container'
                and e.get('event_type') in ('call.done','call.error')]
            ei=[i for i,e in enumerate(evs) if e.get('event_type')=='step.enter'
                and e.get('node_name')=='end']
            if d['status']!='COMPLETED': print('NOT_COMPLETED')
            elif not ei:                 print('NO_END')
            elif not ti:                 print('NO_TERMINAL')
            elif ei[0] < ti[0]:          print('OUT_OF_ORDER')
            else:                        print('ORDERED')
            break
        time.sleep(4)
    else: print('TIMEOUT')
except Exception as e: print('PROBE_ERROR:'+type(e).__name__+':'+str(e)[:90])
PYC11B
)
    case "$DONE" in
      ORDERED) ok "C11b control: the fixture CAN finish, 'end' after terminal" "C11a is not vacuous" ;;
      *)       bad "C11b control: the fixture CAN finish, 'end' after terminal" "got $DONE — C11a proves nothing" ;;
    esac

    # Restore the kind default (poll off).  Kind only; prod is never touched.
    KC set env deploy/noetl-worker-rust NOETL_CONTAINER_COMPLETION_POLL- NOETL_CONTAINER_POLL_INTERVAL_SECS- >/dev/null 2>&1
    kubectl --context kind-noetl -n noetl rollout status deploy/noetl-worker-rust --timeout=280s >/dev/null 2>&1
  fi
else
  info "C11 container gating — skipped (set HARNESS_CONTAINER=1; ~4 min, restarts the kind worker)"
fi

# --------------------------------------------------------------------------
# Cleanup — best effort; the probe may be un-deletable by design (C6).
# --------------------------------------------------------------------------
KC exec "$POD" -- sh -c "wget -q -O- --header='Content-Type: application/json' --header=\"Authorization: Bearer \$NOETL_INTERNAL_API_TOKEN\" --post-data='{\"path\":\"$PROBE_PATH\"}' http://127.0.0.1:8082/api/catalog/delete" </dev/null >/dev/null 2>&1
rm -rf "$TMP"

echo
echo "== $PASS passed, $FAIL failed =="
exit $FAIL
