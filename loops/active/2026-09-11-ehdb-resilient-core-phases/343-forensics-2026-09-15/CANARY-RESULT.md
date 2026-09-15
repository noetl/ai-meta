# Canary result — worker#315 did NOT fix hydration. Rolled back.

2026-09-15. Executed the staged canary in `CANARY-RUNBOOK.md`. **Negative result.**

## Release

noetl/worker#315 merged 17:11:52Z. semantic-release cut **v5.132.2**
automatically on merge — no manual tag was needed (`release.yml` fires on the
tag semantic-release pushes). Run 34999806034 completed/success; `publish-ar`
landed the digest:

```
v5.132.2  sha256:67d725936c1677968358faa9ee6dd905a1621fb26bd547986e3b82ac17d5b39a
v5.132.1  sha256:6f20890b8c22ec5c8a840670ace63dff0b9c8faeb9829b5981fa2ee5c5051843  <- prod, = rollback artifact
```

## Canary

`deploy/noetl-worker-rust` only, 4 pods. system-pool, shard1 and
`sts/noetl-cmdbus-writer` left on their original digests.

**Execution `358309183893807104`:**

```
count       : 0
deref_error : child 358309195021295616 result was externalised (214803 bytes)
              and this read path returned only a _truncated sample …
```

Byte-identical to the pre-canary baseline (`358300266765754368`). No change.

**It really ran on the fixed image** — every `worker_id` in the execution is
`noetl-worker-rust-866c75c7c6-*`, the new replicaset. This is not a deployment
miss.

**No regression:** flights `358310096679215104` → 4 offers, logos / city /
airport_name intact.

**Rolled back** to `sha256:6f20890b…51843`; all four workloads verified back on
their original digests, post-rollback flights COMPLETED.

## Why it did not work — the lead

The canary pod emitted **zero** `result_mint_authoritative` / resolve metrics:
`resolve_by_urn` was **never invoked**. So the failure is upstream of — or
downstream of, but not at — the predicate this PR changed.

Config worth noting:

| | value |
|---|---|
| worker | `NOETL_RESULT_URI_RESOLVE=true`, `NOETL_RESULT_PRODUCER_STAGE=true`, **no** `NOETL_OBJECT_STORE_*` |
| server | `NOETL_RESULT_MINT_AUTHORITATIVE=true`, `NOETL_RESULT_STORE_DUAL_WRITE=false`, `NOETL_OBJECT_STORE_BACKEND=gcs` |

With `DUAL_WRITE=false` the legacy `result_store` is not written, so the
fail-safe fallback has nothing to fall back to; and the worker has no
object-store config of its own. Either the candidate is never formed (so
`resolve_context_references` returns before reaching the fixed predicate), or the
tier fetch cannot be performed from the worker at all.

**The predicate fix was necessary but not sufficient.** It should stay — the
unit tests and negative control prove it corrects a real defect — but it does not
by itself deliver the payload.

## Next investigation (do NOT roll again blind)

1. Instrument `resolve_context_references`: is `reference_locators` producing a
   candidate for the hotel-cards `search_hotels` step in prod? That is the one
   unmeasured link. Raise `RUST_LOG` for `noetl_worker::executor::command` on one
   pod and re-run — prod runs at `info`, which emits none of the relevant lines.
2. Determine whether the worker can reach the result tier at all given it has no
   `NOETL_OBJECT_STORE_*`. If it cannot, that is the real fix.
3. Only then roll again.

## Standing

- Prod: original digests, executions healthy, `deref_error` still guarding.
- adiona/frontend#22 left OPEN — hotels do not render end-to-end.
- adiona/frontend#21 CLOSED — flights validated live.
- noetl/worker#316 open (cross-pod shm hang), cross-linked from #315.
