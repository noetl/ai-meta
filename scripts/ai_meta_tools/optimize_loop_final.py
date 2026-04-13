import re

# 1. Update _issue_loop_commands to fetch collection once
with open("noetl/core/dsl/engine/engine/transitions.py", "r") as f:
    content = f.read()

new_issue_loop = """    async def _issue_loop_commands(
        self,
        state: "ExecutionState",
        step_def: Step,
        step_input: dict[str, Any],
    ) -> list[Command]:
        \"\"\"Issue one or more loop commands based on loop mode and max_in_flight.\"\"\"
        if not step_def.loop:
            command = await self._create_command_for_step(state, step_def, step_input)
            return [command] if command else []

        # Optimization: Fetch loop collection once for the entire batch
        from noetl.core.cache.nats_kv import get_nats_cache
        nats_cache = await get_nats_cache()
        
        existing_loop_state = state.loop_state.get(step_def.step)
        loop_event_id = str(existing_loop_state.get("event_id") or "") if existing_loop_state else ""
        
        collection = None
        if loop_event_id:
            collection = await nats_cache.get_loop_collection(str(state.execution_id), step_def.step, loop_event_id)
        
        if collection is None:
            # Render and save
            context = state.get_render_context(Event(
                execution_id=state.execution_id, step=step_def.step, name="loop_init", payload={}
            ))
            collection_expr = step_def.loop.in_
            collection = self._render_template(collection_expr, context)
            from noetl.core.dsl.engine.executor.commands import CommandEngine
            collection = CommandEngine._normalize_loop_collection(None, collection, step_def.step)
            
            # Note: loop_event_id might be empty here if it's the very first entry.
            # It will be saved inside _create_command_for_step in that case.

        issue_budget = self._get_loop_max_in_flight(step_def)
        commands: list[Command] = []
        shared_control_args = dict(step_input)
        shared_control_args["__loop_collection"] = collection

        for _ in range(issue_budget):
            command = await self._create_command_for_step(state, step_def, shared_control_args)
            if not command:
                break
            commands.append(command)
            shared_control_args["__loop_continue"] = True

        return commands"""

content = re.sub(r'    async def _issue_loop_commands\(.*?return commands', new_issue_loop, content, flags=re.DOTALL)

with open("noetl/core/dsl/engine/engine/transitions.py", "w") as f:
    f.write(content)

# 2. Update _create_command_for_step to use passed collection
with open("noetl/core/dsl/engine/engine/commands.py", "r") as f:
    content = f.read()

new_collection_logic = """            # Use passed collection if available (Optimization)
            collection = control_args.get("__loop_collection")
            
            if collection is None:
                # Distributed Loop Collection logic (Fallback)
                from noetl.core.cache.nats_kv import get_nats_cache
                nats_cache = await get_nats_cache()
                loop_event_id = str(existing_loop_state.get("event_id") or "") if existing_loop_state else ""
                if loop_event_id:
                    collection = await nats_cache.get_loop_collection(str(state.execution_id), step.step, loop_event_id)

            if collection is None:
                # Final fallback: re-render
                context = state.get_render_context(Event(
                    execution_id=state.execution_id, step=step.step, name="loop_init", payload={}
                ))
                collection = self._render_template(step.loop.in_, context)
                collection = self._normalize_loop_collection(collection, step.step)"""

# Replace the previous distributed logic block
find_pattern = r'            # Distributed Loop Collection logic:.*?await nats_cache\.save_loop_collection\(str\(state\.execution_id\), step\.step, loop_event_id, collection\)'
content = re.sub(find_pattern, new_collection_logic, content, flags=re.DOTALL)

# Add saving after init_loop
content = content.replace(
    'event_id=loop_event_id,\n                )',
    'event_id=loop_event_id,\n                )\n                # Save collection to NATS KV immediately after initialization\n                from noetl.core.cache.nats_kv import get_nats_cache\n                await (await get_nats_cache()).save_loop_collection(str(state.execution_id), step.step, loop_event_id, collection)'
)

with open("noetl/core/dsl/engine/engine/commands.py", "w") as f:
    f.write(content)
