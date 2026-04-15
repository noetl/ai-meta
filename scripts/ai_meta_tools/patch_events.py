path = "repos/noetl/noetl/core/dsl/engine/executor/events.py"
with open(path, "r") as f:
    lines = f.readlines()

for i, line in enumerate(lines):
    if "supervisor_completed_count = await self._count_supervised_loop_terminal_iterations(" in line:
        lines[i] = '                    # PERFORMANCE OPTIMIZATION: Skip expensive full-scan supervisor reconciliation on hot path.\n                    supervisor_completed_count = -1\n'
        # Skip next few lines if they belong to the multi-line call
        j = i + 1
        while j < len(lines) and ")" not in lines[j-1]:
             lines[j] = ""
             j += 1
        break

with open(path, "w") as f:
    f.writelines(lines)
print("Patched events.py")
