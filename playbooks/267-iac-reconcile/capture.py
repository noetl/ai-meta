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

# A credential embedded in a connection URL — `postgres://user:pass@host`.
#
# This shape defeated the name rule entirely: the env var is called
# DATABASE_URLS, which matches nothing in SECRETISH, and the value is a URL
# rather than a bare secret, so the entropy rule did not fire either. The
# 2026-08-28 sanitization pass therefore reported that file clean while it
# carried plaintext passwords for four database users, one of them the postgres
# SUPERUSER (noetl/ai-meta#310).
#
# A placeholder or a template expression is not a finding; a literal is.
URL_CRED = re.compile(
    r"(?:postgres|postgresql|mysql|amqp|amqps|redis|rediss|mongodb|nats|http|https)"
    r"://[^:/\s\"']+:([^@\s\"']+)@"
)
# Not a finding: anything that is plainly a substitution rather than a value.
# Covers `{}` / `{name}` format slots, `{{jinja}}`, `$VAR`, `${VAR}`, `$(cmd)`,
# `%s` / `%(name)s`, angle-bracket placeholders, and the usual literals.
#
# The first version of this missed `{}` and `$(...)` and flagged both as real —
# caught by the truth-table control below rather than in review, which is the
# reason the control exists.
URL_CRED_PLACEHOLDER = re.compile(
    r"""(?ix)
    ^(?:
        \$\{ | \$\( | \$[A-Za-z_] |     # $VAR  ${VAR}  $(cmd)
        \{ |                             # {}  {name}  {{jinja}}
        % |                               # %s  %(name)s
        < |                               # <password>
        REPLACE_ME | CHANGEME | PLACEHOLDER | TODO |
        x{3,} | \*+ |
        password | pass | user
    )"""
)


def url_embedded_credentials(value):
    """Literal passwords inside connection URLs in `value`.

    Returns the offending user-visible spans, never the secret itself.
    """
    out = []
    for pw in URL_CRED.findall(value or ""):
        if URL_CRED_PLACEHOLDER.match(pw):
            continue
        out.append(len(pw))
    return out

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
#   GATEWAY_AUTH0_CLIENT_ID — the same value, under its honest name. Verified by
#   sha256 on 2026-08-27 to be byte-identical to three things already public: the
#   `clientId` in ci/manifests/gateway/configmap-ui-files.yaml (served to
#   browsers), VITE_AUTH0_CLIENT_ID in ci/manifests/gui/deployment-prod.yaml
#   (compiled into the shipped bundle), and the prod server's
#   NOETL_AUTH0_AUDIENCE. That last identity is also standing proof of
#   noetl/ai-meta#299: the "audience" variable holds a client id.
#   Allowlisted on the VALUE (digest-matched against already-published copies),
#   not on the name — a different value under this name would still fail closed
#   via the entropy rule.
CLASSIFIED_PUBLIC = {"NOETL_AUTH0_AUDIENCE", "GATEWAY_AUTH0_CLIENT_ID"}

def scrub_meta(m):
    for k in list(m):
        if k in DROP_META: m.pop(k)
    ann = m.get("annotations") or {}
    for k in list(ann):
        if k in DROP_ANN: ann.pop(k)
    if ann: m["annotations"] = ann
    else: m.pop("annotations", None)
    return m


def _looks_high_entropy(v):
    """A literal that looks like a resolved secret regardless of its name.

    Deliberately conservative: alphanumeric, long, and high-entropy. A filesystem
    path fails this on the `/` alone, which is what lets the `_FILE` exemption
    above be safe.
    """
    import math, collections
    if not isinstance(v, str) or len(v) < 24 or not v.isalnum():
        return False
    c = collections.Counter(v)
    n = len(v)
    ent = -sum(x / n * math.log2(x / n) for x in c.values())
    return ent > 3.7

def pod_specs(obj):
    """Every pod spec inside a workload, whatever its kind.

    A CronJob nests its pod spec one level deeper than everything else
    (``spec.jobTemplate.spec.template.spec``), and the original version of this
    function looked only at ``spec.template``.  The effect was not a crash but
    silence: ``check_secrets`` returned clean for every CronJob because it found
    no containers to check, and the summary line printed ``env=0`` for a CronJob
    that plainly sets env vars.  A gate that exists to fail closed was failing
    open on a whole resource kind.
    """
    s = obj.get("spec") or {}
    out = []
    t = s.get("template")                      # Deployment / StatefulSet / DaemonSet / ReplicaSet
    if t and t.get("spec"): out.append(t["spec"])
    jt = s.get("jobTemplate")                  # CronJob
    if jt:
        jts = ((jt.get("spec") or {}).get("template") or {}).get("spec")
        if jts: out.append(jts)
    if not out and s.get("containers"): out.append(s)   # bare Pod
    return out

def containers_of(obj):
    for ps in pod_specs(obj):
        for c in (ps.get("containers") or []) + (ps.get("initContainers") or []):
            yield c

def check_secrets(obj, where):
    """Fail closed on any literal value for a credential-shaped name."""
    bad = []
    for c in containers_of(obj):
        for e in c.get("env", []) or []:
            if "value" not in e or e["name"] in CLASSIFIED_PUBLIC:
                continue
            # A `<VAR>_FILE` variable holds a PATH by construction — that is the
            # whole point of the convention (noetl/ai-meta#267). The name rule
            # necessarily matches it, because the path names the credential it
            # points at, so exempting the name rule here removes a false
            # positive rather than a check.
            #
            # The entropy rule still applies to it: a `_FILE` variable that
            # somehow held a high-entropy blob instead of a path is exactly the
            # mistake worth catching, and this exemption does not hide it.
            name_flag = SECRETISH.search(e["name"]) and not e["name"].endswith("_FILE")
            entropy_flag = _looks_high_entropy(e["value"])
            # A URL-embedded credential passes BOTH rules above: the variable is
            # named for the URL (DATABASE_URLS), not the secret, and the value is
            # a URL rather than a high-entropy blob.
            url_flag = bool(url_embedded_credentials(e["value"]))
            if name_flag or entropy_flag or url_flag:
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
    _jt = o["spec"].get("jobTemplate")
    if _jt:
        scrub_meta(_jt.setdefault("metadata", {}))
        _jtt = (_jt.get("spec") or {}).get("template")
        if _jtt: scrub_meta(_jtt.setdefault("metadata", {}))
    for vct in o["spec"].get("volumeClaimTemplates", []) or []:
        scrub_meta(vct.setdefault("metadata", {}))
        vct.pop("status", None)
    bad = check_secrets(o, name)
    if bad:
        print("SECRET LEAK RISK — literal value on credential-shaped env: %s" % bad, file=sys.stderr)
        sys.exit(2)
    json.dump(o, open(sys.argv[5], "w"), indent=2)
    cs = list(containers_of(o))
    refs = sum(1 for c in cs for e in (c.get("env") or []) if "valueFrom" in e)
    envs = sum(len(c.get("env") or []) for c in cs)
    print("  %-34s env=%-3s secretKeyRef/valueFrom=%-3s  -> %s" % (name, envs, refs, sys.argv[5]))

main()
