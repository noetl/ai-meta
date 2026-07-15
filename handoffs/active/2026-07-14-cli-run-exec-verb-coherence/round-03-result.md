---
thread: 2026-07-14-cli-run-exec-verb-coherence
round: 3
from: claude
to: claude
created: 2026-07-14T00:00:00Z
in_reply_to: round-03-prompt.md
status: partial                        # Phase 1 read-only validation done; Phase 2 (code) BLOCKED on cli 4.19.0
tracks: noetl/ai-meta#192
---

# Phase 1 read-only validation — run/exec/execute unification

Read-only inspection of `repos/cli` at pointer **v4.12.0** (`5f39e54`) plus
docs/wiki/ops/e2e. **No cli files edited.** Phase 2 (implementation) is HELD
until the human confirms cli 4.19.0 has landed and says `coherence go`.

## (1) Fork A implementability — VERDICT: expressible today, NO struct change

`Context.runtime` is a plain **`String`**, not `Option<Runtime>` and not an
enum:

```rust
// repos/cli/src/config.rs:10-12
/// Default runtime mode: local, distributed, or auto
#[serde(default = "default_runtime")]     // default_runtime() -> "auto"  (config.rs:53-55)
pub runtime: String,
```

- Grepped the whole crate: there is **no `enum Runtime` / `RuntimeMode`**.
  (`LocalRuntime`/`LocalSpoolRuntime` in `src/subscribe/` are unrelated
  subscribe structs.) So nothing collapses two states into one enum value.
- The three context states are **distinct strings**, exactly as Fork A needs:

  | context YAML | deserializes to | ladder outcome |
  | :-- | :-- | :-- |
  | *(no `runtime:` key)* | `"auto"` | rung 2 skipped → rung 3 → **local** |
  | `runtime: local` | `"local"` | rung 2 fires → local (from context) |
  | `runtime: distributed` | `"distributed"` | rung 2 fires → distributed |
  | `runtime: auto` | `"auto"` | rung 2 skipped → rung 3 → **local** |

- **The user's specific question — can the code tell "no runtime field" apart
  from "runtime = local"? YES.** `"auto"` ≠ `"local"`; different strings, taken
  at different rungs. No change needed to distinguish them.
- The only collapse is "no field" == explicit `runtime: auto` (both `"auto"`).
  **Harmless** — both must fall through to local under the design; nothing needs
  to tell them apart. `Option<String>` (legacy `"auto"`→`None`) is optional
  polish, **out of scope for #192**.

## (2) Resolution plumbing — VERDICT: ladder already centralized; one-line change

- `resolve_runtime` (`main.rs:1612-1647`) already implements `flag > context >
  fallback` and has **exactly one caller**: the `Exec` handler (`main.rs:2365`).
  - Rung 1 flag-wins: `if runtime_flag != "auto" { return flag }` (1619-1624). ✔ keep
  - Rung 2 context-wins-iff-defined: `if ctx_runtime != "auto" { return ctx }`
    (1627-1634). ✔ keep — this IS Fork A's fall-through (unset==`"auto"`→skip)
  - Rung 3 today = reference-type auto-detect (1637-1646). **← the only change:**
    replace the `match ctx.ref_type {...}` with unconditional `"local"`.
- `RunLegacy` (hidden `run-legacy`) does NOT call `resolve_runtime`; it has its
  own inline 2-rung resolution that already defaults local (`main.rs:2534-2539`).
  It is slated for 5.0 removal — no ladder work needed there.
- `Subscribe` uses a separate `--dispatch local|server` axis (`main.rs:175`);
  out of scope for the ladder (round-2 noted the optional vocabulary unify).
- **Consequence:** the ladder change is one function, one call site. Making
  `run` canonical is a clap relabel of the `Exec` variant (today `Exec` carries
  `alias = "run"`, `main.rs:107`) — same handler, same dispatch, no
  restructuring.

### Implementation detail to watch (deprecation-nudge mechanism)

clap `alias`/`visible_alias` does **not** report *which* alias the user typed,
so a plain alias can't emit "'exec' is deprecated". To print the nudge, the
implementer must either (a) inspect `std::env::args()` for the invoked
subcommand token, or (b) define `exec`/`execute` as **separate hidden
subcommands that delegate to the `run` handler after printing the warning**.
(b) is cleaner and is the recommended shape. Small extra code; flag it so the
implementer doesn't assume a bare `alias=` gives the warning for free.

## (3) `exec` / `execute` call-site inventory (the `run` sweep scope)

**Accurate run-verb counts** (excluded false positives: `kubectl -n noetl
exec`, `kind-noetl`, `codex exec`, `ai exec`, and the `execute <subcommand>`
group):

| Location | `noetl exec` run-verb usages | Notes |
| :-- | --: | :-- |
| `repos/cli/README.md` | 0 | its `execute` usages are the subcommand group |
| `repos/noetl-cli-wiki` | 7 | run/exec/context/subscribe pages |
| `repos/ops` | 17 | + vendored cli copy (below) + `execute playbook` refs |
| `repos/docs` | 56 | tutorials, examples, operations, architecture |
| `repos/e2e` | 37 | `kind_validate_*.sh` scripts, `exec … --runtime distributed --json` |
| `repos/noetl` | 3 | GEMINI.md, CLAUDE.md, `endpoint.py:588` dry-run hint |

**~120 run-verb `exec` usages total.** Plus a separate, already-hidden surface:
the **`execute <playbook|status|rerun>` subcommand group** (`ExecuteCommand`,
`main.rs:660`) referenced in ops bootstrap QUICKSTART/README, `ibkr/README.md`,
`automation/setup/bootstrap.yaml:595`, and the e2e `ibkr_api.yaml` comments.

**cli-source touch points for the sweep + help text:** doc-comment examples on
the `Exec` variant (`main.rs:80, 101-106`), the console banner
`println!("  exec …")` (`main.rs:2045`), the local-needs-file hint
`eprintln!("  Use: noetl exec …")` (`main.rs:2411`), and the
`noetl execute status {id}` hints (`main.rs:4863, 4918`).

**Two important framings for the sweep:**

1. **Non-breaking / can be paced.** Because `exec` (and the hidden `execute`
   group) stay **working aliases**, the ~120 doc/script usages keep running
   unchanged. The docs→`run` sweep is a *consistency* pass, not a hard
   dependency for the cli code change to land. The e2e `kind_validate_*.sh`
   scripts in particular will keep passing on the `exec` alias.
2. **Vendored copy:** `repos/ops/vendor/cli/src/main.rs` is a 186 KB **snapshot
   of the cli source** (mirrors the `Exec` doc-comments). It is refreshed by its
   own vendoring process, not hand-edited in the sweep — note it so it isn't
   mistaken for a live call site.

## Size verdict

**The cli code change is SMALL and self-contained:**
- rung 3 → `"local"` (~4 lines, `main.rs:1637-1646`)
- `run` canonical + `exec`/`execute` hidden-delegating aliases with a one-line
  stderr deprecation nudge
- promote the resolved-runtime print to an unconditional stderr provenance echo
  (`main.rs:1620-1645` → always-on, stderr, kept off `--json` stdout)
- extend the local-needs-file error to suggest `--runtime distributed`/context
- no `Context` struct change; no `noetl-tools`/`noetl-executor` surface change →
  **CLI-only version bump**

**The docs/wiki/examples→`run` sweep is LARGE (~120 refs across 5 repos) but
non-breaking and paceable** because the aliases keep working.

## Manual escalation / HOLD

- **Phase 2 (code) is BLOCKED** by the concurrent 4.19.0 release session that
  owns `repos/cli` right now. Do not branch/edit cli until the human confirms
  4.19.0 has landed and says `coherence go`. Implement on a fresh branch off
  **post-4.19.0 main**, version cleanly above whatever 4.19.0/state-sink ships
  as, publish-verify on crates.io (sparse + tarball), PR **open not merged**.
