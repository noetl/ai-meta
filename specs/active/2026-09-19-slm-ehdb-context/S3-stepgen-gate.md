---
spec: 2026-09-19-slm-ehdb-context-S3
status: draft
created: 2026-09-19T00:00:00Z
owner: claude-opus-5 (ai-meta session 2026-09-19)
---

# S3 — Propose → validate → admit, with all five gates

Phase of [`spec.md`](spec.md). **Planning only.** Depends on **S2**.
**Forks settled by the owner 2026-09-19: F2 = catalog entry (APPROVED); F4 = the
`propose` arm is the ACTIVE default and execution is owner-gated.**

## Scope

Let the model propose a step spec; validate it against the DSL schema; apply the
policy allowlist, the human gate, the budget and the credential bound; admit or
reject with an event either way. Then run an admitted step using only the
primitives §2.3 of the plan verified.

**In scope:** the five gates, the admission events, the register→call path.
**Out of scope:** recursion beyond `NOETL_SLM_MAX_DEPTH`, compaction, replay.

## Flags

| Flag | Values | Default |
| :-- | :-- | :-- |
| `NOETL_SLM_STEPGEN` | `off` \| `propose` \| `on` | `off` |
| `NOETL_SLM_ALLOWED_TOOL_KINDS` | csv | `python,http,noop` |
| `NOETL_SLM_HUMAN_GATE` | `off` \| `required` | `required` |
| `NOETL_SLM_MAX_GENERATED_STEPS` | int | `8` |
| `NOETL_SLM_MAX_DEPTH` | int | `2` |
| `NOETL_SLM_MAX_TURNS` | int | `16` |

`propose` = emit `slm.step.proposed` + validate + emit admitted/rejected, but
**never execute**. `on` executes admitted steps. The intermediate arm exists so
the rejection rate can be measured before anything runs.

## The five gates

1. **DSL schema validation.** ⭐ **VERIFIED callable — the ASSUMED row is
   resolved.** `parse_playbook` (`parser.rs:15`) and `validate_playbook`
   (`parser.rs:164`) are **both `pub`**, so no HTTP dry-run fallback is needed.
   The gate takes an injected `DslValidator` trait; `ehdb-slm-context` never
   grows a DSL opinion of its own. Two validators that disagree is worse than
   one that is strict.
2. **Tool-kind allowlist.** A generated step may use only listed kinds. The
   registry has **VERIFIED** 20 kinds (`repos/tools/src/tools/mod.rs:90–109`);
   the default admits 3.
3. **Human gate** for any kind off the allowlist. Reuses the callback/hook
   pattern (`agents/rules/execution-model.md`) so no worker slot is held while a
   human decides.
4. **Budget.** Three independent bounds, all in the fold's `Budget`. Exhaustion
   emits `slm.budget.exhausted` and terminates — a recorded terminal state, never
   a silent stop.
5. **No credential reach.** No `auth:` block on a generated step; no keychain
   alias outside an allowlist. ⭐ `agents/rules/no-default-connection.md` means a
   credentialed step with no `auth:` is **already refused by the worker** — gate 5
   makes that explicit instead of relying on it incidentally.

## The execution path

Composes only verified primitives — no new one:

```
slm.step.admitted
  └─> POST /api/catalog/register        repos/server/src/handlers/catalog.rs:49  (VERIFIED)
        └─> tool: playbook, path templated  repos/tools/src/tools/playbook.rs:99 (VERIFIED)
              └─> ordinary execution, ordinary events
```

**ASSUMED** the register payload can carry a content digest for provenance; D7's
key is "catalog id / path" (§0.1) so digest-addressing may need to ride in the
payload. S3 checks `catalog.rs` rather than assuming.

## Acceptance criteria

- **A1** — `off`: no proposal path reachable; event stream unchanged.
- **A2** — `propose`: every proposal yields exactly one admitted **or** one
  rejected event. Never both, never neither.
- **A3** — an invalid spec (bad kind, missing required field, malformed loop) is
  rejected, and `slm_step_rejected_total{rule}` increments with the rule label.
- **A4** — a side-effectful kind with `NOETL_SLM_HUMAN_GATE=required` is **not**
  admitted without an approval event.
- **A5** — the loop terminates under each of the three bounds independently.
- **A6** — a generated step carrying `auth:` is rejected by gate 5.

## Instrument

`slm_step_proposed_total`, `slm_step_admitted_total`,
`slm_step_rejected_total{rule}`, `slm_budget_exhausted_total` — all **pinned at
0** for every known `rule` value, because a pinned set that omits one value
reintroduces the absent-series bug on that value alone while the rest read 0 and
look complete.

## RED→GREEN control

Four planted defects, because one control cannot cover five gates:

| Plant | Expected RED |
| :-- | :-- |
| make the validator always return `Ok` | A3 fails; rejection counter stays 0 against known-bad input |
| drop a kind from the allowlist check | A4 fails; a `postgres` step admits |
| decrement the budget by 0 | A5 fails; the loop does not terminate |
| ignore the `auth:` check | A6 fails |

⚠ **Run the battery against a baseline that is green first.** A red baseline
makes every mutant read CAUGHT and throws away the whole result.

## Rollback

Flag to `off`. Admitted-but-unexecuted catalog entries are inert; a cleanup pass
may soft-delete them (catalog soft delete is **VERIFIED live** per the memory
index, reversible via `POST /api/catalog/restore`).

## Exit criteria — ◐ PROPOSE-ONLY MET; execute-mode is the owner gate

**Landed:** `noetl/ehdb` branch `feat/slm-context-s3-propose-gate`, commit
`a3ac326`, module `gate`. 21 tests (43 in the crate).

⛔ **Nothing executes, and not because a flag says so.** There is no execution
path in the crate — no function registers a catalog entry, runs a step, or does
I/O. `StepGenMode::Execute` parses and behaves as `Propose`;
`Admission::executed` is always `false`, asserted.

Met: A1 (`off` considers nothing), A2 (exactly one outcome per proposal, across
every gate), A3 (rejection carries a countable rule), A4 (side-effectful kinds
await approval and are **not** admitted), A6 (`auth:` refused however nested).
A5's three bounds are enforced by the gate reading the fold's `Budget`.

RED→GREEN, six plants, revert verified after each. ⭐ P5 — setting
`executed: true` — fails exactly `nothing_executes_even_in_execute_mode`, which
is what makes the owner gate load-bearing rather than declarative.

**The only remaining work is flipping execute-mode on**, which needs:
1. the owner's explicit confirm (especially for `python`);
2. `DslValidator` implemented in `noetl-server` over the two `pub` parser fns;
3. the register→call path wired (`catalog.rs:49` → `playbook.rs:99`);
4. ⚠ **a tagged `ehdb` release** — `noetl-server` pins ehdb by TAG
   (`Cargo.toml:106-107`, `v0.2.0`), so it cannot consume a branch.
