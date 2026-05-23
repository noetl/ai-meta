# Travel View full order CTA routed to hotel search
- Timestamp: 2026-05-16T01:41:15Z
- Author: Kadyapam
- Tags: travel,booking,view-full-order,playbook,cta-routing

## Summary
OrderConfirmation widget's View full order button emits action_id=order:<id>. Playbook had no handler for that prefix in repos/travel/playbooks/itinerary-planner.yaml v37, so extract_turn fell through to default branching; with slot_state at picked_flight + order_id + no hotel_search_results the next branch was show_hotels and the click triggered Amadeus hotel search instead of order details. Fix in noetl/travel#45 (catalog v38): detect action_id.startswith('order:') -> view_order_now=True; insert 'elif picked_flight and view_order_now and order_id: render_intent={kind:order_detail}' BEFORE show_hotels; cache normalised order in slot_state.last_order on create_order success; new render branch order_detail re-emits order_confirmation from slot_state.last_order with ctas=['new_search'] only (drop view_full to avoid self-loop). Validation exec 627705564037906769: chain reaches final_result with no call_amadeus_hotels step; envelope is full widget_type=order_confirmation order_id=ord_0000B6L06jLwfg9wf724JM ref=74KAEG. ai-meta pointer bumped to feae570 for repos/travel which includes #43+#44; #45 still pending merge. Pattern to remember: every CTA action_id prefix the React widgets emit needs an explicit handler in extract_turn -- otherwise the playbook silently progresses to the next default branch which can look like the wrong feature being triggered.

## Actions
-

## Repos
-

## Related
-
