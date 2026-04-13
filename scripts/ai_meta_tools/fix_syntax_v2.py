with open("noetl/worker/nats_worker.py", "r") as f:
    lines = f.read().split('\n')

for i, line in enumerate(lines):
    if "from noetl.core.dsl.render import _get_compiled_template" in line:
        # Move the import outside the try block or fix the try block
        lines[i] = "                from noetl.core.dsl.render import _get_compiled_template"
    if "rendered = _get_compiled_template" in line:
        lines[i] = "                    rendered = _get_compiled_template(self._jinja_env, template).render(**ctx)"

with open("noetl/worker/nats_worker.py", "w") as f:
    f.write('\n'.join(lines))
