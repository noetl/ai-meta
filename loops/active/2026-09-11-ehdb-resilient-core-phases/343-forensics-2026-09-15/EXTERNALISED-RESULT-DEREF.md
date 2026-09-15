# Externalised results are invisible to mid-workflow consumers

Found 2026-09-15 while validating adiona/frontend#21/#22 on prod. Read-only
diagnosis plus a playbook-side mitigation; the real fix is a server change.

## The failure

A step result over the runtime byte budget is stored out of line. The consuming
step receives:

```json
{"data": {"_ref": "noetl://execution/<eid>/result/<step>/<event_id>"}, "status": "success"}
```

`docs/rfc/decoupled-context-event-chain.md` §1 is explicit that **resolution is a
read-side concern** — `hydrate_result_references` runs when an execution is read
back through the API. Nothing hydrates it for a step consuming the value
**mid-workflow**, so a `kind: playbook` parent gets the raw reference.

**It fails silently.** `status: success`, no error, an empty list. Every step
reports success. Measured: `muno/playbooks/hotel-cards` returned 0 hotels on four
consecutive prod runs while the HotelBeds child had actually fetched **5 hotels /
509 images / 67 rates (214,805 bytes)**.

This is very likely the "hotel search stopped working" report in
adiona/frontend#22 — it needs no failing execution id to reproduce.

## Why it started

adiona/frontend#22 grew the hotel payload deliberately: all Content-API images
instead of 6, up to 20 rates per hotel, 20 hotels instead of 10. That pushes the
result over the externalisation floor. Flight payloads (~41-148 KB) stay under it
and work; hotel payloads (~215 KB) now routinely exceed it.

Per the RFC, externalisation was ~1% of `call.done` events over 90 days. Any
change that grows a `kind: playbook` child result can move a flow across that
line, and nothing warns you.

## ⚠ The trap inside the trap

Reading the child execution back gives the reference **plus `extracted`
metadata**. `extracted` is explicitly flagged `_truncated` — it is a SAMPLE.

An early cut of the mitigation used it and reported **1 hotel as though it were
the whole answer**. That is silently wrong, which is strictly worse than empty,
and it would have passed a smoke test. If you deref, check `_truncated` before
trusting anything you find.

The reference object carries: `ref`, `uri`
(`noetl://default/default/results/<eid>/<step>/0/0/1`), `store: "db"`,
`meta.bytes`, `meta.sha256`, `ipc.lease_expires_at`, and `extracted`.

## What the API does NOT offer

- `/api/executions/{id}` returns the reference, not the payload.
- No query param hydrates it — `hydrate`, `resolve`, `inline`, `include`, `full`
  all return byte-identical responses.
- No `/api/result`, `/api/results`, `/api/artifact`, `/api/result-index`, or
  `/api/executions/{id}/result` route exists (all 404).
- `kind: artifact` (get/put) is documented for the **Python** runtime; prod runs
  the Rust worker and the ref is `noetl://`, not `artifact://`.

The payload IS in the object store and is readable out of band:

```
gs://shastaratech-noetl-prod-results/noetl/env=prod/region=usc1/cell=usc1-a/
  shard=s0068/tenant=default/project=default/date=2026-09-15/
  execution=<eid>/results/<step>/0/0/1.json
```

but `region`/`cell`/`shard` are not derivable from the `uri`, so a playbook
cannot construct that path without listing. Reimplementing the result-tier
client inside a playbook would be the wrong fix.

## Mitigation shipped (noetl/travel#122)

`hotel-cards` and `flights-details` detect the reference, attempt the API read,
**refuse `_truncated` data**, and report `deref_error` naming the cause and the
byte size. A plumbing failure can no longer masquerade as "the provider returned
nothing". It does not make hotels work end-to-end.

## What the platform needs

Hydrate references on the API read path, or expose a deref endpoint. Until then,
**any `kind: playbook` child whose result crosses the byte budget silently
returns nothing** — and the consumer cannot tell.

Worth pairing with the `full_coverage` gate recommendation in
`CATALOG-SPLIT-ROOTCAUSE.md`: both are cases where the platform answers
confidently and wrongly instead of refusing.
