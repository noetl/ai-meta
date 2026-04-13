import ast
import os

src_file = "repos/noetl/noetl/server/api/v2.py"
dest_dir = "repos/noetl/noetl/server/api/v2"

if not os.path.exists(dest_dir):
    os.makedirs(dest_dir)

with open(src_file, "r") as f:
    source = f.read()

tree = ast.parse(source)

# Top-level comments and docstrings
top_level_doc = ""
if isinstance(tree.body[0], ast.Expr) and isinstance(tree.body[0].value, ast.Constant):
    top_level_doc = f'"""\n{tree.body[0].value.value}\n"""\n\n'

# Extract all imports
imports = []
for node in tree.body:
    if isinstance(node, (ast.Import, ast.ImportFrom)):
        imports.append(ast.unparse(node))

imports_str = "\n".join(imports) + "\n\n"

node_mapping = {
    "router": "core",
    "_playbook_repo": "core",
    "_state_store": "core",
    "_engine": "core",
    "_nats_publisher": "core",
    "_batch_accept_queue": "core",
    "_batch_accept_workers_tasks": "core",
    "_batch_acceptor_lock": "core",
    "_CLAIM_DB_ACQUIRE_TIMEOUT_SECONDS": "core",
    "_CLAIM_LEASE_SECONDS": "core",
    "_CLAIM_ACTIVE_RETRY_AFTER_SECONDS": "core",
    "_BATCH_ACCEPT_ENQUEUE_TIMEOUT_SECONDS": "core",
    "_BATCH_ACCEPT_QUEUE_MAXSIZE": "core",
    "_BATCH_ACCEPT_WORKERS": "core",
    "_BATCH_PROCESSING_TIMEOUT_SECONDS": "core",
    "_BATCH_PROCESSING_WARN_SECONDS": "core",
    "_BATCH_PROCESSING_STATEMENT_TIMEOUT_MS": "core",
    "_BATCH_STATUS_STREAM_POLL_SECONDS": "core",
    "_BATCH_MAX_EVENTS_PER_REQUEST": "core",
    "_BATCH_MAX_PAYLOAD_BYTES": "core",
    "_COMMAND_CONTEXT_INLINE_MAX_BYTES": "core",
    "_EVENT_RESULT_CONTEXT_MAX_BYTES": "core",
    "_EVENT_RESULT_CONTEXT_MAX_ROWS_PER_COMMAND": "core",
    "_COMMAND_PUBLISH_RECOVERY_DELAY_SECONDS": "core",
    "_COMMAND_PUBLISH_RECOVERY_JITTER_SECONDS": "core",
    "_COMMAND_PUBLISH_RECOVERY_MAX_CONCURRENCY": "core",
    "_COMMAND_TERMINAL_EVENT_TYPES": "core",
    "_EXECUTION_TERMINAL_EVENT_TYPES": "core",
    "_BATCH_FAILURE_ENQUEUE_TIMEOUT": "core",
    "_BATCH_FAILURE_ENQUEUE_ERROR": "core",
    "_BATCH_FAILURE_QUEUE_UNAVAILABLE": "core",
    "_BATCH_FAILURE_WORKER_UNAVAILABLE": "core",
    "_BATCH_FAILURE_PROCESSING_TIMEOUT": "core",
    "_BATCH_FAILURE_PROCESSING_ERROR": "core",
    "_CLAIM_WORKER_HEARTBEAT_STALE_SECONDS": "core",
    "_CLAIM_HEALTHY_WORKER_HARD_TIMEOUT_SECONDS": "core",
    "_STATUS_VALUE_MAX_BYTES": "core",
    "_STATUS_PREVIEW_ITEMS": "core",
    "_ACTIVE_CLAIMS_CACHE_TTL_SECONDS": "core",
    "_ACTIVE_CLAIMS_CACHE_MAX_ENTRIES": "core",
    "_ACTIVE_CLAIMS_CACHE_PRUNE_INTERVAL_SECONDS": "core",
    "get_engine": "core",
    "get_nats_publisher": "core",
    "_invalidate_execution_state_cache": "core",

    "_BatchAcceptJob": "models",
    "_BatchAcceptanceResult": "models",
    "_BatchEnqueueError": "models",
    "ExecuteRequest": "models",
    "StartExecutionRequest": "models",
    "ExecuteResponse": "models",
    "EventRequest": "models",
    "EventResponse": "models",
    "BatchEventItem": "models",
    "BatchEventRequest": "models",
    "BatchEventResponse": "models",
    "ClaimRequest": "models",
    "ClaimResponse": "models",
    "_ActiveClaimCacheEntry": "models",

    "_contains_legacy_command_keys": "utils",
    "_validate_reference_only_payload": "utils",
    "_extract_event_error": "utils",
    "_extract_command_id_from_payload": "utils",
    "_extract_event_command_id": "utils",
    "_contains_forbidden_payload_keys": "utils",
    "_estimate_json_size": "utils",
    "_status_from_event_name": "utils",
    "_collect_compact_context": "utils",
    "_bounded_context": "utils",
    "_normalize_result_status": "utils",
    "_build_reference_only_result": "utils",
    "_compact_status_value": "utils",
    "_compact_status_variables": "utils",
    "_normalize_utc_timestamp": "utils",
    "_iso_timestamp": "utils",
    "_format_duration_human": "utils",
    "_duration_fields": "utils",
    "_STRICT_RESULT_ALLOWED_KEYS": "utils",
    "_STRICT_PAYLOAD_FORBIDDEN_KEYS": "utils",
    "_STRICT_CONTEXT_FORBIDDEN_KEYS": "utils",

    "_batch_metrics": "metrics",
    "_inc_batch_metric": "metrics",
    "_observe_batch_metric": "metrics",
    "get_batch_metrics_snapshot": "metrics",
    "_batch_queue_depth": "metrics",

    "_active_claim_cache_by_event": "cache",
    "_active_claim_cache_by_command": "cache",
    "_active_claim_cache_last_prune_monotonic": "cache",
    "_active_claim_cache_prune": "cache",
    "_active_claim_cache_get": "cache",
    "_active_claim_cache_set": "cache",
    "_active_claim_cache_invalidate": "cache",

    "_DB_UNAVAILABLE_SHORT_CIRCUIT": "db",
    "_DB_UNAVAILABLE_BACKOFF_BASE_SECONDS": "db",
    "_DB_UNAVAILABLE_BACKOFF_MAX_SECONDS": "db",
    "_DB_UNAVAILABLE_ERROR_MARKERS": "db",
    "_db_unavailable_failure_streak": "db",
    "_db_unavailable_backoff_until_monotonic": "db",
    "_compute_retry_after": "db",
    "_db_unavailable_retry_after": "db",
    "_record_db_operation_success": "db",
    "_is_db_unavailable_error": "db",
    "_record_db_unavailable_failure": "db",
    "_raise_if_db_short_circuit_enabled": "db",
    "_next_snowflake_id": "db",
    "_build_command_id_latest_lookup_sql": "db",
    "_command_id_lookup_params": "db",
    "_EVENT_TYPE_TERMINAL_PREDICATE": "db",
    "_EVENT_TYPE_ACTIVE_CLAIM_PREDICATE": "db",
    "_EVENT_TYPE_CLAIMED_PREDICATE": "db",
    "_EVENT_TYPE_SAME_WORKER_LATEST_PREDICATE": "db",
    "_COMMAND_EVENT_DEDUPE_TYPES": "db",
    "_CLAIM_TERMINAL_LOOKUP_SQL": "db",
    "_CLAIM_EXISTING_LOOKUP_SQL": "db",
    "_CLAIM_SAME_WORKER_LATEST_LOOKUP_SQL": "db",
    "_HANDLE_EVENT_CLAIMED_LOOKUP_SQL": "db",
    "_PENDING_COMMAND_COUNT_SQL": "db",
    "get_pool_status": "db",

    "_publish_recovery_tasks": "recovery",
    "_publish_recovery_semaphore": "recovery",
    "_track_publish_recovery_task": "recovery",
    "shutdown_publish_recovery_tasks": "recovery",
    "_compute_publish_recovery_delay": "recovery",
    "_command_has_claim_or_terminal": "recovery",
    "_fetch_execution_terminal_event": "recovery",
    "_recover_unclaimed_command_after_delay": "recovery",
    "_publish_commands_with_recovery": "recovery",

    "get_command": "commands",
    "claim_command": "commands",
    "_command_input_from_context": "commands",
    "_command_input_from_model": "commands",
    "_build_command_context": "commands",
    "_validate_postgres_command_context": "commands",
    "_validate_postgres_command_context_or_422": "commands",
    "_store_command_context_if_needed": "commands",

    "handle_event": "events",

    "execute": "execution",
    "start_execution": "execution",
    "get_execution_status": "execution",

    "_get_batch_acceptor_lock": "batch",
    "_has_live_batch_workers": "batch",
    "ensure_batch_acceptor_started": "batch",
    "shutdown_batch_acceptor": "batch",
    "_persist_batch_status_event": "batch",
    "_build_batch_error": "batch",
    "_persist_batch_failed_event": "batch",
    "_persist_batch_acceptance": "batch",
    "_issue_commands_for_batch": "batch",
    "_process_accepted_batch": "batch",
    "_batch_accept_worker_loop": "batch",
    "handle_batch_events": "batch",
    "_get_batch_request_state": "batch",
    "get_batch_event_status": "batch",
    "stream_batch_event_status": "batch",
}

modules_content = {k: [] for k in set(node_mapping.values())}

for node in tree.body:
    if isinstance(node, (ast.Import, ast.ImportFrom, ast.Expr)):
        continue
    
    # Identify the name of the node
    name = None
    if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
        name = node.name
    elif isinstance(node, ast.Assign):
        if isinstance(node.targets[0], ast.Name):
            name = node.targets[0].id
    elif isinstance(node, ast.AnnAssign):
        if isinstance(node.target, ast.Name):
            name = node.target.id

    if name and name in node_mapping:
        module_name = node_mapping[name]
        # To preserve comments and formatting better than ast.unparse, 
        # we can use ast.get_source_segment if available.
        # But ast.unparse is safer to normalize and avoid missing decorators.
        modules_content[module_name].append(ast.unparse(node))
    elif name:
        # If it's a global var not explicitly mapped, put it in core
        modules_content["core"].append(ast.unparse(node))
    else:
        # Put anything else in core
        modules_content["core"].append(ast.unparse(node))

# Write out the modules with proper imports
module_imports = {
    "core": "",
    "models": "from .core import *\n",
    "utils": "from .core import *\nfrom .models import *\n",
    "cache": "from .core import *\nfrom .models import *\nfrom .utils import *\n",
    "db": "from .core import *\nfrom .models import *\nfrom .utils import *\n",
    "metrics": "from .core import *\nfrom .models import *\n",
    "recovery": "from .core import *\nfrom .models import *\nfrom .utils import *\nfrom .db import *\n",
    "commands": "from .core import *\nfrom .models import *\nfrom .utils import *\nfrom .cache import *\nfrom .db import *\n",
    "batch": "from .core import *\nfrom .models import *\nfrom .utils import *\nfrom .db import *\nfrom .metrics import *\nfrom .commands import *\nfrom .recovery import *\n",
    "events": "from .core import *\nfrom .models import *\nfrom .utils import *\nfrom .cache import *\nfrom .db import *\nfrom .recovery import *\nfrom .commands import *\n",
    "execution": "from .core import *\nfrom .models import *\nfrom .utils import *\nfrom .db import *\nfrom .recovery import *\nfrom .commands import *\n"
}

for mod, contents in modules_content.items():
    file_path = os.path.join(dest_dir, f"{mod}.py")
    with open(file_path, "w") as f:
        if mod == "core":
            f.write(top_level_doc)
        f.write(imports_str)
        f.write(module_imports.get(mod, ""))
        f.write("\n\n".join(contents))
        f.write("\n")

# Write __init__.py
with open(os.path.join(dest_dir, "__init__.py"), "w") as f:
    f.write("""from .core import router
from .batch import ensure_batch_acceptor_started, shutdown_batch_acceptor
from .recovery import shutdown_publish_recovery_tasks
from .metrics import get_batch_metrics_snapshot

from . import db
from . import commands
from . import events
from . import execution
from . import batch

__all__ = [
    "router",
    "ensure_batch_acceptor_started",
    "shutdown_batch_acceptor",
    "shutdown_publish_recovery_tasks",
    "get_batch_metrics_snapshot",
]
""")

print("Done generating files.")
