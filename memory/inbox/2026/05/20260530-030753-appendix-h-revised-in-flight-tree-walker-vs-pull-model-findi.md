# Appendix H revised in flight: tree walker vs pull-model finding (§ H.10)
- Timestamp: 2026-05-30T03:07:53Z
- Author: Kadyapam
- Tags: rust,architecture,appendix-h,finding,issue-30,pr-175

## Summary
While starting R-1.1 PR-2b, surveyed post-PR-2a state of playbook_runner.rs in depth. Found that the CLI is a recursive tree walker (~550 LoC control loop, evaluates next arcs / case / then in place) while the worker is a pull-model consumer (no tree, no recursion). Different shapes — the original CommandSource trait unification was wrong abstraction for the CLI. Strategy C selected: pause coding, rewrite the binding plan. noetl/docs#175 adds § H.10 + rewrites § H.3 + § H.5 R-1.1. noetl-executor becomes a utilities-and-types crate (template + condition + capabilities + credentials + types + events + arrow), not a control-loop crate. CLI keeps its tree walker; worker keeps its NATS pull loop; CommandSource moves under noetl-executor::worker::*. PR-2b shifts from ~1,200 LoC parser-extraction to ~430 LoC utility extraction. PR-2c stays as tool-dispatch via noetl-tools. PR-2d closes #19. R-1.2 folds into PR-2b/2c. Process note: this is the normal recovery path for mid-implementation architectural findings, same as the v2-spec Phase 3 audit drift recovery.

## Actions
-

## Repos
-

## Related
-
