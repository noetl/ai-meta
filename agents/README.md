# Agent Mapping

This directory is the shared source of truth for AI-agent behavior in
`ai-meta`.

## Source of Truth

- `agents/rules/` contains mandatory shared rules for all agents.
- `agents/skills/` contains shared workflow definitions and command recipes.
- `agents/profiles/` contains per-agent behavioral profiles.

Do not duplicate rules, skills, or profiles under tool-specific directories.
Tool-specific directories should adapt these shared files to the format that
tool expects.

## Claude Adapter

`.claude/` is Claude Code's adapter layer:

- `.claude/rules` is a symlink to `../agents/rules`.
- `.claude/skills` is a symlink to `../agents/skills`.
- `.claude/agents/*.md` are Claude Code subagent wrappers. They provide
  Claude-specific frontmatter, then import the matching shared profile with
  `@agents/profiles/<name>.md`.
- `.claude/settings.json` defines Claude Code permissions, hooks, and env.
- `.claude/settings.local.json`, `.claude/worktrees/`, and
  `.claude/agent-memory-local/` are local state and must stay untracked.

The `codex` wrapper in `.claude/agents/codex.md` is a Claude Code subagent
for Codex-style code work. It is not the standalone Codex runtime.

## Agent Entry Points

| Agent or tool | Primary entrypoint | How it uses shared agent files |
| --- | --- | --- |
| Claude Code | `CLAUDE.md` and `.claude/settings.json` | Auto-loads Claude settings and uses `.claude/rules` / `.claude/skills` symlinks into `agents/`. Claude subagents in `.claude/agents/` import shared profiles. |
| Standalone Codex | `AGENTS.md` plus repository context | Reads shared rules and should use `agents/profiles/codex.md` for role guidance. It does not consume `.claude/agents/codex.md` directly. |
| Gemini CLI | `GEMINI.md` | Reads `AGENTS.md`, shared memory, `agents/rules/`, and `agents/profiles/gemini.md`; uses skills as documented workflows and scripts. |
| GitHub Copilot | `.github/copilot-instructions.md` | Reads shared rules, profiles, and skill docs as instructions. Skills are not native Copilot commands. |
| Cursor | `.cursorrules` | Reads shared rules, profiles, and skill docs as instructions. |

## Refactoring Rule

When changing agent behavior:

1. Put shared policy or workflow content in `agents/`.
2. Keep tool-specific files thin and limited to startup order, integration
   mechanics, or frontmatter required by that tool.
3. If a rule applies to every agent, link to it from the relevant entrypoints
   instead of copying its content.
4. If a Claude subagent needs new behavior, update the shared profile or skill
   first, then adjust `.claude/agents/*.md` only for Claude-specific metadata.
