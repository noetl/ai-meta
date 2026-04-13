import re

filepath = "repos/noetl/noetl/core/dsl/v2/engine.py"
with open(filepath, "r") as f:
    content = f.read()

target = """            context["iter"]["_last"] = claimed_index >= coll_len - 1 if coll_len > 0 else True
            # Update loop metadata
            loop_s = state.loop_state.get(step.step)"""

replacement = """            context["iter"]["_last"] = claimed_index >= coll_len - 1 if coll_len > 0 else True
            context["iter"]["loop_event_id"] = loop_event_id_for_metadata
            # Update loop metadata
            loop_s = state.loop_state.get(step.step)"""

if target in content:
    content = content.replace(target, replacement)
    with open(filepath, "w") as f:
        f.write(content)
    print("Patched successfully!")
else:
    print("Target not found!")
