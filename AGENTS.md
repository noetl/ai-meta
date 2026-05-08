# NoETL ai-meta AI Instructions

This file defines mandatory behavior for AI agents operating in this repository.

## Scope

- Applies to the entire `ai-meta` repository.

## Mission

- Orchestrate changes across submodule repositories.
- Keep centralized instructions accurate and current.
- Maintain deterministic submodule SHAs for reproducible cross-repo states.

## Hard rules

1. This repository is public; never store secrets or sensitive values.
2. Do not store product code here.
3. Allowed content:
   - AI instruction files
   - orchestration docs/checklists
   - submodule pointer updates
   - AI memory entries and compactions
4. Memory updates must be append-only through Git history.
5. Prefer minimal, atomic pointer updates per change set.
6. Never rewrite history on `main`.

## Submodule handling

- Always run from repository root.
- Use:
  - `git submodule sync --recursive`
  - `git submodule update --init --recursive`
- For cross-repo changes:
  1. implement in submodule repo branch
  2. merge upstream PR
  3. update submodule pointer here
  4. commit pointer bump with summary

## NoETL image build/deploy workflow (local dev)

When validating `repos/noetl` changes in local kind, use **ops playbooks from `repos/ops`** instead of ad-hoc kubectl/image scripts whenever possible.

Local kind deployments for this workspace must use the configured Podman machine only. Do not use Colima, a Colima Docker socket, or a Docker fallback for kind cluster creation or NoETL deployment. If Podman is unavailable or unhealthy, stop and report the Podman error instead of switching runtimes.

This repository lives under `/Volumes`; the Podman machine must mount `/Volumes:/Volumes` or kind `extraMounts` will fail. If the host shell sets `XDG_DATA_HOME` to a custom path, unset it for Podman/kind commands so Podman machine metadata and disk state stay in the same default location.

- Preferred playbook:
  - `repos/ops/automation/development/noetl.yaml`
- Typical redeploy command (from `repos/ops`):
  - `noetl run automation/development/noetl.yaml --runtime local --set action=redeploy --set noetl_repo_dir=../noetl`

This keeps build/deploy behavior consistent with project automation defaults.

## Read-only reference submodules

Reference repositories live under `references/<name>` (NOT `repos/<name>`,
which signals active development). They are tracked via `.gitmodules` but
configured `submodule.<name>.update = none` and `submodule.<name>.ignore =
all` so they are not bumped during normal cross-repo updates.

Currently tracked references:

- `references/chatui` — `mlflowio/chatui`. Read-only reference for
  rich-message rendering patterns in a chat UI. We adapt the pattern
  for NoETL's terminal-style prompt component
  (`repos/gui/src/components/NoetlPrompt.tsx`); we do **not** modify
  this submodule, do not propose upstream changes, do not include it
  in deploys. Treat as documentation.

If a reference needs to evolve into an actively-modified dependency, fork
it under `noetl/` first and re-add at the new path under `repos/`.

## Suggested commit message format

- `chore(sync): bump <repo1>, <repo2> to merged SHAs`
- `docs(agents): update cross-repo workflow guidance`
- `memory(add): <topic>`
- `memory(compact): <scope or date>`
- `memory(curate): refresh current.md for <scope>`

## Validation before merge

- `git submodule status --recursive` is clean and expected.
- Changed pointers map to merged commits in upstream repos.
- Instruction docs remain internally consistent.

## Logging hygiene

- Keep logs minimal by default. Avoid INFO-level logs for high-frequency health/internal polling paths.
- When adding new health/check/poll endpoints, either:
  - suppress access logs for those paths, or
  - log at DEBUG with rate-limiting/sampling.
- Any change that can increase request log volume must include a quick flood check and an explicit rationale.
