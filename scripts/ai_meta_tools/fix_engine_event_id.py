import re

filepath = "repos/noetl/noetl/core/dsl/v2/engine.py"
with open(filepath, "r") as f:
    content = f.read()

target = """                                    loop_iteration_state[loop_step]["failed_count"] = 0
                                    loop_iteration_state[loop_step]["index"] = 0"""

replacement = """                                    loop_iteration_state[loop_step]["failed_count"] = 0
                                    loop_iteration_state[loop_step]["index"] = 0
                                    loop_iteration_state[loop_step]["event_id"] = str(loop_event_id)"""

if target in content:
    content = content.replace(target, replacement)
    with open(filepath, "w") as f:
        f.write(content)
    print("Patched successfully!")
else:
    print("Target not found!")
