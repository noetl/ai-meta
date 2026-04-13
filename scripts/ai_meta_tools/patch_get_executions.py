import re

filepath = "repos/noetl/noetl/core/dsl/v2/engine.py"
with open(filepath, "r") as f:
    content = f.read()

target = """                        elif new_count < 0:
                            _nats_count_reliable = False
                            # Keep progress moving even if distributed cache increments fail.
                            # Prefer durable count from persisted call.done events over local in-memory counts.
                            new_count = state.get_loop_completed_count(parent_step)
                            persisted_count = await self._count_step_events(
                                state.execution_id,
                                event.step,
                                "call.done",
                            )
                            if persisted_count >= 0:
                                new_count = max(new_count, persisted_count)"""

replacement = """                        elif new_count < 0:
                            _nats_count_reliable = False
                            # Keep progress moving even if distributed cache increments fail.
                            # Prefer durable count from persisted call.done events over local in-memory counts.
                            new_count = state.get_loop_completed_count(parent_step)
                            
                            # DO NOT fall back to global count(*), which artificially inflates cross-epoch values
                            # and causes immediate loop termination for multi-pass runs!
                            # Let the memory state or NATS state be authoritative.
                            if new_count <= 0 and nats_loop_state:
                                new_count = int(nats_loop_state.get("completed_count", 0))"""

if target in content:
    content = content.replace(target, replacement)
    with open(filepath, "w") as f:
        f.write(content)
    print("Patched successfully!")
else:
    print("Target not found!")
