import os
import re

files = [
    "repos/noetl/noetl/core/dsl/engine/executor/events.py",
    "repos/noetl/noetl/core/dsl/engine/executor/commands.py",
    "repos/noetl/noetl/core/dsl/engine/executor/transitions.py"
]

for file_path in files:
    with open(file_path, "r") as f:
        text = f.read()
    
    # Replace len(collection) with len(collection or [])
    text = text.replace("len(collection)", "len(collection or [])")
    
    # Replace len(pipeline) with len(pipeline or [])
    text = text.replace("len(pipeline)", "len(pipeline or [])")
    
    # Replace len(rendered_collection) with len(rendered_collection or [])
    text = text.replace("len(rendered_collection)", "len(rendered_collection or [])")

    with open(file_path, "w") as f:
        f.write(text)
    print(f"Applied safety to {file_path}")

# Force patch events.py for the scan bottleneck
events_path = "repos/noetl/noetl/core/dsl/engine/executor/events.py"
with open(events_path, "r") as f:
    lines = f.readlines()

for i, line in enumerate(lines):
    if "supervisor_completed_count = await self._count_supervised_loop_terminal_iterations(" in line:
        lines[i] = '                    # PERFORMANCE OPTIMIZATION: Skip expensive full-scan supervisor reconciliation on hot path.\n                    supervisor_completed_count = -1\n'
        # Comment out the rest of the multi-line call
        j = i + 1
        while j < len(lines) and ")" not in lines[j-1]:
            lines[j] = "# " + lines[j]
            j += 1

with open(events_path, "w") as f:
    f.writelines(lines)
print("Force-patched events.py scan bottleneck")
