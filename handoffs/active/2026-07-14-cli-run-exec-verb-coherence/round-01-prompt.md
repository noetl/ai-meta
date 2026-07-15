---
thread: 2026-07-14-cli-run-exec-verb-coherence
round: 1
from: claude
to: claude                             # future implementing session (post-4.19.0)
created: 2026-07-14T00:00:00Z
status: open                           # RFC / design brief — no code shipped in this round
expects_result_at: round-01-result.md
wait_phrase: "coherence go"            # gate: NO cli code, branch, or PR until 4.19.0 lands AND this phrase is said
---

# RFC: coherent `run` / `exec` / `execute` verb model for noetl-cli

> **This is an RFC (design-only), not a dispatch to implement.** It was
> produced by a read-only inspection of `repos/cli` at pointer **v4.12.0**
> (HEAD `5f39e54`) plus the provider branches (`feat/provider-*`) that are
> being released **right now** as the 3.26.0 → executor 0.8.0 → cli 4.19.0
> chain. **Do not touch cli code, branches, or worktrees until 4.19.0 has
> landed and the human says the wait phrase.** The options below are for
> the user to choose between; the implementing session picks one, opens an
> ai-task issue, and does the work in the cli repo directly (Rust → Claude
> writes it, per `agents/rules/handoff-routing.md`).

## The user's problem, verbatim intent

> NoETL's CLI has grown confusing, overlapping verbs for running a
> playbook. `run` was meant to be an alias for `exec`/`execute`, but two
> verbs were introduced to differentiate (a) running a playbook LOCALLY in
> the CLI vs (b) submitting it to the EXECUTION QUEUE in the distributed
> runtime. Later, **context** was introduced, and a context carries a
> **runtime definition** — so the local-vs-distributed choice arguably
> belongs to the context/runtime, not the verb. But the overlapping verbs
> remain. Fix it into a coherent model.

The good news, established below from the source: **the code has already
done ~80% of this unification.** `run` really is just an alias of `exec`
today; the old differentiating verbs are already hidden + marked
deprecated; and `context.runtime` is fully wired with a clean precedence
rule. What remains is (1) two vestigial hidden verbs that still work,
(2) a *silent* placement guess, and (3) vocabulary drift across the local
/ distributed axis. This RFC finishes the migration the code started.

---

## Part 1 — the ACTUAL current verb surface

All citations `repos/cli/src/main.rs` unless noted. Line numbers are from
pointer v4.12.0 (`5f39e54`); the in-flight 4.19.0 work is additive and
does not change these arms.

### 1. `exec`  (visible; alias `run`) — THE unified command

- Defined `Commands::Exec` at **main.rs:108**; doc-comment "Execute a
  playbook (unified command for local and distributed execution)"
  (main.rs:87).
- **`run` is a TRUE clap alias, not a separate verb:**
  `#[command(verbatim_doc_comment, alias = "run")]` (**main.rs:107**).
  `noetl run …` and `noetl exec …` hit the identical handler. The user's
  memory that "run vs exec were two verbs to differentiate local vs
  distributed" is **false in current code** — that differentiation now
  lives in `--runtime`, not in the verb.
- Flags: `-r/--runtime` default `"auto"` (114-115), `-t/--target`
  local-only (118), `--set KEY=VALUE` (122), `--payload`/`--workload`
  (126), `-i/--input` JSON file (130), `-V/--version` (134),
  `--endpoint` (138), `-v/--verbose` (142), `--dry-run` (146),
  `-j/--json` (150).
- Handler **main.rs:2347-2485**. After `resolve_runtime` (below):
  - `"local"` → in-process `PlaybookRunner` (main.rs:2405-2438). No server
    required. `--json` emits a structured `RunOutcome` envelope on stdout.
    Local runtime **requires a file path** ref — catalog/db refs error
    (2409-2414).
  - `"distributed"` → `execute_playbook_distributed(...)` = POST to the
    server / gateway proxy (main.rs:2440-2476). This is the **enqueue to
    the execution queue** path.

### 2. `run-legacy`  (HIDDEN; deprecated) — the OLD `run`

- `Commands::RunLegacy`, `#[command(name = "run-legacy", hide = true)]`
  (**main.rs:211**), doc "Legacy run command (deprecated, use 'exec')"
  (main.rs:210).
- **Distinct code path**, handler **main.rs:2522+**. Differs from `exec`:
  when `--runtime auto` it falls back to context-or-**`"local"`**
  (main.rs:2535-2536) rather than reftype auto-detect; takes
  `trailing_var_arg` args (222); has a `--merge` flag (234).
- This is the historical "`run` = default local" verb. It is the thing the
  user remembers. It is already hidden and superseded by `exec`.

### 3. `execute <subcommand>`  (HIDDEN; deprecated) — the OLD distributed submit

- `Commands::Execute`, `#[command(hide = true)]` (**main.rs:341**), doc
  "Legacy execution management (use 'exec' instead)" (main.rs:340).
- `ExecuteCommand` enum (**main.rs:660**): `playbook <path>` (667,
  distributed submit), `rerun <execution_id>` (684), `status
  <execution_id>` (701). Handler **main.rs:2671+**. **Distributed-only**
  (always POSTs to the server).
- This is the historical "`execute` = distributed" verb the user
  remembers. Already hidden and superseded by `exec --runtime distributed`.

### 4. Top-level legacy shims

- `status <execution_id>` (**main.rs:290**), doc "legacy command, use
  'execute status' instead" (285).
- `list <type>` (**main.rs:327**), doc "legacy command, use 'catalog list'
  instead" (321).

### 5. `subscribe <spec>`  (visible) — event listener, overlapping vocab

- `Commands::Subscribe` (**main.rs:169**). Turns each received message into
  one playbook run. Flag **`--dispatch local|server`** default `"local"`
  (**main.rs:175**): `local` → in-process `PlaybookRunner`; `server` →
  `POST /api/execute`.
- **Terminology drift:** this is the *same* local-vs-distributed axis as
  `exec`, but spelled `--dispatch {local, server}` instead of
  `--runtime {local, distributed}`. Two flags, two value vocabularies, one
  concept.

### 6. `provider {plan,drift,orphans,adopt}` + `--facts-out`  (in-flight 4.19.0)

- NOT in the v4.12.0 checkout. Lives on `feat/provider-org-guard` (the
  `.worktrees/cli-r5` worktree, being released now). Verbs shipped cli
  4.17.0 (`ca7e19b`); `--facts-out` JSONL state sink is `41028b3`
  ("git-backed state sink — --facts-out JSONL append + JSONL read").
- The provisioning path runs provider playbooks through the CLI's **local
  runtime** (`noetl exec --runtime local …`) and writes facts to the
  `--facts-out` sink. **Any verb change MUST keep `--runtime local` working
  and highest-precedence** (see Part 4).

**Summary:** three functional ways to run a playbook today — `exec`
(+`run` alias), hidden `run-legacy`, hidden `execute playbook`. Only one is
visible. `run` is an alias, not a verb.

---

## Part 2 — the context + runtime model (fully wired, not aspirational)

### Context carries a concrete runtime

- `repos/cli/src/config.rs:8` `struct Context` has field
  **`pub runtime: String`** (config.rs:9-12) with
  `#[serde(default = "default_runtime")]`; `default_runtime()` returns
  **`"auto"`** (config.rs:53-55). So yes — **a context really does carry a
  runtime definition, and it is persisted to the config file.** This is
  wired, not "supposed to."
- Set/managed via: `context add --runtime` default `"auto"`
  (main.rs:1181-1182); `context bootstrap --runtime` default
  `"distributed"` (main.rs:1238-1239, reads the gateway runtime contract);
  `context update --runtime` (1259-1261); `context set-runtime <mode>`
  (1305-1313).
- Global **`--context <name>`** override (main.rs:68-83): borrows that
  context's `server_url`, `runtime`, Auth0 settings, and cached token for
  one command — kubectl `--context` / gcloud `--account` UX.

### Precedence rule — `resolve_runtime` (main.rs:1612-1647)

```
1. --runtime flag, if != "auto"        → flag wins            (1619-1624)
2. else context.runtime, if != "auto"  → context wins         (1627-1634)
3. else auto-detect by REFERENCE TYPE  → guess                (1637-1646)
       File(_)        → "local"
       Catalog{…}     → "distributed"
       DatabaseId(_)  → "distributed"
       CatalogPath(_) → "distributed"
```

This is a clean, correct precedence: **explicit flag > context > default.**
It is NOT the problem. The redundancy of "`--runtime local` AND a context
runtime both answering placement" is intentional and kubectl-shaped.

**The problem is tier 3.** When neither flag nor context pins placement
(both `"auto"`), the CLI *silently guesses* from the ref type — and only
prints the choice under `--verbose` (main.rs:1643-1645) or `--dry-run`.

---

## Part 3 — the precise incoherence (where a user gets confused)

1. **Silent placement guess (the sharp one).** Same verb, opposite
   placement, invisible:
   - `noetl run ./foo.yaml`  → File → **local** (runs in your terminal, no
     server, no queue).
   - `noetl run catalog://foo@1`  → Catalog → **distributed** (enqueues to
     the server).
   - `noetl run foo`  → resolves to `CatalogPath` (main.rs:1600-1605) →
     **distributed**, *unless* `./foo.yaml`/`foo.yaml`/`automation/foo.yaml`
     happens to exist on disk (main.rs:1551-1582), in which case → File →
     **local**.

   Typing `noetl run foo`, **you cannot tell whether it ran locally or
   enqueued** without `--verbose`/`--dry-run`. Placement depends on ref
   shape *and* what files exist in your CWD.

2. **Two vestigial verbs still work.** `run-legacy` and `execute playbook`
   are hidden but fully functional, with subtly different semantics
   (`run-legacy` auto→local; `execute` always distributed). Muscle memory
   and old scripts keep them alive; they contradict the "one unified verb"
   story.

3. **Vocabulary drift on the one axis.** The local-vs-distributed choice is
   spelled three ways: `exec --runtime {local,distributed,auto}`;
   `subscribe --dispatch {local,server}`; and `execute` (verb =
   implicitly distributed). Three surfaces, two value vocabularies
   (`distributed` vs `server`) for one concept.

4. **The user's own mental model is stale-but-fixable.** They remember "run
   = local verb, execute = distributed verb." The code already replaced
   that with "one verb, `--runtime` picks placement." The confusion is that
   the old verbs still exist AND the new verb guesses silently — so neither
   the old model nor the new model is cleanly true.

---

## Part 4 — interaction with the provider local-mode work (MUST NOT ORPHAN)

The provisioning path (`repos/ops` automation, the shastara-org GCP
provision handoff) drives provider playbooks with **`noetl exec --runtime
local`** and the **`--facts-out`** JSONL sink. Load-bearing invariants any
option must preserve:

- **Explicit `--runtime local` stays highest precedence** (tier 1 of
  `resolve_runtime`). Provisioning must never be re-routed to distributed
  by a context default.
- **The local in-process `PlaybookRunner` path** (main.rs:2405-2438) stays
  intact and reachable by whatever the surviving verb is.
- **`--facts-out`** and the `provider {plan,drift,orphans,adopt}` verbs
  (in-flight 4.19.0) stay on the local runtime.
- Because this path passes an **explicit flag**, Options A and C below
  leave it untouched. **Option B (verb encodes placement) requires
  migrating every `exec --runtime local` call site to the new local verb**
  — a real, if mechanical, cost.

---

## Part 5 — design options (pick ONE; this is the deliverable)

Common to all: no change to `noetl-tools` or `noetl-executor` public
surface → **CLI-only version bump.** All work is in
`repos/cli/src/main.rs` (clap enum + handlers + `resolve_runtime`) plus
docs. `PlaybookRunner` and `execute_playbook_distributed` are unchanged.

### Option A — One verb, placement orthogonal, guess made LOUD (lowest blast)

- **Verb:** `run` is the one visible verb. `exec` stays as a hidden alias
  (it already is). `run-legacy`, `execute *`, top-level `status`/`list`
  become hidden **deprecated shims that print a one-line warning** to
  stderr pointing at the replacement, for two minor releases, then removed.
- **Placement:** keep the precedence `--runtime` flag > `context.runtime` >
  auto-detect — but **make tier-3 non-silent**: always print
  `→ running locally` / `→ enqueuing to <server_url>` to **stderr**
  (today it only prints under `--verbose`). Add `--local` / `--remote` as
  ergonomic sugar for `--runtime local` / `--runtime distributed`.
- **Vocabulary:** make `{local, distributed}` the one vocabulary; accept
  `subscribe --dispatch server` as a deprecated alias of `distributed`.
- **Commands a user types:**
  - `noetl run ./foo.yaml`            → prints `→ running locally`, runs
  - `noetl run catalog://foo@1`       → prints `→ enqueuing to …`, submits
  - `noetl run foo --local`           → forces local
  - `noetl exec --runtime local …`    → unchanged (provider path)
- **Breaks:** almost nothing. Bare invocations behave identically; they
  just announce placement now. Deprecated verbs still work (with a
  warning).
- **Deprecation/timeline:** warnings now (4.2x); hard-remove `run-legacy` +
  `execute` + top-level `status`/`list` at **5.0**.

### Option B — Verb encodes placement (crisp; matches the user's original intent)

- **Verbs:** `noetl run` = **always local** (in-CLI interpreter);
  `noetl submit` = **always enqueue** to the server. The verb IS the
  placement; `--runtime` is removed (or demoted to a deprecated no-op with
  a warning). `context.runtime` becomes a hint that picks the *default
  verb* when a user types the ambiguous legacy `exec`.
- **Commands a user types:**
  - `noetl run ./foo.yaml`            → always local
  - `noetl submit catalog://foo@1`    → always enqueue
  - `noetl submit ./foo.yaml`         → register + enqueue the local file
- **Breaks (largest):**
  - `noetl run catalog://x` (today auto→distributed) becomes local-only and
    **errors** (local needs a file). Behavior change for anyone relying on
    auto.
  - **Provider migration required:** every `noetl exec --runtime local`
    call site (ops automation, provisioning scripts) must become
    `noetl run`. `exec` must be kept as a compatibility verb honoring
    `--runtime` through the whole deprecation window, because `exec`'s
    correct target is ambiguous (its `--runtime local` sense → `run`, its
    default/distributed sense → `submit`).
- **Deprecation/timeline:** `exec`/`execute`/`run-legacy` kept as
  compat verbs honoring `--runtime` with warnings; remove at 5.0. This is
  the most faithful to "two verbs differentiate local vs distributed" — but
  it re-introduces two verbs, which is arguably what the user wants to
  *stop*. Read the intent carefully before choosing this.

### Option C — One verb = intent; placement lives ENTIRELY in the context

- **Verb:** `noetl run <ref>` is the only verb (exec hidden alias).
- **Placement:** comes from the active context's `runtime`. `--runtime`
  kept strictly as a *per-invocation override* ("override the context"),
  not a co-equal source. **Remove tier-3 reftype-guess**; instead
  **every context has a concrete runtime** — ship a built-in `local`
  context (runtime=local) and a `default` context (runtime=distributed);
  `context bootstrap` already defaults distributed (main.rs:1238-1239).
- **Commands a user types:**
  - `noetl --context local run ./foo.yaml`   → local
  - `noetl run catalog://foo`                → context's runtime decides
  - `noetl run ./foo.yaml --runtime local`   → override
- **Breaks:** users with no context configured need a sensible built-in
  default. A `default` context of `distributed` + a `File` ref would try to
  enqueue a local file (warns today) — pair with a clear error suggesting
  `--context local` or `--runtime local`. Provider path keeps working via
  the explicit `--runtime local` override (or switches to
  `--context local`).
- **Deprecation/timeline:** same shim treatment as Option A. This is the
  most faithful to "the placement choice belongs to the context/runtime,
  not the verb."

---

## Part 6 — RECOMMENDATION

**Option A, with the tier-3 guess made loud, plus C's "give the built-in
contexts a concrete runtime" as a follow-on.** Argued from what the code
actually shows, not from a prior:

1. **The code already chose "one verb, placement orthogonal."** `exec` is
   documented as "unified," `run` is already its alias, and both old
   differentiating verbs are already `hide = true` + "deprecated." Option A
   *finishes the migration that is already 80% shipped* rather than
   starting a new verb scheme. Lowest risk, smallest diff, no re-education.
2. **The only genuinely confusing behavior is the silent guess**, and it
   has a one-line fix (print the resolved placement to stderr
   unconditionally). That single change removes the "I can't tell whether
   it ran locally or enqueued" complaint without breaking a single existing
   invocation.
3. **The provider local-mode path is preserved for free** — it passes an
   explicit `--runtime local`, which is tier-1 and untouched by A. Option B
   would force a migration of that path (and the shastara provisioning
   scripts) for no user-visible benefit.
4. **Option B re-introduces two verbs.** The user's ask is to *stop* having
   overlapping verbs; encoding placement back into the verb name trades one
   kind of two-verb confusion for another, and fights the direction the
   code already moved.
5. **Adopt C's context discipline as a follow-on**, not a replacement: make
   `context bootstrap`/`add` write a concrete runtime and ship a built-in
   `local` context, so that over time the tier-3 guess is rarely reached —
   but keep the announced-guess as the safety net for un-configured users.

Net recommended surface:
- `noetl run <ref>` (visible) with `--runtime {local,distributed}` +
  `--local`/`--remote` sugar; placement precedence unchanged but
  **announced**.
- `exec` → hidden alias of `run` (unchanged).
- `run-legacy`, `execute *`, top-level `status`/`list` → hidden deprecated
  shims with stderr warnings; remove at 5.0.
- `subscribe --dispatch` → accept `distributed` as the preferred spelling,
  keep `server` as a deprecated alias.

---

## Part 7 — migration cost + blast radius

- **Code:** entirely in `repos/cli/src/main.rs` (clap `Commands`/`ExecuteCommand`
  enums, the `Exec`/`RunLegacy`/`Execute`/`Subscribe` handlers, and
  `resolve_runtime`). No touch to `PlaybookRunner`
  (`src/playbook_runner.rs`) or `execute_playbook_distributed`.
- **Public-surface / versioning:** no change to `noetl-tools` or
  `noetl-executor` crates → **CLI-only bump.** Deprecation warnings +
  `--local`/`--remote` sugar + announced placement = **minor** (4.2x).
  Removing `run-legacy`/`execute`/`status`/`list` = **major (5.0)**.
- **Provider local-mode:** preserved under the recommendation (explicit
  `--runtime local` is tier-1, unchanged). Only cosmetic: it will now print
  `→ running locally`. `--facts-out` untouched.
- **Docs/wiki that change:** `repos/noetl-cli-wiki/` command pages
  (run/exec/execute/subscribe/context), `repos/cli/README.md`, the CLI
  examples, `repos/ops/automation/*` playbooks that invoke
  `noetl exec --runtime local` / `noetl run` (verify they still read
  cleanly with the announced placement), and the `context` docs (Option C
  follow-on: document the built-in `local`/`default` contexts).
- **Observability:** CLI is not a boundary service, so no new
  metrics/spans required (`agents/rules/observability.md` fires on
  service boundaries, not the CLI). The announced-placement line is the
  user-facing trace.
- **Sequencing:** implement **after cli 4.19.0 lands.** Open an ai-task
  issue (`repo:cli`) on first touch per `agents/rules/issue-tracking.md`,
  add it to board 3, and validate on kind per
  `agents/rules/deployment-validation.md` (a provider `--runtime local`
  smoke run is the natural check).

---

## Part 8 — FORKS that need the USER's decision (not the agent's)

1. **Which model — A, B, or C?** The core fork. A = finish the current
   "one verb + `--runtime`" design (recommended). B = verb encodes
   placement (`run` local / `submit` remote) — matches the *original*
   intent but re-adds two verbs and forces a provider-path migration. C =
   placement lives only in the context. The rest of the forks below assume
   A/C unless B is chosen.
2. **The silent tier-3 guess:** (a) keep it but **announce** to stderr
   (recommended, zero breakage); (b) **refuse** when placement is
   ambiguous and require `--local`/`--remote`/context (strict, breaks bare
   scripts); or (c) **remove** it and require every context to carry a
   concrete runtime (Option C). This is a behavioral decision with real
   backward-compat consequences — the user should pick.
3. **Default when nothing is specified:** should bare `noetl run <ref>`
   default to **local**, **distributed**, or **refuse to guess**? (Tied to
   fork 2.)
4. **Primary visible verb name:** keep BOTH `run` and `exec` visible, or
   make **`run` primary + `exec` a hidden alias** (recommended — user calls
   it "the run verb")? Note provider docs/scripts currently say `exec`.
5. **Hard-remove timeline for `run-legacy` / `execute` / top-level
   `status`/`list`:** remove at the next major (5.0, recommended) vs keep
   them hidden indefinitely.
6. **`subscribe` vocabulary:** rename `--dispatch {local,server}` to
   `{local,distributed}` (with `server`/`dispatch` kept as deprecated
   aliases) to unify the vocabulary, or leave `subscribe` alone as a
   separate surface?

## Phases (for the implementing session — GATED)

### Phase A — read-only confirmation (unattended, after 4.19.0 lands)

1. Confirm cli pointer is ≥ 4.19.0 and the provider release chain merged.
2. Re-read `resolve_runtime`, the `Exec`/`RunLegacy`/`Execute` arms, and
   the provider `--facts-out` path on the *current* main (line numbers
   will have shifted from v4.12.0).
3. Confirm which forks in Part 8 the user answered.

### Phase B — implement the chosen option

> ***Run only after explicit human go-ahead. Wait phrase: `coherence go`.***

4. Open the ai-task issue (`repo:cli`), add to board 3.
5. Implement in `repos/cli/src/main.rs`; keep `--runtime local` tier-1.
6. `cargo build` + `cargo clippy` + unit tests for `resolve_runtime`
   (announce/refuse behavior) and the deprecation-warning shims.
7. Kind smoke: a provider `noetl run … --runtime local --facts-out` run
   still produces the JSONL sink.
8. Update `repos/noetl-cli-wiki/`, `README.md`, ops automation call sites.
9. Open the PR citing the issue; bump the ai-meta pointer + wiki + board in
   one change set.

## FINAL REPORT

Write `round-01-result.md` recording which option the user chose, the
issue/PR, and the kind-validation outcome — or, if picked up before
4.19.0, status `blocked: awaiting cli 4.19.0`.

## Hard rules for this thread

- **No cli code, branch, worktree, or PR touch until 4.19.0 lands AND the
  human says `coherence go`.** The provider release chain owns cli right
  now.
- Rust code → Claude writes it directly (`agents/rules/handoff-routing.md`);
  do not dispatch Codex.
- Never force-push; never merge PRs yourself.
- Public repo — no secrets in any file.
- If preconditions aren't met, stop and report — don't improvise.
