import os
init_file = "repos/noetl/noetl/server/api/v2/__init__.py"
with open(init_file, "r") as f:
    content = f.read()

exports_to_add = """
from .batch import ensure_batch_acceptor_started, shutdown_batch_acceptor
from .recovery import shutdown_publish_recovery_tasks
from .metrics import get_batch_metrics_snapshot

__all__ = [
    "router", 
    "get_engine", 
    "get_nats_publisher",
    "ensure_batch_acceptor_started",
    "shutdown_batch_acceptor",
    "shutdown_publish_recovery_tasks",
    "get_batch_metrics_snapshot"
]
"""

content = content.replace('__all__ = ["router", "get_engine", "get_nats_publisher"]', exports_to_add)

with open(init_file, "w") as f:
    f.write(content)
