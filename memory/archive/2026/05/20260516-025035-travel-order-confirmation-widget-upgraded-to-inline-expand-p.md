# Travel order_confirmation widget upgraded to inline expand + PDF link
- Timestamp: 2026-05-16T02:50:35Z
- Author: Kadyapam
- Tags: travel,order-confirmation,duffel-pdf,widget-ux,closed

## Summary
Two follow-ups after noetl/travel#45. (1) View full order CTA was triggering a new playbook turn that re-emitted the same OrderConfirmation widget, looking like a duplicate bubble. Fix in noetl/travel#46: 'View full order' is now a client-side Collapse toggle showing per-slice itinerary + per-passenger detail inline; no widget_cta_click event for that action. (2) No path to Duffel PDF/electronic ticket. Added optional documents[{unique_identifier,type,document_url}] field to order_confirmation widget schema + payload. Travel UI renders a Download PDF button only when one of the documents has a non-empty document_url (uses <Button component=a target=_blank>). Pairs with noetl/ops#95: Duffel MCP _safe_order now passes through documents, and _create_order re-fetches via GET /air/orders/{id} when create response has empty documents (Duffel issues itinerary receipts async). Validation: Duffel test exec 627739854746420033 get_order returns 2 electronic_ticket documents with document_url=null -- Duffel test environment doesn't host PDFs (dashboard-only). Live mode orders will surface URLs. Travel npm type-check + smoke:widgets + build green; new bundle index-CeDaQ1wb.js. Catalog v39 for travel, v7 for duffel registered live on GKE. Pointer for repos/travel bumped to c25f1bc (PR #45).

## Actions
-

## Repos
-

## Related
-
