# NoETL ai-meta

The meta-repository (`ai-meta`) for coordinating all NoETL repositories via Git submodules and maintaining centralized AI working instructions.

## Purpose

- Keep one control point for cross-repo development.
- Provide shared AI instructions and change orchestration rules.
- Track exact submodule SHAs used for coordinated releases.

## Long-term Vision: NoETL as a Chemistry Lab Cloud

NoETL — coordinated through this meta-repo — is being built toward a
**shared chemistry lab cloud**: universities, research laboratories,
biotech companies, and individual scientists running molecular workflows
on pooled computation resources, with results published in a
reproducible, citable, peer-review-ready way.

The active pilot tenant is [`repos/glut-probe-design`](repos/glut-probe-design)
— AI-driven probe design for the GLUT glucose-transporter family. The
in-flight workstream `kadyapam/ligand-prep-worker-local-deps` lands
**pluggable per-task dependencies** in NoETL workers so any tenant can
declare its own scientific toolchain (RDKit, Meeko, AutoDock,
AutoDock-GPU, OpenMM, REINVENT, Qiskit, …) in playbook YAML instead of
baking it into the platform image. That capability is the substrate on
which the chemistry cloud is built: each lab registers a tenant
playbook, pulls in its scientific dependencies, runs on shared
CPU/GPU/TPU/quantum backends, and has raw artifacts, metadata,
checksums, and provenance captured in the platform's data registry for
citation and replication.

**For AI agents:** treat NoETL features as multi-tenant platform
primitives (auth, quotas, plugin isolation, reproducible compute, data
lineage, event-store provenance) — not as one-off helpers for a single
project. When in doubt, generalize.

**For humans:** this framing explains why we invest in worker plugin
isolation, structured event stores, strict data-catalog boundaries, and
runtime self-healing even when only one tenant is live today. Today's
GLUT pipeline is the load-bearing example for tomorrow's open
chemistry cloud.

## Layout

- `AGENTS.md` - global AI rules for this orchestration repo.
- `CLAUDE.md` - Claude-specific entry point and context rules.
- `GEMINI.md` - Gemini-specific entry point and context rules.
- `agents/` - AI-specific instructions.
- `handoffs/` - file-based cross-agent prompts + results (see below).
- `memory/` - NoETL platform/cross-repo AI memory (entries, compactions, current state).
- `playbooks/` - orchestration workflows/checklists.
- `sync/` - cross-repo synchronization procedures.
- `repos/` - all NoETL code repositories as Git submodules.

## Submodules

Initialize/update:

```bash
git submodule sync --recursive
git submodule update --init --recursive
```

Update all submodules to latest tracked default branch heads:

```bash
git submodule foreach --recursive 'git fetch --all --tags'
```

## Cross-repo workflow

1. Create feature branches inside affected submodules.
2. Open/merge PRs in each submodule repo.
3. In this repo, bump submodule pointers to merged SHAs.
4. Commit pointer updates with one coordination message.

Day-to-day operating guide:

- `playbooks/how_to_use_ai_meta_day_to_day.md`

## Commit policy for this repo

Only commit:

- instruction updates (`AGENTS.md`, `CLAUDE.md`, `GEMINI.md`, `agents/*`, `sync/*`, `playbooks/*`)
- memory updates (`memory/*`)
- submodule pointer updates

Do not add product source code to this repo.

## AI Memory workflow

Add a NoETL platform or cross-repo memory entry:

```bash
./scripts/memory_add.sh "<title>" "<summary>" "<tags>"
git add memory
git commit -m "memory(add): <title>"
```

Compact pending entries:

```bash
./scripts/memory_compact.sh
git add memory
git commit -m "memory(compact): <date/scope>"
```

This keeps a durable memory chain in Git commits and a compact working state in `memory/current.md`.

Project-specific memory belongs in the owning repository. For
`glut-probe-design`, keep task/session/science/data-catalog/tenant playbook
memory under `repos/glut-probe-design/memory/`. Use `ai-meta/memory/` only when
recording NoETL platform decisions, deployment state, submodule pointer syncs,
or cross-repo coordination.

## Contributor checklist (cross-repo / ecosystem changes)

Use this repo when a change spans multiple NoETL repositories (server/worker/CLI/gateway/plugins/docs).

### Before you start
- [ ] Confirm the list of impacted repos under `repos/` (submodules).
- [ ] Create a short plan: what changes per repo, expected order, and compatibility concerns.
- [ ] Add a memory entry if this is a non-trivial NoETL/cross-repo effort
      (decision record / plan). For project-specific work, write memory in the
      owning submodule instead.

### Implementing changes
- [ ] Make code changes inside the appropriate submodule(s), not in `ai-meta` root.
- [ ] Open PRs in the upstream repos (each submodule has its own PR lifecycle).
- [ ] Keep PRs small and composable when possible; note any ordering constraints.

### After merges
- [ ] Update pinned submodule SHAs in `ai-meta`:
  - `git submodule update --remote --recursive`
  - commit: `chore(sync): bump submodules for <topic>`
- [ ] Add a sync note under `sync/YYYY/MM/` with:
  - summary, repo scope, PR links, and resulting SHAs/tags
- [ ] Add an ai-meta memory entry only for NoETL/platform decisions,
      compatibility notes, pointer/deploy state, and cross-repo follow-ups.
- [ ] Run memory compaction periodically:
  - `./scripts/memory_compact.sh`
  - commit: `memory(compact): <scope>`

### Safety / hygiene
- [ ] Do not commit secrets, tokens, private credentials, or customer data.
- [ ] Keep memory entries public-safe and vendor-neutral.
- [ ] Prefer linking to upstream PRs/issues rather than copying large diffs into `ai-meta`.

## AI agent handoffs (file-based, cross-tool)

Long-running tasks that span more than one AI session are passed
between agents through files under `handoffs/`, not through chat.
This lets Claude, Codex, Cursor, Gemini, and any future tool collaborate
on the same thread, with the executor's report captured at a known
path so the dispatcher can pick up exactly where it left off — days
later, on a different machine, or with a different model.

Full convention: [`handoffs/README.md`](handoffs/README.md).
Behavioral rules: [`agents/rules/handoffs.md`](agents/rules/handoffs.md).

### Shape

```
handoffs/
  active/<YYYY-MM-DD-slug>/
    round-01-prompt.md     ← dispatcher writes (claude / human)
    round-01-result.md     ← executor writes back (codex / claude / …)
    round-02-prompt.md     ← dispatcher follow-up
    round-02-result.md
  archive/<slug>/          ← closed threads moved here
  templates/               ← copyable prompt.md / result.md
```

Each file carries YAML frontmatter with `thread / round / from / to /
status`. Prompts declare `expects_result_at: round-NN-result.md`;
executors write to that path and pick a result `status` of
`complete | partial | blocked`.

### Enter handoff mode

#### Claude Code

```
Open a handoff to codex about <topic>. Slug it
<YYYY-MM-DD-short-topic>. Phase A is sanity checks (no remote writes),
B is push PR (gated on "push <thing>"), …
```

Claude calls `/handoff-open`, writes the prompt body to
`handoffs/active/<slug>/round-01-prompt.md`, and tells you the path to
hand to Codex.

To read a result that has been written back:

```
Read handoffs/active/<slug>/round-01-result.md and tell me what to do
next.
```

#### Codex

Pass the absolute prompt path on launch:

```
You are operating in /Volumes/X10/projects/noetl/ai-meta. Read the
handoff prompt at handoffs/active/<slug>/round-NN-prompt.md
end-to-end, follow handoffs/README.md, do the work inside the phase
gates, then write your final report to
handoffs/active/<slug>/round-NN-result.md with the matching
frontmatter (status: complete | partial | blocked).
```

Codex reads the prompt, executes the phases, and writes the result
file at the declared path. It commits the result so it shows up in
`git log` for review.

#### Cursor / Gemini / other tools

Any agent operating in this repo can join a thread by following the
same two rules: read the highest-numbered `round-NN-prompt.md` under
`handoffs/active/<slug>/`, then write the matching `round-NN-result.md`
using `handoffs/templates/result.md` as a guide.

### Return to regular conversation mode

There is no flag to flip. The convention only applies when the agent
is asked to write or read a handoff file. To return to ordinary
chat-driven work, just keep talking — ask the agent to explain code,
make a small edit, review a diff, etc., and it will respond in chat
as normal. The handoff thread on disk stays as-is; reopen it whenever
the next round is needed.

### Close a thread

When the work is done:

```
Close the handoff <slug>.
```

The agent runs `git mv handoffs/active/<slug> handoffs/archive/<slug>`
and commits with `handoff(close): <slug>`. The thread is preserved
verbatim for posterity.

### When NOT to use a handoff

- A question the current agent can answer in one chat turn.
- A trivial edit the current session will finish.
- Anything where the convention overhead exceeds the value of having
  a durable record.
