# Hydration bug — final localization. The failure is the resolve FETCH.

2026-09-15, end of session. **This supersedes every earlier diagnosis in this
directory.** Read it before touching anything.

Four release cycles and two diagnostic builds produced three correct fixes, none
of which moved the needle, because each addressed a layer that was already
working. The instrumented build finally settled it.

## ✅ FIVE layers positively EXCLUDED — by measurement, not inference

Do not re-investigate any of these.

| # | layer | how it was excluded |
|---|---|---|
| 1 | **Predicate** (`contains_summary_bulk`, `is_reference_stub`) | #315 shipped as v5.132.2; canary exec `358309183893807104` → `count: 0` unchanged on an image confirmed to contain it |
| 2 | **Locator shape** (`reference_locators` fixed paths) | #317 works — resolve metrics 0 → 63-69/pod; #319 made it depth-independent, RED→GREEN on the real prod fixture |
| 3 | **`steps` population** | probe `358337679496060928` + `358387099021352960`: `steps` is a dict containing the parent step with the locator |
| 4 | **Context ordering** (`render_context` rebuilt after resolve) | **DIAG(1)** — `steps` is present in `ctx.variables` *at the moment the resolver runs* |
| 5 | **Candidate detection / early returns** | **DIAG(2b)/(4)** — locator found, `candidates=1`, NEITHER early return fires |

### The DIAG evidence, verbatim (kind, diagnostic build, exec `358393064194052096`)

```
DIAG(1) pre-resolve context
  step=inspect tool_kind=python
  variables_keys=["path","catalog_id","ctx","fetch","rows","start",
                  "action","node_name","steps","workload","execution_id"]
  steps_kind=object

DIAG(2)  entry: steps IS an object   branch="object"  step_names=["fetch", …]
DIAG(2b) per-step locator probe  step_name=fetch  locator_found=true
DIAG(2b) per-step locator probe  step_name=start  locator_found=false
DIAG(4)  proceeding with candidates  candidates=1
```

Every gate is open. The resolver enters the per-candidate loop with a valid
candidate.

## ⛳ WHERE IT ACTUALLY FAILS — the resolution fetch

After `DIAG(4)` the loop either logs `ref kept as summary` (skipped) or
`resolved over-budget result by URN` (succeeded). **Neither is ever logged for
the parent consume**, which places the failure inside the fetch itself:

```
resolve_by_urn(client, canon)      → crate::result_resolver
  └─ fallback: client.resolve_ref(&uri)   → ControlPlaneClient → SERVER
```

Two different symptoms, same place:

- **prod** — returns fast, no data, no error. Step completes, `count: 0`, the
  playbook guard reports `deref_error`.
- **kind** (diagnostic build) — the `inspect` step **HANGS** after `DIAG(4)`.

## ⚠ Hypothesis: this may be noetl/worker#316, i.e. #316 is the ROOT

#316 (cross-pod shared-memory attach wedging a consumer indefinitely) was filed
as a separate layer and explicitly scoped OUT of #315/#317/#319. The kind hang
after `DIAG(4)` is the same shape: a consumer blocking while fetching an
already-identified result.

If the fetch path shares the shm attach, **#316 is not a side issue — it is the
actual root cause of the hydration failure**, and the three shape fixes were
always going to be insufficient. This is unproven and is the first thing the
next diagnostic should test.

## The ONE next diagnostic — precise

1. **Worker**, inside the `match fetched` arms of `resolve_context_references`:
   log the outcome explicitly — `Ok(Some(_))` with byte size, `Ok(None)`, or
   `Err(e)` with the error — plus elapsed time around the fetch call. Today all
   three outcomes are silent, which is why four cycles could not see this.
2. **Server**: instrument the resolve endpoint the `ControlPlaneClient` calls
   (`resolve_ref` / the object-store read) — request received, bytes returned,
   error. **The server has not been instrumented at all in this investigation.**

That answers: does the fetch return `None`, error, or block — and does the
server ever see the request?

⚠ Do **not** ship another shape/parsing fix. Three landed; all three correct;
none changed the outcome.

## Cost so far

- 4 release cycles (v5.132.1 → v5.132.4), each ~40 min build + canary
- 2 diagnostic builds
- The decisive evidence came from a **2-minute playbook probe** (excluded three
  layers) and **one instrumented build** (excluded two more)
- Next step requires instrumenting the **server**, a component not yet touched

## Merged and keeping

- **worker#315** predicate fix · **#317** locator gate (measurably works) ·
  **#319** depth-independent locator · **#318+#319** CI gate (live in `main`,
  caught two flaws in itself) · **travel#122** playbook fail-loud guard.
- **worker#316** open — now a *candidate root cause*, not out of scope.

## Final state

- **prod** — untouched this round. All workloads `sha256:6f20890b…51843`,
  `RUST_LOG=info,noetl_worker=info,noetl_executor=info`.
- **kind** — restored: `localhost/noetl-worker:265p2`, KEDA pin removed,
  `RUST_LOG` unset.
- **adiona/frontend#22** OPEN, failing loud · **#21** CLOSED.
