with open("noetl/worker/nats_worker.py", "r") as f:
    content = f.read()

# Fix the broken line in nats_worker.py
broken = "from noetl.core.dsl.render import _get_compiled_template\\n                rendered = _get_compiled_template(self._jinja_env, template).render(**ctx)"
fixed = """from noetl.core.dsl.render import _get_compiled_template
                rendered = _get_compiled_template(self._jinja_env, template).render(**ctx)"""

content = content.replace(broken, fixed)

with open("noetl/worker/nats_worker.py", "w") as f:
    f.write(content)
