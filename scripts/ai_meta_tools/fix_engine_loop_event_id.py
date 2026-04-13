import re

filepath = "repos/noetl/noetl/core/dsl/v2/engine.py"
with open(filepath, "r") as f:
    content = f.read()

target = """            loop_event_id_for_metadata = (
                str(loop_state.get("event_id"))
                if loop_state.get("event_id") is not None
                else None
            )

            # Resolve distributed loop key candidates.
            if force_new_loop_instance:"""

replacement = """            loop_event_id_for_metadata = (
                str(loop_state.get("event_id"))
                if loop_state.get("event_id") is not None
                else None
            )

            # Resolve distributed loop key candidates.
            if force_new_loop_instance:
                loop_event_id_for_metadata = loop_state.get("event_id")"""

if target in content:
    content = content.replace(target, replacement)
    with open(filepath, "w") as f:
        f.write(content)
    print("Patched successfully!")
else:
    print("Target not found!")
