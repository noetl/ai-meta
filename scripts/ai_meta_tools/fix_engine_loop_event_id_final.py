import re

filepath = "repos/noetl/noetl/core/dsl/v2/engine.py"
with open(filepath, "r") as f:
    content = f.read()

target = """            loop_event_id_for_metadata = (
                str(loop_state.get("event_id"))
                if loop_state.get("event_id") is not None
                else loop_event_id_for_metadata
            )"""

replacement = """            loop_event_id_for_metadata = (
                str(resolved_loop_event_id)
                if resolved_loop_event_id is not None
                else (str(loop_state.get("event_id")) if loop_state.get("event_id") is not None else loop_event_id_for_metadata)
            )"""

if target in content:
    content = content.replace(target, replacement)
    with open(filepath, "w") as f:
        f.write(content)
    print("Patched successfully!")
else:
    print("Target not found!")
