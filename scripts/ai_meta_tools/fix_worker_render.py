import re

with open("noetl/worker/nats_worker.py", "r") as f:
    content = f.read()

new_render_func = """            def render_template_str(template: str, ctx: dict) -> Any:
                \"\"\"Render a single Jinja2 template string, parsing JSON results back to objects.\"\"\"
                import json
                from noetl.core.dsl.render import _get_compiled_template
                try:
                    rendered = _get_compiled_template(self._jinja_env, template).render(**ctx)
                    # If result looks like JSON (dict or list), parse it back to object
                    if isinstance(rendered, str):
                        stripped = rendered.strip()
                        if (stripped.startswith('{') and stripped.endswith('}')) or \\
                           (stripped.startswith('[') and stripped.endswith(']')):
                            try:
                                return json.loads(stripped)
                            except json.JSONDecodeError:
                                import ast
                                return ast.literal_eval(stripped)
                    return rendered
                except Exception as e:
                    logger.error(f"Template rendering error: {e} | template={template[:100]}...")
                    return template"""

pattern = r'            def render_template_str\(template: str, ctx: dict\) -> Any:.*?return template'
content = re.sub(pattern, new_render_func, content, flags=re.DOTALL)

with open("noetl/worker/nats_worker.py", "w") as f:
    f.write(content)
