# Travel terminal event payload extraction shipped

Date: 2026-05-13 23:30 PDT

After callback fallback and gateway `/noetl` polling were fixed, the Travel UI
showed `COMPLETED` with an empty assistant response for execution
`626398065691198302`. The execution detail endpoint returned top-level
`result: null`, but its events contained the actual terminal payload:

- `final_result` had `render`, `bot_message`, and `final_slot_state`.
- `render_widget_chat` had `first_widget`, `bot_message`, and `final_slot_state`.
- The bot text was "I found a destination anchor. Next I need dates and
  travellers."

Fix shipped in `repos/travel` PR #37:

- When top-level `result`/`data` is empty, walk `execution.events`.
- Prefer `final_result`, then workflow/playbook completion contexts, then
  `render_widget_chat`.
- Extract `render` or `first_widget` as the widget envelope.
- Extract `final_slot_state`/`slot_state` for the right-pane trip state.
- Extract `bot_message`/`text`/`summary` instead of falling back to the raw
  execution status.

Validation:

- `npm run build` passed locally in `repos/travel`.
- `npm test -- --run` passed locally: 9 files, 19 tests.
- GitHub `Build and verify` passed on PR #37.
- Cloudflare Pages preview passed on PR #37.
- PR #37 was squash-merged to `noetl/travel@2c352d6`.
- Main Cloudflare Pages deploy passed for run `25845544449`.
- Live `https://travel.mestumre.dev` serves asset `index-BrcP-c6l.js`, and the
  deployed JavaScript contains the terminal event extraction markers
  `final_result`, `render_widget_chat`, and `first_widget`.

Design lesson:

NoETL execution detail may expose a null top-level `result` even when terminal
events contain the correct payload. Browser clients should treat terminal event
contexts as a first-class fallback result source, especially for playbooks whose
tail result can be hidden by gateway/projection behavior.
