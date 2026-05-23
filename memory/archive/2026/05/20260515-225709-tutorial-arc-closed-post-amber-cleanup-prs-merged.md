# Tutorial arc closed + post-amber cleanup PRs merged
- Timestamp: 2026-05-15T22:57:09Z
- Author: Kadyapam
- Tags: tutorial,runtime-reaper,pft-v2,closed,pointer-bump

## Summary
Six PRs merged on 2026-05-15: tutorial e2e #19, tutorial docs #72, runtime-reaper docs #73, PFT v2 fixture #20, NoETL #433 (same-worker CLAIM hard-timeout reclaim, released as 2.38.1), and ops #92 (helm reaper knobs + Postgres CPU/probe tuning). ai-meta pointers bumped on local main: doctor f117ab1, noetl dcfd4cd, ops bdca8a6, e2e f87e607, docs 62b145d. Local-kind tutorial validation reproduced earlier GKE result: WI exec 627604897713619379 wrote noetl-demo-output/.../627604897713619379.csv (183B) and HMAC exec 627605072314106408 wrote noetl-demo-19700101/.../627605072314106408.csv (190B), all 14 command rows COMPLETED with error=null. Pointer-bump commits sit on local ai-meta main (ahead 2) plus on the pushed worktree branch claude/crazy-blackwell-78e4fa; ai-meta main push to origin not yet authorized.

## Actions
-

## Repos
-

## Related
-
