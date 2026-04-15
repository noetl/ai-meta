import os
import re

# 1. Surgical fix for state.py
state_path = "repos/noetl/noetl/core/dsl/engine/executor/state.py"
with open(state_path, "r") as f:
    text = f.read()

# Protect the collection_size calculation
old_line = 'collection_size = len(loop_state["collection"]) if "collection" in loop_state else int(loop_state.get("collection_size", 0))'
new_line = 'collection_size = len(loop_state["collection"]) if ("collection" in loop_state and loop_state["collection"] is not None) else int(loop_state.get("collection_size", 0))'
text = text.replace(old_line, new_line)

with open(state_path, "w") as f:
    f.write(text)
print("Surgically patched state.py")

# 2. Surgical fix for transitions.py
trans_path = "repos/noetl/noetl/core/dsl/engine/executor/transitions.py"
with open(trans_path, "r") as f:
    text = f.read()

# Make sure _issue_loop_commands is fast but safe
# I'll re-apply the batch claim logic but with better safety
pattern = r'issue_budget = self\._get_loop_max_in_flight\(step_def\)\n\s+commands: list\[Command\] = \[\]\n\s+shared_control_args = dict\(step_input\)\n\s+if collection is not None:\n\s+shared_control_args\["__loop_collection"\] = collection\n\n\s+for _ in range\(issue_budget\):\n\s+command = await self\._create_command_for_step\(state, step_def, shared_control_args\)\n\s+if not command:\n\s+break\n\s+commands\.append\(command\)\n\s+shared_control_args\["__loop_continue"\] = True'

replacement = """issue_budget = self._get_loop_max_in_flight(step_def)
        commands: list[Command] = []
        shared_control_args = dict(step_input)
        if collection is not None:
            shared_control_args["__loop_collection"] = collection

        # PERFORMANCE OPTIMIZATION: Batch claim loop indices to avoid O(N) NATS round-trips
        claimed_indices = []
        if collection is not None and isinstance(collection, list):
            claimed_indices = await nats_cache.claim_next_loop_indices(
                str(state.execution_id),
                step_def.step,
                collection_size=len(collection),
                max_in_flight=issue_budget, 
                requested_count=issue_budget,
                event_id=loop_event_id
            )

        if claimed_indices:
            for idx in claimed_indices:
                args = dict(shared_control_args)
                args["__loop_claimed_index"] = idx
                command = await self._create_command_for_step(state, step_def, args)
                if not command:
                    break
                commands.append(command)
                shared_control_args["__loop_continue"] = True
        else:
            # Fallback to single-claim loop if batch claim returned nothing (e.g. max_in_flight reached)
            for _ in range(issue_budget):
                command = await self._create_command_for_step(state, step_def, shared_control_args)
                if not command:
                    break
                commands.append(command)
                shared_control_args["__loop_continue"] = True"""

text = re.sub(pattern, replacement, text)

with open(trans_path, "w") as f:
    f.write(text)
print("Surgically patched transitions.py")

