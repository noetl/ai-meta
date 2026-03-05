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

- Preferred playbook:
  - `repos/ops/automation/development/noetl.yaml`
- Typical redeploy command (from `repos/ops`):
  - `noetl run automation/development/noetl.yaml --runtime local --set action=redeploy --set noetl_repo_dir=../noetl`

This keeps build/deploy behavior consistent with project automation defaults.

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
