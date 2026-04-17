# Bug: LOOP-HYDRATE Falls Back to Re-rendering Cold Template — loop.done Epoch 2 Never Fires

**Date**: 2026-04-17  
**Execution**: 606899895592551035  
**Image**: local/noetl:arm64-e74fd9a9  
**Status**: Open  
**Precedes**: Bugs #1, #2, #3 are fixed and confirmed active in this run

---

## Summary

After fixes #1–#3 unblock the first and second `claim_patients_for_assessments` dispatches
and correctly derive epoch ID `loop_606899895592551035_fetch_assessments_2`, the
`fetch_assessments` loop epoch 2 still stalls. Workers claim individual `task_sequence`
items but `loop.done` for epoch 2 is never emitted.

---

## Observed Error

Server log (repeated ~18 times per task_sequence completion, epoch 2):

```
Message: [LOOP-HYDRATE] Failed to render loop collection for fetch_assessments
         epoch=loop_606899895592551035_fetch_assessments_2:
         'claim_patients_for_assessments' is undefined
```

Interleaved with:

```
Message: [CLAIM] Command 606899895592551035:fetch_assessments:task_sequence:606899963624161957
         claimed by worker-f5592505
Message: [CLAIM] Command 606899895592551035:fetch_assessments:task_sequence:606899963624161953
         claimed by worker-f5592505
```

---

## Fix #3 Confirmed Active

Epoch ID `loop_606899895592551035_fetch_assessments_2` was correctly generated (the `_2`
suffix proves the DB-derived attempt counter worked). Fix #3 (`e74fd9a9`) is active.

---

## Root Cause

### Loop collection template

`fetch_assessments` loop is defined in the playbook as:

```yaml
loop:
  in: '{{ claim_patients_for_assessments.rows }}'
  iterator: patient
```

### `_ensure_loop_state_for_epoch` cold-render path

`rendering.py` lines 160–177:

```python
collection: list[Any] = []
if existing_state and isinstance(existing_state.get("collection"), list):
    collection = list(existing_state.get("collection") or [])

if not collection:                                     # ← collection is empty on rebuilt state
    try:
        context = state.get_render_context(event)      # ← step_results not populated
        rendered_collection = self._render_template(step.loop.in_, context)
        collection = self._normalize_loop_collection(rendered_collection, step.step)
    except Exception as exc:
        logger.warning(
            "[LOOP-HYDRATE] Failed to render loop collection for %s epoch=%s: %s",
            ...
        )
if not collection:
    return existing_state                              # ← returns empty/stale state
```

### Why `claim_patients_for_assessments` is undefined

When the server processes a `fetch_assessments:task_sequence:XXX call.done` event, it
rebuilds `ExecutionState` from DB events. At that point `state.step_results` is populated
from the serialized state snapshot — but the loop collection for epoch 2 was initialized
in-memory when epoch 2's `claim_patients_for_assessments call.done` was first processed.
That in-memory state is not persisted into NATS KV's loop state entry; only
`completed_count` / `scheduled_count` / `loop_done_claimed` are stored.

So when `_ensure_loop_state_for_epoch` is called for a subsequent task_sequence event:

1. NATS KV lookup succeeds (nats_loop_state is found for epoch `_2`)
2. `existing_state.collection` is empty (cold rebuilt state, no persisted collection)
3. Falls back to re-rendering `{{ claim_patients_for_assessments.rows }}`
4. `state.step_results` does not contain `claim_patients_for_assessments` for this rebuild
   → `UndefinedError`
5. `collection` stays empty → returns `existing_state` with no collection
6. `completed_count` increments reach NATS KV correctly, but the in-memory loop_state
   has `collection_size = 0` or is entirely missing
7. `loop.done` threshold check (`completed_count >= scheduled_count`) cannot fire
   because `scheduled_count` was set from the empty hydration → epoch 2 stalls

---

## Code Pointers

| File | Line | Note |
|------|------|------|
| `noetl/core/dsl/engine/executor/rendering.py` | 160–177 | Cold-render fallback for loop collection |
| `noetl/core/dsl/engine/executor/rendering.py` | 125–204 | `_ensure_loop_state_for_epoch` full body |
| `noetl/core/cache/nats_kv.py` | `set_loop_state` | Only persists counts and flags, not collection |
| `tests/fixtures/playbooks/pft_flow_test/test_pft_flow.yaml` | ~368 | `in: '{{ claim_patients_for_assessments.rows }}'` |

---

## Fix Direction

The loop collection must survive state reconstruction. Two options:

**Option A (preferred) — Persist collection size in NATS KV**  
When `set_loop_state` (or the initial `init_loop`) is first called for an epoch, store
`collection_size = len(collection)` in the NATS KV entry alongside `scheduled_count`.
In `_ensure_loop_state_for_epoch`, if re-rendering fails, fall back to
`nats_loop_state["collection_size"]` to reconstruct a synthetic collection
(e.g., `list(range(collection_size))`) so `loop.done` threshold math works correctly.

**Option B — Persist full collection in NATS KV**  
Serialize and store the full collection list in NATS KV. Avoids re-rendering entirely but
increases KV entry size for large batches (100 patients × payload = non-trivial).

Option A is safe: `collection_size` is a single integer; the items themselves are not
needed after the loop is dispatched (each task carries its own `patient` payload).

---

## Exit Criterion

Execution with all four fixes should emit:

```
[LOOP-HYDRATE] Restored loop collection for fetch_assessments epoch=loop_..._2 from NATS KV collection_size=100
```
(or equivalent), followed by `loop.done` for epoch 2, followed by progression through
remaining assessment batches until `mark_facility_processed` / `validate_all_results` /
`check_results` / `end` complete.

---

## Chain Summary (updated)

| # | Commit | Bug | Fix |
|---|--------|-----|-----|
| 1 | `0d380689` | NATS KV `max(existing, incoming)` preserves old epoch's `completed_count=100` | `force_replace=True` overwrites entry |
| 2 | `79abbdee` | Async batch acceptance lag makes `completed_steps` stale → re-entrant step suppressed | DB authority check before suppression |
| 3 | `e74fd9a9` | Epoch ID `loop_..._1` reused → `uidx_event_loop_done_loop_id` silently deduplicates 2nd `loop.done` | Derive attempt = `COUNT(loop.done) + 1` from DB |
| 4 | TBD | `_ensure_loop_state_for_epoch` cold-render fallback uses `step_results` that are absent on rebuilt state → collection empty → `loop.done` epoch 2 never fires | Persist `collection_size` in NATS KV; fall back to synthetic collection on re-render failure |
