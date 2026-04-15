import os
import re

path = "repos/noetl/noetl/core/dsl/engine/executor/transitions.py"
with open(path, "r") as f:
    text = f.read()

# Make sure transitions.py passes the newly generated loop_event_id to commands.py
# so they share exactly the same epoch ID!
old_block = """        if claimed_indices:
            for idx in claimed_indices:
                args = dict(shared_control_args)
                args["__loop_claimed_index"] = idx
                command = await self._create_command_for_step(state, step_def, args)
                if not command: break
                commands.append(command)
                shared_control_args["__loop_continue"] = True
        else:
            for _ in range(issue_budget):
                command = await self._create_command_for_step(state, step_def, shared_control_args)
                if not command: break
                commands.append(command)
                shared_control_args["__loop_continue"] = True"""

new_block = """        if claimed_indices:
            for idx in claimed_indices:
                args = dict(shared_control_args)
                args["__loop_claimed_index"] = idx
                args["__loop_epoch_id"] = loop_event_id  # Pass the newly generated epoch ID to commands.py!
                command = await self._create_command_for_step(state, step_def, args)
                if not command: break
                commands.append(command)
                shared_control_args["__loop_continue"] = True
        else:
            for _ in range(issue_budget):
                args = dict(shared_control_args)
                args["__loop_epoch_id"] = loop_event_id  # Pass the newly generated epoch ID to commands.py!
                command = await self._create_command_for_step(state, step_def, args)
                if not command: break
                commands.append(command)
                shared_control_args["__loop_continue"] = True"""

text = text.replace(old_block, new_block)

with open(path, "w") as f:
    f.write(text)

path = "repos/noetl/noetl/core/dsl/engine/executor/commands.py"
with open(path, "r") as f:
    text = f.read()

# Make commands.py use the passed epoch ID
old_block2 = """        loop_event_id_for_metadata: Optional[str] = None
        claimed_index: Optional[int] = control_args.get("__loop_claimed_index")"""

new_block2 = """        loop_event_id_for_metadata: Optional[str] = control_args.get("__loop_epoch_id")
        claimed_index: Optional[int] = control_args.get("__loop_claimed_index")"""

text = text.replace(old_block2, new_block2)

# Ensure the counter reset block uses the passed epoch ID
old_block3 = """                else:
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

new_block3 = """                else:
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

text = text.replace(old_block3, new_block3)

with open(path, "w") as f:
    f.write(text)

print("Successfully linked Epoch IDs between transitions.py and commands.py")
