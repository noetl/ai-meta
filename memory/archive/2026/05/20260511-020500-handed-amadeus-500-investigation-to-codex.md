# Handed Amadeus test API 500 investigation to Codex (diagnostic round)

- date: 2026-05-11T02:05:00Z
- tags: amadeus, test-api, 500-investigation, audit-data, codex-handoff

## Round goal

Diagnose the persistent Amadeus test API 500s on flights/locations
(and now hotels/activities). The friendly-error widget masks them, but
we don't actually know whether it's our payload, Amadeus sandbox flake,
or an auth quirk. Item #4 (audit side-effect) gives us the data to find
out.

## Why this is the right time

Item #4 just landed: travel_agent_events now captures every failure as a
render_amadeus_failure row with payload.envelope_status_code and full
classified_intent. That's the dataset we need. Before item #4, we'd have
been guessing from manual screenshot scrapes; now we can SQL the failure
pattern in seconds.

## Investigation strategy

1. **Characterise** via SQL on travel_agent_events. Group by intent +
   status_code. Pull 3-5 full payloads. Pattern: intent-specific /
   endpoint-wide / time-clustered.
2. **Reproduce with curl** using our exact payload + a known-good example
   from Amadeus docs. If their example also fails, sandbox flake.
3. **Compare** against developers.amadeus.com spec. Diff required/optional,
   formats, path/version, headers.
4. **Verdict** (a/b/c):
   - (a) Our bug: small ops PR fix, re-smoke
   - (b) Sandbox flake: document, recommend production switch as follow-up
   - (c) Auth quirk: document, propose token-refresh-on-401 follow-up
5. **Document** in sync issue + memory entry.

## Cap

1 ops PR if verdict (a) lands. Otherwise 0 PRs — investigation result
file + sync issue + memory entry only.

## Phases (6)

1. Characterise failure pattern.
2. Reproduce with curl.
3. Compare to Amadeus self-service spec.
4. Verdict + optional fix.
5. Document findings.
6. ai-meta pointer bump if (a).

## Bridge artefacts

- `bridge/inbox/delegated/20260511-020500-amadeus-500-investigation.task.json`
- `scripts/amadeus_500_investigation_msg.txt`

## What's next after this lands

8. NoETL-Python globals/locals idiom into the authoring guide as 13th rule
9. Single-source-of-truth refactor for the classifier system_prompt
10. Anthropic re-smoke (gated on user)

After #8 and #9, the architectural arc has no obvious next round. The
travel agent is feature-complete as a NoETL-DSL-as-templating-library
demo. Items #8/#9 are pure debt cleanup; #10 is gated on out-of-band
provisioning.
