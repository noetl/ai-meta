---
thread: 2026-07-14-cli-run-exec-verb-coherence
round: 3
from: claude
to: claude                             # future implementing session (post-4.19.0)
created: 2026-07-14T00:00:00Z
status: open                           # FINAL decided spec — still design-only, no cli code this round
expects_result_at: round-03-result.md
tracks: noetl/ai-meta#192
wait_phrase: "coherence go"            # gate: NO cli code, branch, or PR until 4.19.0 lands AND this phrase is said
---

# RFC round 3 — FINAL: decisions ratified, tracked as noetl/ai-meta#192

> **Predecessors:** [`round-01-prompt.md`](round-01-prompt.md) (options),
> [`round-02-prompt.md`](round-02-prompt.md) (ratified model + forks). This
> round records the user's final ratifications, gives the **definitive Fork A
> code verdict**, and locks `run` as canonical with its migration plan. The
> detailed ladder/echo/truth-table in round 2 still stands; this round is the
> decision record + the implementation-sizing verdict.
>
> **Tracked as [noetl/ai-meta#192](https://github.com/noetl/ai-meta/issues/192)**
> (labels `ai-task` + `repo:cli`, on roadmap board 3, status Todo).
>
> **Still design-only. No cli code, branch, worktree, or PR until cli 4.19.0
> has landed AND the human says `coherence go`.**

## Decisions ratified (2026-07-14)

1. **Fork A — GO.** Context defined but no `runtime` field = **unset → fall
   through to LOCAL**. Do not error; do not force distributed.
2. **Canonical verb = `run`.** `run` is THE verb in all docs / wiki / examples
   / help text. `exec` + `execute` become **deprecated working aliases** (soft
   stderr warning on use), removed no sooner than the next major (5.0).
3. (Carried from round 2, unchanged) **Fork B — GO.** Bake in the one-line
   stderr provenance echo. Enqueue-to-named-remote confirm stays an *optional*
   TTY-only `--confirm-remote` (default OFF); the echo alone is the baseline.

## Fork A — definitive code verdict (this determines implementation size)

**The current code CAN express Fork A cleanly. No struct change is required.
The implementation is SMALL.**

Evidence (`repos/cli`, pointer v4.12.0):

- `Context.runtime` is a plain **`String`** (`config.rs:12`) — grepped every
  occurrence; there is **no `Runtime` enum** anywhere that would collapse
  values on deserialize. `#[serde(default = "default_runtime")]` with
  `default_runtime() = "auto"` (`config.rs:53-55`).
- Therefore the three states are **distinct strings**, exactly as Fork A needs:
  | context YAML | deserializes to | ladder outcome |
  | :-- | :-- | :-- |
  | *(no `runtime:` key)* | `"auto"` | rung 2 skipped → rung 3 → **local** |
  | `runtime: local` | `"local"` | rung 2 fires → **local (from context)** |
  | `runtime: distributed` | `"distributed"` | rung 2 fires → **distributed (from context)** |
  | `runtime: auto` | `"auto"` | rung 2 skipped → rung 3 → **local** |
- The user's specific worry — can the code tell **"no runtime field" apart from
  "runtime = local"**? — **Yes.** `"auto"` ≠ `"local"`; they are different
  strings and take different rungs.
- The rung-2 fall-through for unset is **already implemented**: the guard is
  `if ctx_runtime != "auto"` (`main.rs:1628`). "auto" (which is what a missing
  field becomes) already means "context does not pin a runtime → fall through."

### The one honest caveat (harmless, not a blocker)

"No `runtime` field" and an explicit "`runtime: auto`" collapse to the **same**
value (`"auto"`) — the code cannot tell those two apart. **This is harmless
under the ratified design**, because both must fall through to local anyway.
There is no behavior in the design that needs to distinguish them.

- If a future design ever needs "unset" as a first-class, unambiguous state
  (distinct from an explicit `auto`), migrate `Context.runtime` →
  `Option<String>` and map legacy `"auto"`→`None` on load. **Optional polish,
  explicitly out of scope for #192.**

### So the ONLY required `resolve_runtime` change is rung 3

Replace the reference-type match (`main.rs:1637-1646`)

```rust
// current rung 3 — auto-detect by reference type
let resolved = match &ctx.ref_type {
    RefType::File(_) => "local",
    RefType::Catalog { .. } => "distributed",
    RefType::DatabaseId(_) => "distributed",
    RefType::CatalogPath(_) => "distributed",
};
```

with an unconditional default:

```rust
// ratified rung 3 — CLI-first: default to local
let resolved = "local";
```

That is the whole ladder change. Everything else (Fork A fall-through, rung 1
flag-wins, rung 2 context-wins) is already in place.

## Precedence ladder with `run` example commands (final)

```
Rung 1  explicit --runtime            noetl run wf/etl --runtime distributed   → enqueue
                                       noetl run ./prov.yaml --runtime local    → local (provider path)
Rung 2  active context's runtime       noetl context set-runtime distributed
        (wins iff it defines one)      noetl run wf/etl                          → enqueue  (from context)
                                       noetl --context prod run wf/etl           → enqueue  (from context 'prod')
Rung 3  default → LOCAL                 noetl run ./foo.yaml                      → local    (default)
                                       noetl run foo                             → local    (default)
```

A catalog/db ref that resolves to local with no file present fails loudly
("local runtime requires a file path"; extend the message at `main.rs:2409-2414`
to suggest `--runtime distributed` or a context) — explicit, self-correcting,
strictly better than today's silent enqueue.

## Provenance echo (Fork B, final)

One line to **stderr** on every run (so `--json` stdout stays clean —
`main.rs:2420-2436`); promote the current `--verbose`-only print
(`main.rs:1620-1645`) to unconditional:

```
runtime: local (default)
runtime: local (--runtime flag)
runtime: local (from context 'dev')
runtime: distributed (from context 'prod')
runtime: distributed (--runtime flag)
```

Enqueue-to-named-remote: echo is the baseline; ship the optional TTY-only
`--confirm-remote`/`--yes` guard (never prompts under `--json` or non-TTY) only
if the user opts in later. Keep it lightweight — do not gate the default path.

## `run` canonical — deprecation + migration plan

- **Clap flip:** today `Commands::Exec` carries `alias = "run"` (`main.rs:107`).
  Make `run` the canonical variant; add `exec` + `execute` as aliases.
- **Soft deprecation nudge** on alias use, one line to stderr, e.g.:
  `note: 'exec' is a deprecated alias for 'run'; both work today, 'exec' is removed in noetl 5.0.`
  (Same text with `execute`.) One line per invocation; allowed on stderr even
  under `--json`.
- **Timeline:** deprecate now (next **minor**, ~4.2x); remove the `exec` /
  `execute` run-aliases at **5.0** (major). The already-hidden legacy surfaces
  from round 1 (`run-legacy`, the `execute` *subcommand group* `ExecuteCommand`
  at `main.rs:660`, top-level `status`/`list`) ride the same 5.0 removal. NB:
  the `execute` **run-alias** (new) is a different surface from the `execute`
  **subcommand group** (existing, stays hidden-deprecated).
- **Versioning:** no `noetl-tools` / `noetl-executor` public-surface change →
  **CLI-only bump.** Ladder + echo + `run`-canonical + deprecation nudges =
  **minor**; alias removal = **5.0 major**.

### Full doc / wiki / example blast radius (all sweep to `run`, same change set)

- `repos/cli/README.md` — 10 verb usages (6× `execute`, 4× `run`) →
  standardize on `run`.
- `repos/noetl-cli-wiki/` — run/exec/execute/context pages (currently 7× `exec`,
  1× `run`); document the ladder as `flag > context > default(local)` + the
  provenance echo; switch examples to `run`.
- `repos/cli` clap help text / doc-comments on the `Commands` variant + the
  `context` subcommands that mention runtime.
- `repos/ops/automation/*` — migrate `noetl exec --runtime local` → `noetl run
  --runtime local` (bridge `run_commands`, `noetl.yaml`, `gcp_gke/`, automation
  READMEs). Mechanical; keeps provisioning output nudge-free.
- Any `agents/rules/*` prose that narrates `noetl exec …` as the run verb.

## Provider `--runtime local` path — proven unaffected

- `--runtime local` is **rung 1**; it short-circuits above context and default
  (`main.rs:1619-1624`). A stale `distributed` context cannot re-route
  provisioning. ✔
- `exec` remains a **working alias** — the command runs; only a one-line stderr
  nudge is added (removed once ops automation is swept to `run` in the same
  change set). ✔
- Local `PlaybookRunner` (`main.rs:2405-2438`) and `--facts-out` untouched. ✔
- Provenance echo prints `runtime: local (--runtime flag)` — stderr,
  informational, no effect on the sink or exit code. ✔

## Phases (for the implementing session — GATED)

### Phase A — read-only confirmation (unattended, after 4.19.0 lands)

1. Confirm cli pointer ≥ 4.19.0 and the provider chain merged.
2. Re-locate `resolve_runtime` rung 3, `config.rs::Context`, the `Exec` arm, the
   `--facts-out` path on current main (line numbers shift from v4.12.0).
3. Confirm #192 is still the tracking issue and the fork answers above.

### Phase B — implement

> ***Run only after explicit human go-ahead. Wait phrase: `coherence go`.***

4. On #192: comment "Starting work in session <date>. Branch: <name>."; flip
   board 3 status Todo → In progress.
5. Implement: rung-3 → `"local"`; `run` canonical + `exec`/`execute` alias
   nudges; unconditional stderr provenance echo; extend the local-needs-file
   error message. (No `Context` struct change — Fork A already expressible.)
6. `cargo build` + `cargo clippy` + unit tests: `resolve_runtime` per rung +
   provenance string; the Fork-A matrix (no-field / `auto` / `local` /
   `distributed`); `--json`-stdout-stays-clean invariant; alias-nudge presence.
7. Kind smoke: provider `noetl run … --runtime local --facts-out` writes the
   sink + echoes local; a distributed context run echoes context provenance.
8. Docs→`run` sweep (README, cli-wiki, ops automation) in the same change set.
9. PR citing `Closes noetl/ai-meta#192`; bump ai-meta pointer + wiki + board.

## FINAL REPORT

Write `round-03-result.md` with the PR, kind-validation output, and #192
closure — or, if picked up before 4.19.0, status `blocked: awaiting cli 4.19.0`.

## Hard rules for this thread

- **No cli code, branch, worktree, or PR touch until 4.19.0 lands AND the human
  says `coherence go`.** The provider release chain owns cli right now.
- Rust code → Claude writes it directly (`agents/rules/handoff-routing.md`).
- Never force-push; never merge PRs yourself. Public repo — no secrets.
- If preconditions aren't met, stop and report — don't improvise.
