# Travel order_confirmation null document_url crashed widget validator
- Timestamp: 2026-05-16T03:56:28Z
- Author: Kadyapam
- Tags: travel,order-confirmation,duffel,widget-validator,ajv,closed

## Summary
Fresh booking on travel.mestumre.dev after the noetl/travel#46 + noetl/ops#95 round failed with 'Unable to render this response (template mismatch): data/documents/0/document_url must be string, data/documents/1/document_url must be string'. Duffel test mode returns electronic_ticket entries with document_url=null; #95 added the documents passthrough but the OrderConfirmation widget envelope schema typed document_url as 'string' only, so Ajv envelope validation in src/components/WidgetRenderer.tsx rejected the envelope. Two-layer fix: (1) noetl/ops#96 -- _safe_order now keeps only documents where document_url is a non-empty string, so the field never appears as null. Verified via get_order on existing ord_0000B6L1uvQtkAarjW4RbU: was 2 electronic_ticket docs with null url, now 0 documents (filtered). (2) noetl/travel#47 -- widget-contract/order_confirmation.schema.json relaxed unique_identifier/type/document_url to ['string','null'] as defensive belt-and-suspenders for any null that slips through some other path. Important: existing firestore agent_widget_emit events from BEFORE the v8 deploy still carry the bad payload, so historical bubbles stay broken. New bookings on Duffel MCP v8+ are clean. Pattern to remember: every nullable upstream field that ends up in a widget envelope payload needs either source filtering or schema ['string','null'] -- Ajv is strict and the WidgetRenderer falls back to BotText with the error string.

## Actions
-

## Repos
-

## Related
-
