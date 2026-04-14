import re
with open("repos/noetl/noetl/core/dsl/engine/executor/state.py", "r") as f:
    text = f.read()

# Fix get_render_context "length": len(loop_state["collection"])
text = re.sub(
    r'"length": len\(loop_state\["collection"\]\),',
    r'"length": loop_state.get("collection_size", 0),',
    text
)

# Fix _loop_results_total logic
# Since we removed "results" array, we need to track completed count properly.
# But wait, completed_count might just be tracked via an integer!
# Let's see _loop_results_total in common.py
