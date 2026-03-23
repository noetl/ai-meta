# Render namespace fix for ctx and iter
- Timestamp: 2026-03-23T08:42:14Z
- Author: Kadyapam
- Tags: noetl,rendering,ctx,iter,prod,pr-300

## Summary
Prod execution 588775268844568971 failed after ctx.facility_mapping_id rendered through TaskResultProxy instead of plain dict lookup. Opened noetl PR #300 to keep ctx, iter, loop, and event namespaces as plain dicts during Jinja rendering and added focused regressions for ctx.facility_mapping_id and iter.patient.patient_id lookups.

## Actions
-

## Repos
-

## Related
-
