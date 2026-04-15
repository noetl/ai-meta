import re

path = "repos/noetl/noetl/core/dsl/engine/executor/commands.py"
with open(path, "r") as f:
    text = f.read()

# Wait, the previous block I tried to replace was actually:
#                else:
#                    # Update existing loop collection without resetting counters
#                    state.loop_state[step.step]["collection_size"] = len(collection or []) if hasattr(collection, "__len__") else 0

# But since I applied the safety wrappers earlier, the exact text in the file was:
#                    state.loop_state[step.step]["collection_size"] = len(collection or []) if hasattr(collection, "__len__") else 0

old_block = """                else:
                    # Update existing loop collection without resetting counters
                    state.loop_state[step.step]["collection_size"] = len(collection or []) if hasattr(collection, "__len__") else 0"""

new_block = """                else:
                    # Update existing loop collection AND reset counters for the new batch!
                    import time
                    loop_event_id_for_metadata = f"loop_{state.last_event_id or int(time.time() * 1000000)}"
                    state.loop_state[step.step].update({
                        "collection_size": len(collection or []) if hasattr(collection, "__len__") else 0,
                        "completed_count": 0,
                        "scheduled_count": 0,
                        "failed_count": 0,
                        "break_count": 0,
                        "omitted_results_count": 0,
                        "index": 0,
                        "event_id": loop_event_id_for_metadata,
                        "completed": False
                    })"""

text = text.replace(old_block, new_block)

with open(path, "w") as f:
    f.write(text)

print("Successfully applied loop counter reset for multi-batch loops AGAIN")
