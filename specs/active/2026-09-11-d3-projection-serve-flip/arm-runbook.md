# D3 serve-flip — the arm gate (prepared 2026-09-11, NOT executed)

⚠ **Owner-gated.** Nothing in this file has been run against prod except the
read-only `--dry-run=server` diffs, whose output is reproduced verbatim below.

⚠ **Recommendation: DO NOT ARM on v3.108.0.** See *Go/no-go* at the bottom.
The materials are prepared so the gate is ready the moment the blocker clears.

## Preconditions (re-check immediately before arming, per `apply-safety.md`)

1. The server image is a build that contains noetl/server#424 (Postgres-
   authoritative verification). On v3.108.0 the verification leg reads the tier
   it is verifying, so the flag would widen serving on a check that cannot fail.
2. Re-run the full-object diff below and confirm it is **still exactly 2 lines**.
   A diff you prepped earlier is not a diff you verified now (#323).
3. `kubectl --context "$PROD" -n noetl get pod noetl-server-rust-embedded-0` is
   `1/1`, `Restarts: 0`.

## The command

```bash
PROD=gke_shastaratech-noetl-prod_us-central1_noetl-prod-autopilot
kubectl --context "$PROD" -n noetl patch statefulset noetl-server-rust-embedded \
  --type=json -p '[{"op":"add","path":"/spec/template/spec/containers/0/env/-",
    "value":{"name":"NOETL_EHDB_PROJECTION_SERVE_ON_BEHIND","value":"true"}}]'
```

**`patch`, not `apply`.** Round-tripping the live object through `apply` rewrites
`metadata.annotations.kubectl.kubernetes.io/last-applied-configuration`; a
control run confirmed a reconstructed manifest does not diff clean for that
reason alone. `patch` touches only the field named.

## The full-spec diff (server-side dry-run, run 2026-09-11)

```
$ diff live.yaml armed-dryrun.yaml     # resourceVersion/generation filtered
160a161,162
>         - name: NOETL_EHDB_PROJECTION_SERVE_ON_BEHIND
>           value: "true"
```

Exactly two lines. No image change, no volume change, no probe/resource change,
no replica change.

**Positive control** — the same method applied to a patch that also sets
`replicas: 2` reports *both* hunks:

```
21c21
<   replicas: 1
---
>   replicas: 2
160a161,162
>         - name: NOETL_EHDB_PROJECTION_SERVE_ON_BEHIND
>           value: "true"
```

So the one-hunk result above is the method working, not the method blind. This
control exists because #323 was an apply authorised by a proof narrower than the
action it authorised.

## ⚠ Arming restarts the server

The patch writes `spec.template`, which is part of the pod-template hash, so the
StatefulSet rolls **by construction**. `replicas: 1`, so there is a serving gap
of roughly 30–60s. This is not a surprise to be discovered during the window —
plan it, or arm outside one. ("Shape-only is restart-free" was wrong once
already; 3 of 5 workloads rolled.)

## Soak plan

Baseline first (cumulative counters are per-pod and the arm resets them, so a
pre-arm reading is not comparable to a post-arm one except as a rate):

| t | check |
| :-- | :-- |
| t+0 | pod `1/1`, `Restarts: 0`; `/api/health` 200 |
| t+5m | `projection_read{outcome=...}` — expect `stale_within_window` to become non-zero; that is the flip doing its job |
| t+5m | all four `projection_serve_refusal{reason}` series present; `stored_ahead` must stay **0** |
| t+15m | `projection_refold{verdict="digest_mismatch"}` — expect non-zero and **falling**; see below |
| t+1h | no dispatch backlog growth; no `EHDB claim connect failed` |
| t+24h | `stored_ahead` still 0; `digest_mismatch` rate at or below its pre-arm rate |

⚠ **`digest_mismatch` will be noisy and that is expected, not a failure.** With
#424 the verdict compares against Postgres, so transient mirror lag surfaces
here. 13 such cases were observed under load and **all** converged within ~3 min.
The discriminator is *persistence*, not presence: re-check the same
`execution_id` after settle before treating any one as real. A single-shot sweep
cannot tell lag from loss.

**Abort if:** `stored_ahead` ever leaves 0; `digest_mismatch` does not decay;
dispatch latency regresses; or any execution shows an equal-version content
divergence that survives settle.

## Rehearsed revert

Both rehearsed as `--dry-run=server` on 2026-09-11; both produce a diff
containing only this env var.

**Preferred — set it to `false`** (leaves the knob visible in the spec, so the
next reader can see it was considered and turned off):

```bash
kubectl --context "$PROD" -n noetl patch statefulset noetl-server-rust-embedded \
  --type=json -p '[{"op":"add","path":"/spec/template/spec/containers/0/env/-",
    "value":{"name":"NOETL_EHDB_PROJECTION_SERVE_ON_BEHIND","value":"false"}}]'
```

`serve_on_behind_enabled()` matches `== "true"` exactly and is mutation-gated by
`serve_on_behind_defaults_off_and_is_strict`, so any other value — including
`"1"`, `"yes"`, `"TRUE"` — disables it.

**Alternative — remove the entry.** In the armed object the flag is env index
**62** (0-based), but ⚠ *verify the index at revert time*; it is positional and
any other env edit moves it:

```bash
kubectl --context "$PROD" -n noetl get statefulset noetl-server-rust-embedded \
  -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}{"\n"}{end}' \
  | grep -n SERVE_ON_BEHIND      # 1-based; subtract 1 for the JSON pointer
kubectl --context "$PROD" -n noetl patch statefulset noetl-server-rust-embedded \
  --type=json -p '[{"op":"remove","path":"/spec/template/spec/containers/0/env/62"}]'
```

Either revert also rolls the pod. Reverting restores the *pre-arm* behaviour,
which is the tier still being served on `Match` — the flag was never what put
the tier on the read path.

## Go / no-go

**NO-GO as of 2026-09-11**, on one blocker:

> On v3.108.0 the check that decides whether a tier snapshot is safe to serve
> reads the tier. Arming widens serving from `Match` to `Match +
> StoredBehindSpine` on the strength of a check that cannot fail.

That is noetl/server#424. Once it is merged, released, and deployed inert, the
blocker clears and this gate is ready — the diff, controls and revert above do
not change, because the flag's shape does not.

Independently: noetl/ai-meta#335 (the WAL path double-applies every event) is a
live defect on this same path. It does not block arming — it is present with the
flag off — but it should be understood before widening what the path serves.
