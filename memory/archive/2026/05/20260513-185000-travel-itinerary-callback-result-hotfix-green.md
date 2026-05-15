# Travel itinerary callback result hotfix GREEN

Date: 2026-05-13

Context:
- Live Travel submit reached `Muno is planning...` and eventually showed `Playbook callback timed out`.
- GKE logs proved the playbook was being called (`POST /api/execute 200`), so the failure was inside the itinerary workflow before a useful gateway callback payload reached the browser.

Diagnosis:
- `append_widget_event.next` tested `render_widget_chat.second_widget.widget_type` directly.
- On single-widget turns, NoETL's `TaskResultProxy` may not expose that optional nested value, so transition evaluation emitted template errors before the workflow reached a clean callback payload.
- After the Firestore append side-effect steps, `final_result` also could not reliably read `render_widget_chat.first_widget` as a top-level proxy field; the preserved value was available through `render_widget_chat.context.first_widget`.

Fix:
- travel#28 (`de566d087e60f256e060785cb3c00c43c4375288`) added an explicit `has_second_widget` boolean in `render_widget_chat`.
- The optional companion-widget transition now branches on that boolean instead of probing `second_widget.widget_type`.
- `render_widget_chat` now carries `final_slot_state`.
- `final_result` reads `slot_state`, `widget`, and `bot_message` from `render_widget_chat.context.*`, preserving the execution-level `render` payload the gateway callback needs.

Validation:
- `npm run test`
- `npm run type-check`
- `npm run build`
- Patched playbook registered on GKE as catalog version 12.
- Direct distributed GKE smoke execution `626258185636020693` completed in 9s at `final_result`, with `render.widget_type=place_autocomplete_input`.
- PR checks passed and Cloudflare Pages production deploy `25836791694` completed successfully.

Notes:
- The live catalog was hot-registered before the PR merged so `travel.mestumre.dev` could be unblocked immediately.
- This was a playbook/source fix, not a frontend deploy requirement, but the Pages pipeline still completed cleanly after merge.
