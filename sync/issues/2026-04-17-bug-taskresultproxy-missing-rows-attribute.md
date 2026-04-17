# Bug: TaskResultProxy Missing 'rows' Attribute Access in Template Rendering

**Date**: 2026-04-17 (discovered during Fix #6 & batch event model fix validation)
**Execution**: 607054456953242533
**Status**: Open
**Component**: `noetl/core/dsl/render.py`, TaskResultProxy class

---

## Summary

During execution 607054456953242533, after 14 steps completed, template rendering fails with:

```
Template rendering error: 'noetl.core.dsl.render.TaskResultProxy object' has no attribute 'rows'
(template_len=54)
```

This error repeats for subsequent steps that depend on results from earlier steps. The execution stalls
because playbook templates cannot access result data via the `.rows` attribute expected on step outputs.

---

## Observed Error

Server log — render.py:

```
2026-04-17T13:52:12.852502 [ERROR] /opt/noetl/noetl/core/dsl/render.py:299
Message: Template rendering error: 'noetl.core.dsl.render.TaskResultProxy object' has no attribute 'rows'
(template_len=54)
```

Repeats many times in quick succession for different template lengths (41, 39, 54).

---

## Context

Execution 607054456953242533 was launched with:
- Fix #6 (99c6ee8e) — dedicated background pool + main pool=32
- Batch event model fix (99c6ee8e) — added missing `meta` field
- Image: `local/noetl:arm64-99c6ee8e`

Both prior fixes allowed the execution to progress past the initial step (where previous test
failed due to BatchEventItem.meta). Now hitting template rendering issue at step 14+.

---

## Likely Cause

`TaskResultProxy` class in `noetl/core/dsl/render.py` does not expose (or proxy) the `.rows`
attribute from the underlying task result. Templates reference result data like:

```yaml
in: '{{ some_prior_step.rows }}'
```

But `TaskResultProxy` either:
- Doesn't proxy `__getattr__` to the underlying result
- Has a bug in its attribute delegation logic
- Was refactored to use a different attribute name (e.g. `data`, `items`)

---

## Reproduction

1. Launch `tests/fixtures/playbooks/pft_flow_test/test_pft_flow`
2. Wait for execution to reach steps that reference prior step results (e.g. `claim_patients_*`, `fetch_*` tasks)
3. Observe template rendering errors on `.rows` access

---

## Proposed Fix

1. Check `TaskResultProxy.__getattr__` implementation in `noetl/core/dsl/render.py`
2. Verify it correctly delegates to the underlying result object
3. If refactored, update all playbook templates to use the new attribute name
4. Add test coverage for TaskResultProxy attribute access

---

## Files to Review

| File | Reason |
|---|---|
| `noetl/core/dsl/render.py` | TaskResultProxy definition and `__getattr__` |
| `tests/fixtures/playbooks/pft_flow_test/test_pft_flow.yaml` | Uses result.rows in templates |
| Any playbook using result data | Check attribute references |
