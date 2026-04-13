import re

with open("noetl/worker/nats_worker.py", "r") as f:
    content = f.read()

# Ensure imports are at the top
if "from jinja2 import Environment" not in content:
    content = "from jinja2 import Environment, BaseLoader\nfrom noetl.core.dsl.render import add_b64encode_filter\n" + content

# Fix the __init__ assignment
content = re.sub(
    r'self\._concurrency = AdaptiveConcurrencyController\(.*?\)\n\s+self\._jinja_env = Environment\(loader=BaseLoader\(\)\)',
    r'self._concurrency = AdaptiveConcurrencyController()\n        self._jinja_env = Environment(loader=BaseLoader())\n        self._jinja_env = add_b64encode_filter(self._jinja_env)',
    content,
    flags=re.DOTALL
)

with open("noetl/worker/nats_worker.py", "w") as f:
    f.write(content)
