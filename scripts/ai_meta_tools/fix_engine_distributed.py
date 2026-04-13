import re

# 1. Remove lru_cache from render.py
with open("noetl/core/dsl/render.py", "r") as f:
    content = f.read()

content = content.replace("from functools import lru_cache", "")
content = re.sub(r'@lru_cache\(maxsize=1024\)\ndef _get_compiled_template\(env, template_str\):.*?return env\.from_string\(template_str\)', '', content, flags=re.DOTALL)
content = content.replace('_get_compiled_template(env, template)', 'env.from_string(template)')

with open("noetl/core/dsl/render.py", "w") as f:
    f.write(content)

# 2. Fix transitions.py (remove the _get_compiled_template import and use)
with open("noetl/core/dsl/engine/engine/transitions.py", "r") as f:
    content = f.read()

content = content.replace("from noetl.core.dsl.render import _get_compiled_template", "")
content = content.replace("_get_compiled_template(self.jinja_env, template)", "self.jinja_env.from_string(template)")

with open("noetl/core/dsl/engine/engine/transitions.py", "w") as f:
    f.write(content)

# 3. Fix commands.py (remove ephemeral setattr and use NATS KV)
with open("noetl/core/dsl/engine/engine/commands.py", "r") as f:
    content = f.read()

# Replace my previous "Optimization" with a distributed one
find_pattern = r'            # Optimization: Cache rendered collection in the state object\'s ephemeral storage.*?setattr\(state, ephemeral_key, collection\)'

distributed_logic = """            # Distributed Loop Collection logic:
            # We fetch/save the rendered collection from NATS KV to ensure consistency 
            # across multiple NoETL server instances and avoid redundant Jinja2 CPU load.
            from noetl.core.cache.nats_kv import get_nats_cache
            nats_cache = await get_nats_cache()
            
            # The loop_event_id is the unique identifier for this loop's "epoch"
            loop_event_id = str(existing_loop_state.get("event_id") or "") if existing_loop_state else ""
            
            collection = None
            if loop_event_id:
                collection = await nats_cache.get_loop_collection(str(state.execution_id), step.step, loop_event_id)

            if collection is not None:
                logger.debug("[LOOP] Reusing distributed collection from NATS KV for %s", step.step)
            else:
                # Fallback: render and save to NATS KV
                context = state.get_render_context(Event(
                    execution_id=state.execution_id,
                    step=step.step,
                    name="loop_init",
                    payload={}
                ))
                collection_expr = step.loop.in_
                collection = self._render_template(collection_expr, context)
                collection = self._normalize_loop_collection(collection, step.step)
                
                # If we have a loop_event_id, save it for other servers to pick up
                if loop_event_id:
                    await nats_cache.save_loop_collection(str(state.execution_id), step.step, loop_event_id, collection)"""

content = re.sub(find_pattern, distributed_logic, content, flags=re.DOTALL)

with open("noetl/core/dsl/engine/engine/commands.py", "w") as f:
    f.write(content)

