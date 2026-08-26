#!/usr/bin/env python3
"""Replace ONLY the workload document in a multi-doc manifest, preserving the rest.

The prod manifests carry a Deployment AND a Service. Overwriting the file with
just the captured Deployment would silently delete the Service declaration —
the same class of defect this whole reconcile exists to remove.
"""
import json, sys, yaml

live_json, target, header = sys.argv[1], sys.argv[2], sys.argv[3]
live = json.load(open(live_json))
kind, name = live["kind"], live["metadata"]["name"]

try:
    docs = [d for d in yaml.safe_load_all(open(target)) if d]
except FileNotFoundError:
    docs = []

out, replaced = [], False
for d in docs:
    if d.get("kind") == kind and d.get("metadata", {}).get("name") == name:
        out.append(live); replaced = True
    else:
        out.append(d)
if not replaced:
    out.insert(0, live)

with open(target, "w") as f:
    f.write(header.rstrip() + "\n")
    for i, d in enumerate(out):
        if i: f.write("---\n")
        yaml.safe_dump(d, f, default_flow_style=False, sort_keys=False, width=100)
print("  %-46s %s %s (%s docs, workload %s)" % (
    target.split('/')[-1], kind, name, len(out), "replaced" if replaced else "added"))
