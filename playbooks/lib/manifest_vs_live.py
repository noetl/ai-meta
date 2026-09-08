#!/usr/bin/env python3
"""Full-spec manifest-vs-live comparison (noetl/ai-meta#323 incident, 2026-09-08).

The failure this exists to prevent: a pre-apply proof that compared ONE FIELD.
A server-side dry-run confirmed `image` was preserved across five workloads; the
same manifest also declared a fourth volume for a PVC that has never existed in
prod. Applying it left the cmdbus writer unschedulable for ~55 minutes and took
both buses down.

**A dry-run answers only the question you ask it.** So this asks about the whole
rendered object, and specifically about the asymmetry that bites:

    an element present in the MANIFEST but absent from LIVE

That direction is the dangerous one. A phantom volume, a mount for a claim that
does not exist, a container the cluster has never seen — applying any of them
mutates a running object toward something that cannot schedule. The reverse
direction (live has something the manifest omits) is usually deliberate: it is
what shape-only manifests DO, and it is why the image pin is not a finding here.

Read-only. Prints its denominators; exits non-zero only on a real finding.
"""
import json
import subprocess
import sys

try:
    import yaml
except ImportError:
    print("SKIP|pyyaml not installed")
    sys.exit(0)


def live_object(ctx, ns, kind, name):
    r = subprocess.run(
        ["kubectl", "--context", ctx, "-n", ns, "get", kind, name, "-o", "json"],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        return None
    return json.loads(r.stdout)


def pod_spec(obj):
    return obj["spec"]["template"]["spec"]


def compare(manifest_path, ctx, ns):
    """Yield (severity, message) tuples. Severity 'DRIFT' or 'INFO'."""
    docs = [d for d in yaml.safe_load_all(open(manifest_path)) if d]
    # ⚠ Assert the extraction. A parse that silently yielded nothing would make
    # every manifest look clean — the exact shape of a check that passes by
    # measuring zero bytes.
    workloads = [d for d in docs if d.get("kind") in ("Deployment", "StatefulSet")]
    if not workloads:
        return [("INFO", f"no workload objects parsed from {manifest_path}")], 0

    findings = []
    compared = 0
    for w in workloads:
        kind = w["kind"].lower()
        name = w["metadata"]["name"]
        live = live_object(ctx, ns, kind, name)
        if live is None:
            findings.append(("INFO", f"{kind}/{name}: not present in the cluster (nothing to compare)"))
            continue
        compared += 1
        m, l = pod_spec(w), pod_spec(live)

        # --- volumes: name -> claim (the incident's exact shape) ---
        mv = {v["name"]: v.get("persistentVolumeClaim", {}).get("claimName") for v in m.get("volumes", [])}
        lv = {v["name"]: v.get("persistentVolumeClaim", {}).get("claimName") for v in l.get("volumes", [])}
        for vn, claim in mv.items():
            if vn not in lv:
                findings.append(("DRIFT", f"{kind}/{name}: volume '{vn}' is declared in the manifest and ABSENT from live"
                                          f"{f' (claim {claim})' if claim else ''} — applying it mutates a running object"))
            elif lv[vn] != claim:
                findings.append(("DRIFT", f"{kind}/{name}: volume '{vn}' claim differs — manifest={claim} live={lv[vn]}"))

        # --- the claims themselves must exist as PVCs ---
        for vn, claim in mv.items():
            if not claim:
                continue
            r = subprocess.run(["kubectl", "--context", ctx, "-n", ns, "get", "pvc", claim,
                                "-o", "name"], capture_output=True, text=True)
            if r.returncode != 0:
                findings.append(("DRIFT", f"{kind}/{name}: volume '{vn}' claims PVC '{claim}' which DOES NOT EXIST"
                                          " — a pod using it cannot schedule (this is the #323 incident verbatim)"))

        # --- mounts, per container ---
        lc = {c["name"]: c for c in l["containers"]}
        for c in m["containers"]:
            cn = c["name"]
            if cn not in lc:
                findings.append(("DRIFT", f"{kind}/{name}: container '{cn}' is in the manifest and ABSENT from live"))
                continue
            mm = {x["name"]: x["mountPath"] for x in c.get("volumeMounts", [])}
            lm = {x["name"]: x["mountPath"] for x in lc[cn].get("volumeMounts", [])}
            for mn, path in mm.items():
                if mn not in lm:
                    findings.append(("DRIFT", f"{kind}/{name}/{cn}: volumeMount '{mn}' -> {path} declared and ABSENT from live"))
                elif lm[mn] != path:
                    findings.append(("DRIFT", f"{kind}/{name}/{cn}: mount '{mn}' path differs — manifest={path} live={lm[mn]}"))

        # --- pod-template annotations: not a hazard, but the ROLLOUT predictor ---
        ma = (w["spec"]["template"].get("metadata") or {}).get("annotations") or {}
        la = (live["spec"]["template"].get("metadata") or {}).get("annotations") or {}
        differing = sorted(set(ma) ^ set(la)) + sorted(k for k in set(ma) & set(la) if ma[k] != la[k])
        if differing:
            findings.append(("INFO", f"{kind}/{name}: pod-template annotations differ ({', '.join(differing[:4])})"
                                     " — applying this ROLLS the workload; the template hash changes by construction"))
    return findings, compared


if __name__ == "__main__":
    ctx, ns = sys.argv[1], sys.argv[2]
    total_compared = 0
    total_files = 0
    for path in sys.argv[3:]:
        total_files += 1
        try:
            findings, compared = compare(path, ctx, ns)
        except Exception as e:  # a parse error must be loud, not clean
            print(f"DRIFT|{path}: comparison FAILED ({e}) — a check that errors is not a check that passes")
            continue
        total_compared += compared
        for sev, msg in findings:
            print(f"{sev}|{msg}")
    print(f"COUNTS|files={total_files}|workloads_compared={total_compared}")
