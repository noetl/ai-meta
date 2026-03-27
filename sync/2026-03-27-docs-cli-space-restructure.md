# Sync Note: 2026-03-27 — Docs CLI Space Restructure

## Summary
- Started docs IA update to give CLI a dedicated top-level section (parallel to Gateway).
- Moved CLI reference from `docs/reference/noetl_cli_usage.md` to `docs/cli/usage.md`.
- Updated cross-doc links to new canonical path `/docs/cli/usage`.

## Scope (Repos)
- repos/docs:
  - `sidebars.ts`: CLI moved to dedicated top-level section.
  - `docs/cli/usage.md`: new canonical CLI reference location.
  - `docs/reference/noetl_cli_usage.md`: compatibility stub page.
  - updated links in getting-started, development, test, and reference docs.

## PRs / Links
- repos/docs: pending

## Resulting SHAs / Tags
- repos/docs: changed (uncommitted in ai-meta workspace)

## Compatibility / Notes
- Backward compatible: yes (legacy path has compatibility page)
- Migration required: no
- Config/DSL impact: none
- Known risks:
  - external links to `/docs/reference/noetl_cli_usage` now land on move notice instead of full content.

## Follow-ups
- [ ] Open `noetl/docs` issue for docs IA change + review.
- [ ] Decide whether to keep legacy stub long-term or add redirect rule in Docusaurus config.
- [ ] Expand CLI section landing page to include Codex integration docs once M1 ships.

## Memory Entries
- memory/inbox/2026/03/20260327-212038-docs-cli-section-split-started-and-github-issue-creation-blo.md

## Verification
- Tests run: content/link grep validation only
- Environments verified: N/A
- Observability notes: N/A
