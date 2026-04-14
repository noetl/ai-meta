import re

with open("repos/noetl/noetl/core/dsl/engine/executor/state.py", "r") as f:
    state_content = f.read()

# Remove collection from loop_state initialization
state_content = re.sub(
    r'"collection": list\(collection\),',
    r'"collection_size": len(collection) if hasattr(collection, "__len__") else 0,',
    state_content
)

# Remove results from loop_state initialization
state_content = re.sub(
    r'"results": \[\],  # Track iteration results for aggregation\n',
    r'# "results" array removed for memory efficiency - use event graph tracking\n',
    state_content
)

# Replace add_loop_result implementation
new_add_loop_result = """    def add_loop_result(self, step_name: str, result: Any, failed: bool = False):
        \"\"\"Update loop metadata without storing unbounded result arrays.\"\"\"
        if step_name not in self.loop_state:
            return

        loop_state = self.loop_state[step_name]
        
        # We no longer store an array of results. We only keep a reference to the latest item
        # and standard counters. The full lineage is available via the event table (event_id/parent_event_id).
        loop_state["last_result"] = _compact_loop_result(result)
        
        if failed:
            loop_state["failed_count"] += 1
        elif isinstance(result, dict):
            status = str(result.get("status", "")).lower()
            is_policy_break = result.get("policy_break") is True
            if status == "break" or is_policy_break:
                loop_state["break_count"] = loop_state.get("break_count", 0) + 1"""

state_content = re.sub(
    r'    def add_loop_result\(self, step_name: str, result: Any, failed: bool = False\):.*?(?=\n    def get_loop_aggregation)',
    new_add_loop_result + "\n",
    state_content,
    flags=re.DOTALL
)

# Fix get_loop_aggregation
new_get_loop_aggregation = """    def get_loop_aggregation(self, step_name: str) -> dict[str, Any]:
        \"\"\"Get aggregated loop results in standard format (counters only, arrays removed).\"\"\"
        if step_name not in self.loop_state:
            return {"results": [], "stats": {"total": 0, "success": 0, "failed": 0}}
        
        loop_state = self.loop_state[step_name]
        total = _loop_results_total(loop_state)
        failed = loop_state["failed_count"]
        success = total - failed
        
        return {
            "results": [loop_state.get("last_result")] if loop_state.get("last_result") else [],
            "stats": {
                "total": total,
                "success": success,
                "failed": failed,
            }
        }"""

state_content = re.sub(
    r'    def get_loop_aggregation\(self, step_name: str\) -> dict\[str, Any\]:.*?(?=\n    def get_loop_completed_count)',
    new_get_loop_aggregation + "\n",
    state_content,
    flags=re.DOTALL
)

# Fix get_next_loop_item to handle missing collection
new_get_next = """    def get_next_loop_item(self, step_name: str, collection: list = None) -> tuple[Any, int] | None:
        \"\"\"Get next item from loop. Returns (item, index) or None if done.\"\"\"
        if step_name not in self.loop_state:
            return None
        
        state = self.loop_state[step_name]
        if state["completed"]:
            return None
        
        index = state["index"]
        collection_size = state.get("collection_size", 0)
        
        if index >= collection_size or (collection is not None and index >= len(collection)):
            state["completed"] = True
            return None
        
        item = collection[index] if collection else None
        state["current_item"] = item
        
        state["index"] = index + 1
        state["scheduled_count"] += 1
        return item, index"""

state_content = re.sub(
    r'    def get_next_loop_item\(self, step_name: str\) -> tuple\[Any, int\] \| None:.*?(?=\n    def is_loop_done)',
    new_get_next + "\n",
    state_content,
    flags=re.DOTALL
)

with open("repos/noetl/noetl/core/dsl/engine/executor/state.py", "w") as f:
    f.write(state_content)
print("Updated state.py")
