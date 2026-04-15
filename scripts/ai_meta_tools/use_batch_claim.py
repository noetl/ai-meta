import re

file_path = "repos/noetl/noetl/core/dsl/engine/executor/transitions.py"
with open(file_path, "r") as f:
    text = f.read()

# Replace the sequential loop with batch claim
replacement = """        issue_budget = self._get_loop_max_in_flight(step_def)
        commands: list[Command] = []
        shared_control_args = dict(step_input)
        if collection is not None:
            shared_control_args["__loop_collection"] = collection

        # PERFORMANCE OPTIMIZATION: Batch claim loop indices to avoid O(N) NATS round-trips
        claimed_indices = await nats_cache.claim_next_loop_indices(
            str(state.execution_id),
            step_def.step,
            collection_size=len(collection),
            max_in_flight=issue_budget, # budget IS max_in_flight for parallel loops
            requested_count=issue_budget,
            event_id=loop_event_id
        )

        for idx in claimed_indices:
            args = dict(shared_control_args)
            args["__loop_claimed_index"] = idx
            command = await self._create_command_for_step(state, step_def, args)
            if not command:
                break
            commands.append(command)
            shared_control_args["__loop_continue"] = True
"""

pattern = r'        issue_budget = self\._get_loop_max_in_flight\(step_def\)\n        commands: list\[Command\] = \[\]\n        shared_control_args = dict\(step_input\)\n        if collection is not None:\n            shared_control_args\["__loop_collection"\] = collection\n\n        for _ in range\(issue_budget\):\n            command = await self\._create_command_for_step\(state, step_def, shared_control_args\)\n            if not command:\n                break\n            commands\.append\(command\)\n            shared_control_args\["__loop_continue"\] = True'

text = re.sub(pattern, replacement, text)

with open(file_path, "w") as f:
    f.write(text)

print("Successfully patched transitions.py to use batch claim.")
