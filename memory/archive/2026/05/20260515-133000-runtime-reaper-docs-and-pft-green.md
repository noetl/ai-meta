# Runtime reaper documentation refresh after PFT v2 green

Date: 2026-05-15

## Summary

PFT v2 execution `627209422065893596` completed successfully after the
command reaper and runtime reaper workstream landed and redeployed on
local kind.

Important distinction:

- The automatic recovery during the PFT v2 run was performed by the
  **in-process NoETL command reaper** in `repos/noetl`
  (`noetl/server/command_reaper.py`), running inside `deploy/noetl-server`
  under a runtime lease.
- `repos/doctor` is the **out-of-process runtime reaper /
  self-healing surface** for monitoring and MCP callers. It detects,
  probes, inspects, and can trigger safe repair by delegating back to
  NoETL playbooks/APIs. It does not directly reclaim commands or write
  to `noetl.command`.

## Observed PFT v2 recovery evidence

Execution:

- `execution_id`: `627209422065893596`
- path: `fixtures/playbooks/pft_flow_test/test_pft_flow_v2`
- status: `COMPLETED`
- duration: `3h 54m 21s`
- end time: `2026-05-15T13:07:31Z`

Validation:

- 10/10 facilities logged in `demo_noetl.public.pft_test_validation_log`.
- Each facility reached `1000/1000` for assessments, conditions,
  medications, vital signs, demographics, and assessment queue.
- MDS was non-zero and complete for every facility. Facility examples:
  - facility 1: `22630 / 22630`
  - facility 6: `22362 / 22362`
  - facility 10: `22521 / 22521`

Command table final state:

```text
status     count
---------  -----
COMPLETED  26199
```

No `PENDING`, `CLAIMED`, `RUNNING`, `FAILED`, or `CANCELLED` rows were
left for the execution.

Server log evidence showed the command reaper intervened twice:

```text
[COMMAND-REAPER] Found 20 orphaned active command(s); re-publishing
[COMMAND-REAPER] Re-published execution_id=627209422065893596 ... step=fetch_mds_details:task_sequence
[COMMAND-REAPER] Re-published 20/20 recovered commands
```

This happened twice on `fetch_mds_details:task_sequence`, so 40 MDS
detail commands were recovered automatically by NoETL.

## Documentation updates requested

User asked to:

- update ai-meta memory;
- update `repos/docs` regular documentation with a dedicated doctor
  section;
- update `repos/doctor` documentation and review all docs there to
  match current state.

Docs should state clearly that `doctor` is shorthand for the runtime
reaper / self-healing surface, not a generic doctor toolkit, and that
correctness rules stay in `repos/noetl`.
