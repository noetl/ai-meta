---
paths:
  - "repos/**"
---

# Submodule Rules

- Always run git commands from the repository root.
- Sync before working: `git submodule sync --recursive && git submodule update --init --recursive`
- Treat `repos/*` as independent source-of-truth repositories.
- Do not move files between submodules from the ai-meta root.
- Do not vendor code from one submodule into another.
- Prefer minimal, atomic pointer updates per change set.
- For cross-repo changes: implement in submodule → merge upstream PR → update pointer here → commit with summary.

## Worktrees on shared submodule trees

Shared submodule checkouts (`repos/server`, `repos/cli`, `repos/noetl`,
and any tree another concurrent session may be using) must be worked on
through `git worktree` to avoid concurrent-checkout corruption — never
two sessions checking out branches in the same `repos/<name>` directory.

**Hazard — do NOT `git worktree add` from inside a `repos/<name>`
submodule.** A submodule's git dir lives under the superproject at
`.git/modules/repos/<name>/`, and a worktree added from there gets a
stale `core.worktree` that makes git resolve the new worktree's
top-level to `.git/modules/repos/<name>` itself. Symptoms:

- `git rev-parse --show-toplevel` returns a path under
  `.git/modules/...` instead of the worktree.
- `git status` in the worktree reports garbage — internal git files
  (`HEAD`, `index`, `objects/`, `packed-refs`) as untracked, plus
  **other sessions' in-flight files** from the shared module dir.
- Committing there risks writing the wrong tree.

Hit this 2026-07-24 building the Python wheel; recovered by abandoning
the worktree for a fresh `git clone` of the submodule's upstream before
committing anything.

Hit **again** 2026-08-05 on `repos/noetl`, which is worth recording
because of how it presented and why the rule was walked past.

**It does not fire uniformly.** Worktrees added the same way against
`repos/ops`, `repos/e2e` and `repos/cli` that day all resolved
correctly (`--is-inside-work-tree=true`, `--show-toplevel` matching).
Four consecutive worktrees behaving perfectly is exactly what makes the
fifth one's output look like a repo problem rather than a known trap.
The differentiator is in `.git/modules/repos/<name>/config`:

```ini
[core]
    worktree = ../../../../repos/noetl
[extensions]
    worktreeConfig = true          # <- only repos/noetl has this
```

`core.worktree` is resolved relative to each worktree's own gitdir. For
the primary (`.git/modules/repos/noetl`) that relative path is correct;
a secondary worktree's gitdir is two levels deeper
(`…/noetl/worktrees/<name>`), so the same path lands back on the module
directory. With `worktreeConfig` enabled, `core.worktree` is supposed
to live in the per-worktree `config.worktree`, not the shared `config` —
that is the actual misconfiguration, and it will keep leaking into every
new worktree until it moves.

**Pre-flight check — one command, do it before trusting any output:**

```bash
git -C <worktree> rev-parse --is-inside-work-tree   # must print true
```

`false` means every subsequent `status` / `diff` / `add` in that
worktree describes the git directory instead of your checkout. Nothing
errors; the diff just looks plausible and is of the wrong thing.

**Cheap repair, if you would rather not re-clone:**

```bash
git -C <worktree> config --worktree core.worktree "<abs path to worktree>"
```

Verified: dirty `62 → 0`, `--is-inside-work-tree` `false → true`,
top-level correct. This is per-worktree and reversible; it does not
touch the shared config. A fresh clone is still the more reliable path
when the work is going to be committed.

Tracked as [noetl/ai-meta#239](https://github.com/noetl/ai-meta/issues/239),
which also records that 16 `.codex` worktrees of `repos/noetl` are
currently in this state.

**The safe pattern for isolated work on a submodule:**

- `git clone git@github.com:noetl/<name>.git <scratch-dir>` into a
  scratch location, branch there, push, open the PR. A fresh clone has
  a correct top-level and cannot see the shared module dir. This is the
  reliable path when a submodule tree is dirty or another session holds
  it.
- Worktrees created against the **superproject** (`ai-meta` itself, for
  pointer-bump branches) are fine — the hazard is specific to worktrees
  rooted inside a `repos/<name>` submodule's git dir.

If a broken submodule worktree already exists, remove it from the
submodule root (`cd repos/<name> && git worktree remove <path> --force
&& git worktree prune`) — not from the ai-meta root, which does not know
about the submodule's worktree registrations.
