# Booking widget envelope empty - cross-step scope erosion on first_widget
- Timestamp: 2026-05-16T00:52:26Z
- Author: Kadyapam
- Tags: travel,booking,widget,playbook,dsl-v2,task-result-proxy

## Summary
Follow-up to noetl/travel#43. Phone fix and calendar persist chain fix unblocked the booking flow runtime, but the booking widget arrived in firestore with envelope:'' so the UI rendered nothing. Server log smoking gun: 'TaskResultProxy object has no attribute first_widget' (template_len=37) at append_widget_event. The same DSL v2 cross-step scope erosion that broke the calendar chain also breaks render_widget_chat.first_widget at append_widget_event when the calendar persist chain runs (now two steps removed); the reference resolves to a TaskResultProxy that does not expose nested attributes. Fix in noetl/travel#44 (catalog v36): propagate first_widget, second_widget, has_second_widget, bot_message, final_slot_state via ctx.* on the arc out of render_widget_chat (both branches), then read from ctx in append_widget_event / append_second_widget_event / append_chat_event / final_result. Validation exec 627680699104887004: full step chain runs, agent_widget_emit firestore event now contains the full envelope (was empty string). Side evidence: catalog v35 exec 627673724816195999 had Duffel return ok=True status_code=201 order=ord_0000B6L06jLwfg9wf724JM booking_reference=74KAEG total=657.66 USD; the order is in Duffel, only the UI widget was missing. Pattern to remember for future NoETL DSL v2 playbooks: any value referenced more than ONE step downstream from its producer must be propagated via 'set: ctx.X' on the arc; cross-step references on TaskResultProxy do not resolve nested attributes.

## Actions
-

## Repos
-

## Related
-
