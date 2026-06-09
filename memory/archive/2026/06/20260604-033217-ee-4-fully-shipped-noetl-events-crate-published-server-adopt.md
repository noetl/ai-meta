# EE-4 fully shipped: noetl-events crate published + server adoption (server v2.9.0)
- Timestamp: 2026-06-04T03:32:17Z
- Author: Kadyapam
- Tags: rust,events,crates-io,server,ee-4,umbrella-49,phase-f-next

## Summary
Three-PR sequence closed in one extended session.  PR 1 (noetl/cli#49) extracted the noetl-events workspace crate from noetl-executor::events; the executor's events module became a 1-line re-export.  PR 2 (noetl/cli#50) prepped the crates.io publish — bumped noetl-executor to 0.4.0 + added the noetl-events publish block to the cli release workflow (positioned before the executor block, since the dep graph is events <- executor <- bin).  Manual gh workflow run release-cli on cli@d6e2432 then landed all three crates on crates.io in one go: noetl-events 0.1.0 (first release), noetl-executor 0.4.0, and noetl 4.9.0 itself — the last had been stuck on a pre-existing 'cannot find function gcs_upload in module noetl_executor::tools_bridge' bin-verification failure between live executor 0.3.1 and current source, which the 0.4.0 re-publish resolved as a side effect.  PR 3 (noetl/server#38, server v2.9.0) wired the adoption: noetl-events = '0.1' direct dep on noetl-server, plus From<ExecutorEvent> + TryFrom<&EventRequest> impls in src/handlers/events.rs, plus four wire-compat tests pinning the shared-subset round-trip semantics.  Design call: server's EventRequest legitimately keeps its 5 server-only fields (result_kind, result_uri, event_ids, actionable, informative) and its String wire format for execution_id / event_id (browser JSON-number precision); the two types stay distinct but the SHARED SUBSET is now anchored to noetl_events::ExecutorEvent.  Future changes to either type that break compat fail the build instead of a kind-val cycle.  No runtime behavior change in the live POST /api/events handlers; the new conversions are infrastructure for follow-up callers.  noetl/ai-meta#49 stays open — Phase F (sharding design + cutover) is the next major phase.

## Actions
-

## Repos
-

## Related
-
