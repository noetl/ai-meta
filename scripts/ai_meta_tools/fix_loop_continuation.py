import re

path = "repos/noetl/noetl/core/dsl/engine/executor/commands.py"
with open(path, "r") as f:
    text = f.read()

# Fix the bug where loop epoch IDs are reused for new collections during a loop continuation
old_block = """            if not reuse_cached_collection:
                # Store new collection and init state
                await nats_cache.save_loop_collection(str(state.execution_id), step.step, loop_event_id_for_metadata, collection)
                
                if step.step not in state.loop_state:
                    state.init_loop(
                        step.step,
                        collection,
                        step.loop.iterator,
                        mode=step.loop.mode,
                        event_id=loop_event_id_for_metadata,
                    )
                else:
                    # Update existing loop collection without resetting counters
                    state.loop_state[step.step]["collection_size"] = len(collection or []) if hasattr(collection, "__len__") else 0"""

new_block = """            if not reuse_cached_collection:
                # We have a new collection! If this is a continuation, the old epoch is dead.
                # Generate a brand new epoch ID to prevent NATS KeyExistsError and database cross-talk.
                if step.step in state.loop_state and loop_continue_requested:
                    import time
                    loop_event_id_for_metadata = f"loop_{state.execution_id}_{int(time.time() * 1000000)}"
                    # Forcibly delete the old loop state to trigger a full reset
                    del state.loop_state[step.step]

                # Store new collection and init state
                await nats_cache.save_loop_collection(str(state.execution_id), step.step, loop_event_id_for_metadata, collection)
                
                if step.step not in state.loop_state:
                    state.init_loop(
                        step.step,
                        collection,
                        step.loop.iterator,
                        mode=step.loop.mode,
                        event_id=loop_event_id_for_metadata,
                    )
                else:
                    # Update existing loop collection without resetting counters
                    state.loop_state[step.step]["collection_size"] = len(collection or []) if hasattr(collection, "__len__") else 0"""

text = text.replace(old_block, new_block)

with open(path, "w") as f:
    f.write(text)

print("Successfully patched loop continuation epoch IDs")
