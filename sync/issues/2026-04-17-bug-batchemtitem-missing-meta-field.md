# Bug: BatchEventItem Missing 'meta' Field — Pre-existing Schema Mismatch

**Date**: 2026-04-17 (discovered during Fix #6 validation)
**Fix Commit**: 99c6ee8e
**Regression Source**: 20330b6 (Apr 15) — added `item.meta` merge but didn't update model
**Status**: Fixed
**Severity**: Critical (blocks all executions at event serialization)

---

## Summary

Commit 20330b6 (Apr 15, "preserve worker metadata in batch event processing") added code to
merge worker-sent metadata via `item.meta` in `noetl/server/api/core/batch.py:142`:

```python
meta = {
    ...,
    **(item.meta or {})  # <-- expects item.meta to exist
}
```

However, the `BatchEventItem` Pydantic model in `noetl/server/api/core/models.py` was never
updated to include a `meta` field, causing immediate failure on every batch event:

```
'BatchEventItem' object has no attribute 'meta'
```

All executions failed at the first step (`start`) when the worker tried to send events.

---

## Root Cause

Schema divergence: server code changes without corresponding Pydantic model update.

---

## Fix

Add `meta: Optional[dict[str, Any]] = None` field to `BatchEventItem`:

```python
class BatchEventItem(BaseModel):
    """A single event within a batch."""
    step: str
    name: str
    payload: dict[str, Any] = Field(default_factory=dict)
    actionable: bool = False
    informative: bool = True
    meta: Optional[dict[str, Any]] = None  # <-- added
```

Commit: **99c6ee8e**

---

## Impact

- All executions launched after 20330b6 (Apr 15 06:56 UTC) failed immediately at step 1.
- No workaround without patching.
- Pre-existing for ~2 days before discovery.

---

## Related

- Fix #6 (ccbf6f6f) validated during pool exhaustion testing on 2026-04-17.
- Uncovered alongside Fix #6 during execution 607051885635175300 launch.
