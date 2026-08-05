#!/usr/bin/env python3
"""Compare each pinned metric-label set against the literals its recorder is
actually called with.

Why this exists as a script and not only as a Rust test: the `*_literals_are_
all_pinned` tests in noetl/server and noetl/worker are the real guards, but
noetl/ai-meta#232 records that **no `cargo test` runs in CI on any Rust repo**,
so nothing executes them unless a human does.  This gives them a runner inside
`drift-audit.sh`, which is read-only and needs no build.

The failure it catches is specific and quiet: a pinned set that omits one
outcome.  The omitted series stays ABSENT from /metrics — which is exactly what
pinning was supposed to fix — while the other six read 0 and look complete.
Found for real on `record_result_tier_gc`, where a same-line grep saw 6, reading
the file saw 7, and the extraction below saw 8.

Reads `origin/main`, not the working tree.  The first version read the tree and
would have reported confidently against whatever branch happened to be checked
out — including a `main` that was 143 commits stale, which is how this was
found.  Every other check in `drift-audit.sh` reads `origin/main`; this one now
matches.

Two extraction rules, both learned from getting it wrong:

  1. Take the next quoted string AFTER the call, not on the same line.  One of
     the GC literals is wrapped onto the following line.
  2. Do not assume the recorder name is derivable from the metric name.  Three
     recorders here are not (`record_credential_seal` /
     `noetl_credentials_sealed_total`), so the mapping is explicit.

Usage:  pinned_sets.py <repos-root>
Prints one line per set: OK / SHORT / NO-GUARD, then a summary line
`RESULT <n_short> <n_noguard>` for the caller to branch on.
"""

import os
import re
import subprocess
import sys

# const name -> (repo, recorder fn, files the recorder is called from)
# Explicit because recorder names are not derivable from metric names.
REGISTRY = {
    "ORPHAN_SWEEP_OUTCOMES": ("server", "record_orphan_sweep", None),
    "RESULT_TIER_GC_OUTCOMES": ("server", "record_result_tier_gc", None),
    "CREDENTIAL_SEAL_STATUSES": ("server", "record_credential_seal", None),
    "STATE_BUILDER_DRIVE_OUTCOMES": ("worker", "record_state_builder_drive", None),
    "STATE_BUILDER_DRIVE_WAIT_OUTCOMES": ("worker", "record_state_builder_drive_wait", None),
    "STATE_BUILDER_BUILD_OUTCOMES": ("worker", "record_state_builder_build", None),
    "EHDB_CLAIM_RECONNECT_REASONS": ("worker", "record_ehdb_claim_reconnect", None),
    # NONCONVERGENCE_SWEEP_OUTCOMES is deliberately absent: five of its seven
    # values come from `Disposition::metric_label`, not from call-site literals,
    # so a literal scan under-reports it by design.  Its guard is the exhaustive
    # match in `every_disposition_label_is_pinned`, which fails at COMPILE time.
    "NONCONVERGENCE_SWEEP_OUTCOMES": None,
}


def git_show(repo_dir: str, path: str):
    """File content at origin/main, or None if absent."""
    try:
        return subprocess.run(
            ["git", "show", f"origin/main:{path}"],
            cwd=repo_dir, capture_output=True, text=True, check=True,
        ).stdout
    except Exception:
        return None


def git_ls_rs(repo_dir: str):
    """Every .rs path under src/ at origin/main."""
    try:
        out = subprocess.run(
            ["git", "ls-tree", "-r", "--name-only", "origin/main", "src/"],
            cwd=repo_dir, capture_output=True, text=True, check=True,
        ).stdout
    except Exception:
        return []
    return [l for l in out.splitlines() if l.endswith(".rs")]


def literals_after(src: str, call: str):
    """Every string literal passed as the first argument to `call`."""
    out, rest, needle = [], src, call + "("
    while True:
        i = rest.find(needle)
        if i < 0:
            break
        rest = rest[i + len(needle):]
        q1 = rest.find('"')
        if q1 < 0:
            break
        # A ')' before the quote means this call had no string first arg.
        if rest[:q1].count(")") == 0:
            after = rest[q1 + 1:]
            q2 = after.find('"')
            if q2 >= 0:
                out.append(after[:q2])
    seen = []
    for o in out:
        if o not in seen:
            seen.append(o)
    return seen


def const_values(metrics_src: str, name: str):
    m = re.search(
        re.escape(name) + r"\s*:\s*\[&str;\s*\d+\]\s*=\s*(?:\n\s*)?\[(.*?)\]\s*;",
        metrics_src,
        re.S,
    )
    if not m:
        return None
    return [x.strip().strip('"') for x in m.group(1).split(",") if x.strip()]


def main(root: str) -> int:
    n_short = n_noguard = 0
    declared = {}
    for repo in ("server", "worker"):
        d = os.path.join(root, "repos", repo)
        if not os.path.isdir(d):
            continue
        src = git_show(d, "src/metrics.rs")
        if src is None:
            continue
        for name in re.findall(r"pub const ([A-Z_]+(?:OUTCOMES|STATUSES))\s*:", src):
            declared[name] = (repo, src)

    # A const with no registry entry is the drift this file must not have.
    for name in sorted(declared):
        if name not in REGISTRY:
            n_noguard += 1
            print(f"NO-GUARD {name} ({declared[name][0]}): declared but not registered here")

    for name, entry in REGISTRY.items():
        if entry is None:
            continue
        repo, call, _ = entry
        if name not in declared:
            n_noguard += 1
            print(f"NO-GUARD {name} ({repo}): registered here but no longer declared in metrics.rs")
            continue
        _, metrics_src = declared[name]
        pinned = const_values(metrics_src, name)
        if pinned is None:
            n_noguard += 1
            print(f"NO-GUARD {name} ({repo}): could not parse the const body")
            continue
        d = os.path.join(root, "repos", repo)
        found = []
        for rel in git_ls_rs(d):
            if rel.endswith("metrics.rs"):
                continue
            content = git_show(d, rel)
            if content:
                found += literals_after(content, call)
        seen = []
        for o in found:
            if o not in seen:
                seen.append(o)
        missing = [x for x in seen if x not in pinned]
        if not seen:
            # No call sites found at all: either the recorder was renamed or the
            # extraction broke.  Either way this is not a pass.
            n_noguard += 1
            print(f"NO-GUARD {name} ({repo}): no call sites found for {call}() — renamed?")
        elif missing:
            n_short += 1
            print(f"SHORT    {name} ({repo}): recorded but not pinned: {missing}")
        else:
            print(f"OK       {name} ({repo}): {len(seen)} literal(s), all pinned")

    print(f"RESULT {n_short} {n_noguard}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "."))
