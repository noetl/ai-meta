# Handed travel PropertyBlock full slot surfacing to Codex (Round 11)

- date: 2026-05-13T16:00:00Z
- tags: trip-planner, travel, ux, property-block, slot-surfacing, codex-handoff, round-11

## Round goal

Second post-Round-9 UX iteration. Right-pane PropertyBlock today shows
only Destination + Dates even when the agent has captured more (party,
star rating, budget, bed type, amenities). Make it surface EVERY slot
the agent has collected, with the existing edit-pencil pattern per row.

Knocks the 'Full property block right-pane surfacing' bullet from
tutorial 08's 'What's NOT covered'. Pure repos/travel work + small
docs trim. Single travel PR. No infra. No new GCP setup.

## Decisions locked

- Filter-narrowing widgets (star rating slider, budget range, amenities
  chips) are a SEPARATE round. Round 11 renders the slot VALUES when
  the payload has them; it doesn't build the collectors.
- formatParty helper from Round 10 is reused for the party slot value.
- No schema changes — property_block schema already declares the right
  `slots[]` array shape.
- Pencil click on a slot → emits `widget_cta_click` with
  `{slot_id, action: 'edit'}` → agent re-opens the matching collector.
- Round 11 is INDEPENDENT of Round 10's pending browser smoke. If
  Round 10 surfaces a regression, fix separately; Round 11 doesn't
  touch Round 10's code paths.

## Pre-handoff (NONE)

travel main at `7a1902f` (post-Round-10-hotfix). No new secrets, no
new IAM, no new schemas.

## Bridge artefacts

- `bridge/inbox/delegated/20260513-160000-travel-property-block-full-slots.task.json`
- `scripts/travel_property_block_full_slots_msg.txt`

## Trigger prompt for Codex

```
Travel PropertyBlock full slot surfacing. Right-pane today only shows
Destination + Dates; make it render every slot the agent has captured
(region, dates, party, star rating, budget, bed type, amenities) with
the existing edit-pencil pattern per row. Trip-planner Round 11.

Bridge task: bridge/inbox/delegated/20260513-160000-travel-property-block-full-slots.task.json
Prompt details: scripts/travel_property_block_full_slots_msg.txt
Scoping doc: sync/issues/2026-05-12-trip-planner-app-scoping.md
Result file: bridge/outbox/20260513-160000-travel-property-block-full-slots.result.json

Pre-handoff: NONE. travel main at 7a1902f, no new GCP setup.

Run all 7 phases per the bridge task. Architectural rules:
  - repos/travel + repos/docs only.
  - NO schema changes. NO new widget types. NO collector widgets
    (filter narrowing is a separate later round).
  - NO auth/gateway/Firestore changes.
  - Reuse formatParty from Round 10; don't reimplement.
  - Cloudflare Pages auto-deploys preview + prod. Verify preview
    before merging to main.
  - Kadyapam-side browser smoke is the GREEN gate.
  - Round 11 is independent of Round 10's pending smoke; can land
    in parallel.
  - No tokens or credentials echoed.

If schema doesn't match the expected slots[]/edit_action_id shape:
AMBER + STOP, surface for review.
```

## Smoke checklist Kadyapam runs after deploy

1. Incognito → travel.mestumre.dev → sign in.
2. Prompt 'Trip to Paris'. Region appears in right pane.
3. Submit a date range. Dates appears (alongside Region).
4. Submit party (2 adults / 1 child age 3). Party appears, formatted
   as '2 adults · 1 child (3 yrs)' per Round 10.
5. Click pencil next to Region → destination collector reopens in
   chat.
6. Click pencil next to Dates → date_range_picker reopens.
7. Click pencil next to Party → party_picker reopens.

Star rating / budget / bed type / amenities will NOT yet appear
because the collector widgets aren't built. That's expected and
correct for Round 11 scope.

## What's after this round

Remaining v1 polish queue:
- Filter narrowing widgets (Round 12 — bigger; agent learns when to
  emit them).
- Date consistency between picker and rendered events (small).
- Mobile responsive (Figma `mob-*` variants — larger).
- NoETL server-side JWT validation (security hardening).
- Per-uid Firestore rules + authenticated Firebase reads (security).

## Related

- `sync/issues/2026-05-12-trip-planner-app-scoping.md`
- `memory/inbox/2026/05/20260513-100000-handed-travel-v1-ux-polish-to-codex.md` (Round 10)
- `memory/inbox/2026/05/20260513-144500-travel-shell-submit-menu-hotfix-green.md` (Round 10 hotfix)
- `repos/travel/src/components/widgets/PropertyBlock.tsx`
- `repos/travel/src/utils/formatParty.ts` (Round 10 reusable)
- `repos/travel/playbooks/widget-contract/property_block.schema.json`
