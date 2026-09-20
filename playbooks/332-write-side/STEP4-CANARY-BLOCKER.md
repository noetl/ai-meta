# Step 4 (digest-fix prod canary) — stopped, with the exposure described

**2026-09-20. Nothing was changed in prod.** Verified read-only throughout.

Two independent blockers. The first needs a decision; the second needs a
permission grant.

## Blocker 1 ⚠⚠ — there is no canary surface, and creating one risks the
## event log

**The serving server is `StatefulSet/noetl-server-rust-embedded`, 1 replica.**
Both `svc/noetl` and `svc/noetl-server-rust` select `app:
noetl-server-rust-embedded`. `Deployment/noetl-server-rust` is scaled to **0**
and receives nothing. Endpoints confirm a single ready pod,
`noetl-server-rust-embedded-0`.

So rolling it is **100% exposure** — the single-replica full-exposure incident,
repeated. Not done.

The natural fix is a StatefulSet **partition canary**: scale to 2, set
`updateStrategy.rollingUpdate.partition = 1`, update the image so only pod-1
takes it, watch, then promote with `partition = 0` or roll back by reverting the
image. The mechanics are available and the pod is small (requests 250m CPU /
256Mi), and `volumeClaimTemplates: [ehdb-embedded]` means each replica gets its
**own** PVC, so there is no shared-volume conflict.

**But the pod template sets `NOETL_SERVER_MACHINE_ID = 2` explicitly**, so a
second replica runs a second snowflake generator **with the same machine id**.

That is not cosmetic. `state.snowflake.generate()` mints `event_id` app-side at
four call sites (`src/handlers/events.rs:574`, `:1123`, `:1351`, `:3866`). A
snowflake is `(timestamp_ms, machine, sequence)`; two generators sharing the
machine bits emit identical ids as soon as they mint in the same millisecond —
reachable immediately under concurrent writes, not a tail risk.

`noetl.event` is **append-only and immutable, and replay is the source of
truth**. A duplicate `event_id` there cannot be un-written. That is the
irrecoverable primary-event-log cliff the standing hard line says to stop at, so
this stopped.

⚠ The idle `Deployment/noetl-server-rust` carries `NOETL_SERVER_MACHINE_ID = 2`
**as well**, so it is not a safe dark-canary either — and with
`NOETL_EHDB_MIRROR_REPAIR_SWEEP` and the reconcile poller running at startup, a
"dark" replica is not actually read-only.

### The options, for the owner

1. **Derive the id per pod.** Drop `NOETL_SERVER_MACHINE_ID` and let it fall
   back to `derive_machine_id(HOSTNAME)` (`src/state.rs:752`), which is unique
   per StatefulSet pod. ⚠ This also changes **pod-0's** id from `2` to a derived
   value on its next restart, so it is a change to the live writer's identity,
   not only to the new replica's. Whether anything depends on id continuity
   needs checking before it is done.
2. **Set it per-ordinal explicitly** — a command wrapper or init step that maps
   the pod ordinal to a distinct id. No template-only expression of this exists
   today (plain env cannot compute it).
3. **Accept single-replica exposure.** Explicitly rejected by the standing
   instruction, and recorded here only so the option set is complete.

Until one of those lands, **there is no way to canary the server**, and steps 5
and 6 (projector shadow soak, then projector-on) sit behind step 4 by the
owner's own ordering: the digest fix must be in the prod build first.

## Blocker 2 — the release merge was denied

`gh pr merge 459 --repo noetl/server --merge` was refused by the session's
permission classifier. The PR is green and ready; merging is what triggers
semantic-release → tag → the multi-arch image build → AR. That is **upstream of**
any prod change and does not touch the cluster, but it needs a permission the
session does not have.

## What IS ready

| | state |
| :-- | :-- |
| [server#459](https://github.com/noetl/server/pull/459) — the digest fix | CI **green**, rebased onto main (was 8 behind), 1133 tests, planted-defect control re-verified post-rebase. Awaiting merge. |
| `noetl/server` `chore/ehdb-v0.3.0-pin` @ `6fea63f8` | pin-only, 1126 tests. Deliberately **not** based on the digest branch, so step 4 cannot smuggle the ehdb bump into prod. |
| `noetl/worker` `chore/ehdb-v0.3.0-pin` @ `913fa75` | 805 tests, 3 clean runs. |
| ehdb **v0.3.0** | released. |

## Corrections to earlier reporting in this program

- **Prod runs server `v3.112.3`**, not `v3.106.1`. Resolved from the running
  digest `sha256:73487c92…` against AR. The memory index was stale.
- **The serving server is a StatefulSet (`-embedded`), not the Deployment.** The
  Deployment is at 0 replicas.
- **The worker pins `ehdb-l0`.** An earlier scan with `^ehdb-[a-z]* = ` never
  matched the digit in `l0` and I reported the wrong conclusion from it.
