import os

core_file = "repos/noetl/noetl/server/api/v2/core.py"
with open(core_file, "r") as f:
    content = f.read()

missing_constants = """

_COMMAND_TERMINAL_EVENT_TYPES = [
    "command.completed",
    "command.failed",
    "command.cancelled",
]

_EVENT_TYPE_TERMINAL_PREDICATE = (
    "event_type IN ("
    + ", ".join(f"'{e}'" for e in _COMMAND_TERMINAL_EVENT_TYPES)
    + ")"
)
_EVENT_TYPE_ACTIVE_CLAIM_PREDICATE = "event_type IN ('command.claimed', 'command.heartbeat')"
_EVENT_TYPE_CLAIMED_PREDICATE = "event_type = 'command.claimed'"
_EVENT_TYPE_SAME_WORKER_LATEST_PREDICATE = (
    "event_type IN ('command.started', 'command.heartbeat', 'command.completed', 'command.failed')"
)
_COMMAND_EVENT_DEDUPE_TYPES = {
    "call.done",
    "call.error",
    "step.exit",
    "command.started",
    "command.completed",
    "command.failed",
}

def _build_command_id_latest_lookup_sql(
    *,
    inner_select_columns: str,
    outer_select_columns: str,
    event_type_predicate: str,
    alias: str,
) -> str:
    \"\"\"
    Build latest-event lookup SQL with index-friendly command_id predicates.
    \"\"\"
    return f\"\"\"
        SELECT {outer_select_columns}
        FROM noetl.event {alias}
        WHERE execution_id = %s
          AND {event_type_predicate}
          AND meta ? 'command_id'
          AND meta->>'command_id' = %s
        ORDER BY event_id DESC
        LIMIT 1
    \"\"\"

_CLAIM_TERMINAL_LOOKUP_SQL = _build_command_id_latest_lookup_sql(
    inner_select_columns="event_type, event_id",
    outer_select_columns="event_type",
    event_type_predicate=_EVENT_TYPE_TERMINAL_PREDICATE,
    alias="terminal_match",
)
_CLAIM_EXISTING_LOOKUP_SQL = _build_command_id_latest_lookup_sql(
    inner_select_columns="event_id, worker_id, meta, created_at",
    outer_select_columns="event_id, worker_id, meta, created_at",
    event_type_predicate=_EVENT_TYPE_ACTIVE_CLAIM_PREDICATE,
    alias="claimed_match",
)
_CLAIM_SAME_WORKER_LATEST_LOOKUP_SQL = _build_command_id_latest_lookup_sql(
    inner_select_columns="event_type, event_id",
    outer_select_columns="event_type",
    event_type_predicate=_EVENT_TYPE_SAME_WORKER_LATEST_PREDICATE,
    alias="same_worker_latest_match",
)
_HANDLE_EVENT_CLAIMED_LOOKUP_SQL = _build_command_id_latest_lookup_sql(
    inner_select_columns="worker_id, meta, event_id",
    outer_select_columns="worker_id, meta",
    event_type_predicate=_EVENT_TYPE_CLAIMED_PREDICATE,
    alias="claimed_event",
)

"""

if "_COMMAND_EVENT_DEDUPE_TYPES" not in content:
    with open(core_file, "a") as f:
        f.write(missing_constants)
