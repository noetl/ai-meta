import re

path = "repos/noetl/noetl/core/dsl/engine/executor/queries.py"
with open(path, "r") as f:
    text = f.read()

# Fix the supervisor query to look in result->'context' as well
old_block = """                        "AND COALESCE(meta->>'loop_event_id', meta->>'__loop_epoch_id') = %s"
                    ),
                    (execution_id, ("call.done", "command.completed", "command.failed"), step_name, loop_event_id),"""

new_block = """                        "AND COALESCE(meta->>'loop_event_id', meta->>'__loop_epoch_id', result->'context'->>'loop_event_id') = %s"
                    ),
                    (execution_id, ("call.done", "command.completed", "command.failed"), step_name, loop_event_id),"""

text = text.replace(old_block, new_block)

# And also fix the other fallback query in queries.py just in case
old_block2 = """                        "AND COALESCE(meta->>'loop_event_id', meta->>'__loop_epoch_id') = %s"
                    ),
                    (execution_id, ("call.done", "command.completed", "command.failed", "step.exit"), node_name, loop_event_id),"""

new_block2 = """                        "AND COALESCE(meta->>'loop_event_id', meta->>'__loop_epoch_id', result->'context'->>'loop_event_id') = %s"
                    ),
                    (execution_id, ("call.done", "command.completed", "command.failed", "step.exit"), node_name, loop_event_id),"""

text = text.replace(old_block2, new_block2)

with open(path, "w") as f:
    f.write(text)

print("Successfully patched fallback queries to check result->'context'->>'loop_event_id'!")
