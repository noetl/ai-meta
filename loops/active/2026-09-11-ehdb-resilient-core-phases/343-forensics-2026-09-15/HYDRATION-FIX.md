# The hydration gap — root cause and fix (noetl/worker#315)

Follows `EXTERNALISED-RESULT-DEREF.md`, which described the symptom. This is the
code-level cause and the fix.

## Where the code lives

- Consume path: `noetl/worker` `src/executor/command.rs` —
  `resolve_context_references` (2807) → `step_needs_bulk_resolution` (2925) →
  `accessor_paths` → `path_satisfiable` (3025) → `contains_summary_bulk` (3098).
- Resolver: `noetl/worker` `src/result_resolver.rs` (`resolve_by_urn`, gated by
  `NOETL_RESULT_URI_RESOLVE`, **already true on prod**).
- Read path (for contrast): `noetl/server` `src/handlers/events.rs:1817`
  `hydrate_result_references`.

**A consume-path resolver already existed.** Nothing needed to be built — the
gate in front of it was wrong.

## Root cause

`path_satisfiable` asks whether a step's bounded summary can answer the
template's bindings. A **whole-object bind** (`{{ step }}`,
`{{ step | default({}) }}`) yields an **empty accessor path**, so the loop never
runs and control falls straight to `contains_summary_bulk`.

`contains_summary_bulk` looked only for `_len` / `_truncated` / `_keys` /
`_count` markers and arrays. A reference container has none of them → "no
collapsed bulk" → satisfiable → **resolution never fires**. The step is handed a
bare `noetl://` reference and sees no data, with `status: success` and no error.

#104 Phase C added exactly this guard to the **absent-key** branch
(`!is_reference_stub(o)`, comment: *"without this an over-budget upstream is
never resolved on a bulk bind"*). Only attribute access reaches that branch. The
whole-object path was missed — the guard was written once and needed twice.

## A second instance, found by a test

`is_reference_stub` requires an object hold **only** locators. A real container
is `{_ref, extracted:{_truncated, data:{…}}}` — `extracted` is not a locator, so
the object was not recognised as a stub, and `{{ step.data.hotels }}` was
answered from the **truncated SAMPLE**: a handful of rows reported as the whole
answer. Silently wrong, and worse than empty.

Fixed by teaching `is_reference_stub` that `extracted` / `_truncated` / `meta` /
`ipc` / `kind` / `scope` are reference METADATA, not payload content.

⚠ Found only because a test asserted the truncated case. A first, broader
attempt ("any locator disqualifies the absent-key inference") broke the existing
`ref_and_scalar_access_does_not_force_resolution` — a key-preserving summary
legitimately carries injected locators at its top level. The narrower
metadata-key rule satisfies both.

## Trade direction

Resolving when not strictly needed costs one fetch. NOT resolving loses the
payload silently. Fail-safe is to resolve. Locator predicate access
(`{{ step._ref is defined }}`) still short-circuits — tested.

## Tests added

`whole_object_bind_of_a_reference_resolves`,
`whole_object_bind_of_a_small_inline_result_is_unchanged`,
`truncated_sample_is_never_treated_as_complete`,
`locator_predicate_access_still_does_not_over_resolve`.

Full worker suite: **766 passed, 0 failed.**

## Rollout — NOT done from a workstation

`release.yml` triggers on a **tag** and builds via **Cloud Build** into
`us-central1-docker.pkg.dev/<project>/noetl/noetl-worker-rust`. That is the path
with provenance (and what `RELEASE-LEDGER.md` exists to record). A laptop-built
image pushed to prod AR would bypass it.

**Sequence:** merge noetl/worker#315 → tag → CI publishes → roll the published
digest → re-run `muno/playbooks/hotel-cards` and confirm ~20 hotels with rooms
across price bands and full images.

Prod rollback digests captured 2026-09-15:

```
deploy/noetl-worker-rust                sha256:6f20890b8c22ec5c8a840670ace63dff0b9c8faeb9829b5981fa2ee5c5051843
deploy/noetl-worker-system-pool         (same)
deploy/noetl-worker-system-pool-shard1  (same)
sts/noetl-cmdbus-writer                 sha256:c13b2957999f0bc15fe56b91a3005e7bfecd16bbbf51135c3ee641f2510e7466
```

Rollback: `kubectl -n noetl set image deploy/<name> noetl-worker=<digest>`.

## Scope note

This is a correctness fix for **every** `kind: playbook` caller whose child
result crosses the externalisation floor, not just hotels. Per the RFC,
externalisation was ~1% of `call.done` events over 90 days — so the blast radius
is small but the failure is invisible where it lands.
