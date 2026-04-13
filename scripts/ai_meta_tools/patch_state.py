import re

with open("repos/noetl/noetl/core/dsl/v2/engine/state.py", "r") as f:
    content = f.read()

to_dict_method = """

    def to_dict(self) -> dict[str, Any]:
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
            "loop_state": self.loop_state,
            "step_stall_counts": self.step_stall_counts,
            "emitted_loop_epochs": list(self.emitted_loop_epochs),
            "pagination_state": self.pagination_state,
            "pending_next_actions": self.pending_next_actions,
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any], playbook: Playbook) -> ExecutionState:
        state = cls(
            execution_id=data["execution_id"],
            playbook=playbook,
            payload=data["payload"],
            catalog_id=data["catalog_id"],
            parent_execution_id=data.get("parent_execution_id")
        )
        state.current_step = data.get("current_step")
        state.variables = data.get("variables", {})
        state.last_event_id = data.get("last_event_id")
        state.step_event_ids = data.get("step_event_ids", {})
        state.step_results = data.get("step_results", {})
        state.completed_steps = set(data.get("completed_steps", []))
        state.issued_steps = set(data.get("issued_steps", []))
        state.failed = data.get("failed", False)
        state.completed = data.get("completed", False)
        state.root_event_id = data.get("root_event_id")
        state.loop_state = data.get("loop_state", {})
        state.step_stall_counts = data.get("step_stall_counts", {})
        state.emitted_loop_epochs = set(data.get("emitted_loop_epochs", []))
        state.pagination_state = data.get("pagination_state", {})
        state.pending_next_actions = data.get("pending_next_actions", {})
        return state
"""

content = content.replace("def get_step(self, step_name: str) -> Optional[Step]:", to_dict_method + "\n    def get_step(self, step_name: str) -> Optional[Step]:")

with open("repos/noetl/noetl/core/dsl/v2/engine/state.py", "w") as f:
    f.write(content)

