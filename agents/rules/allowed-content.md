# Allowed Content

Only the following may be committed to ai-meta:

- AI instruction files (CLAUDE.md, AGENTS.md, .claude/rules/, .claude/agents/, .claude/skills/)
- Orchestration docs and checklists (playbooks/, sync/)
- Submodule pointer updates (repos/*)
- AI memory entries and compactions for NoETL/platform or cross-repo orchestration state (memory/)

Project-specific memory belongs in the owning submodule repository. Keep
`glut-probe-design` memory under `repos/glut-probe-design/memory/` unless the
entry is specifically about NoETL platform changes, submodule pointer state, or
cross-repo orchestration.
