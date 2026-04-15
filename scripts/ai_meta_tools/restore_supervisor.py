import os

events_path = "repos/noetl/noetl/core/dsl/engine/executor/events.py"
with open(events_path, "r") as f:
    lines = f.readlines()

for i, line in enumerate(lines):
    if "supervisor_completed_count = -1" in line:
        # Remove the hack and uncomment the original method call
        lines[i] = ""
        lines[i-1] = ""
        
        j = i + 1
        while j < len(lines):
            if lines[j].startswith("# "):
                lines[j] = lines[j][2:] # Remove comment prefix
            if ")" in lines[j]:
                break
            j += 1
        break

with open(events_path, "w") as f:
    f.writelines(lines)
print("Restored supervisor reconciliation in events.py")
