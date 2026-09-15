> ## ⚠ CORRECTION (2026-09-15, later the same day)
>
> **The conclusion below is WRONG for the case that actually mattered.**
>
> This note says kind cannot validate the path without an object store and the
> off-server state builder. That is true only for the `reference` OBJECT shape.
> The shape the runtime actually emits to a consuming step is the **flat**
> accessor form — `{"_ref": …, "data": {"_ref": …}}` — and **kind emits that
> already** (its BEFORE probe produced exactly it). So kind CAN gate this fix,
> with no MinIO and no off-server builder.
>
> Two further claims here are also wrong:
> - **An object store is not needed.** The default backend is **Postgres**
>   (`NOETL_OBJECT_STORE_BACKEND` unset ⇒ bytes in `noetl.object_store`), which
>   kind already has.
> - **The worker needs no object-store config.** Per
>   `server/src/services/object_backend.rs`: *"workers never reach GCS directly —
>   they `PUT`/`GET` through the server."* The "worker has no object-store
>   config" hypothesis was a dead end.
>
> The real blocker was never infrastructure: `reference_locators` did not
> recognise the flat shape, so no candidate was formed. See
> `CANARY-RESULT.md` and noetl/worker#317.
>
> Kept unedited below because the *method* — compare versions before building,
> reproduce the mechanism not just the symptom — is still right, and because a
> wrong conclusion reached carefully is worth being able to re-read.

# Why kind cannot validate the externalised-reference path

2026-09-15, while validating noetl/worker#315. **Do not repeat this attempt
without first provisioning kind** — the reason is structural, not incidental.

## Short version

The `reference` object that `reference_locators` keys on is produced by the
**off-server state-builder path backed by an object store**. Kind runs the
in-server state builder with no object store, so it **never emits that shape**,
and the consume-path resolution code is never entered. A BEFORE/AFTER on kind is
therefore vacuous: both sides are identical because the code under test does not
run in either.

## Two theories tested and DISPROVEN

1. ⚠ **"Kind's server image is too old."** WRONG. Kind runs
   `ghcr.io/noetl/server:3.108.0`; prod runs ~3.108.x. Essentially the same.
   A server rebuild was started on this theory and abandoned once the versions
   were compared. **Compare versions before building anything.**
2. ⚠ **"`NOETL_REFS_IN_STATE` is off in kind."** WRONG. It defaults to **true**
   (`server/src/config/app.rs:51,1135`), so it is on in both.

## The actual difference

| setting | prod | kind |
|---|---|---|
| `NOETL_STATE_BUILDER` | `offserver` | `server` |
| `NOETL_OFFSERVER_TAIL_PLAYBOOK_PREFIXES` | `muno/playbooks/itinerary-planner,automation/agents/mcp/` | unset |
| `NOETL_RESULT_MINT_AUTHORITATIVE` | `true` | unset |
| `NOETL_RESULT_URI_RESOLVE` (worker) | `true` | unset |
| `NOETL_OBJECT_STORE_BACKEND` | `gcs` | unset |
| `NOETL_RESULT_CELL_ENV/REGION/CELL` | `prod` / `usc1` / `usc1-a` | unset |
| `NOETL_RESULT_SHARD_COUNT` | `256` | unset |

Note the prefix list: `automation/agents/mcp/` is exactly the provider path whose
result over-ran the budget in prod. Only playbooks under those prefixes take the
off-server path at all.

## Evidence

**Kind never emits a reference.** The `fetch` (child-playbook) `call.done` in kind
carries the **full inline data**:

```
"result": {"context": {"data": {"count": 60, "hotels": [ … ]}}}
```

The flat `_ref` / `_store` / `_uri` a kind consumer sees comes from a DIFFERENT
mechanism — state summarisation — which `reference_locators` does not match
(it reads `/context/result/reference` or `/reference`).

**Prod does emit it**, confirmed on a real captured execution:

```
reference at /events[11]/result/context/result/reference
  keys: ['extracted','ipc','kind','meta','ref','scope','store','uri']
  ref : noetl://execution/358159477016371200/result/hotelbeds_dispatch/358159487439216640
  uri : noetl://default/default/results/358159477016371200/hotelbeds_dispatch/0/0/1
```

**Aligning kind to the off-server path breaks it.** Setting
`NOETL_STATE_BUILDER=offserver` + the tail prefixes made kind executions hang —
the path needs an object store and the off-server builder, which kind does not
have. Reverted immediately; kind verified executing again and restored to its
original image, env, and KEDA annotation.

## So a kind BEFORE/AFTER is vacuous here

Kind's BEFORE reproduces the *symptom* (`GOT_BARE_REF`, 1 item of 60, 514 bytes
of ~300 KB) but through the summarisation mechanism, not the reference
mechanism. Both BEFORE and AFTER returned byte-identical results because neither
entered the changed code.

Reproducing the symptom is not the same as reproducing the mechanism. That
distinction cost about an hour here.

## What would make kind viable

Provision it with an object store (MinIO or a GCS emulator), set
`NOETL_OBJECT_STORE_BACKEND` + `NOETL_RESULT_CELL_*` + `NOETL_RESULT_SHARD_COUNT`,
switch `NOETL_STATE_BUILDER=offserver` with tail prefixes covering the probe
path, and set `NOETL_RESULT_URI_RESOLVE=true` on the worker. That is a
test-environment build-out, worth doing once — this path is now known to carry at
least two real defects (noetl/worker#315, #316) and has no non-prod coverage.

## Incidental findings

- **KEDA `ScaledObject` (min=2)** governs the kind worker; manual scaling is
  reverted within seconds. Pin with
  `autoscaling.keda.sh/paused-replicas: "1"` (reversible annotation).
- A **cross-pod shared-memory handoff** wedges the consuming worker indefinitely
  when replicas > 1 — filed as noetl/worker#316, reproducible on kind.
- The worker Docker build breaks if a local `.cargo/config.toml` + `vendor/`
  exist (untracked, absent in CI): the planner stage copies the config, the cook
  stage does not copy `vendor/`. Build with an ignorefile excluding both.
