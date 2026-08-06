# RFC — should a provider error terminate the step?

**Decision needed from:** the user (semantics — changes retry and failure behaviour)
**Related:** [ai-meta#246](https://github.com/noetl/ai-meta/issues/246)
**Status:** open. The **measurement** half shipped (worker v5.107.0); this is
the half that was deliberately left alone.

---

## 1. The situation

A tool can return a **successful** `ToolResult` whose payload reports a
failure. MCP providers do this by convention: the transport worked, the
provider says "I could not do it", and that lives in the payload as the
MCP-standard `isError: true`.

Today the executor is blind to it. The run reports:

```
call.done          <provider>_dispatch   COMPLETED
command.completed  <provider>_dispatch   success
playbook.completed playbook              COMPLETED
```

with the real outcome — e.g. a 403 fetching a credential — buried in
`_meta.error`.

**This is not hypothetical.** Four production MCP providers were failing *every*
call for an unknown period and were read as healthy by every status-based
observer. They were found by reading result payloads by hand, and repaired on
2026-08-05.

**Already shipped:** `noetl_worker_tool_result_error_total` counts the
condition, keyed on `isError`, verified against live payloads for a working
provider (200) and a failing one (403) — both of which reported `COMPLETED`. So
the condition is now *visible*. What it should *do* is this decision.

## 2. Why it was not just fixed

Flipping `call.done` → `call.error` changes behaviour for **every tool**, not
just MCP providers, and it changes two things at once:

1. **Failure propagation** — the step fails, so the playbook's error path runs
   instead of the success path.
2. **Retry** — `call.error` feeds the retry machinery. A provider error would
   then be retried under whatever policy the step declares.

Those interact badly in one specific case (§4.2), which is the crux.

## 3. The options

### Option 1 — leave as-is (measure only)

| | |
| :-- | :-- |
| **Behaviour** | unchanged; the counter and WARN are the only signal |
| **Pro** | zero risk; already shipped; alertable today |
| **Con** | an execution that produced nothing still reports success. Downstream steps consume an error payload as if it were data — the failure surfaces later, somewhere less obvious, or not at all |
| **Blast radius** | none |
| **Reversibility** | n/a |

### Option 2 — terminal `call.error` on `isError`

| | |
| :-- | :-- |
| **Behaviour** | the step fails immediately; no retry |
| **Pro** | honest. A provider that could not do the thing did not do the thing |
| **Con** | **wrong for transient provider errors** — a 429 or a 503 is exactly what retry exists for, and this makes them permanent |
| **Blast radius** | every tool that returns a payload-level error; playbooks that currently "succeed" past provider failures would start failing (arguably correct, but it *is* a behaviour change on live playbooks) |
| **Reversibility** | flag-gated: good |

### Option 3 — `call.error`, retryable

| | |
| :-- | :-- |
| **Behaviour** | the step fails and is retried per its declared policy |
| **Pro** | correct for transient errors; matches how a transport-level failure behaves today |
| **Con** | **retries a permanent failure** — the credential 403 that motivated all this would retry the full policy on every call, multiplying load against a provider that will keep saying no. With four providers broken for days, that is a meaningful amount of pointless traffic |
| **Blast radius** | as Option 2, plus retry amplification |
| **Reversibility** | flag-gated: good |

### Option 4 — classify, then decide (recommended)

Treat the provider's own signal as the input it already is:

| provider signal | disposition |
| :-- | :-- |
| `_meta.status_code` 5xx, 429, or 0-with-timeout | **retryable** `call.error` |
| 4xx other than 429 — auth, permission, validation | **terminal** `call.error`, no retry |
| `code: credential_unavailable` (or any credential-class marker) | **terminal**, and worth its own metric label — it is an operator problem, not a data problem |
| no classifiable signal | Option 1 behaviour: count, warn, complete |

| | |
| :-- | :-- |
| **Pro** | the 403 case (permanent, operator-actionable) stops pretending to succeed *without* being retried into a storm; the 503 case retries |
| **Con** | most implementation work; depends on providers populating `_meta.status_code` consistently — true for the ones checked, unverified in general |
| **Blast radius** | narrower than 2 or 3: only classifiable errors change behaviour, and each class changes it in the direction that is right for that class |
| **Reversibility** | flag-gated, and can ship class-by-class |

## 4. Two things worth knowing before deciding

### 4.1 The predicate is settled

`isError` is an MCP protocol field and does **not** appear on success —
verified against live production payloads for both a working provider and a
failing one. The looser markers that accompany it (`status: "error"`,
`ok: false`) occur inside legitimate business payloads and would be noisy. So
"how do we detect it" is not part of this decision; only "what do we do".

### 4.2 The interaction that makes this non-obvious

The failure that motivated this — `credential_unavailable`, a 403 from Secret
Manager — is **permanent until a human acts**. Option 3 retries it. Option 2
fails fast but would also fail fast on a 503. Neither single answer is right for
both, which is precisely why Option 4 exists and why this was not swept in with
the metric.

## 5. Recommendation

**Option 4, shipped behind a default-off flag, starting with the credential
class only.**

Rationale: the credential class is the one with real production evidence behind
it, it is unambiguously permanent, and treating it as terminal cannot cause a
retry storm. Landing that slice first proves the classification plumbing on the
narrowest possible surface. Extend to 5xx/429 once the shape is settled.

**Whatever is chosen, keep the counter.** If Option 1 stands, it is the only
signal. If any of 2–4 ship, it becomes the before/after evidence that the change
did what was intended — and the natural alert (`rate(tool_result_error_total)`
by provider) is useful in every option.
