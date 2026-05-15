# Travel Duffel flight contract hotfix GREEN

Date: 2026-05-13 21:10 PT

Kadyapam reported that the Travel/Muno planner reached Duffel flight search but the UI rendered a template mismatch. The failing render came from execution `626325398611034294`: Duffel offers used provider-shaped segment fields (`iataCode`, `carrierCode`, `number`, `numberOfStops`) while the `flight_list` widget contract requires canonical segment fields (`departure.iata`, `arrival.iata`, `carrier`, `flight_number`, `stops`) and forbids provider-only extras.

Fix shipped in `noetl/travel#34`:

- `playbooks/itinerary-planner.yaml` now normalizes Duffel flight offers before emitting `flight_list`.
- Segment normalization maps airport, carrier, flight number, duration, and stop count into the widget contract shape.
- Carrier and total stop metadata are derived from normalized segments when provider-level fields are absent.

Validation:

- `npm run test`
- `npm run type-check`
- `npm run build`
- YAML parse for `playbooks/itinerary-planner.yaml`
- GKE playbook re-registered as `muno/playbooks/itinerary-planner` version 29.
- Cloudflare Pages production deploy `25841024416` completed successfully.

Note: a direct GKE smoke retry during this hotfix was blocked before `normalize_input` by an unrelated worker queue/backlog symptom, so the shipped proof is contract-shape normalization plus CI/Pages/build validation. The specific live mismatch is addressed by stripping raw Duffel segment keys before render.
