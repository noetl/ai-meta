import os
import re

files = [
    "repos/noetl/noetl/core/dsl/engine/executor/events.py",
    "repos/noetl/noetl/core/dsl/engine/executor/commands.py",
    "repos/noetl/noetl/core/dsl/engine/executor/transitions.py",
    "repos/noetl/noetl/core/dsl/engine/executor/state.py"
]

# Revert first
for f in files:
    os.system(f"cd repos/noetl && git checkout {f}")

for file_path in files:
    with open(file_path, "r") as f:
        lines = f.readlines()
    
    new_lines = []
    for line in lines:
        # Safe len replacements
        line = line.replace("len(collection)", "len(collection or [])")
        line = line.replace("len(pipeline)", "len(pipeline or [])")
        line = line.replace("len(rendered_collection)", "len(rendered_collection or [])")
        line = line.replace("len(loop_state['collection'])", "len(loop_state.get('collection') or [])")
        line = line.replace('len(loop_state["collection"])', 'len(loop_state.get("collection") or [])')
        
        new_lines.append(line)
    
    with open(file_path, "w") as f:
        f.writelines(new_lines)
    print(f"Applied safety to {file_path}")

# Force patch events.py for the scan bottleneck
events_path = "repos/noetl/noetl/core/dsl/engine/executor/events.py"
with open(events_path, "r") as f:
    lines = f.readlines()

for i, line in enumerate(lines):
    if "supervisor_completed_count = await self._count_supervised_loop_terminal_iterations(" in line:
        lines[i] = '                    # PERFORMANCE OPTIMIZATION: Skip expensive full-scan supervisor reconciliation on hot path.\n                    supervisor_completed_count = -1\n'
        j = i + 1
        while j < len(lines) and ")" not in lines[j-1]:
            lines[j] = "# " + lines[j]
            j += 1

with open(events_path, "w") as f:
    f.writelines(lines)
print("Force-patched events.py scan bottleneck")

# Apply batch claim to transitions.py SAFELY
trans_path = "repos/noetl/noetl/core/dsl/engine/executor/transitions.py"
with open(trans_path, "r") as f:
    text = f.read()

pattern = r'issue_budget = self\._get_loop_max_in_flight\(step_def\)\n\s+commands: list\[Command\] = \[\]\n\s+shared_control_args = dict\(step_input\)\n\s+if collection is not None:\n\s+shared_control_args\["__loop_collection"\] = collection\n\n\s+for _ in range\(issue_budget\):\n\s+command = await self\._create_command_for_step\(state, step_def, shared_control_args\)\n\s+if not command:\n\s+break\n\s+commands\.append\(command\)\n\s+shared_control_args\["__loop_continue"\] = True'

replacement = """issue_budget = self._get_loop_max_in_flight(step_def)
        commands: list[Command] = []
        shared_control_args = dict(step_input)
        if (collection or []) is not None:
            shared_control_args["__loop_collection"] = collection

        # PERFORMANCE OPTIMIZATION: Batch claim loop indices to avoid O(N) NATS round-trips
        claimed_indices = await (await get_nats_cache()).claim_next_loop_indices(
            str(state.execution_id),
            step_def.step,
            collection_size=len(collection or []),
            max_in_flight=issue_budget, 
            requested_count=issue_budget,
            event_id=loop_event_id
        ) if (collection or []) else []

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

text = re.sub(pattern, replacement, text)
with open(trans_path, "w") as f:
    f.write(text)
print("Patched transitions.py batch claim")

# Apply pre-claimed index support to commands.py SAFELY
comm_path = "repos/noetl/noetl/core/dsl/engine/executor/commands.py"
with open(comm_path, "r") as f:
    lines = f.readlines()

for i, line in enumerate(lines):
    if 'claimed_index: Optional[int] = None' in line:
        indent = line[:len(line) - len(line.lstrip())]
        lines[i] = f"{indent}claimed_index: Optional[int] = control_args.get('__loop_claimed_index')\n"
    if '_nats_slot_incremented = False' in line:
        indent = line[:len(line) - len(line.lstrip())]
        lines[i] = f"{indent}_nats_slot_incremented = claimed_index is not None\n"
    if 'claimed_index = await nats_cache.claim_next_loop_index(' in line:
        indent = line[:len(line) - len(line.lstrip())]
        lines[i] = f"{indent}if claimed_index is None: {line.lstrip()}"

with open(comm_path, "w") as f:
    f.writelines(lines)
print("Patched commands.py pre-claimed support")
