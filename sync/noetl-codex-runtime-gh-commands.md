# GitHub Commands: NoETL Codex Runtime Program

Run from any shell with a valid `gh` login for the `noetl` org.

## 1) Authenticate

```bash
gh auth login -h github.com
gh auth status
```

## 2) Create tracking issues

### noetl/cli

```bash
gh issue create \
  --repo noetl/cli \
  --title "feat(cli): add noetl codex passthrough and noetl ai bootstrap (M1)" \
  --body-file /Volumes/X10/projects/noetl/ai-meta/sync/issues/2026-03-27-noetl-cli-codex-runtime-program.md \
  --label "program:codex-runtime,area:cli,type:feature,priority:p0"
```

### noetl/gateway

```bash
gh issue create \
  --repo noetl/gateway \
  --title "design(gateway): validate and align session/runtime contracts for noetl ai operations (M1)" \
  --body-file /Volumes/X10/projects/noetl/ai-meta/sync/issues/2026-03-27-noetl-gateway-codex-runtime-contract.md \
  --label "program:codex-runtime,area:gateway,type:design,priority:p0"
```

## 3) Create GitHub Project (org-level)

```bash
gh project create \
  --owner noetl \
  --title "NoETL AI Runtime Program" \
  --body "Cross-repo delivery for Codex-powered noetl CLI with gateway contract alignment."
```

Get project number:

```bash
gh project list --owner noetl
```

## 4) Add issues to project

Replace `<PROJECT_NUMBER>`, `<CLI_ISSUE_URL>`, `<GATEWAY_ISSUE_URL>`:

```bash
gh project item-add <PROJECT_NUMBER> --owner noetl --url <CLI_ISSUE_URL>
gh project item-add <PROJECT_NUMBER> --owner noetl --url <GATEWAY_ISSUE_URL>
```
