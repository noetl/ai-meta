---
paths:
  - "memory/**"
  - "scripts/**"
---

# Memory Workflow Rules

- Add entries via `./scripts/memory_add.sh "<title>" "<summary>" "<tags>"`.
- Each entry gets a unique timestamped filename — safe for concurrent writes.
- Compact via `./scripts/memory_compact.sh` — moves inbox to archive, creates compaction summary, updates current.md and timeline.md.
- Only one person/agent should compact per cycle (daily or weekly) to avoid races.
- Curate `memory/current.md` periodically so it stays useful as a session bootstrap.
