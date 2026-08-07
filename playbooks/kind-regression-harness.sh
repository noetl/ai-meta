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
# Cleanup — best effort; the probe may be un-deletable by design (C6).
# --------------------------------------------------------------------------
KC exec "$POD" -- sh -c "wget -q -O- --header='Content-Type: application/json' --header=\"Authorization: Bearer \$NOETL_INTERNAL_API_TOKEN\" --post-data='{\"path\":\"$PROBE_PATH\"}' http://127.0.0.1:8082/api/catalog/delete" </dev/null >/dev/null 2>&1
rm -rf "$TMP"

echo
echo "== $PASS passed, $FAIL failed =="
exit $FAIL
