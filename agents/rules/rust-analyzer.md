---
paths:
  - "repos/cli/**"
  - "repos/server/**"
  - "repos/worker/**"
  - "repos/tools/**"
  - "repos/doctor/**"
  - "repos/gateway/**"
  - "**/Cargo.toml"
  - "**/Cargo.lock"
  - "**/*.rs"
  - ".vscode/**"
---

# rust-analyzer in the ai-meta workspace

The NoETL Rust stack lives across six top-level submodules:

- `repos/cli` — Rust workspace (CLI + `noetl-executor`).
- `repos/server` — Rust control plane (the noetl-server binary).
- `repos/worker` — Rust worker pool (the noetl-worker binary).
- `repos/tools` — `noetl-tools` registry crate.
- `repos/doctor` — `noetl-doctor` diagnostic CLI.
- `repos/gateway` — `noetl-gateway` HTTP edge.

Each submodule has its own `Cargo.toml` at the top of the repo.
There is **no** outer workspace `Cargo.toml` at the ai-meta root —
the submodules are independent Cargo workspaces that ship
independently and pull each other as crates.io dependencies.

This shape needs explicit configuration for rust-analyzer to work
inside ai-meta, because rust-analyzer otherwise finds nothing at
the root and refuses to index the per-submodule workspaces.

## The rule

When working on Rust code inside this workspace:

1. **Use the rust-analyzer extension.** Code navigation, inline
   diagnostics, type information, and refactors all assume it.
   Don't reach for `grep`-driven editing when rust-analyzer can
   tell you the call sites directly.
2. **Don't open each submodule as a separate VS Code window.**
   The workspace-level `linkedProjects` setting (`.vscode/settings.json`)
   wires up all six Rust submodules at once, so a single window
   can edit and navigate across them — including cross-submodule
   references (e.g. when `noetl/worker` adopts a new feature from
   `noetl/tools`).
3. **Keep `linkedProjects` current.** When a new Rust submodule is
   added (or a Rust submodule is renamed / removed), update the
   `rust-analyzer.linkedProjects` array in `.vscode/settings.json`
   in the **same change set** as the submodule pointer addition.
   Stale `linkedProjects` entries cause rust-analyzer to crash on
   load with `failed to find Cargo.toml`.
4. **Trust the extension recommendation.** `.vscode/extensions.json`
   pins `rust-lang.rust-analyzer` (and `tamasfe.even-better-toml` for
   Cargo.toml, `vadimcn.vscode-lldb` for debugging). VS Code prompts
   to install on first workspace open — accept it.

## Workspace-level settings (`.vscode/settings.json`)

The current shape, with the reasoning:

| Setting | Reason |
| :-- | :-- |
| `rust-analyzer.linkedProjects` | The list of `Cargo.toml` paths rust-analyzer should index. One entry per Rust submodule. |
| `rust-analyzer.check.command = "clippy"` | On-save check runs clippy, not just `cargo check`. Matches the CI gate every submodule's release pipeline runs — catches lints locally before they trip CI. |
| `rust-analyzer.check.allTargets = true` | Include test + example targets in on-save check, so test-only code doesn't drift from main. |
| `rust-analyzer.cargo.features = "all"` | Index all feature-gated code paths. The Rust stack uses non-default features for some sqlx + tracing layers; without this, hover/goto fails inside those paths. |
| `rust-analyzer.imports.granularity.group = "module"` | Auto-imports group per module (one `use foo::{bar, baz};` line per crate) instead of one line per symbol. Matches the style every submodule already uses. |
| `rust-analyzer.inlayHints.*.enable = "never"` | Suppress lifetime + closure-return inlay hints. Noise-to-signal ratio is low; type hints stay on. |
| `[rust]` block | Format on save with rust-analyzer's `rustfmt` integration. Each submodule's `rustfmt.toml` is authoritative. |
| `files.watcherExclude` for `target/**` | VS Code's file watcher otherwise burns CPU on Cargo build artifacts (multi-GB per submodule). |

When tuning these, change them in the **workspace** settings
(`.vscode/settings.json` at the ai-meta root), not user settings —
the workspace is the natural unit because it sees every Rust
submodule at once.

## When to update

Update `.vscode/settings.json` + `.vscode/extensions.json` in the
same change set when:

- A new Rust submodule is added under `repos/` — add it to
  `linkedProjects`.
- A Rust submodule is removed or renamed — drop / rename its
  `linkedProjects` entry.
- A rust-analyzer feature flag changes its default in a way the
  team disagrees with — pin the desired value here so every
  developer's IDE behaves the same.

Update **per-submodule** `.vscode/settings.json` only when a
setting is genuinely per-crate (e.g. submodule-specific runnables,
breakpoint mappings, debug profiles). Cross-cutting Rust settings
belong at the ai-meta workspace level.

## When this rule doesn't fire

- Editing non-Rust submodules (`repos/noetl`, `repos/ops`,
  `repos/docs`, `repos/gui`, `repos/travel`, `repos/e2e`).
- Editing only the wiki submodules (`repos/noetl-*-wiki/`).
- Documentation-only changes inside Rust submodules that don't
  touch `.rs` / `Cargo.toml` files.

## Coordination with other rules

- [`submodules.md`](submodules.md) — pointer hygiene applies to
  the Rust submodules as much as any other. rust-analyzer
  `linkedProjects` updates ride the same change set as the
  pointer add/remove.
- [`deployment-validation.md`](deployment-validation.md) — local
  kind validation builds the Rust binaries from these same
  submodules; rust-analyzer-driven edits stay consistent with
  what `cargo build` sees because both read the same `Cargo.toml`.
- [`commit-conventions.md`](commit-conventions.md) — IDE config
  changes use the `docs(agents):` prefix when they accompany a
  rule update, or a topical prefix (e.g. `chore(vscode):`) for
  pure tooling tweaks.

## History

Codified 2026-06-04 after the user instruction:

> update vscode settings to add rust analyzer extension and add
> rule to use rust analyzer extension for rust based projects.

The initial `.vscode/settings.json` (commit `1dc634b`) wired
`linkedProjects` but didn't pin the extension recommendation or
the related settings. This rule + the same-change-set additions
codify the workspace IDE shape so it survives across machines.
