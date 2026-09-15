# Externalised-result hydration — definitive state of play

2026-09-15, end of session. **Read this first.** It supersedes the diagnosis in
`HYDRATION-FIX.md` and `CANARY-RESULT.md`, both of which propose causes that have
since been DISPROVEN by measurement.

## The symptom (unchanged)

A `kind: playbook` child whose result crosses the externalisation byte budget
delivers nothing to its parent. `muno/playbooks/hotel-cards` returns
**`count: 0`** while the HotelBeds child really fetched 5 hotels / 509 images /
67 rates (~215 KB). Silent: `status: success`, no error.

The playbook-side guard (noetl/travel#122, merged) now makes it **fail loud**:

```
deref_error: child <id> result was externalised (214813 bytes) and this read path
             returned only a _truncated sample; the payload lives in the result
             tier and is not hydrated here
```

## ✅ Three layers POSITIVELY EXCLUDED — measured, not inferred

Each was a hypothesis, each got a fix, each fix was correct, and **none of them
was the blocker**. Do not re-investigate these.

| layer | status | evidence |
|---|---|---|
| **Predicate** (`contains_summary_bulk` / `is_reference_stub`) | fixed, **not the cause** | noetl/worker#315, released v5.132.2, canaried → `count: 0` unchanged (exec `358309183893807104`) on an image confirmed to contain it (`worker_id: noetl-worker-rust-866c75c7c6-*`) |
| **Locator shape** (`reference_locators` fixed paths) | fixed, **not the cause** | #317 (v5.132.3) demonstrably WORKS — resolve metrics went 0 → 63-69/pod and `resolved over-budget result by URN step=hotelbeds_dispatch` appeared for the first time. Parent still `count: 0`. #319 then made it depth-independent |
| **`steps` population** | **NOT the cause** | probe exec `358337679496060928`: `steps` is a populated `dict` containing the parent step, with the locator present |

### The `steps["fetch"]` structure, verbatim (probe `358337679496060928`)

```json
{"context": {"call_index": 0,
             "command_id": "358337679496060928:fetch:358337683581313024",
             "result": {"context": {"data": {"_ref": "noetl://execution/358337687603650560/result/hotelbeds_dispatch/…"},
                                    "status": "success"},
                        "status": "success"}},
 "status": "COMPLETED"}
```

Locator at **`/context/result/context/data/_ref`**. No `_uri`.

This is exactly the fixture #319's recursive locator passes against
(`reference_locators_finds_the_locator_in_a_real_parent_steps_entry`), and
`steps` is an object — so **neither** early return in
`resolve_context_references` should fire, and at minimum a `ref kept as summary`
debug line should appear.

**None ever did.** On the v5.132.4 canary with debug enabled and confirmed live
(`map_cards` debug line present on the pod that ran it), there were **zero**
`resolved over-budget` and **zero** `kept as summary` lines for the parent step.

## ✅ BOTH original hypotheses also EXCLUDED (probe `358387099021352960`)

A diagnostic clone of hotel-cards (`muno/probe/hotel-shape` — prod playbook
untouched) dumped what `map_cards` sees at render time:

```
steps_ns_type             : dict
steps_ns_keys             : ['resolve_dates', 'search_hotels', 'start']
ref_paths_in_steps        : ['/search_hotels/context/result/context/data/_ref']
search_result_type        : dict
ref_paths_in_search_result: ['/_ref', '/data/_ref']
```

So at the consuming step, `steps` **is** an object, it **does** contain the
parent step, and the locator **is** at exactly the path the recursive search
handles. Every precondition for resolution is satisfied — and the v5.132.4
canary still logged nothing for `map_cards`.

That kills both:

1. ~~`resolve_context_references` never invoked on this path~~ — there is exactly
   ONE call site (`command.rs:478`) and it is on the common command path.
2. ~~Resolver runs before the `_ref` is injected~~ — the ref is present in the
   very namespace the resolver reads.

## ❓ The ONE surviving question — an ordering question about `render_context`

Static analysis found the decisive line:

```rust
ctx.variables = command.render_context.clone();   // command.rs:~443
```

`variables` is **server-supplied per command**. A probe can only observe RENDER
time, which is *after* line 478. The open question is whether
`command.render_context` carries `steps` **at dispatch**, or whether `steps` is
assembled/enriched between line 443 and render — after the resolver has already
run and returned.

The code comment at ~446 makes this plausible: the server **stopped** sending
parts of the context because persisting it "ballooned to 5MB", and the worker
"rebuild[s] them transiently here".

If `steps` is rebuilt after line 478, every observation is explained at once.

## ❓ The two surviving hypotheses (SUPERSEDED — see above)

1. **`resolve_context_references` is never invoked on the `kind: playbook`
   consume path.** Its only call site is `executor/command.rs:~478`. A
   child-playbook step may be dispatched through a different path that does not
   reach it. Consistent with total log silence.

2. **⭐ The timing hypothesis — it is invoked against an EARLY `variables` map,
   before the flat `_ref` is injected at render time.** The dump above is what
   the *template* sees; the resolver may run earlier, against a context that does
   not yet carry the locator. This explains every observation at once: the
   resolver runs (no error), finds nothing (no candidate, no log line), and the
   step later renders a `_ref` that arrived after the resolve attempt.

(2) is the better fit and should be tested first.

## The NEXT diagnostic — one targeted probe, not a fishing expedition

Instrument the **call site**, not the data:

- `executor/command.rs` at the `resolve_context_references(&mut ctx.variables, …)`
  call: log `step`, `tool_kind`, and **`ctx.variables.keys()`** immediately
  BEFORE the call.
- Inside the function, log on entry: whether `variables.get("steps")` is present,
  its type, and its key set.
- Log at BOTH early returns, distinguishing which fired.

That answers, in one run: *is the function called for a `kind: playbook` consume,
and does `variables` hold the locator at call time or only at render time?*

If `variables.keys()` at call time lacks `steps` (or `steps` lacks the child
entry) while the render-time dump has it, hypothesis (2) is confirmed and the fix
is a **sequencing** change, not another shape/parsing change.

⚠ Do **not** ship another shape fix. Three have landed; all three were correct
and none moved the needle. The remaining defect is about *when* or *whether*
resolution runs, not *what it can parse*.

## Merged and worth keeping

- **noetl/worker#315** — predicate fix. Necessary; proven reached by #317.
- **noetl/worker#317** — locator gate fix. **Measurably works** (metrics 0 → 63-69/pod).
- **noetl/worker#319** — depth-independent locator. RED→GREEN on the real prod fixture.
- **noetl/worker#318 + #319** — CI regression gate, live in `main`, auto-run by
  `cargo test --all-targets`. It caught **two false-negative flaws in itself**
  (indentation-trimming truncated a nested `fn`; the column-0 anchor missed
  `async fn`) — both erring in the reassuring direction.
- **noetl/travel#122** — playbook-side fail-loud guard. The reason any of this was
  diagnosable.
- **noetl/worker#316** — cross-pod shm hang, open, unrelated layer.

## ⚠ Method note for whoever picks this up

Four fix-release-canary cycles were spent, each validating one layer and
discovering the layer above was the blocker. The probe that finally excluded
three layers at once cost **two minutes** and no build, by binding the runtime's
own namespace from a playbook.

**Prefer a probe over a build.** A playbook can dump what a step actually
receives; that answered in minutes what four 40-minute release cycles did not.

## Final state

- **prod** — all workloads on `sha256:6f20890b…51843` (v5.132.1); debug reverted;
  no regression at any point in any canary.
- **kind** — original image `localhost/noetl-worker:265p2`, KEDA pause annotation
  removed.
- **adiona/frontend#22** — correctly OPEN. Hotels do not hydrate; provider-side
  wins are proven and the failure is loud.
- **adiona/frontend#21** — CLOSED, flights validated live.
