#!/usr/bin/env python3
"""noetl/ai-meta#267 — capture a LIVE prod workload as an applyable manifest.

Reads the live object and strips only what the API server owns, so that a
re-apply is a no-op rather than a 51-variable deletion.

Secrets: env entries sourced from a Secret arrive as `valueFrom.secretKeyRef`
and are emitted verbatim.  This script NEVER resolves a secret, and it hard
fails if a literal `value:` appears on a name that looks credential-shaped —
failing closed is the point, because the whole hazard here is a plaintext
credential reaching a public repo.
"""
import json, re, subprocess, sys

DROP_META = {"uid","resourceVersion","generation","creationTimestamp","selfLink","managedFields"}
# Only `last-applied` is dropped. The autopilot/* and cloud.google.com/*
# annotations are CLUSTER-AUTHORED, and stripping them makes `kubectl diff`
# report a removal — i.e. an apply that mutates live state. Keeping them is what
# makes the reconcile provably a no-op, which is the entire deliverable.
DROP_ANN = {
    "kubectl.kubernetes.io/last-applied-configuration",
    "deployment.kubernetes.io/revision",
}
SECRETISH = re.compile(r"(PASSWORD|TOKEN|SECRET|CREDENTIAL|APIKEY|API_KEY|PRIVATE_KEY|DSN|_PWD|AUDIENCE|CLIENT_ID)", re.I)

# Names the gate would flag, that have been CLASSIFIED public with evidence.
# This is an allowlist of decided cases, not a relaxation: anything not named
# here still fails closed, and each entry carries why it is safe.
#
#   NOETL_AUTH0_AUDIENCE — holds the Auth0 CLIENT ID, which is public by
#   construction. Confirmed four independent ways: it is served to browsers in
#   ci/manifests/gateway/configmap-ui-files.yaml (as `clientId` inside auth.js);
#   it is VITE_AUTH0_CLIENT_ID in ci/manifests/gui/deployment-prod.yaml, a Vite
#   var compiled into the shipped bundle; it is DEFAULT_AUTH0_CLIENT_ID in
#   repos/travel/src/auth/authConfig.ts; and it is a committed plaintext default
#   in the api_integration/auth0/get_auth0_token playbook. The Auth0 client
#   SECRET is a different value and lives in the NoETL keychain as `auth0_client`
#   — it is not, and must never be, a workload env literal.
#   See docs/rfc/secret-manager-retrieval.md §1.4.
CLASSIFIED_PUBLIC = {"NOETL_AUTH0_AUDIENCE"}

def scrub_meta(m):
    for k in list(m):
        if k in DROP_META: m.pop(k)
    ann = m.get("annotations") or {}
    for k in list(ann):
        if k in DROP_ANN: ann.pop(k)
    if ann: m["annotations"] = ann
    else: m.pop("annotations", None)
    return m

def check_secrets(obj, where):
    """Fail closed on any literal value for a credential-shaped name."""
    bad = []
    t = obj.get("spec", {}).get("template")
    if not t: return bad
    for c in (t["spec"].get("containers") or []) + (t["spec"].get("initContainers") or []):
        for e in c.get("env", []) or []:
            if (
                SECRETISH.search(e["name"])
                and "value" in e
                and e["name"] not in CLASSIFIED_PUBLIC
            ):
                bad.append("%s/%s/%s" % (where, c["name"], e["name"]))
    return bad

def main():
    ctx, ns, kind, name = sys.argv[1:5]
    raw = subprocess.run(["kubectl","--context",ctx,"-n",ns,"get",kind,name,"-o","json"],
                         capture_output=True, text=True, check=True).stdout
    o = json.loads(raw)
    o.pop("status", None)
    scrub_meta(o["metadata"])
    if o["spec"].get("template"):
        scrub_meta(o["spec"]["template"].setdefault("metadata", {}))
    for vct in o["spec"].get("volumeClaimTemplates", []) or []:
        scrub_meta(vct.setdefault("metadata", {}))
        vct.pop("status", None)
    bad = check_secrets(o, name)
    if bad:
        print("SECRET LEAK RISK — literal value on credential-shaped env: %s" % bad, file=sys.stderr)
        sys.exit(2)
    json.dump(o, open(sys.argv[5], "w"), indent=2)
    t = o["spec"].get("template")
    cs = (t["spec"].get("containers") or []) if t else []
    refs = sum(1 for c in cs for e in (c.get("env") or []) if "valueFrom" in e)
    envs = sum(len(c.get("env") or []) for c in cs)
    print("  %-34s env=%-3s secretKeyRef/valueFrom=%-3s  -> %s" % (name, envs, refs, sys.argv[5]))

main()
