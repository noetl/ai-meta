import re

with open("noetl/core/dsl/engine/engine/transitions.py", "r") as f:
    content = f.read()

# 1. Update _issue_loop_commands to support passing a pre-rendered collection
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

        issue_budget = self._get_loop_max_in_flight(step_def)
        commands: list[Command] = []

        # Optimization: Pre-render loop state once for the entire batch to avoid 
        # redundant get_render_context() and template rendering calls in the loop.
        shared_control_args = dict(step_input)
        
        for _ in range(issue_budget):
            command = await self._create_command_for_step(state, step_def, shared_control_args)
            if not command:
                break
            commands.append(command)
            # Ensure next iteration doesn't re-render collection
            shared_control_args["__loop_continue"] = True

        return commands"""

content = re.sub(r'    async def _issue_loop_commands\(.*?return commands', new_issue_loop, content, flags=re.DOTALL)

with open("noetl/core/dsl/engine/engine/transitions.py", "w") as f:
    f.write(content)

with open("noetl/core/dsl/engine/engine/commands.py", "r") as f:
    cmd_content = f.read()

# 2. Update _create_command_for_step to use a local variable for rendered collection 
# within the state object to survive across calls in the same engine invocation.
# This prevents re-rendering when issuing 20 commands for the same loop.

find_pattern = r'            if reuse_cached_collection:.*?collection = self\._normalize_loop_collection\(collection, step\.step\)'
optimized_collection_logic = """            # Optimization: Cache rendered collection in the state object's ephemeral storage
            # to avoid redundant rendering during a single engine turn (e.g. issuing batch of 20 commands).
            ephemeral_key = f"_rendered_collection_{step.step}"
            
            if reuse_cached_collection and hasattr(state, ephemeral_key):
                collection = getattr(state, ephemeral_key)
                logger.debug("[LOOP] Using ephemeral cached collection for %s", step.step)
            elif reuse_cached_collection:
                context = state.get_render_context(Event(
                    execution_id=state.execution_id,
                    step=step.step,
                    name="loop_continue",
                    payload={}
                ))
                collection = list(existing_loop_state.get("collection", []))
                setattr(state, ephemeral_key, collection)
            else:
                context = state.get_render_context(Event(
                    execution_id=state.execution_id,
                    step=step.step,
                    name="loop_init",
                    payload={}
                ))
                collection_expr = step.loop.in_
                collection = self._render_template(collection_expr, context)
                collection = self._normalize_loop_collection(collection, step.step)
                setattr(state, ephemeral_key, collection)"""

cmd_content = re.sub(find_pattern, optimized_collection_logic, cmd_content, flags=re.DOTALL)

with open("noetl/core/dsl/engine/engine/commands.py", "w") as f:
    f.write(cmd_content)
