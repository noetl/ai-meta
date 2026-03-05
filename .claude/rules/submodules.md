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
