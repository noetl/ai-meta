---
thread: 2026-07-14-noetl-python-wrappers
round: 4
from: claude
to: human
created: 2026-08-31
status: complete
tracks: noetl/ai-meta#201
---

# Closing — the retirement shipped, and the plan it was written against was wrong in one load-bearing way

## What this thread set out to do

Turn `repos/noetl` into a thin Python wrapper over the Rust ecosystem, and
retire the parallel Python implementation.

## What actually happened

**Both halves are done, but not in the order this thread assumed.**

The round-03 retirement analysis (2026-07-24) treated the **distribution
handover as the gate on everything else** — its whole sequencing rested on the
wrapper being unpublished. That was already false when it was written and stayed
false for five weeks: `packaging/pypi/` is a complete maturin/PyO3 wheel, and
**`pypi-v5.0.0` published successfully on 2026-07-26**. The legacy
`build_push_pip` job had been removed in `d68d1965` precisely so the two could
not collide.

⚠ **How that was missed matters more than the fact itself.** The audit that
re-derived this listed `.github/workflows/` from the *submodule working tree*,
which sat on a stale branch — so `pypi.yml` was invisible and
`build_on_release.yml` still looked like the PyPI publisher. The audit opened by
warning about that exact stale checkout and used a clean worktree for the
package analysis, then read the workflow directory from the dirty one. Guarding
one path and not the other is how it survived.

## Final state

| | |
| :-- | :-- |
| PyPI `noetl` | **5.0.0**, the maturin/PyO3 CLI wheel from `packaging/pypi/` |
| `noetl/noetl` contents | the wheel + `noetl/database/` (`schema_ddl.sql`) — nothing else |
| removed | `noetl#699`: 523 files, **132,650 deletions** (core, server, worker, tools, outbox, projector, claim_policy, 155 tests, 8 scripts, `docker/noetl`, the 43-package dependency list including `nats-py`) |
| image | `ghcr.io/noetl/noetl` no longer built (`noetl#698`) |
| DR path | closed by `ops#290` — ⚠ **not** by the deletion |

## The finding worth carrying forward

**Deleting source does not retire an artifact.** `ghcr.io/noetl/noetl:v2.8.9`
and `:latest` remain pullable, and the fresh-stack playbook *deploys a published
image* — it does not build one. Had only `#699` landed, a DR apply would have
stood a **second, Python stack beside the live Rust one** in namespace `noetl`,
under Deployment names that do not collide, so nothing would have been replaced
and nothing would have errored.

## Deliberately not done

* **No backfill.** Retirement removed code, not history.
* **`core/auth/ib_provider`** was deleted; its only consumer,
  `e2e validate_implementation.py`, guards all three imports with
  `try/except ImportError` and is run by no CI. It will now report ✗ and exit 1
  when run by hand — `noetl/e2e` should retire that script.
* **The DSL schema generator** was deleted. Its replacement is `noetl schema`
  (`cli#82`), generated from a Rust model — but see that PR for what it does
  **not** constrain.

Closing this thread. `noetl/ai-meta#201` carries anything left.
