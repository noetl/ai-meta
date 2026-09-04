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

Discovery matches ANY `pub const NAME: [&str; N]` rather than a suffix
convention.  It used to match `*_OUTCOMES | *_STATUSES`, then also `*_REASONS`,
then `EHDB_CLAIM_FEEDS` arrived — three widenings for the same reason.  A naming
convention that has to be extended per metric is a representation of the set of
pinned sets, and it drifted every time.  Now the registry below is the only
place relevance is decided: an unregistered const is NO-GUARD (a gap to decide
on), and an explicitly `None` entry is a documented exclusion.

Usage:  pinned_sets.py <repos-root>
Prints one line per set: OK / SHORT / NO-GUARD, then a summary line
`RESULT <n_short> <n_noguard>` for the caller to branch on.
"""

import os
import re
import subprocess
import sys

# const name -> (repo, recorder fn, arg_index)
#
# `arg_index` is which string literal in the call carries THIS set: 0 for a
# single-label recorder, 1 when an earlier label comes first.  It exists because
# `record_ehdb_claim_reconnect(feed, reason)` gained a `feed` label, and reading
# argument 0 there would compare feed names against reason names and report a
# correct set as SHORT.
# Explicit because recorder names are not derivable from metric names.
REGISTRY = {
    "ORPHAN_SWEEP_OUTCOMES": ("server", "record_orphan_sweep", None),
    "RESULT_TIER_GC_OUTCOMES": ("server", "record_result_tier_gc", None),
    "CREDENTIAL_SEAL_STATUSES": ("server", "record_credential_seal", None),
    "SYSTEM_PLUGIN_SEED_OUTCOMES": ("server", "record_system_plugin_seed", None),
    "EHDB_COMMAND_PUBLISH_FAILED_REASONS": ("server", "record_ehdb_command_publish_failed", None),
    # The four mirror sets + the projection snapshot gate.  Each was NO-GUARD —
    # declared and pinned, but with no registry entry, so the check could not say
    # whether the pinned list matched what the recorder is called with.
    #
    # ⚠ An unverifiable guard is the thing this file exists to catch, one level
    # up: "we pin these outcomes" reads as a guarantee, and NO-GUARD means nobody
    # was checking it.  Each recorder was confirmed to exist exactly once and to
    # have real call sites (5, 8, 5, 7 and 2) before being registered — a mapping
    # to a recorder that is never called would make the entry green and vacuous.
    "EHDB_EVENTLOG_MIRROR_OUTCOMES": ("server", "record_ehdb_eventlog_mirror", None),
    "EHDB_EVENTLOG_MIRROR_QUEUE_OUTCOMES": ("server", "record_ehdb_eventlog_mirror_queue", None),
    "EHDB_PROJECTION_MIRROR_OUTCOMES": ("server", "record_ehdb_projection_mirror", None),
    "EHDB_PROJECTION_MIRROR_QUEUE_OUTCOMES": ("server", "record_ehdb_projection_mirror_queue", None),
    "EHDB_PROJECTION_SNAPSHOT_GATE_OUTCOMES": ("server", "record_ehdb_projection_snapshot_gate", None),
    "COMMAND_ROW_INSERT_MODES": ("server", "record_command_row_insert_failed", None),
    # Not a label set at all: a list of METRIC NAMES that `init_unlabelled_series`
    # must touch.  Its guard is `startup_inits_alone_register_every_unlabelled_metric`,
    # which asserts each name is served after startup AND that the count matches
    # the number of accessor touches.  Excluded explicitly so it reads as a
    # decision rather than an unregistered gap.
    "UNLABELLED_STARTUP_METRICS": None,
    "LOGIN_OUTCOMES": ("gateway", "record_login", None),
    "SESSION_CHECK_OUTCOMES": ("gateway", "record_session_check", None),
    # SECRET_REFRESH_OUTCOMES is deliberately absent: two of its five values
    # (`succeeded`, `failed`) are assigned to a local in a `match` and passed as
    # a variable, so a literal scan finds three and would call a complete set
    # SHORT.  Its guard is `plugin_seed_and_secret_refresh_series_exist`, which
    # asserts all five are pinned.
    "SECRET_REFRESH_OUTCOMES": None,
    "STATE_BUILDER_DRIVE_OUTCOMES": ("worker", "record_state_builder_drive", None),
    "STATE_BUILDER_DRIVE_WAIT_OUTCOMES": ("worker", "record_state_builder_drive_wait", None),
    "STATE_BUILDER_BUILD_OUTCOMES": ("worker", "record_state_builder_build", None),
    # arg 1: the recorder is (feed, reason) — arg 0 would compare feeds to reasons.
    "EHDB_CLAIM_RECONNECT_REASONS": ("worker", "record_ehdb_claim_reconnect", 1),
    "EHDB_CLAIM_FEEDS": ("worker", "record_ehdb_claim_reconnect", 0),
    "STATE_BUILDER_REPLAY_END_REASONS": ("worker", "record_state_builder_replay_end", None),
    "MATERIALIZER_ACK_STAGES": ("worker", "record_materializer_ack_failed", None),
    # NONCONVERGENCE_SWEEP_OUTCOMES is deliberately absent: five of its seven
    # values come from `Disposition::metric_label`, not from call-site literals,
    # so a literal scan under-reports it by design.  Its guard is the exhaustive
    # match in `every_disposition_label_is_pinned`, which fails at COMPILE time.
    "NONCONVERGENCE_SWEEP_OUTCOMES": None,
    # --- registered 2026-08-09; these six were NO-GUARD since they were added ---
    "CATALOG_DELETE_OUTCOMES": ("server", "record_catalog_delete", None),
    "SINK_STATE_OPS": ("server", "record_sink_state", None),
    "AUTHZ_OUTCOMES": ("gateway", "record_authz", None),
    "SESSION_CACHE_STAGES": ("gateway", "record_session_cache_failed", None),
    "EVENT_FEED_RECONNECT_REASONS": ("gateway", "record_event_feed_reconnect", None),
    # SINK_GATE_OUTCOMES is deliberately absent: its six values come from FOUR
    # separate zero-arg recorders that each hardcode their own literal
    # (`record_sink_gate_marked` -> "marked", `_confirmed` -> "confirmed", ...)
    # plus `record_sink_gate_released(reason: &str)`, which passes a VARIABLE.
    # A literal scan against any one recorder under-reports by design — the same
    # shape as SECRET_REFRESH_OUTCOMES above.
    "SINK_GATE_OUTCOMES": None,
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


def strip_tests(src: str) -> str:
    """Remove every `#[cfg(test)] mod ... { ... }` block, by brace matching.

    Three attempts, each wrong in a different direction, which is why this is
    spelled out:

      1. Scanning test code counted `record_login("{o}")` inside a `format!`
         in a guard test as a call site — two false SHORTs the moment the
         gateway was added, whose sets live in the same file as their test.
      2. Truncating at the first `#[cfg(test)]` overshot: `state_builder.rs`
         annotates individual test-only helpers at lines 865/877, far above its
         real call sites at 1333.
      3. Truncating at the first `#[cfg(test)] mod` still overshot:
         `event_bus.rs` has a test module at line 548 and real call sites at
         871 and 905 AFTER it — which silently dropped one of two feeds and
         still reported OK, because everything it did find was pinned.

    A false OK is worse than a false SHORT, and (3) was caught only by noticing
    the literal COUNT drop from 2 to 1.  That is why the check prints counts.
    """
    out, i = [], 0
    for m in re.finditer(r"#\[cfg\(test\)\]\s*\n\s*(?:pub\s+)?mod\s+\w+\s*\{", src):
        out.append(src[i:m.start()])
        depth, k = 1, m.end()
        while k < len(src) and depth:
            if src[k] == "{":
                depth += 1
            elif src[k] == "}":
                depth -= 1
            k += 1
        i = k
    out.append(src[i:])
    return "".join(out)


def literals_after(src: str, call: str, arg_index: int = 0):
    """Every string literal at position `arg_index` of a call to `call`."""
    out, rest, needle = [], src, call + "("
    while True:
        i = rest.find(needle)
        if i < 0:
            break
        rest = rest[i + len(needle):]
        # Walk the argument list, collecting quoted literals until the call
        # closes.  A ')' reached before enough literals means this site passed a
        # variable — correctly skipped rather than guessed at.
        seg, depth, k, lits = rest, 0, 0, []
        while k < len(seg):
            c = seg[k]
            if c == ")" and depth == 0:
                break
            if c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
            elif c == '"':
                end = seg.find('"', k + 1)
                if end < 0:
                    break
                lits.append(seg[k + 1:end])
                k = end
            k += 1
        if len(lits) > arg_index:
            out.append(lits[arg_index])
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
    for repo in ("server", "worker", "gateway"):
        d = os.path.join(root, "repos", repo)
        if not os.path.isdir(d):
            continue
        # The gateway has no metrics.rs; its sets live beside the ingress
        # registry.  Scan whichever file exists rather than assuming a layout.
        src = git_show(d, "src/metrics.rs") or git_show(d, "src/ingress/mod.rs")
        if src is None:
            continue
        for name in re.findall(r"pub const ([A-Z_0-9]+)\s*:\s*\[&str;", src):
            declared[name] = (repo, src)

    # A const with no registry entry is the drift this file must not have.
    for name in sorted(declared):
        if name not in REGISTRY:
            n_noguard += 1
            print(f"NO-GUARD {name} ({declared[name][0]}): declared but not registered here")

    for name, entry in REGISTRY.items():
        if entry is None:
            continue
        repo, call, arg_index = entry
        arg_index = arg_index or 0
        if name not in declared:
            n_noguard += 1
            print(
                f"NO-GUARD {name} ({repo}): registered here but not discovered in "
                "metrics.rs — deleted, renamed, or its suffix is outside "
                "OUTCOMES/STATUSES/REASONS"
            )
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
                found += literals_after(strip_tests(content), call, arg_index)
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
