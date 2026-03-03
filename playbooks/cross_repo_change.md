# Playbook: Cross-Repo Change

## Inputs

- Feature/bug description
- Impacted repositories
- Required release channels

## Steps

1. Confirm impacted submodules.
2. Create branches in impacted repos.
3. Implement + validate per repo.
4. Open PRs and merge.
5. Update `ai-meta` submodule pointers.
6. Add a short sync note in `sync/`.

## Output

- List of merged PRs
- Final submodule SHAs
- Any follow-up release actions
