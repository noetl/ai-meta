import re

path = "repos/noetl/noetl/core/dsl/engine/executor/transitions.py"
with open(path, "r") as f:
    text = f.read()

old_block = """        if claimed_indices:
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

new_block = """        if claimed_indices:
            for idx in claimed_indices:
                args = dict(shared_control_args)
                args["__loop_claimed_index"] = idx
                args["__loop_epoch_id"] = loop_event_id  # Pass the newly generated epoch ID to commands.py!
                command = await self._create_command_for_step(state, step_def, args)
                if not command: continue
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

old_block2 = """            if claimed_index >= len(collection or []):
                logger.warning(
                    "[LOOP] Claimed index %s is out of range for %s (col_size=%s); %s",
                    claimed_index,
                    step.step,
                    len(collection or []),
                    "releasing NATS slot to prevent in-flight saturation"
                    if _nats_slot_incremented
                    else "slot was not NATS-claimed (retry/watchdog path)",
                )"""

new_block2 = """            if claimed_index is None or claimed_index >= len(collection or []):
                logger.warning(
                    "[LOOP] Claimed index %s is out of range or None for %s (col_size=%s); %s",
                    claimed_index,
                    step.step,
                    len(collection or []),
                    "releasing NATS slot to prevent in-flight saturation"
                    if _nats_slot_incremented
                    else "slot was not NATS-claimed (retry/watchdog path)",
                )"""

text = text.replace(old_block2, new_block2)

with open(path, "w") as f:
    f.write(text)

print("Successfully replaced break with continue in transitions.py and fixed TypeError in commands.py!")
