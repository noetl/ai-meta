# issue 251 readiness-gated recovery implemented
- Timestamp: 2026-03-05T09:14:07Z
- Author: Kadyapam
- Tags: noetl,issue-251,recovery,auto-resume,ops,kind,validation

## Summary
Opened noetl/noetl issue #251 and implemented readiness-gated startup recovery in repos/noetl (restart/cancel modes, dependency checks for Postgres+NATS+worker heartbeats, retry/backoff, and auto_resume metrics). Opened PR #252 and validated via tests plus local kind redeploy using ops automation playbook.

## Actions
- Created issue: https://github.com/noetl/noetl/issues/251
- Pushed branch `codex/issue-251-recovery-playbook` to `noetl/noetl`
- Opened PR: https://github.com/noetl/noetl/pull/252
- Posted issue update: https://github.com/noetl/noetl/issues/251#issuecomment-4003534355
- Updated `ai-meta/AGENTS.md` with ops-playbook-based NoETL image build/deploy guidance
- Validated local kind redeploy using `repos/ops/automation/development/noetl.yaml`

## Repos
- noetl/noetl: `40d42beb` (branch `codex/issue-251-recovery-playbook`)
- noetl/ai-meta: pending pointer/memory commit

## Related
- https://github.com/noetl/noetl/issues/251
- https://github.com/noetl/noetl/pull/252
