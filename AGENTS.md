# NoETL ai-meta AI Instructions

This file defines mandatory behavior for AI agents operating in this repository.

## Scope

- Applies to the entire `ai-meta` repository.

## Mission

- Orchestrate changes across submodule repositories.
- Keep centralized instructions accurate and current.
- Maintain deterministic submodule SHAs for reproducible cross-repo states.

## Hard rules

1. This repository is **private** and must stay private.
2. Do not store product code here.
3. Allowed content:
   - AI instruction files
   - orchestration docs/checklists
   - submodule pointer updates
4. Prefer minimal, atomic pointer updates per change set.
5. Never rewrite history on `main`.

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

## Suggested commit message format

- `chore(sync): bump <repo1>, <repo2> to merged SHAs`
- `docs(agents): update cross-repo workflow guidance`

## Validation before merge

- `git submodule status --recursive` is clean and expected.
- Changed pointers map to merged commits in upstream repos.
- Instruction docs remain internally consistent.
