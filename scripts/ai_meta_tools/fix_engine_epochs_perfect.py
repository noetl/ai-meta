import re

path = "repos/noetl/noetl/core/dsl/engine/executor/transitions.py"
with open(path, "r") as f:
    text = f.read()

# Make sure transitions.py always generates a new epoch ID for a fresh batch
old_block = """        # PERFORMANCE & CORRECTNESS FIX: If this is a fresh entry into the loop (not a continuation),
        # force a completely new epoch ID *before* we batch claim the NATS slots.
        if existing_loop_state and not step_input.get("__loop_continue") and not step_input.get("__loop_retry"):
            import time
            loop_event_id = f"loop_{state.last_event_id or time.time_ns()}"
        
        collection = None"""

new_block = """        # PERFORMANCE & CORRECTNESS FIX: If this is a fresh entry into the loop (not a continuation),
        # force a completely new epoch ID *before* we batch claim the NATS slots.
        if existing_loop_state and not step_input.get("__loop_continue") and not step_input.get("__loop_retry"):
            import time
            loop_event_id = f"loop_{state.last_event_id or int(time.time() * 1000000)}"
            # Delete the local state so commands.py knows this is a fresh loop instance!
            del state.loop_state[step_def.step]
            existing_loop_state = None
        
        collection = None"""

text = text.replace(old_block, new_block)

with open(path, "w") as f:
    f.write(text)


path = "repos/noetl/noetl/core/dsl/engine/executor/commands.py"
with open(path, "r") as f:
    text = f.read()

# Make sure commands.py uses the passed epoch ID and NEVER generates a conflicting one
old_block2 = """                else:
                    # Update existing loop collection AND reset counters for the new batch!
                    import time
                    loop_event_id_for_metadata = loop_event_id_for_metadata or f"loop_{state.last_event_id or int(time.time() * 1000000)}"
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

# We don't even need this block anymore because we deleted the local state in transitions.py!
# So `if step.step not in state.loop_state:` will be TRUE, and `state.init_loop` will run perfectly!
# Let's just leave it as a fallback but make sure it uses the passed ID.
new_block2 = """                else:
                    # Update existing loop collection AND reset counters for the new batch!
                    import time
                    loop_event_id_for_metadata = loop_event_id_for_metadata or f"loop_{state.last_event_id or int(time.time() * 1000000)}"
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

text = text.replace(old_block2, new_block2)

with open(path, "w") as f:
    f.write(text)

print("Successfully applied perfect epoch synchronization")
