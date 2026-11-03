#!/usr/bin/env python3
"""Select chain-store partitions that are safe to delete. READ-ONLY.

noetl/ai-meta#506. Reads every partition's `wm` mtime (one `stat`, no recursive
walk) and `cov` total, keeps partitions last written >= MIN_AGE_DAYS ago, then
checks each one's execution status through the server API and keeps only
terminal ones. Writes candidates.txt (one execution id per line) and prints the
expected inode reclaim.

    ./select_candidates.py [MIN_AGE_DAYS=7] [OUT_DIR=.]

Excluded on purpose:
  - partitions with no `cov` file. `populate_from_log` deletes `cov` on a
    detected divergence and keeps the events as evidence; those are not ours
    to delete.
  - anything the status call cannot confirm as COMPLETED / FAILED / CANCELLED,
    including errors. Unknown is never a delete.

Inode cost per partition is 2 * events + 6 (ev/ + seq/ file per event; head,
wm, cov; the partition dir, ev/, seq/). On 2026-11-03 that formula predicted
599,080 against 600,647 in use on /data.
"""
import json
import subprocess
import sys
import time

CTX = "noetl-prod"
POD = "noetl-server-rust-embedded-0"
CHAIN = "/data/ehdb-chain/chain"
TERMINAL = {"COMPLETED", "FAILED", "CANCELLED"}

min_age = float(sys.argv[1]) if len(sys.argv) > 1 else 7.0
out_dir = sys.argv[2] if len(sys.argv) > 2 else "."


def pod_sh(script):
    r = subprocess.run(
        ["kubectl", "--context", CTX, "-n", "noetl", "exec", POD, "--", "sh", "-c", script],
        capture_output=True, text=True, check=True)
    return r.stdout


def status(execution_id):
    url = (f"/api/v1/namespaces/noetl/pods/{POD}:8082/proxy"
           f"/api/executions/{execution_id}/status")
    r = subprocess.run(["kubectl", "--context", CTX, "get", "--raw", url],
                       capture_output=True, text=True)
    if r.returncode != 0:
        return "ERR"
    try:
        return json.loads(r.stdout).get("status") or "ERR"
    except ValueError:
        return "ERR"


now = time.time()
wm = {}
for line in pod_sh(f"cd {CHAIN} && stat -c '%Y %n' */wm").splitlines():
    t, name = line.split(" ", 1)
    wm[name.split("/")[0]] = int(t)
cov = {}
for line in pod_sh(f"cd {CHAIN} && grep -H '' */cov").splitlines():
    name, rest = line.split("/cov:", 1)
    cov[name] = int(rest.rsplit(":", 1)[1])

# Print the denominator: a clean selection over zero partitions reads the same
# as a healthy store.
print(f"partitions={len(wm)} with_cov={len(cov)} no_cov={len(set(wm) - set(cov))}")

old = sorted(k for k, t in wm.items()
             if (now - t) / 86400 >= min_age and k in cov)
print(f"last write >= {min_age}d ago, with cov: {len(old)}")

keep, skipped = [], {}
for i, k in enumerate(old, 1):
    s = status(k)
    if s in TERMINAL:
        keep.append(k)
    else:
        skipped[k] = s
    if i % 250 == 0:
        print(f"  checked {i}/{len(old)}", flush=True)
    time.sleep(0.3)  # ~3 req/s; the server has two Tokio workers

reclaim = sum(2 * cov[k] + 6 for k in keep)
with open(f"{out_dir}/candidates.txt", "w") as f:
    f.write("".join(k + "\n" for k in keep))
with open(f"{out_dir}/skipped.json", "w") as f:
    json.dump(skipped, f, indent=1)
print(f"candidates={len(keep)} skipped={len(skipped)} expected_inode_reclaim={reclaim}")
