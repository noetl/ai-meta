# Canvas form-submit fixed; widget rerun button remains AMBER
- Timestamp: 2026-05-09T07:35:42Z
- Author: Codex
- Tags: ai-os,travel-agent,gui,canvas,widgets,amber,report-formatter,local-kind

## Summary
Codex processed bridge task `20260509-071816-canvas-form-submit-and-report-formatter-amber-to-green`. GUI PR noetl/gui#31 merged at `bfa0b90d83ea90498f802ce7c2991296452ee5c4`; semantic-release produced `v1.10.2` at `4ac127c8aecedbb34b706e791d9621db1e70bed3`. The local kind GUI deployment was bumped to `ghcr.io/noetl/gui:v1.10.2` through the `bump_image` lifecycle after the GHCR image workflow finished.

## Evidence
The AntD form-submit fix worked. Submitting `flights from SFO to JFK on 2026-07-15 for 2 adults` from `/travel` stayed on `/travel?after-submit=v8` and produced execution `622809044436123891`; the assistant bubble rendered the `Travel agent · search failed` app:column widget below the chat entry. Hard refresh preserved the query and widget. The `report 622809044436123891` command now prints `render=app:column` in the textual summary and still renders the widget below. Terminal prompt regression remained green: `travel help` (`622811334584828248`), flights (`622811387315618221`), and locations (`622811469029048850`) all completed with inline widgets.

## Remaining AMBER
The canvas widget `rerun this search` button still navigates to `/catalog` instead of resubmitting in-place from `/travel`. This is separate from the native form-submit bug: direct canvas submit is now fixed, but widget command routing in the canvas surface still needs a follow-up. No GREEN validation log paragraph was appended.

## Lesson
Two GUI rules are now clear. First, routed pages with Enter-handling inputs should wrap the input in an explicit form submit handler that calls `preventDefault`. Second, canvas-rendered widget command events need their own in-place command routing contract; fixing the input form does not automatically fix buttons inside the rendered widget tree.
