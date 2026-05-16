# Travel booking unblocked - phone + calendar persist chain
- Timestamp: 2026-05-16T00:30:10Z
- Author: Kadyapam
- Tags: travel,booking,duffel,playbook-stall,dsl-v2,closed

## Summary
Two distinct bugs in repos/travel/playbooks/itinerary-planner.yaml v34 caused the Book CTA to silently dead-end on travel.mestumre.dev: (1) _test_passengers used phone_number +15555550100 (US 555 fiction range), Duffel test API returned HTTP 422 invalid_phone_number for every order, no order ever reached the Duffel dashboard; (2) the persist_calendar_event_N chain stalled at the first arc whose when: referenced render_widget_chat from a downstream step -- NoETL DSL v2 does not bind cross-step refs in arc when: evaluation, both is defined / is not defined branches resolved against StrictUndefined and no arc fired, leaving every booking exec stuck in RUNNING after persist_calendar_event_1 (server log: 'Object of type StrictUndefined is not JSON serializable'). Fix in noetl/travel#43: switch test phone to +442080168000 (London local, Duffel-accepted) and propagate calendar payloads/count via set: ctx.X on the arc into persist_calendar_event_1, then evaluate downstream arcs against ctx.calendar_event_count >/<= N (canonical DSL v2 cross-step pattern). Validation on GKE catalog v35 exec 627668770076492547: completed=true failed=false current_step=end duration=30s, full step trace reaches final_result, persist_calendar_event_1 -> persist_calendar_event_2 -> append_widget_event chain runs end-to-end. Follow-up noetl/ops#94 adds the missing 'step: end (kind: noop)' terminator to automation/agents/mcp/duffel.yaml so Duffel sub-executions stop accumulating in RUNNING state in noetl.execution (parent already unblocked because it reads call.done, but the table polluted on every dispatch).

## Actions
-

## Repos
-

## Related
-
