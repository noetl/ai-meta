# Amadeus test API 500s - investigation

Date: 2026-05-10
Status: filed
Verdict: (b) Amadeus test API sandbox/service-side failure for flights, locations, and hotels; no NoETL payload fix shipped.

## Summary

The travel agent's Amadeus failure widgets are doing the right user-facing thing: upstream failures are contained and the execution completes with a friendly `app:column` error widget. The missing piece was root-cause evidence.

The new `travel_agent_events` audit rows show a narrow pattern, not a general travel-agent failure:

| Intent | Status | Rows | First seen UTC | Last seen UTC |
| --- | ---: | ---: | --- | --- |
| locations | 500 | 4 | 2026-05-10 04:51:57 | 2026-05-10 05:25:32 |
| flights | 500 | 2 | 2026-05-10 04:48:25 | 2026-05-10 05:24:42 |
| hotels | 500 | 2 | 2026-05-10 04:52:40 | 2026-05-10 05:26:25 |
| activities | null | 2 | 2026-05-10 04:53:24 | 2026-05-10 05:27:17 |

The direct API reproduction used a fresh OAuth token from the same GCP Secret Manager-backed credentials. The token flow returned HTTP 200. Flights, locations, and hotels then returned the same Amadeus error:

```json
{"errors":[{"code":38189,"title":"Internal error","detail":"An internal error occurred, please contact your administrator","status":500}]}
```

This reproduced with both our exact payloads and documentation-style control calls. Activities returned HTTP 200 for both the travel payload and the Amadeus documentation example, so the sandbox is not globally down.

## Direct Reproduction

Credentials and tokens were sanitised. Only token prefix/length was printed during the run.

Token:

```text
POST https://test.api.amadeus.com/v1/security/oauth2/token
status=200
token_prefix=sb1GqDFe...
```

Flights, exact NoETL MCP payload:

```text
POST https://test.api.amadeus.com/v2/shopping/flight-offers
origin=SFO destination=JFK departureDate=2026-07-15 adults=1 maxFlightOffers=10
status=500
error.code=38189
```

Flights, docs-style GET control:

```text
GET https://test.api.amadeus.com/v2/shopping/flight-offers?originLocationCode=MAD&destinationLocationCode=ATH&departureDate=2026-07-15&adults=1&max=3
status=500
error.code=38189
```

Locations, exact shape:

```text
GET https://test.api.amadeus.com/v1/reference-data/locations?keyword=Boston&subType=AIRPORT%2CCITY
status=500
error.code=38189
```

Hotels, docs example shape:

```text
GET https://test.api.amadeus.com/v1/reference-data/locations/hotels/by-city?cityCode=PAR
status=500
error.code=38189
```

Activities, travel payload:

```text
GET https://test.api.amadeus.com/v1/shopping/activities?latitude=40.758&longitude=-73.9855&radius=5
status=200
data_count=1799
```

Activities, docs example:

```text
GET https://test.api.amadeus.com/v1/shopping/activities?longitude=-3.69170868&latitude=40.41436995&radius=1
status=200
data_count=117
```

## Spec Comparison

The current NoETL MCP playbook's call shapes line up with the Amadeus public docs:

- Flight Offers Search supports both GET and POST forms. The minimum GET form requires origin IATA code, destination IATA code, ISO `YYYY-MM-DD` departure date, and adult count. Our exact POST payload and an equivalent GET both failed with the same 38189 response. Source: https://developers.amadeus.com/self-service/apis-docs/guides/developer-guides/resources/flights/
- Airport and City Search uses `GET /v1/reference-data/locations` with required `subType` and `keyword`. Our query passes both as query parameters. Source: https://developers.amadeus.com/self-service/apis-docs/guides/developer-guides/resources/flights/
- Hotel List by city requires `cityCode`; the docs example uses `cityCode=PAR`, which failed with 38189. Source: https://admin.developers.amadeus.com/self-service/apis-docs/guides/developer-guides/resources/hotels/
- Tours and Activities by radius requires latitude and longitude; both our Times Square query and the docs Madrid example returned 200. Source: https://developers.amadeus.com/self-service/apis-docs/guides/developer-guides/resources/destination-experiences/

No fixable field-shape deviation was found for the 500ing endpoints.

## Separate Non-500 Finding

The two `activities` audit rows are not Amadeus 500s. Direct curl returns 200, and the child `automation/agents/mcp/amadeus` execution for `search_activities` also returned `data_ok=true`, `data_status_code=200`, and `data_activities_total=1799`.

The parent travel execution still rendered `render_amadeus_failure` because the successful child result was very large and stored as a referenced payload (`noetl://...`, 1.2 MB compressed). The parent agent hop saw only the child execution id and not the hydrated activity data. This is a separate follow-up from the Amadeus 500 investigation: either cap the `search_activities` result before returning to the parent, make the MCP playbook tail bubble a compact summary, or teach the parent-side child fetcher to hydrate NoETL result references.

## Recommendation

Do not patch `automation/agents/mcp/amadeus.yaml` for flights, locations, or hotels in this round. The smallest correct action is to keep the friendly error widget and document the Amadeus sandbox failure pattern.

Follow-ups:

1. Production-Amadeus switch capability landed in ops#72 (`e9cf2fdaf3c482513268a5ba7642d732362d5221`) as a code-only GREEN. `automation/agents/mcp/amadeus` now accepts `amadeus_env: test | production`, defaults to `test`, switches OAuth/API hosts to `api.amadeus.com` only when production is requested, and uses separate production secret paths. Production smoke is pending secret provisioning for `amadeus-production-client-id` and `amadeus-production-client-secret`; no paid production API calls were made in the switch round.
2. Add an activities-result compaction/hydration round so successful `search_activities` calls do not look like travel failures when the child result is stored by reference.
3. Consider adding a short retry for Amadeus 500 code 38189 only if production shows intermittent recovery; the current evidence suggests a persistent sandbox/service-side failure, not a transient one.
