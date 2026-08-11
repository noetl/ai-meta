# Worker 5.108.1 → 5.115.3 — the behaviourally-inert roll

**Status: STAGED, NOT APPLIED.** Prepared 2026-08-11. Nothing in this
directory has been run against prod.

## Why this is its own step

The EHDB primary serve path arrives as an image change and, later, as a flag
flip. Doing both at once means any regression has two candidate causes and no
way to separate them. This roll moves the image and **changes no behaviour**,
so that when a flag is later flipped, the flip is the only variable.

That claim has to be earned, not asserted — §2 is the audit that earns it.

## 1. What is running now

Read from the cluster, not from a manifest (read-only, 2026-08-11):

| workload | replicas | digest | `noetl_worker_build_info` |
| :-- | --: | :-- | :-- |
| `deploy/noetl-worker-rust` | 2 | `sha256:5dee5466…` | `5.108.1` |
| `deploy/noetl-worker-system-pool` | 1 | `sha256:5dee5466…` | `5.108.1` |
| `deploy/noetl-worker-system-pool-shard1` | 1 | `sha256:5dee5466…` | — |
| `sts/noetl-cmdbus-writer` | 1 | `sha256:5dee5466…` | `5.108.1` |
| `deploy/noetl-cmdbus-writer-1` | **0** | `sha256:6d3f9c36…` | — |

Target: `us-central1-docker.pkg.dev/shastaratech-noetl-prod/noetl/noetl-worker-rust@sha256:c50eff5579af1f3baedaa58d739f4284e8c8c943d89a286d1874e5a838d95a18`

Already present in Artifact Registry as `v5.115.3` — **no `crane` copy needed**.
`crane config` on that digest reports `linux/amd64`, matching both prod
(Autopilot amd64) and the digest being replaced. Worth checking rather than
assuming: the GHCR tag is a 4-entry index and the arm64 leg would schedule
nowhere.

## 2. Delta audit — 14 releases, 16 non-release commits

Every behaviour-bearing change in `v5.108.1..v5.115.3`, and what gates it:

| commit | change | gate | fires in prod today? |
| :-- | :-- | :-- | :-- |
| `dd8d793` `415c46b` `30b5f76` `f37afb2` | tier-service skeleton, client, durable store, query source | `NOETL_EHDB_TIER_SERVICE_BIND` / `_ADDR` / `NOETL_EHDB_TIER_QUERY_SOURCE` (default `local`) | **no** — set nowhere |
| `92ce0ce` `9f10266` | primary-serve policy, wired into the event-log append | tier must be `primary` | **no** — all four tiers `shadow` |
| `3fc1b63` | `primary` no longer silently disarms the mirror | tier must be `primary` | **no** |
| `92646f8` `1c3c836` `c5161b2` | reachability measured, not inferred; evidence-based re-promotion | reachable tier service | **no** |
| `8fed005` | tier client accepts DNS names | client must be configured | **no** |
| `26e2d80` | provider errors terminate the step | `NOETL_PROVIDER_ERROR_TERMINATES`, default **off** | **no** |
| `4a7d2d4` | deletes `noetl_worker_affinity_decisions_total` | none — but it had no caller | **no series to lose** (verified: 0 matches on a live prod pod's `/metrics`) |
| `b56e225` | **poison commands park to dead-letter instead of NACKing forever** | **none — unconditional** | **yes, on a path that is currently broken** |
| `97245f7` | CI staging dir for `publish-ar` | build-time | n/a |

**Migrations: none.** `git diff v5.108.1..v5.115.3 -- '*.sql' migrations/` is
empty, and the worker owns no schema — it reaches `noetl.*` only through the
server API.

### The one ungated change

`b56e225` is the honest asterisk on "behaviourally inert". A command whose row
is absent from `noetl.command` returns 404 from the claim endpoint; that landed
in the catch-all failure arm, which NACKs for redelivery. Correct for a
transient failure, permanently wrong here — the claim can never succeed, so the
message returns to the head of the queue and **blocks every message behind it**
(measured on a wedged kind pool: 30 claim failures, 0 successful claims, in five
minutes).

So the roll does change behaviour, in exactly one direction: a pool that would
have wedged now parks the poison record and keeps draining. It fires only on a
404 claim — a path whose current behaviour is a wedge. Taking it is the point of
rolling, not a risk of rolling.

### ⚠ Landmine — the `cargo fmt` sweep

`b56e225` touches **25 files, 754 insertions**. Three of them carry the fix
(`worker.rs`, `executor/command.rs`, `client/control_plane.rs`); the other 22
are a formatting sweep that rode along. Reviewing this range diff-first will
drown the signal. Read the three files, or read the commit message, and treat
the rest as noise. (Related standing rule: never run `cargo fmt --all` on these
crates — rustfmt 1.9.0 reflows them.)

### ⚠ Landmine — `noetl-cmdbus-writer-1`

A `replicas: 0` Deployment, 15 days old, pinned to a **different and much
older** digest (`sha256:6d3f9c36…`, worker 5.83.0). It is not part of this roll
and must not be included in it. It is harmless at zero replicas and would start
an ancient writer beside a current one if anyone scaled it — the sort of thing
that gets scaled "to see if it helps" during an incident. Decide its fate
separately: delete it, or re-pin it so scaling it is survivable.

## 3. The roll

Four workloads, one digest, no env change. **Not run.**

```bash
CTX=gke_shastaratech-noetl-prod_us-central1_noetl-prod-autopilot
IMG=us-central1-docker.pkg.dev/shastaratech-noetl-prod/noetl/noetl-worker-rust@sha256:c50eff5579af1f3baedaa58d739f4284e8c8c943d89a286d1874e5a838d95a18

# The user pools first — they are replicas>1 and roll without a gap.
kubectl --context $CTX -n noetl set image deploy/noetl-worker-rust          noetl-worker=$IMG
kubectl --context $CTX -n noetl set image deploy/noetl-worker-system-pool   noetl-worker=$IMG
kubectl --context $CTX -n noetl set image deploy/noetl-worker-system-pool-shard1 noetl-worker=$IMG

# The writer LAST and on its own.  replicas: 1 hosting BOTH buses: this is a
# brief total bus outage, and gateway `Connection refused` bursts during it are
# the restart, not a fault.
kubectl --context $CTX -n noetl set image sts/noetl-cmdbus-writer          noetl-worker=$IMG
```

⚠ **Verify the container name against each live workload before patching.**
Prod names them `noetl-worker`; the kind rig names the user pool's container
`worker`. A wrong container name in a `kubectl patch` has previously aborted a
reconcile half-applied.

## 4. Verification

Not "the pods are Running" — that is true of a pod that pulled the wrong image.

1. **Version, from the process:**
   `noetl_worker_build_info{version="5.115.3"}` on all four workloads, read via
   `kubectl exec … wget -qO- 127.0.0.1:9090/metrics`. The Deployment's image tag
   is a different representation and can disagree with what runs.
2. **No new EHDB serving:** `noetl_ehdb_*_ops_total{outcome="served_primary"}`
   **absent** on every pod, and `operation="runtime_hook"` absent entirely
   (nothing was flipped, so nothing should report a flip).
3. **The tier-service flags are still set nowhere:**
   `kubectl get deploy,sts -o yaml | grep -c NOETL_EHDB_TIER_SERVICE` → `0`.
4. **Dispatch is alive:** one real execution end to end, and
   `ehdb_feed_subject_lag` returning to its pre-roll level.
5. **The b56e225 path:** `CLAIM_UNRESOLVABLE` should appear **zero** times. It
   is not expected to fire; seeing it means there are poison rows, which is
   information either way.

## 5. Rollback

`kubectl set image` back to `sha256:5dee54664354f764fda938e2016426f6ccf702cd485dafe18c405e7e724c10c7`
on the same four workloads. No state migration in either direction, so rollback
is symmetric — that is a consequence of §2 finding no migrations, not an
assumption.

## 6. What this roll does NOT do

- Does not set `NOETL_EHDB_TIER_SERVICE_BIND` or `_ADDR` anywhere.
- Does not promote any tier to `primary`.
- Does not apply [noetl/ops#255](https://github.com/noetl/ops/pull/255) (the
  `:9110` face).
- Does not make EHDB serve any prod traffic.

Those stay gated on the cross-store comparator producing real parity evidence
plus an explicit per-tier go.
