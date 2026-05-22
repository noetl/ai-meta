---
paths:
  - "memory/**"
  - "scripts/**"
---

# Memory Workflow Rules

- Add entries via `./scripts/memory_add.sh "<title>" "<summary>" "<tags>"`.
- Each entry gets a unique timestamped filename — safe for concurrent writes.
- Use `ai-meta/memory/` only for NoETL platform, deployment, submodule pointer,
  and cross-repo orchestration state.
- Keep `glut-probe-design` project-specific memory in
  `repos/glut-probe-design/memory/`; do not duplicate tenant project notes in
  `ai-meta`.
- Compact via `./scripts/memory_compact.sh` — moves inbox to archive, creates compaction summary, updates current.md and timeline.md.
- Only one person/agent should compact per cycle (daily or weekly) to avoid races.
- Curate `memory/current.md` periodically so it stays useful as a session bootstrap.
