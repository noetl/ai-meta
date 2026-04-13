import re

with open("noetl/core/dsl/engine/engine/state.py", "r") as f:
    content = f.read()

# 1. Update to_dict to exclude collection from loop_state
to_dict_replacement = """    def to_dict(self) -> dict[str, Any]:
        loop_state_dict = {}
        for step_name, ls in self.loop_state.items():
            ls_copy = dict(ls)
            # Remove full collection list to prevent massive JSONB state bloat.
            # Engine will re-render collection from playbook and step_results when needed.
            if "collection" in ls_copy:
                ls_copy.pop("collection", None)
            loop_state_dict[step_name] = ls_copy

        return {
            "execution_id": self.execution_id,
            "catalog_id": self.catalog_id,
            "parent_execution_id": self.parent_execution_id,
            "payload": self.payload,
            "current_step": self.current_step,
            "variables": self.variables,
            "last_event_id": self.last_event_id,
            "step_event_ids": self.step_event_ids,
            "step_results": self.step_results,
            "completed_steps": list(self.completed_steps),
            "issued_steps": list(self.issued_steps),
            "failed": self.failed,
            "completed": self.completed,
            "root_event_id": self.root_event_id,
            "loop_state": loop_state_dict,
            "step_stall_counts": self.step_stall_counts,
            "emitted_loop_epochs": list(self.emitted_loop_epochs),
            "pagination_state": self.pagination_state,
            "pending_next_actions": self.pending_next_actions,
        }"""

content = re.sub(
    r'    def to_dict\(self\) -> dict\[str, Any\]:.*?return \{.*?\}',
    to_dict_replacement,
    content,
    flags=re.DOTALL
)

# 2. Update init_loop to avoid redundant collection copy
init_loop_replacement = """        self.loop_state[step_name] = {
            # Note: collection is NOT stored in persistent loop_state to avoid JSONB bloat.
            # It is kept in-memory for the current engine process and re-rendered on resume.
            "collection": list(collection),
            "iterator": iterator,
            "index": 0,"""

content = content.replace(
    '        self.loop_state[step_name] = {\n            # Keep a local snapshot so downstream in-place list mutations outside loop_state\n            # do not alter continuation/retry scheduling.\n            "collection": list(collection),\n            "iterator": iterator,\n            "index": 0,',
    init_loop_replacement
)

with open("noetl/worker/nats_worker.py", "r") as f:
    worker_content = f.read()

# 3. Increase default DB semaphore in NATSWorker (V2Worker)
worker_content = worker_content.replace(
    'self._max_inflight_db_commands = max(1, int(worker_settings.max_inflight_db_commands))',
    'self._max_inflight_db_commands = max(1, int(os.getenv("NOETL_WORKER_DB_SEMAPHORE", "16")))'
)

with open("noetl/core/dsl/engine/engine/state.py", "w") as f:
    f.write(content)

with open("noetl/worker/nats_worker.py", "w") as f:
    f.write(worker_content)
