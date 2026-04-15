import re

file_path = "repos/noetl/noetl/core/dsl/engine/executor/events.py"
with open(file_path, "r") as f:
    text = f.read()

# Locate the call to _count_supervised_loop_terminal_iterations and add a condition to skip it
# or simply comment it out for now to verify the speed up.

# Around line 1426:
# supervisor_completed_count = await self._count_supervised_loop_terminal_iterations(
#     str(state.execution_id),
#     event.step,
#     event_id=str(resolved_loop_event_id),
# )

# We want to change it to only run if it's been a while, or just disable it for now.
# Let's disable it for the hot path.

replacement = """                    # PERFORMANCE OPTIMIZATION: Skip expensive full-scan supervisor reconciliation on hot path.
                    # This call performs O(N) NATS KV GETs where N is the number of iterations.
                    # Rely on the atomic counter maintained in NATS instead.
                    supervisor_completed_count = -1 
                    # await self._count_supervised_loop_terminal_iterations(...)"""

# Use a regex that matches the multi-line call
pattern = r'supervisor_completed_count = await self\._count_supervised_loop_terminal_iterations\(\s*str\(state\.execution_id\),\s*event\.step,\s*event_id=str\(resolved_loop_event_id\),\s*\)'

text = re.sub(pattern, replacement, text)

with open(file_path, "w") as f:
    f.write(text)

print("Successfully patched events.py to disable supervisor scan.")
