import re

filepath = "repos/noetl/noetl/core/dsl/v2/engine.py"
with open(filepath, "r") as f:
    content = f.read()

target = """            if parent_step_def and parent_step_def.loop and parent_step in state.loop_state:
                loop_state = state.loop_state[parent_step]
                if not loop_state.get("aggregation_finalized", False):"""

replacement = """            if parent_step_def and parent_step_def.loop and parent_step in state.loop_state:
                loop_state = state.loop_state[parent_step]
                if not loop_state.get("aggregation_finalized", False):
                    logger.error(f"[DEBUG-TRACE-3] AGGREGATION NOT FINALIZED for {parent_step}")"""

if target in content:
    content = content.replace(target, replacement)
    with open(filepath, "w") as f:
        f.write(content)
    print("Patched successfully!")
else:
    print("Target not found!")
