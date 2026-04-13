import re

filepath = "repos/noetl/noetl/core/dsl/v2/engine.py"
with open(filepath, "r") as f:
    content = f.read()

target = """                                if loop_step in loop_iteration_state:
                                    loop_iteration_state[loop_step].pop("completed", None)
                                    loop_iteration_state[loop_step].pop("aggregation_finalized", None)"""

replacement = """                                if loop_step in loop_iteration_state:
                                    loop_iteration_state[loop_step].pop("completed", None)
                                    loop_iteration_state[loop_step].pop("aggregation_finalized", None)
                                    loop_iteration_state[loop_step]["results"] = []
                                    loop_iteration_state[loop_step]["omitted_results_count"] = 0
                                    loop_iteration_state[loop_step]["scheduled_count"] = 0
                                    loop_iteration_state[loop_step]["failed_count"] = 0
                                    loop_iteration_state[loop_step]["index"] = 0"""

if target in content:
    content = content.replace(target, replacement)
    with open(filepath, "w") as f:
        f.write(content)
    print("Patched successfully!")
else:
    print("Target not found!")
