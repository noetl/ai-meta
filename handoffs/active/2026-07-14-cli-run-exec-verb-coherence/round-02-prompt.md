---
thread: 2026-07-14-cli-run-exec-verb-coherence
round: 2
from: claude
to: claude                             # future implementing session (post-4.19.0)
created: 2026-07-14T00:00:00Z
status: open                           # RATIFIED design — still design-only, no cli code this round
expects_result_at: round-02-result.md
wait_phrase: "coherence go"            # gate: NO cli code, branch, or PR until 4.19.0 lands AND this phrase is said
---

# RFC round 2 — RATIFIED model: `run ≡ exec ≡ execute` + `flag > context > local` ladder

> **Predecessor:** [`round-01-prompt.md`](round-01-prompt.md) — the read-only
> inspection + the three options. **The user has now chosen the direction.**
> This round makes it THE recommendation, spells out the precedence ladder
> with concrete commands, calls out the two ratification forks (A, B), proves
> the provider path survives, and gives the migration/blast-radius. Options in
> round 1 remain for context; this round is the chosen path.
>
> **Still design-only. No cli code, branch, worktree, or PR until cli 4.19.0
> has landed AND the human says `coherence go`.** The provider release chain
> (tools 3.26.0 → executor 0.8.0 → cli 4.19.0) owns cli right now.

## The chosen model, in one paragraph

There is **one way to run a playbook**, spelled three interchangeable ways —
`noetl run`, `noetl exec`, `noetl execute` — all the same code path, same
behavior. One is canonical; the other two are **deprecated-but-working**
aliases that print a soft one-line deprecation nudge (never an error, never
removed before the next major). Placement (local vs distributed/enqueue) is
**never** encoded in the verb; it is resolved by a strict precedence ladder:
**explicit `--runtime` flag → active context's runtime → default LOCAL.**
Every run echoes the resolved placement and its provenance so a stale context
can never silently enqueue what the user thought would run locally.

---

## Part 1 — the precedence ladder (the core of the RFC)

`resolve_runtime` (`repos/cli/src/main.rs:1612`) already implements
`flag > context > fallback`. The chosen model keeps rungs 1–2 and **changes
rung 3 from "auto-detect by reference type" to "LOCAL, always."**

### Rung 1 — explicit `--runtime` on the command line → ALWAYS wins

Per-invocation override, highest priority. This is the escape hatch.

```
noetl run ./foo.yaml --runtime local          → local        (rung 1)
noetl run catalog://foo@2 --runtime distributed → enqueue     (rung 1)
noetl exec ./provision.yaml --runtime local    → local        (rung 1)  ← provider path
```

Today: `resolve_runtime` returns the flag verbatim when `runtime_flag != "auto"`
(`main.rs:1619-1624`). **Unchanged.**

### Rung 2 — active context's runtime → wins IFF the context defines one

Switch context and it becomes the standing runtime for subsequent runs;
`--runtime` overrides it per-invocation.

```
noetl context set-runtime distributed          # standing choice
noetl run catalog://foo@2                       → enqueue      (rung 2, from context)
noetl --context prod run wf/etl                  → enqueue      (rung 2, from context 'prod')
noetl --context prod run wf/etl --runtime local  → local        (rung 1 overrides rung 2)
```

Today: rung 2 fires when `context_runtime` is `Some(x)` and `x != "auto"`
(`main.rs:1627-1634`). **Kept — but see Fork A for the "defines one" subtlety.**

### Rung 3 — default → LOCAL

No `--runtime` flag and no context (or the context defines no runtime) ⇒ run
locally. Rationale (user's words): *noetl is a CLI tool, so command-line/local
behavior is the priority default.*

```
noetl run ./foo.yaml            # no context set → local     (rung 3, default)
noetl run foo                    # no context set → local     (rung 3, default)
```

**This is the behavior change from today.** Currently rung 3 auto-detects by
reference type (`main.rs:1637-1646`): `File→local`, but
`Catalog/DatabaseId/CatalogPath→distributed`. Under the chosen model rung 3 is
**unconditionally `local`** — the reftype guess is removed. A catalog/db ref
with no server placement selected will attempt local and fail loudly with a
"local runtime requires a file path" error (`main.rs:2409-2414`), whose message
should be extended to say "…or select distributed with `--runtime distributed`
or a context." That failure is *better* than today's silent enqueue: it is
explicit and self-correcting.

**Document it exactly as standard `flag > context > default`.** No fourth
source exists: there is no `NOETL_RUNTIME` env var (grep confirms only
`NOETL_SESSION_TOKEN`/`NOETL_HOST`/`NOETL_PORT`/etc.), so the ladder is complete
and closed.

---

## Part 2 — Fork A (ratify): context defined but no `runtime` field

**Recommendation:** treat a missing runtime as **UNSET → fall through to rung 3
(local)**. Do NOT error, and do NOT force distributed just because a context
exists. The rule is precisely: *"the context's runtime wins iff it defines
one."*

### The real code gap (implementation risk — this is load-bearing)

`repos/cli/src/config.rs:8-12`:

```rust
pub struct Context {
    pub server_url: String,
    /// Default runtime mode: local, distributed, or auto
    #[serde(default = "default_runtime")]   // default_runtime() = "auto"  (config.rs:53-55)
    pub runtime: String,
    ...
}
```

`runtime` is a **`String`, not `Option<String>`**, with a serde default of
`"auto"`. Consequences the implementer must handle:

- A context YAML that **omits** `runtime:` deserializes to `runtime = "auto"`.
- A context YAML with **`runtime: auto`** also deserializes to `"auto"`.
- **The current representation cannot distinguish "context defines no runtime"
  from "context.runtime = auto".** Both are the string `"auto"`.

Good news: **"no context at all" IS cleanly distinguishable** — `effective_context`
returns `None` when there is no current context and no `--context` override
(unit test `effective_context_returns_none_when_no_current_and_no_override`,
`main.rs:8611`), so `context_runtime` is `None`, which already routes to the
fallback rung. The ambiguity is only *within* an existing context.

**Two clean ways to implement "defines one iff":**

1. **Sentinel (minimal diff):** keep `runtime: String` and treat `"auto"` as
   the sentinel for "unset → fall through to local." This works with today's
   representation and every existing `~/.noetl/config.yaml` on disk. Cost: a
   user can no longer pin a context to literal "auto = reftype-detect" — but
   that behavior is being **removed** anyway, so "auto" cleanly re-reads as
   "defer to default (local)." Recommended for round-1 of implementation.
2. **`Option<String>` (clean model, small migration):** change the field to
   `Option<String>`, map legacy `"auto"` → `None` on load, and let `None` mean
   "unset." Expresses the design intent exactly (None vs Some("local") vs
   Some("distributed")). Slightly more code + a load-time compat shim. Preferred
   as the durable shape; can be a fast-follow after the sentinel version.

**Report line for the user:** the ladder is implementable today via the "auto"
sentinel; the only *clean-model* gap is that `runtime` is a bare `String`, so
"undefined" and "auto" are the same value. Recommend migrating to
`Option<String>` (legacy `"auto"`→`None`) so "context defines a runtime" is a
first-class, unambiguous predicate. **This is the single real implementation
risk in the whole change.**

---

## Part 3 — Fork B (ratify): surprise-avoidance provenance echo

The one downside of context-carried runtime: a **stale context silently
enqueuing to distributed** when the user expected local. Design a **provenance
echo** — baked in, not opt-in.

**Recommendation:** every run prints exactly one line stating the resolved
runtime AND where it came from, to **stderr**:

```
runtime: local (default)
runtime: local (--runtime flag)
runtime: distributed (from context 'prod')
runtime: distributed (--runtime flag)
```

Design details the implementer must honor:

- **stderr, not stdout.** The `exec` handler already routes progress to stderr
  and, under `--json`, suppresses stdout progress so stdout is ONLY the
  `RunOutcome` envelope (`main.rs:2420-2436`). The echo MUST go to stderr so it
  never corrupts `--json` piping into `jq`.
- **Always on** (both local and distributed), so the line is a stable, greppable
  trace, not a scary warning that trains users to ignore it.
- Replaces the current behavior where the resolved runtime prints only under
  `--verbose` (`main.rs:1620-1645`) — promote it to unconditional.

**Higher-consequence path (distributed/enqueue) — keep it lightweight:**

- **Recommended:** the echo is enough by default. Do **not** add a blocking
  confirm to the default path — it would break every unattended/CI invocation
  and the provider automation.
- **Optional guard (surface as a sub-decision, default OFF):** a
  `--confirm-remote` / `--yes` opt-in that, only when stdin is a TTY and
  `--json` is NOT set, prompts before enqueuing to a *named remote* context.
  Scripts and `--json` never prompt. Ship it only if the user wants belt-and-
  suspenders; the echo alone satisfies the surprise-avoidance goal.

---

## Part 4 — provider / `exec --runtime local` path preserved (proof)

The org provisioning (the `2026-07-14-shastara-org-gcp-provision` thread, the
`repos/ops/automation/*` playbooks) drives provider playbooks with
**`noetl exec --runtime local`** plus the `--facts-out` JSONL sink and the
`provider {plan,drift,orphans,adopt}` verbs (in-flight cli 4.19.0).

**Proof it cannot break under this ladder:**

1. `--runtime local` is **rung 1** — always wins, above context and default. A
   stale context set to `distributed` cannot re-route it. Verified against
   `resolve_runtime` rung-1 short-circuit (`main.rs:1619-1624`).
2. The verb is `exec`, which stays a **working alias** (only a soft stderr
   deprecation nudge if `run` is chosen canonical — see Part 5). The command
   still executes; nothing functional changes.
3. The local in-process `PlaybookRunner` path (`main.rs:2405-2438`) and
   `--facts-out` are untouched by verb/ladder changes.
4. The provenance echo prints `runtime: local (--runtime flag)` — informational,
   on stderr, does not affect the `--facts-out` sink or any exit code.

**Migration nicety:** to avoid the ops automation emitting a per-run deprecation
nudge (if `run` becomes canonical), migrate the `repos/ops/automation/*`
call sites `noetl exec …` → `noetl run …` **in the same change set**. This
keeps provisioning output clean. It is a mechanical find/replace, not a
behavior change (see Part 6). The `run_commands` bridge, `noetl.yaml`,
`gcp_gke/`, and the automation READMEs are the call sites (grep:
`--runtime local` across `repos/ops`).

---

## Part 5 — canonical verb + deprecation

### Which verb is canonical? (recommendation + the entrenchment evidence)

The user leans `run` ("the run verb"); the evidence cuts slightly the other
way. Measured usage in the current tree:

| Surface | `run` | `exec` | `execute` |
| :-- | --: | --: | --: |
| `repos/cli/README.md` | 4 | 0 | 6 |
| `repos/noetl-cli-wiki` | 1 | 7 | 0 |
| provider/ops automation | — | dominant (`exec --runtime local`) | — |
| clap enum variant | alias | **`Commands::Exec` (canonical today)** | — |

**Recommendation: make `run` canonical anyway.** Reasoning from what the code
and users actually do:

- It is the verb the user names and reasons about, the shortest, and what a new
  user reaches for. The whole point of the change is a coherent *user* model.
- `exec`/`execute` staying **working aliases** means the entrenched docs and
  the provider path keep functioning — the only cost is a soft nudge, which the
  same-change-set doc/automation migration (Parts 4, 6) removes.
- The clap-level flip is trivial: `run` becomes the `Commands` variant name /
  primary, `exec` + `execute` become `alias = …` (today it is the reverse:
  `Exec` with `alias = "run"`, `main.rs:107`).

**Sub-fork for the user:** if avoiding ALL churn/warning-noise matters more than
the `run`-first naming, keep **`exec` canonical** (it already is) and make
`run` + `execute` the soft-deprecated aliases. Lower diff, zero provider-path
nudge, but loses the "run is the verb" framing. Flagged in Part 8.

### Deprecation shape

- Aliases are **deprecated-but-working**, never hard-removed before the next
  major. A single stderr line on use, e.g.:
  `note: 'exec' is a deprecated alias for 'run'; both work today, 'exec' will be removed in noetl 5.0`.
- Print the nudge **once per invocation, to stderr**, gated so `--json` runs
  stay clean (nudge still allowed on stderr, but keep it one line).
- Timeline: **deprecate now (4.2x minor), remove the aliases at 5.0 (major).**
  The already-hidden legacy verbs from round 1 (`run-legacy`, the `execute`
  *subcommand* group, top-level `status`/`list`) follow the same 5.0 removal —
  note `execute` the *subcommand group* (`ExecuteCommand`, `main.rs:660`) is a
  different surface from `execute` the run-alias; the alias is new, the
  subcommand group stays hidden-deprecated.

---

## Part 6 — migration + blast radius

- **Code (all in `repos/cli/src/main.rs` + `src/config.rs`):**
  - `resolve_runtime` rung 3: `File→local / others→distributed` becomes
    unconditional `local`; drop the `RefType` match (`main.rs:1637-1646`).
  - Rung-2 predicate: treat `"auto"`/unset as "does not define a runtime"
    (Fork A). Optionally migrate `Context.runtime` → `Option<String>`.
  - Promote the resolved-runtime line from `--verbose`-only to an unconditional
    stderr provenance echo (Fork B).
  - Flip canonical verb to `run`; `exec`/`execute` become soft-deprecated
    aliases with a one-line stderr nudge.
  - Extend the "local runtime requires a file path" error (`main.rs:2409-2414`)
    to mention `--runtime distributed` / context selection.
  - `PlaybookRunner` and `execute_playbook_distributed` are **unchanged**.
- **Versioning:** no `noetl-tools` / `noetl-executor` public-surface change →
  **CLI-only bump.** Ladder + echo + deprecation nudges = **minor (4.2x)**.
  Removing the aliases + hidden legacy verbs = **major (5.0)**.
- **Provider path:** preserved (Part 4). Only cosmetic: an extra stderr line.
- **Docs/wiki/examples that change (same change set):**
  - `repos/noetl-cli-wiki/` — run/exec/execute/context pages; document the
    ladder as `flag > context > default(local)` + the provenance echo; switch
    examples to `run`.
  - `repos/cli/README.md` — 10 verb usages; standardize on `run`.
  - `repos/ops/automation/*` — migrate `noetl exec --runtime local` → `noetl run
    --runtime local` (mechanical; keeps provisioning output nudge-free).
  - `agents/rules/` references to `noetl exec …` if any narrate the verb.
- **Observability:** CLI is not a service boundary, so no new metrics/spans
  required (`agents/rules/observability.md` fires on boundaries). The provenance
  echo is the user-facing trace.
- **Kind validation** (`agents/rules/deployment-validation.md`): a provider
  `noetl run … --runtime local --facts-out` smoke run confirms the sink still
  writes and the echo prints `runtime: local (--runtime flag)`; plus a
  distributed run against the kind server confirms `runtime: distributed (from
  context …)`.

---

## Part 7 — worked examples (the full truth table)

Assume no `--runtime` unless shown. "ctx" = active context's runtime.

| Command | ctx | Resolved | Echo (stderr) |
| :-- | :-- | :-- | :-- |
| `noetl run ./f.yaml` | none | local | `runtime: local (default)` |
| `noetl run foo` | none | local | `runtime: local (default)` |
| `noetl run catalog://x@1` | none | local → **errors** (needs file) | echo + "select `--runtime distributed`/context" |
| `noetl run ./f.yaml` | local | local | `runtime: local (from context 'dev')` |
| `noetl run wf/etl` | distributed | enqueue | `runtime: distributed (from context 'prod')` |
| `noetl run wf/etl --runtime local` | distributed | local | `runtime: local (--runtime flag)` |
| `noetl exec ./prov.yaml --runtime local` | anything | local | `runtime: local (--runtime flag)` + `note: 'exec' deprecated…` |
| `noetl run ./f.yaml` | ctx omits runtime | local (Fork A) | `runtime: local (default)` |

---

## Part 8 — FORKS the user must ratify

1. **Fork A — context with no runtime field:** RECOMMENDED = treat as unset →
   fall through to local default (do not error, do not force distributed).
   Implementation note the user should be aware of: the current `runtime:
   String` + serde-default-`"auto"` cannot distinguish "undefined" from
   `"auto"`; recommend the `"auto"`-as-sentinel shim now and an
   `Option<String>` migration for the clean model. **This is the one real code
   risk.**
2. **Fork B — provenance echo:** RECOMMENDED = bake in an always-on one-line
   stderr echo of resolved runtime + provenance. Sub-decision: add an optional
   `--confirm-remote`/`--yes` TTY-only guard for enqueuing to a named remote
   (default OFF; echo alone is likely enough). User picks whether the optional
   guard ships.
3. **Canonical verb (from Part 5):** RECOMMENDED = `run` canonical,
   `exec`/`execute` soft-deprecated working aliases. Sub-fork: keep `exec`
   canonical instead to minimize doc/automation churn and avoid any provider-
   path nudge. User picks `run`-first vs `exec`-first.
4. **Removal timeline:** RECOMMENDED = deprecate now (4.2x), remove aliases +
   hidden legacy verbs at 5.0. User confirms the major-version removal.

## Phases (for the implementing session — GATED)

### Phase A — read-only confirmation (unattended, after 4.19.0 lands)

1. Confirm cli pointer ≥ 4.19.0 and the provider chain merged.
2. Re-read `resolve_runtime`, `config.rs::Context`, the `Exec` arm, and the
   provider `--facts-out` path on current main (line numbers shift from v4.12.0).
3. Confirm the user's answers to the four forks in Part 8.

### Phase B — implement the ratified ladder

> ***Run only after explicit human go-ahead. Wait phrase: `coherence go`.***

4. Open the ai-task issue (`repo:cli`), add to board 3.
5. Implement rung-3-local, Fork A predicate, Fork B echo, verb-canonical flip +
   deprecation nudges in `repos/cli/src/main.rs` + `src/config.rs`.
6. `cargo build` + `cargo clippy` + unit tests: `resolve_runtime` for each rung
   + the provenance string, the Fork-A unset/auto/local/distributed matrix, and
   the `--json`-stays-clean-on-stdout invariant.
7. Kind smoke: provider `noetl run … --runtime local --facts-out` writes the
   sink + echoes local; a distributed run echoes the context provenance.
8. Migrate docs (`noetl-cli-wiki`, `README.md`) + ops automation call sites.
9. Open the PR citing the issue; bump ai-meta pointer + wiki + board in one
   change set.

## FINAL REPORT

Write `round-02-result.md` recording the ratified fork answers, the issue/PR,
and kind-validation output — or, if picked up before 4.19.0, status
`blocked: awaiting cli 4.19.0`.

## Hard rules for this thread

- **No cli code, branch, worktree, or PR touch until 4.19.0 lands AND the human
  says `coherence go`.** The provider release chain owns cli right now.
- Rust code → Claude writes it directly (`agents/rules/handoff-routing.md`).
- Never force-push; never merge PRs yourself. Public repo — no secrets.
- If preconditions aren't met, stop and report — don't improvise.
