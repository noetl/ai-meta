# Travel full widget envelope event extraction shipped

Date: 2026-05-13 23:38 PDT

After terminal event extraction shipped, the Travel UI found the widget in
execution `626403360127582634` but attempted to render a shallow projected
envelope:

```text
Unable to render this response (template mismatch): data must have required property 'payload'
```

The NoETL execution detail showed two related shapes:

- Terminal `final_result` and `render_widget_chat` contexts carried only a
  shallow widget header: `schema_version`, `widget_type`, and `variant`.
- `append_widget_event` contexts carried the full envelope at
  `data.event.payload.envelope`, including the required `payload` object with
  the Paris place data and static map URL.

Fix shipped in `repos/travel` PR #38:

- Only treat a widget object as renderable when it has
  `schema_version: 1`, `widget_type`, and an object `payload`.
- Recover full envelopes from `append_widget_event` result contexts at
  `data.event.payload.envelope`.
- Also support full envelopes from command-issued tool payloads at
  `tool_config.payload.arguments.event.payload.envelope`.
- Prefer full envelope event contexts over shallow terminal projections.
- Preserve terminal `bot_message` and slot-state extraction from `final_result`.

Validation:

- `npm run build` passed locally in `repos/travel`.
- `npm test -- --run` passed locally: 9 files, 19 tests.
- GitHub `Build and verify` passed on PR #38.
- Cloudflare Pages preview passed on PR #38.
- PR #38 was squash-merged to `noetl/travel@343082a`.
- Main Cloudflare Pages deploy passed for run `25845821989`.
- Live `https://travel.mestumre.dev` serves asset `index-Bdk5Cjbw.js`.

Design lesson:

Terminal event projections can preserve the widget header but drop nested
payload content. For rendered widgets, the browser must require a full envelope
and search event contexts that store the original emission, especially
`append_widget_event`.
