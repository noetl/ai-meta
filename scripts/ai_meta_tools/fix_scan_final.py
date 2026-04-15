import re

path = "repos/noetl/noetl/core/dsl/engine/executor/events.py"
with open(path, "r") as f:
    text = f.read()

# I accidentally deleted the assignment!
# Let's restore the full call
old_block = """                        state.execution_id,
                        event.step,
                        resolved_loop_event_id,
                    )
                    if supervisor_completed_count > completed_count:"""

new_block = """                    supervisor_completed_count = await self._count_supervised_loop_terminal_iterations(
                        str(state.execution_id),
                        event.step,
                        event_id=str(resolved_loop_event_id)
                    )
                    if supervisor_completed_count > completed_count:"""

text = text.replace(old_block, new_block)

with open(path, "w") as f:
    f.write(text)
print("Successfully restored the assignment of the supervisor scan.")
