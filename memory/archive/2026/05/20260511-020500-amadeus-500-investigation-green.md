# Amadeus 500 investigation closed - sandbox/service-side verdict

Date: 2026-05-10

Item #7 closed as diagnostic GREEN. The audit table from the render-audit side-effect round did its job: `travel_agent_events` immediately showed the pattern instead of forcing screenshot archaeology.

Findings:

- Flights, locations, and hotels all return Amadeus HTTP 500 with error code 38189 from the test API.
- The same 38189 response reproduces with direct curl/Python urllib using a fresh OAuth token and both NoETL's exact payloads and documentation-style control payloads.
- Activities is healthy upstream: direct Times Square and docs Madrid calls returned HTTP 200 with large result sets.
- Therefore the 500 verdict is (b) Amadeus test sandbox/service-side failure, not a NoETL payload bug. No ops PR was opened.

Separate follow-up discovered:

- Activities rows in `travel_agent_events` are not true Amadeus failures. The child `automation/agents/mcp/amadeus` execution returned `data_ok=true`, `data_status_code=200`, and 1799 activities, but the result was stored as a large NoETL reference. The travel parent did not hydrate the referenced child payload and rendered `render_amadeus_failure`.
- Future fix shape: compact `search_activities` before returning to the parent, make the MCP playbook tail bubble a compact result, or teach parent child-result fetch to hydrate NoETL references.

Sync issue filed:

- `sync/issues/2026-05-11-amadeus-test-api-500s.md`

Architectural lesson:

Audit side effects inside render tails are now paying rent. The system can distinguish upstream API failures from local projection/result-carrier failures quickly because the audit rows record intent, provider, envelope status, and classification context.
