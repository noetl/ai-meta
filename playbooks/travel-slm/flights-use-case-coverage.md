# Flights use-cases — spec validation + coverage matrix

- **Spec:** `Flights_Training_Use_Cases.md` (owner-supplied 2026-08-19) — 10
  general rules, 9 canonical slots, scenarios F1–F10, MVP = F1–F6 + F7–F8.
- **Assessed against:** `muno/playbooks/itinerary-planner` **v83** (now **v88**) (the only
  playbook the SPA calls — `ChatThread.tsx:14`) and
  `muno/playbooks/flight-planner` **v3** (standalone, not wired to the UI).
- **Method:** read of the registered playbook logic, not assumptions. Line
  references are `repos/travel/playbooks/itinerary-planner.yaml`.

---

## 1. Spec validation — internal coherence

The spec is coherent and implementable. Five points need a ruling; I picked a
reading for each and implemented it, flagged here so the owner can overrule.

| # | Issue | Reading taken |
| :-- | :-- | :-- |
| S1 | **Rule 6 "Best value" is qualitative** — "speed/convenience first, then most price-efficient among the stronger candidates". No cutoff for "stronger". | Take the top half of candidates by duration (min 3), then pick lowest price-per-hour among them. Deterministic, and it cannot collapse onto Cheapest by construction. Documented in-playbook. |
| S2 | **Rule 1 vs Rule 9 overlap.** Rule 1 caps flight *duration* by trip length; Rule 9 says show layovers "mainly for trips of about a week or longer". Both key off trip length and can disagree (a 9h one-stop on a week trip is allowed by 1, encouraged by 9). | Rule 1 is a *ranking hint* only (the spec says so explicitly); Rule 9 governs presentation order. Neither filters. |
| S3 | **Rule 4 requires "party information" before search**, but F1/F2 list party as *optional* ("when it affects pricing"). | Treat party as **defaultable to 1 adult** only when the user gave no party signal at all, and never re-use a stale party across a change. Origin / destination / dates are hard-gated; party is soft. |
| S4 | **Rule 10 lap-infant** says "typically age 16+" for the ticketed adult but the platform has no adult-age slot. | Count every adult as eligible. Infant-per-adult ratio enforced; adult age not modelled. Flagged as roadmap. |
| S5 | **F7 baggage / fare flexibility** — "Do not claim baggage or flexibility without fare-rule data". Duffel returns baggage per passenger, but the planner's `_normalise_offer` **drops it**. | Store as a *preference*, do not claim it, and surface only what the provider returns. Pre-search filtering is not supported → roadmap. |

No contradictions found that block implementation.

---

## 2. Gap analysis — general rules (v83, before this change)

| Rule | State | Evidence |
| :-- | :-- | :-- |
| 1 · duration→radius heuristic | **Missing** | no `max_flight_hours` anywhere |
| 2 · origin inference + explicit override | **Partial** | `flight_origin` parsed from text wins, but the fallback is a hardcoded `"NYC"` (L1307) / `"SFO"` (L1354), not platform context |
| 3 · profile precedence | **N/A** | no profile store exists |
| 4 · required-input gating | **VIOLATED** | the flight branch fabricates every missing input: `origin or "NYC"`, `destination or "PAR"`, `departure = today+30` (L1302-1307). It searches instead of asking. |
| 5 · one primary tool per turn | **Satisfied** | exclusive arcs; `tool_requests[:1]` in the LLM validator |
| 6 · three result groups | **Missing** | no cheapest/fastest/best-value anywhere |
| 7 · no-result handling | **VIOLATED** | see rule 7 finding below |
| 8 · stale results | **Missing** | nothing clears `flight_search_results` / `picked_flight_offer_id` on slot change |
| 9 · layovers | **Missing** | `stops` computed for the card only; never used for ranking |
| 10 · children / lap infants | **Missing** | passengers built as `[{"type":"adult"}] * adults` (L2447) — children dropped entirely |

### ⚠ Rule 7 — the planner fabricates flight inventory

`show_flights` renders a **synthetic offer with a fabricated price** whenever
the provider returns nothing:

```python
flight_items = offers[:10] or [{
    "offer_id": "synthetic-offer-1",
    "price": {"total": "220.00", "currency": "USD"},
    ...
}]
```

An empty or failed Duffel response therefore shows the user a **$220 flight that
does not exist**. The same pattern exists for places, hotels, activities and
transfers (L4646-4696), and in `flight-planner` v3 (L1225).

This is the single most serious gap: it is a direct violation of rule 7 ("Do not
invent inventory") and F10 ("Do not fabricate flights, prices, or availability"),
and it is live.

---

## 3. Gap analysis — scenarios

| # | Scenario | Before | After this change |
| :-- | :-- | :-- | :-- |
| F1 | Open discovery | **Partial** — discovery works, but a flight ask with no origin/dates searched on fabricated defaults | **Satisfied** — gated; asks for the blocking input |
| F2 | Named destination, no dates | **Violated** — searched immediately using `today+30` | **Satisfied** — gated on dates |
| F3 | Named origin + destination | **Violated** — an explicit origin was *dropped* (one unknown LLM key rejected the whole payload) so the platform default was used; and a single date silently added a return leg | **Satisfied** — unknown keys aliased; one-way stays one-way |
| F4 | Exact dates, destination missing | **Violated** — destination defaulted to `PAR`/`MIA` | **Satisfied** — gated on destination |
| F5 | Budget-led | **Missing** — no budget slot reached the search or the ranking | **Partial** — cap post-filters returned fares + relaxation offered; Duffel has no price parameter |
| F6 | Relative / window dates | **Partial** — heuristic parses ISO + "next month"; the LLM handles relative language | **Partial** — verified ("next weekend" → 2026-08-29); month-*window* scanning is roadmap |
| F7 | Route/stop/baggage/cabin/timing | **Mostly missing** — cabin hardcoded `"economy"`, no stops filter, no time window, baggage dropped | **Partial** — cabin + nonstop (`max_connections`) + return_date now passed; baggage/flex/time stored as preferences, not claimed |
| F8 | Passenger / family | **Violated** — children dropped from the search entirely | **Satisfied** — child + lap-infant passengers built per rule 10 |
| F9 | Corrections | **Violated** — nothing invalidated stale offers, *and* a correction with no flight keyword ("actually make it business class") left the flight branch entirely and asked for travellers | **Satisfied** — stale invalidation on any search-affecting slot change, and a thread with a route + date stays a flight thread through a flight-slot adjustment |
| F10 | Empty / provider failure | **VIOLATED** — fabricated a flight | **Satisfied** — `error_card` naming the blocking constraint + controlled relaxations |

## 3b. Two defects only execution found

Both were invisible to a read of the playbook and both returned a
confident wrong answer rather than an error. Neither was in the original
gap analysis, which is the point.

| Defect | Symptom | Why a read missed it |
| :-- | :-- | :-- |
| **Invented return leg** | `on 2026-10-10` searched `return_date: 2026-10-14` | A single date derives a checkout at +4 days for the hotel side; `_flight_args` read `check_out_date` and could not tell a *stated* range from a *derived* one. Both look identical in slot state. |
| **Correction left the flight branch** | `actually make it business class` rendered `party_picker` | The flight branch keys off flight keywords. A correction has none, so the turn fell through to the guided flow — only visible on a **second** turn of the same thread. |

The return-leg fix is not cosmetic: on that query it moved the fare
**86.11 → 38.37 USD**, because the search is finally the one the user
asked for. A one-way ask priced as a round trip is a wrong answer that
looks entirely plausible.

Durable lesson, in the shape of `representation-drift.md`: **`check_out_date`
was a copy with no provenance.** Two different facts — "the user stated a
range" and "we derived an end date" — were stored in one field, so every
reader downstream had to guess which one it held. The fix stores the
provenance (`dates_explicit_range`) rather than teaching each reader a
heuristic.

---

## 5. Proof — real executions on prod, live providers

No unit tests; every row is an execution against Duffel through the
registered playbook.

| Scenario | Observed |
| :-- | :-- |
| F1 / F4 vague | gates without inventing a destination |
| F2 missing dates | `collect_missing missing=['dates']` → `date_range_picker` |
| F3 explicit origin | `origin: LIS` overrides the SFO default; three groups rendered |
| F5 impossible cap | `error_card` · `blocking_constraints: ["budget 50 EUR"]` · `alternatives: [raise_budget, flexible_dates, nearby_airports]` · **no fabricated offer** |
| F5 satisfiable cap | filtered `flight_list`, groups intact |
| F6 relative dates | "next weekend" → `departure_date: 2026-08-29` |
| F7 cabin + nonstop | `cabin_class: business`, `max_connections: 0` (643.60 vs 243.55 economy) |
| F8 family | `passengers: [adult, adult, infant_without_seat]` |
| F9 correction | turn 2 preserves route + date, re-searches at `cabin_class: business` |
| F10 empty result | `error_card`, never a synthetic offer |
| one-way vs range | single date → no `return_date`; stated range → `return_date` present |
| regression | places / hotels / activities / transfers unchanged |

**Rule 6 is best evidenced by the F9 corrected turn**, where the three
groups genuinely diverge: Cheapest 342.10 (1 stop) · Fastest 475.60
(nonstop 2h25m) · **Best value 378.59** — neither of the other two.

Registered: `itinerary-planner` **v88**, `flight-planner` **v4**.

---

## 4. Not implementable on the current provider — roadmap, not faked

| Capability | Why |
| :-- | :-- |
| Baggage / fare-flexibility **filtering** | Duffel exposes baggage per passenger on the returned offer, not as a search parameter; `_normalise_offer` also drops it today. Pre-search filtering would be a fiction. |
| Month-**window** scanning (F6) | Requires iterating departure dates at the tool layer; one request = one date. |
| Multi-city trip type | The slice builder is one-way / return only. |
| Departure-time window (F7) | No Duffel search parameter; would need post-filtering on segment times, which silently shrinks an already-capped 10-offer page. |
| Adult-age eligibility for lap infants (S4) | No adult-age slot in the party model. |
