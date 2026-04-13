import re

with open("noetl/worker/nats_worker.py", "r") as f:
    content = f.read()

# Fix the broken constructor
broken_pattern = r'self\._concurrency = AdaptiveConcurrencyController\(\n\s+initial_limit=max\(1\.0, self\._max_inflight_commands / 2\.0\),\n\s+# Pre-initialize Jinja2 environment for reuse\n\s+self\._jinja_env = Environment\(loader=BaseLoader\(\)\)\n\s+self\._jinja_env = add_b64encode_filter\(self\._jinja_env\)\n,'

fixed_concurrency = """self._concurrency = AdaptiveConcurrencyController(
            initial_limit=max(1.0, self._max_inflight_commands / 2.0),
            min_limit=1.0,
            max_limit=float(self._max_inflight_commands),
            probe_interval=worker_settings.concurrency_probe_interval,
        )
        self._jinja_env = Environment(loader=BaseLoader())
        self._jinja_env = add_b64encode_filter(self._jinja_env)"""

content = re.sub(broken_pattern, fixed_concurrency, content, flags=re.DOTALL)

# Also fix the duplicated min_limit/max_limit part if it's there
content = content.replace(',\n            min_limit=1.0,\n            max_limit=float(self._max_inflight_commands),\n            probe_interval=worker_settings.concurrency_probe_interval,\n        )', '')

with open("noetl/worker/nats_worker.py", "w") as f:
    f.write(content)
