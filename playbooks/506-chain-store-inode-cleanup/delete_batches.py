#!/usr/bin/env python3
"""Delete chain-store partitions listed in candidates.txt, in checked batches.

noetl/ai-meta#506. DESTRUCTIVE on the chain store only. Never touches
noetl.event, Postgres, or /data/ehdb-embedded.

    ./delete_batches.py CANDIDATES [MIN_AGE_DAYS=7] [CANARY=10] [BATCH=200]

Before each batch, re-reads every id's `wm` mtime and `cov` in ONE exec and
drops any id written since the age cut or missing a `cov`: the candidate list
is a snapshot, and an execution that came back to life since is not ours.

After each batch it stops on the first of:
  - the pod was replaced or restarted (another session may be rolling it);
  - /health is not ok;
  - a chain-populate failure counter moved;
  - fewer than 90% of the expected inodes came back (2 * events + 6 each);
  - any delete reported an error.
"""
import json
import os
import subprocess
import sys
import time

# Overridable only so the driver can be rehearsed against kind first.
CTX = os.environ.get("CLEANUP_CONTEXT", "noetl-prod")
POD = os.environ.get("CLEANUP_POD", "noetl-server-rust-embedded-0")
CHAIN = "/data/ehdb-chain/chain"
PROXY = f"/api/v1/namespaces/noetl/pods/{POD}:8082/proxy"
# The outcomes that mean the store could not answer. A deleted partition of a
# finished execution must never produce one, because nothing reads it.
WATCH = ["diverged", "guarded_read_refused", "guarded_read_failed", "populate_failed",
         "stale_log_unresolved", "log_read_failed", "log_truncated", "open_failed"]

DELETE_LOOP = f'''cd {CHAIN} || exit 1
while read id; do
  case "$id" in ""|*[!0-9]*) echo "SKIP bad id: $id"; continue;; esac
  [ -d "$id" ] || {{ echo "absent $id"; continue; }}
  rm -rf -- "./$id" || echo "ERROR $id"
  [ -e "$id" ] && echo "ERROR still present $id"
done
echo done'''


def kubectl(*args, stdin=None):
    r = subprocess.run(["kubectl", "--context", CTX, *args], input=stdin,
                       capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"kubectl {' '.join(args[:4])} failed: {r.stderr[:300]}")
    return r.stdout


def used_inodes():
    line = kubectl("-n", "noetl", "exec", POD, "--", "df", "-i", "/data").splitlines()[-1]
    return int(line.split()[2]), int(line.split()[3])


def pod_identity():
    p = json.loads(kubectl("-n", "noetl", "get", "pod", POD, "-o", "json"))
    return p["metadata"]["uid"], p["status"]["containerStatuses"][0]["restartCount"]


def counters():
    out = {}
    for line in kubectl("get", "--raw", f"{PROXY}/metrics").splitlines():
        if line.startswith("noetl_chain_populate_total{"):
            name = line.split('outcome="')[1].split('"')[0]
            out[name] = float(line.rsplit(" ", 1)[1])
    return {k: out.get(k, 0.0) for k in WATCH}


def health():
    return json.loads(kubectl("get", "--raw", f"{PROXY}/health")).get("status") == "ok"


def recheck(ids, min_age):
    """Return {id: events} for ids still old enough and with a cov."""
    script = (f'cd {CHAIN} || exit 1; for id in "$@"; do '
              'printf "%s %s %s\\n" "$id" "$(stat -c %Y "$id/wm" 2>/dev/null)" '
              '"$(cat "$id/cov" 2>/dev/null)"; done')
    now = time.time()
    keep = {}
    for line in kubectl("-n", "noetl", "exec", POD, "--", "sh", "-c", script, "_", *ids).splitlines():
        parts = line.split(" ", 2)
        if len(parts) < 3 or not parts[1] or ":" not in parts[2]:
            continue
        if (now - int(parts[1])) / 86400 < min_age:
            continue
        keep[parts[0]] = int(parts[2].rsplit(":", 1)[1])
    return keep


def main():
    path = sys.argv[1]
    min_age = float(sys.argv[2]) if len(sys.argv) > 2 else 7.0
    canary = int(sys.argv[3]) if len(sys.argv) > 3 else 10
    size = int(sys.argv[4]) if len(sys.argv) > 4 else 200
    ids = [l.strip() for l in open(path) if l.strip()]
    batches = [ids[:canary]] + [ids[i:i + size] for i in range(canary, len(ids), size)]

    ident = pod_identity()
    base = counters()
    start_used, start_free = used_inodes()
    print(f"start: used={start_used} free={start_free} candidates={len(ids)} "
          f"batches={len(batches)} pod={ident}", flush=True)

    deleted = 0
    for n, batch in enumerate(batches, 1):
        live = recheck(batch, min_age)
        dropped = len(batch) - len(live)
        expect = sum(2 * e + 6 for e in live.values())
        before, _ = used_inodes()
        out = kubectl("-n", "noetl", "exec", "-i", POD, "--", "sh", "-c", DELETE_LOOP,
                      stdin="".join(k + "\n" for k in live))
        after, free = used_inodes()
        freed = before - after
        deleted += len(live) - out.count("absent ") - out.count("SKIP")
        print(f"batch {n}/{len(batches)}: ids={len(live)} dropped_on_recheck={dropped} "
              f"expected={expect} freed={freed} used={after} free={free}", flush=True)

        problems = []
        if "ERROR" in out or "done" not in out:
            problems.append("delete errors: " + " | ".join(
                l for l in out.splitlines() if "ERROR" in l)[:300])
        if expect and freed < 0.9 * expect:
            problems.append(f"freed {freed} < 90% of expected {expect}")
        if pod_identity() != ident:
            problems.append("server pod replaced or restarted")
        now = counters()
        moved = {k: now[k] - base[k] for k in WATCH if now[k] != base[k]}
        if moved:
            problems.append(f"failure counters moved: {moved}")
        if not health():
            problems.append("/health not ok")
        if problems:
            print("STOP: " + "; ".join(problems), flush=True)
            sys.exit(2)
        if n < len(batches):
            time.sleep(5)

    end_used, end_free = used_inodes()
    print(f"finished: partitions_deleted~{deleted} used {start_used}->{end_used} "
          f"free {start_free}->{end_free}", flush=True)


if __name__ == "__main__":
    main()
