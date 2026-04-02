# dsl fixture refactor aligned to pr347 completed
- Timestamp: 2026-03-28T16:59:04Z
- Author: Kadyapam
- Tags: dsl-refactor,noetl,fixtures,pr347,playbooks

## Summary
Aligned fixtures with merged noetl/noetl PR #347 (Mar 28, 2026): migrated 126 playbook fixture YAMLs under repos/noetl/tests/fixtures/playbooks to canonical DSL v2 fields and routing semantics (args->input, set_ctx/set_iter->set with scoped ctx./iter. targets, outcome->output, Arc.args/input->Arc.set, result config key->output, selected step.result references->step.data). Validated by full YAML parse of 139 fixture files and zero residual legacy-pattern matches.

## Actions
-

## Repos
-

## Related
-
