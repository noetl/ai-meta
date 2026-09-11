# Deploying v3.108.1 — the AC14 fix (prepared 2026-09-11, NOT executed)

⚠ **Owner-gated.** Nothing here has run against prod except read-only
`--dry-run=server` diffs.

⚠ **This deploy is NOT inert.** The v3.108.0 roll was image-only with no
behaviour change, because the flag it shipped defaulted off. This one is
different: it changes what the *currently live* read path does.

## What changes the moment this rolls

`NOETL_EHDB_PROJECTION_SERVE_ON_BEHIND` stays **unset**. The behaviour change is
not gated by it, because the defect was never behind it.

Before (v3.108.0): `wal_projection_state` re-folded the recovery ladder, which
resolves to the tier on 100% of prod calls, and compared that against the tier's
own record. The check could not fail. Prod served **2,212** reads on it
(`projection_read{outcome="served_tier"}`).

After (v3.108.1): the same leg folds `noetl.event`. The check can now fail, and
for a genuinely gapped tier it *will*.

So the expected, correct outcome of this deploy is **fewer `served_tier` and
more refusals**. A refusal returns `Ok(None)`, and the caller rebuilds from
Postgres in full — which is what already happens on the ~83% of reads that
return `no_stored_record`. **Refusing is the safe direction**; serving was the
unsafe one.

⚠ Do not read a `digest_mismatch` rise as a regression caused by this deploy.
The divergence it reports was already there and already being served; the deploy
is what makes it *visible*. The regression would be the opposite — a deploy that
changed nothing.

## Pre-deploy checks (immediately before, per `apply-safety.md`)

1. Re-run the full-spec diff below and confirm it is **still image-only**.
   A diff prepped earlier is not a diff verified now (#323).
2. `recovery_source_info{tier}=1` and `NOETL_EHDB_PROJECTION_READ_SOURCE=wal`
   still set — this deploy assumes that topology.
3. Record the pre-deploy counter baseline (below). Counters are cumulative
   **per pod**, so the roll resets them; the baseline is only comparable as a
   *rate*, never by subtraction across the roll.

```bash
PROD=gke_shastaratech-noetl-prod_us-central1_noetl-prod-autopilot
kubectl --context "$PROD" -n noetl port-forward svc/noetl 19800:8082 &
curl -s localhost:19800/metrics | grep -E \
  'noetl_ehdb_projection_read_total|noetl_ehdb_projection_refold_total|noetl_ehdb_projection_serve_refusal_total'
```

## Release identity

| | |
| :-- | :-- |
| tag | **v3.108.1** (semantic-release chose the patch from `fix:`) |
| merge commit | `f82f69f7` |
| release commit | `aea78ec7` (`chore(release): version 3.108.1 [skip ci]`) |
| AR digest | `sha256:b9bed0304104247caa7b01594033c216ff98fa09f275173d7011160d07d075ee` |
| replaces | `sha256:867b822f838bd54a9bc13069954f3ae337c836aa497759ba9a624574f6111daf` (v3.108.0) |

Fix confirmed present in the built artifact by symbol inspection of
`app/noetl-control-plane` (linux/amd64), three-way:

```
                        new   old
bounded_fold_agrees       1     0     <- unique to the fix
bounded_fold_at           1     0
events_from_postgres      4     0
wal_projection_state      3     4     <- positive control: technique finds names
fold_from_postgres        3     1
grant_for_behind          2     2
<nonexistent symbol>      0     0     <- negative control
version "3.108.1"         3     0
version "3.108.0"         0     3
```

The positive control is what makes the zeros meaningful: shared symbols are
found in both binaries, so `old=0` for the fix's symbols is a real absence and
not a `strings` invocation that matches nothing.

## The full-spec diff (server-side dry-run, run 2026-09-11)

```
$ diff live.yaml rolled.yaml    # resourceVersion/generation filtered
161c161
<   image: ...server-rust@sha256:867b822f...
---
>   image: ...server-rust@sha256:b9bed030...
```

**Image-only.** `env` count unchanged at 62,
`NOETL_EHDB_PROJECTION_SERVE_ON_BEHIND` **absent** in both,
`READ_SOURCE=wal` and `RECOVERY_SOURCE=tier` unchanged.

Positive control — the same method on a roll that *also* adds an env var reports
both hunks, so the single-hunk result above is the method working, not blind:

```
161c161,163
<   image: ...@sha256:867b822f...
---
>   - name: ZZ_CONTROL_ONLY
>     value: "1"
>   image: ...@sha256:b9bed030...
```

## The command

Image-only roll, by digest, same shape as the v3.108.0 deploy:

```bash
kubectl --context "$PROD" -n noetl set image \
  statefulset/noetl-server-rust-embedded \
  noetl-server=us-central1-docker.pkg.dev/shastaratech-noetl-prod/noetl/server-rust@sha256:b9bed0304104247caa7b01594033c216ff98fa09f275173d7011160d07d075ee
```

## Soak plan

The window must be long enough to see `digest_mismatch` **rise and then fall**.
A rise alone proves nothing — under load, 13 apparent divergences all converged
within ~3 min, because an async mirror can deliver the last event before some
middle ones. The discriminator is **persistence, not presence**.

| t | signal | healthy | abort |
| :-- | :-- | :-- | :-- |
| t+0 | pod | `1/1`, restarts 0, `/api/health` 200 | CrashLoop, or restarts climbing |
| t+0 | `*_build_info{version}` | reads `3.108.1` | still `3.108.0` → the roll did not take |
| t+5m | `projection_refold{verdict="digest_mismatch"}` | **non-zero** | flat 0 → suspect the deploy did nothing |
| t+30m | same, as a rate | **falling** | flat or climbing → real, persistent loss |
| t+30m | `projection_read{outcome="served_tier"}` | lower than before, non-zero | 0 → every read refusing |
| t+1h | no-op storm | ~**0/min** | climbing → re-drive loop |
| t+1h | dispatch latency | at or near pre-deploy | regression |
| t+1h | `recovery_source_info` | still `tier` | changed |
| t+1h | ERROR lines | **0** | any |
| t+24h | `serve_refusal{stored_ahead}` | **0** | ever non-zero |

⚠ `served_tier` dropping to **0** is an abort trigger, not a success. It would
mean the verification refuses everything — the option-(a) failure mode this fix
was chosen specifically to avoid. Some agreement must survive, or the tier is
not actually a usable mirror.

**Confirm any persistent divergence before acting on it:** re-check the same
`execution_id` after settle, not once.

```bash
curl -s localhost:19800/api/ehdb/projection-fold/executions/<ID> | \
  jq '{agree:.result.digests_agree, tier:.result.tier.applied_count,
       pg:.result.postgres.applied_count}'
```

## Rehearsed revert

Image rollback to v3.108.0, by digest:

```bash
kubectl --context "$PROD" -n noetl set image \
  statefulset/noetl-server-rust-embedded \
  noetl-server=us-central1-docker.pkg.dev/shastaratech-noetl-prod/noetl/server-rust@sha256:867b822f838bd54a9bc13069954f3ae337c836aa497759ba9a624574f6111daf
```

⚠ **Reverting restores the defect, it does not restore correctness.** v3.108.0
goes back to serving on a check that cannot fail. Revert to stop a *different*
problem (crash, latency, storm) — never because `digest_mismatch` is non-zero,
which is the fix working.

Both this and the roll write `spec.template`, so each rolls the pod
(`replicas: 1` → ~30–60s serving gap).

## Not in this deploy

- `NOETL_EHDB_PROJECTION_SERVE_ON_BEHIND` — still unset. The flag arm is a
  separate gate (`arm-runbook.md`), and it stays **no-go** until this deploy has
  soaked, because arming widens what gets served.
- noetl/ai-meta#335 (the WAL path double-applies every event) is unfixed and
  unaffected — present before and after.
