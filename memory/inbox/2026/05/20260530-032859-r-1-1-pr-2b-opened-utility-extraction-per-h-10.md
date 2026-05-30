# R-1.1 PR-2b opened: utility extraction per § H.10
- Timestamp: 2026-05-30T03:28:59Z
- Author: Kadyapam
- Tags: rust,executor,migration,issue-30,pr-22,r1-1-pr2b

## Summary
PR noetl/cli#22 extracts 432 LoC of utility logic from src/playbook_runner.rs into three new noetl-executor modules: template.rs (~280 LoC), condition.rs (~200 LoC), capabilities.rs (~190 LoC). 6 CLI method bodies become 1-line forwards. validate_capabilities becomes an adapter that calls a pure function returning ValidationReport. Per § H.10.3 restructure: placeholder LocalPlaybookSource + sources/ + dispatch.rs deleted from PR-1. CommandSource trait moved under noetl-executor::worker::source. playbook_runner.rs went 2,277 -> 1,964 lines (-313 net). 13 new unit tests; noetl-executor test count 3 -> 16. cargo check + cargo test --workspace green. No CLI behavior change; tree walker stays untouched. Next: PR-2c lifts ~870 LoC of inline tool execution and replaces with noetl-tools calls.

## Actions
-

## Repos
-

## Related
-
