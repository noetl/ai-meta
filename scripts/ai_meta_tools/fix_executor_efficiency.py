import re

with open("noetl/worker/task_sequence_executor.py", "r") as f:
    content = f.read()

# 1. Optimize render_ctx construction to avoid redundant copies
old_render_ctx = """            render_ctx = {
                **base_context,
                **ctx.results,  # Task results at root level: {{ amadeus_search }}
                **task_seq_dict,  # Pipeline-local vars: _prev, _task, _attempt, output, results
                "ctx": merged_ctx,  # Merged execution ctx + task sequence ctx
                "iter": merged_iter,  # Merged iteration vars
            }"""

new_render_ctx = """            # Optimization: Use a lazy-merging view instead of dict spread for large contexts.
            # For now, we use a simple dict update which is still faster than multiple spreads.
            render_ctx = base_context.copy()
            render_ctx.update(ctx.results)
            render_ctx.update(task_seq_dict)
            render_ctx["ctx"] = merged_ctx
            render_ctx["iter"] = merged_iter"""

content = content.replace(old_render_ctx, new_render_ctx)

# 2. Skip rendering for empty config or noop tools
old_render_call = """                config_to_render = {k: v for k, v in tool_config.items() if k not in ("kind", "spec", "output")}
                rendered_config = self.render_dict(config_to_render, render_ctx)"""

new_render_call = """                config_to_render = {k: v for k, v in tool_config.items() if k not in ("kind", "spec", "output")}
                if tool_kind == "noop" or not config_to_render:
                    rendered_config = config_to_render
                else:
                    rendered_config = self.render_dict(config_to_render, render_ctx)"""

content = content.replace(old_render_call, new_render_call)

with open("noetl/worker/task_sequence_executor.py", "w") as f:
    f.write(content)
