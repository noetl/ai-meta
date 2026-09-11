# External Memory Systems

This repository supports external systems as memory extensions for AI agents.

## Goal

Keep local Git memory and external trackers synchronized so tasks survive across sessions, tools, and people.

## Supported systems

- GitHub Issues
- Jira
- GitHub Wiki
- Confluence

## Operating model

Use local repository memory as the operational memory backbone:

- `memory/current.md` for active state
- `memory/inbox/` for raw entries
- `memory/compactions/` for periodic summaries
- `sync/issues/` for cross-repo change linkage

Use external systems as durable memory extensions:

- Issues/tickets track task lifecycle, blockers, owners, and acceptance criteria.
- Wiki/docs pages track stable technical knowledge and runbooks.

## Required synchronization points

When a substantive task changes state, update in the same session:

1. Local memory (`memory/` and/or `sync/issues/`)
2. Work item (`GitHub Issue` and/or `Jira`)
3. Documentation memory (`GitHub Wiki` and/or `Confluence`) when public surfaces changed

## Linking standard

Every substantive cross-repo task should include these links:

- One primary task ID (`<repo>#<number>` and/or `<JIRA_KEY>`)
- Submodule PR URL(s)
- Relevant wiki/confluence page URL(s)
- Local sync note path (`sync/issues/...`)
- Local memory entry path (`memory/inbox/...`)

## Safety

- Never copy secrets or private data into issues, tickets, wiki pages, or confluence pages.
- If a diagnostic string includes sensitive values, redact before storing externally.
