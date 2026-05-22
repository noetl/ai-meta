# AI Memory

This directory is the long-lived memory store for NoETL platform,
deployment, submodule pointer, and cross-repo AI orchestration work.

Project-specific memory belongs in the project repository that owns the work.
For example, `glut-probe-design` task plans, scientific data decisions,
tenant playbook notes, and implementation session records must be stored under
`repos/glut-probe-design/memory/`, not in `ai-meta/memory/`.

## Structure

- `current.md` - compact active memory for current context.
- `timeline.md` - high-level chronological index.
- `inbox/` - new un-compacted memory entries.
- `compactions/` - periodic summaries generated from inbox entries.
- `archive/` - processed inbox entries moved by compaction.

## Rules

1. Keep entries factual and actionable.
2. Never store tokens, secrets, or credentials.
3. Keep one topic per memory entry.
4. Store project-specific memory in the owning submodule repository.
5. Compact regularly to keep `current.md` small and useful.

## Commands

Create entry:

```bash
./scripts/memory_add.sh "<title>" "<summary>" "<tags>"
```

Compact inbox:

```bash
./scripts/memory_compact.sh
```
