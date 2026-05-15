# Fix regex bug in Postgres SQL parser
- Timestamp: 2026-04-13T14:23:02Z
- Author: Kadyapam
- Tags: bugfix, postgres, sql

## Summary
Fixed 'cannot refer to an open group' re.error in postgres/command.py caused by invalid \3 backreference in the dollar-quote regex.

## Actions
-

## Repos
-

## Related
-
