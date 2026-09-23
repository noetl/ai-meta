# #315 root cause, in code: two defects, both verified by reading

Server `noetl/server@35c45182`. Measurements from prod 2026-09-23.

## Defect A — terminality is FORGOTTEN by eviction

`ExecDescriptor.terminal` (`src/state.rs:472`) is the only terminal guard on the
stateless drive:

```rust
// dispatch_offserver_stateless_drive, src/handlers/events.rs:3034
if desc.terminal {
    ... record_orchestrate_drive("stateless_terminal_skip"); return Ok(0);
}
```

But the descriptor is **in-memory only** — `ExecDescriptors` is a plain
`HashMap` and its `coherence` backend defaults to `local` (disabled)
(`src/state.rs:482-489`) — and on the terminal event the code **evicts it**:

```rust
// src/handlers/events.rs:3508 (and :3038, :3838)
state.exec_descriptors.evict(execution_id).await;
```

The struct's own doc states what happens next: *"A cold slot … yields `None`,
and the drive falls back to the server-built state path for that trigger —
**which re-seeds the descriptor**"* (`src/state.rs:478-481`). The re-seed has no
way to know the execution already finished, so it seeds `terminal: false`.

**So the terminal flag is destroyed by the very event that sets it, and the
guard can never fire again for that execution.**

Matches the measurement exactly: `stateless_terminal_skip` sat at **7
cumulative** (delta **+0** across a 23-minute window) while **4 executions with a
non-null `completed_at`** were being re-driven ~30x/hour.

## Defect B — the give-up RESETS the loop instead of halting it

The no-op counter lives inside the orch_cache slot, and give-up **evicts that
slot**:

```rust
// src/handlers/events.rs:2982-3001
let (n, give_up) = reconcile_decision(advanced, g.consecutive_reconcile_noops, cap);
g.consecutive_reconcile_noops = n;
...
if give_up {
    record_reconcile_giveup("max_noops");
    state.orch_cache.evict(execution_id);   // <-- destroys the counter
}
```

The intent is documented in the comment above it: *"Giving up is deliberately
NOT destructive: it drops a cache entry … a later real event calls
`orch_cache.entry`, which **recreates the slot and resumes driving**."*

Recreating the slot recreates `consecutive_reconcile_noops = 0`. So give-up is a
**sawtooth, not a halt**: at `RECONCILE_INTERVAL = 8s`
(`events.rs:2901`) and `default_reconcile_max_noops = 225`
(`config/app.rs:1004`), an execution that can never advance is re-driven ~225
times (~30 min), gives up once, and starts counting from zero again — forever.

Matches the measurement: **0.17 give-ups/min against 15.9 retries/min.**

## Why both matter together

Defect A supplies a permanent population (terminal executions that can never
advance). Defect B guarantees nothing ever removes them. Result: 825 of 825
drives are no-ops, 43 distinct executions re-driven 28-36x/hour each, none
younger than 1 hour, `attempts=0` on all 483.

## Fix design (not yet implemented)

**A.** Terminality must survive eviction. Either retain a bounded terminal
tombstone that outlives the descriptor, or have the cold-slot re-seed consult
authoritative state before driving. The current design destroys the only record
of terminality at exactly the moment it becomes true.

**B.** The give-up must not store its own counter in the thing it evicts. Mark
the slot given-up and stop driving it, rather than evicting and letting
`orch_cache.entry` silently reset the budget. The documented self-heal ("a later
real event resumes it") is worth keeping — but it must be a *deliberate* clear,
not a side effect of the give-up.

⚠ Both are changes to the server's orchestration core on a **single-replica**
prod server, and kind was destroyed by my earlier prune, so there is no
rehearsal environment until it is rebuilt. Not implemented yet.
