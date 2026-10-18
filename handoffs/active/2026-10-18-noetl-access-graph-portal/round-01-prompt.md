---
thread: 2026-10-18-noetl-access-graph-portal
round: 1
from: codex
to: claude
created: 2026-10-18T17:47:52Z
status: open
expects_result_at: round-01-result.md
wait_phrase: "publish portal branch"
---

# NoETL global portal: identity-to-scope access graph

Build the first safe, useful step toward a NoETL-hosted interface where users can request access to labs, projects, curated assets, and explicitly approved services/playbooks. This is a **global NoETL platform** capability, not a GLUT-specific portal. GLUT may be a future pilot, but do not hard-code its people, data, or scientific workflow into the platform.

## Domain decision

Use **noetl.ai** as the canonical product/runtime portal domain; retain **saqbit.com** for corporate/brand presence. NoETL's public site itself describes the division as “Start on noetl.dev, Build with GitHub, Operate on noetl.ai” (<https://www.noetl.io/>). Treat that as the product-domain recommendation, not proof that the DNS, hosting, certificate, or app route is already configured. First inspect the current deployment and domain conventions; use an existing app subdomain such as `app.noetl.ai` only if that is the established routing pattern. Do not change DNS, certificates, identity-provider settings, or production routing in this round.

## Background and start-up checks

- Work from the live NoETL ecosystem state, not assumptions in this prompt. Follow `ai-meta/CLAUDE.md`, `AGENTS.md`, `memory/current.md`, relevant `agents/rules/`, current issues, and wiki instructions first. Check repository, submodule, and wiki SHAs/branches before editing.
- The previous inspection saw `memory/current.md` dated 2026-06-09 and the ai-meta wiki `Home.md` refreshed 2026-07-01, while the live ai-task queue had progressed through at least #480. Reconcile these against GitHub before creating/updating issues; do not copy their old active-issue list as current.
- At handoff creation, the NoETL product-code submodules were not initialized in this checkout; only `repos/ai-meta-wiki` was initialized. Initialize only the relevant submodules after inspection and verify their actual state. Do not assume a GUI, gateway, or server feature exists because it is proposed here.
- The NoETL execution boundary is load-bearing: the gateway authenticates/authorizes/routes but is not a data plane; browser code and gateway handlers must not directly read/write PostgreSQL, GCS, or domain data. Data reads/writes, external APIs, and projections must run inside policy-controlled playbook steps. For `noetl.*`, follow the server-owned HTTP API boundary; preserve the event log as the source of truth. Workers remain atomic compute; do not add persistent per-tenant agents/processes.
- This repository is public. Never commit credentials, private reviewer data, raw molecular structures, or other restricted data. Use synthetic/public fixtures for tests.

## Goal and product model

Users should be able to authenticate, request or accept an invitation to a workspace context, and see only assets and actions explicitly granted to them. “Organization → lab → project” may be useful as a **navigation or labeling convention**, but it must not be an authorization inheritance tree. Organizations, labs, projects, people/groups/service identities, and assets are independently addressable entities linked by explicit relationships. Any entity can relate to multiple others; assets and projects can be shared across organizations through explicit, auditable grants. Membership in an organization must not silently confer access to every lab, project, asset, or playbook under it.

Do not invent a schema before inspecting existing identity, catalog, project, resource, and authorization models. The conceptual model to validate against the existing platform is:

- **Principal:** a verified user, group, or service identity authenticated by the platform's existing identity provider.
- **Scope:** an organization, lab, project, or other existing supported workspace scope. Scope links are for organization/discovery; they do not imply transitive permission.
- **Asset/service:** a catalogued dataset, result, resource, connector, or service with an owner/custodian, provenance/classification, and supported operations.
- **Membership/grant:** an explicit edge from a principal or approved scope to a scope/asset, carrying role or allowed actions, purpose, grantor/approver, validity/expiry, and revocation/audit state. Default is deny. Cross-organization sharing requires a direct, reviewable grant; no implicit transitive sharing.

Use the platform's existing policy/role vocabulary where possible. Avoid creating a second identity system or parallel role database. At minimum, test reader/reviewer versus editor/operator/owner boundaries and ensure that read permission does not imply execute, share, administer, or download permission.

## Phases

### Phase A — inspect and map (read-only)

1. Read the current agent/repo instructions, live ai-task issues, and relevant wiki pages. If the task is not already tracked, open an ai-meta `ai-task` umbrella before substantive implementation, select the correct primary `repo:<name>` label, add it to roadmap board 3, and update the corresponding wiki dashboard/session/umbrella pages per current rules. First reconcile the known stale dashboard rather than append to an obsolete issue inventory.
2. Inspect the existing GUI/navigation, authentication/session flow, gateway authorization boundary, server APIs and catalog/resources, playbook policy model, storage/result retrieval path, and current deploy/domain configuration. Record paths, SHAs, and observed contracts. Locate existing invitation, membership, organization, project, asset, or grant primitives before proposing new ones.
3. Produce a short current-state map and threat boundary: what is already implemented, what is missing, which repo owns each gap, and how real data is safely served today. Confirm whether the public product entry point is `noetl.ai`, a subdomain, or an existing route. This phase does not change DNS or deploy.

### Phase B — design the smallest end-to-end vertical slice

4. Write a concrete authorization/data-flow design that fits the observed code. Specify the entity relationships, explicit grant/revoke/expiry semantics, role-to-action matrix, invitation/request/approval lifecycle, audit events, and the non-hierarchical sharing rules. Include a compact threat model covering IDOR/object-ID guessing, cross-org leakage, expired/revoked access, identity spoofing, unauthenticated endpoints, privilege escalation, confused-deputy playbooks, and direct-store bypass.
5. Choose an MVP that is safe and demonstrable: authenticated, invite/request-based registration; an administrator reviews and approves membership; a reviewer sees a curated, explicitly granted asset list; a permitted read or submission uses an allowlisted policy-governed playbook. Any later write/execute capability must be separately granted, constrained to named playbooks/actions, and audited. If existing contracts cannot support the slice safely, stop at the design and report the exact missing API/schema/owner rather than inventing a hidden path.
6. Define behavior for cross-organization asset sharing and revocation, including what the recipient can discover before grant (prefer no asset metadata leakage), whether access expires, and how downloads/copies are handled. A URL, email-domain match, organization membership, or anyone-with-link setting is not an authorization grant.

### Phase C — implement and verify locally

7. Implement the approved minimal slice in the actual owning submodule(s), with policy enforced server-side and data touched only inside allowed playbook steps. Use existing auth and storage interfaces. No arbitrary SQL, arbitrary URI/file access, open-ended workflow execution, or browser/gateway direct data-store access. Keep GUI permissions as affordances, not the authority boundary.
8. Add tests for: unauthenticated denial; same-org without a direct grant denied; explicit cross-org grant allowed only for named action; no implicit org→lab→project inheritance; expired and revoked grants denied promptly; reviewer cannot edit/share/execute; guessed asset IDs reveal no content or sensitive metadata; playbook policy rejects unapproved operations; actor, approver, purpose, and decision are auditable. Include positive and negative paths.
9. Validate with synthetic/public fixtures and the repo's required test/format/type checks. If container behavior changes, validate on configured local kind before considering any hosted rollout. Report exact commands/results, failures, and untested boundaries. Update the relevant per-repo wiki and ai-meta cross-repo tracking as required.

### Phase D — publishing and deployment gates

Local implementation and commits on a feature branch are in scope. **Do not push a branch, open a PR, merge, change DNS/identity-provider settings, expose real/private data, or deploy to shared/production infrastructure without explicit human go-ahead.** For a branch push/PR, wait for the user to say `publish portal branch`. Any deployment requires a separate explicit human instruction in that session. Never push to `origin/main` or merge a PR.

## Scientific and data-integrity boundary

This is identity/access infrastructure, not a scientific finding. Keep all scientific authority and fail-closed determination gates closed. A portal membership, asset grant, workflow run, uploaded artifact, or reviewer comment must not promote a provisional result to a finding or authorize a scientific determination. Do not represent synthetic fixture output as project evidence.

## FINAL REPORT

Always write `round-01-result.md`, including on early stop, with frontmatter:

```yaml
---
thread: 2026-10-18-noetl-access-graph-portal
round: 1
from: claude
to: codex
created: <ISO8601 UTC>
in_reply_to: round-01-prompt.md
status: complete | partial | blocked
---
```

Include:

```markdown
## Phase A — inspect and map
- Current app/auth/data path, verified paths and SHAs, and domain finding.

## Phase B — design
- Chosen MVP, permission model, threat model, and unresolved decisions.

## Phase C — implementation and verification
- Changed repos/files/branches/commits and exact tests with outcomes.

## Issues observed
- Grep-able errors, blockers, or security-relevant surprises; quote exact fingerprints.

## Manual escalation needed
- Anything that needs a human, with precise action/command and why.
```

## Hard rules

- Follow the current repo instructions and the NoETL execution/data-access boundary above.
- Never commit secrets, credentials, private/user data, or raw biochemical structures.
- Do not alter DNS, authentication-provider configuration, cloud IAM, production data, or deployment state in this round.
- Never push to `origin/main`, force-push, or merge a PR.
- If the current implementation cannot support least-privilege authorization without bypassing policy, stop and report the concrete gap.
