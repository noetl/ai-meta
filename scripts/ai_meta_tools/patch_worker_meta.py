import re

with open("repos/noetl/noetl/worker/v2_worker_nats.py", "r") as f:
    content = f.read()

content = content.replace(
    'loop_iteration_index = meta.get("loop_iteration_index")',
    'loop_iteration_index = meta.get("loop_iteration_index")\n        state_ref = meta.get("state_ref")'
)

content = content.replace(
    'loop_event_meta = {"command_id": command_id} if command_id else {}',
    'loop_event_meta = {"command_id": command_id} if command_id else {}\n        if state_ref:\n            loop_event_meta["state_ref"] = state_ref'
)

with open("repos/noetl/noetl/worker/v2_worker_nats.py", "w") as f:
    f.write(content)

