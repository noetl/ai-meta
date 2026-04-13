with open("noetl/worker/nats_worker.py", "r") as f:
    content = f.read()

content = content.replace("from noetl.core.dsl.render import _get_compiled_template", "")
content = content.replace("_get_compiled_template(self._jinja_env, template)", "self._jinja_env.from_string(template)")

with open("noetl/worker/nats_worker.py", "w") as f:
    f.write(content)
