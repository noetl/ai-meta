import re

with open("noetl/worker/nats_worker.py", "r") as f:
    content = f.read()

# 1. Initialize jinja_env in __init__
init_replacement = """        # Pre-initialize Jinja2 environment for reuse
        self._jinja_env = Environment(loader=BaseLoader())
        self._jinja_env = add_b64encode_filter(self._jinja_env)
"""

if "self._jinja_env =" not in content:
    content = re.sub(
        r'(self\._concurrency = AdaptiveConcurrencyController\(.*?\))',
        r'\1\n' + init_replacement,
        content,
        flags=re.DOTALL
    )

# 2. Update _execute_tool to use self._jinja_env and remove internal imports
tool_setup_pattern = r'        import time\n        t_jinja_start = time\.perf_counter\(\)\n        from jinja2 import Environment, BaseLoader\n        from noetl\.core\.dsl\.render import add_b64encode_filter\n        from noetl\.core\.auth\.token_resolver import register_token_functions\n        \n        jinja_env = Environment\(loader=BaseLoader\(\)\)\n        jinja_env = add_b64encode_filter\(jinja_env\)  # Add custom filters including tojson\n        register_token_functions\(jinja_env, context\)'

tool_setup_replacement = """        from noetl.core.auth.token_resolver import register_token_functions
        register_token_functions(self._jinja_env, context)
        jinja_env = self._jinja_env"""

content = content.replace(tool_setup_pattern, tool_setup_replacement)

# 3. Update task_sequence block to use self._jinja_env
ts_replacement = """            def render_dict_templates(data: dict, ctx: dict) -> dict:
                \"\"\"Recursively render templates in a dict.\"\"\"
                from noetl.core.dsl.render import render_template as recursive_render
                return recursive_render(self._jinja_env, data, ctx)"""

content = content.replace(
    '            def render_dict_templates(data: dict, ctx: dict) -> dict:\n                """Recursively render templates in a dict."""\n                from noetl.core.dsl.render import render_template as recursive_render\n                return recursive_render(jinja_env, data, ctx)',
    ts_replacement
)

content = content.replace(
    'rendered = jinja_env.from_string(template).render(**ctx)',
    'rendered = self._jinja_env.from_string(template).render(**ctx)'
)

with open("noetl/worker/nats_worker.py", "w") as f:
    f.write(content)
