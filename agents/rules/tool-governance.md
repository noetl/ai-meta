# Tool and MCP Governance

Every tool, MCP server, or subagent an agent profile can call is an
expansion of that agent's capability and risk surface. New capability
needs a deliberate decision, not an implicit one that arrives as a side
effect of an agent profile edit.

## Registry

When specializing this template, list approved tools/MCP servers here:

| Tool / MCP server | Scope | Risk tier | Approved for | Owner | Approved date |
| :-- | :-- | :-- | :-- | :-- | :-- |
| TBD | TBD | read-only / write / credentialed / destructive | agent profile(s) | TBD | TBD |

The registry is the source of truth for what capability exists and who
approved it. An agent profile (`agents/profiles/*.md` or
`.claude/agents/*.md`) must not reference a tool or MCP server that isn't
listed here.

## Risk tiers

- **read-only** — no state change possible (read files, search, fetch
  public data).
- **write** — can change local repo state (edit files, commit locally).
- **credentialed** — requires an explicit `auth:` reference per
  [`no-default-connection.md`](no-default-connection.md) to reach an
  external system.
- **destructive** — can push, deploy, delete, or otherwise affect shared
  state irreversibly; requires the same human gating
  [`safety.md`](safety.md) and [`handoffs.md`](handoffs.md) require for
  destructive phases, regardless of which agent or tool triggers it.

## Rules

- Adding a new tool/MCP server to any agent profile requires a registry
  entry first: scope, risk tier, which profile(s) it's approved for, an
  owner, and the approval date.
- A `destructive`-tier tool must never be invoked without the same
  explicit human gate a handoff's gated phase requires — automation does
  not exempt a call from this.
- A `credentialed`-tier tool must declare its `auth:` reference per
  [`no-default-connection.md`](no-default-connection.md); it never falls
  back to an ambient default.
- Retiring a tool: mark its registry row retired (don't delete the row)
  and remove it from every agent profile that referenced it, in the same
  change.
- Review the registry whenever a new agent/tool integration is proposed,
  or whenever `.claude/settings.json` permission allowlisting changes
  would expand what an agent can reach unattended.

## Coordination with other rules

- [`no-default-connection.md`](no-default-connection.md) — credentialed
  tools need explicit auth references.
- [`data-access-boundary.md`](data-access-boundary.md) — platform-owned
  data still goes through the owning service API, regardless of which
  tool a workflow step uses to reach it.
- [`safety.md`](safety.md) and [`execution-model.md`](execution-model.md)
  — gating for destructive actions.
- [`agents/README.md`](../README.md) — where profiles and adapters live.
