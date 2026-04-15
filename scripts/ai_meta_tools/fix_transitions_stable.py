import os
import re

path = "repos/noetl/noetl/core/dsl/engine/executor/transitions.py"
with open(path, "r") as f:
    text = f.read()

# I'll use a very specific replacement that doesn't mess up indentation
old_block = """        for _ in range(issue_budget):
            command = await self._create_command_for_step(state, step_def, shared_control_args)
            if not command:
                break
            commands.append(command)
            shared_control_args["__loop_continue"] = True"""

new_block = """        # PERFORMANCE OPTIMIZATION: Batch claim loop indices to avoid O(N) NATS round-trips
        claimed_indices = []
        if (collection or []) is not None:
            from noetl.core.cache.nats_kv import get_nats_cache
            claimed_indices = await (await get_nats_cache()).claim_next_loop_indices(
                str(state.execution_id),
                step_def.step,
                collection_size=len(collection or []),
                max_in_flight=issue_budget, 
                requested_count=issue_budget,
                event_id=loop_event_id
            )

        if claimed_indices:
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

text = text.replace(old_block, new_block)
with open(path, "w") as f:
    f.write(text)
print("Successfully patched transitions.py")
