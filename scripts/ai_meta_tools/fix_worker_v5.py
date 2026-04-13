with open("noetl/worker/nats_worker.py", "r") as f:
    content = f.read()

broken = """        self._concurrency = AdaptiveConcurrencyController(
            initial_limit=max(1.0, self._max_inflight_commands / 2.0)
        self._jinja_env = Environment(loader=BaseLoader())
        self._jinja_env = add_b64encode_filter(self._jinja_env)
            min_limit=1.0,
            max_limit=float(self._max_inflight_commands),
            probe_interval=worker_settings.concurrency_probe_interval,
        )"""

fixed = """        self._concurrency = AdaptiveConcurrencyController(
            initial_limit=max(1.0, float(self._max_inflight_commands) / 2.0),
            min_limit=1.0,
            max_limit=float(self._max_inflight_commands),
            probe_interval=worker_settings.concurrency_probe_interval,
        )
        self._jinja_env = Environment(loader=BaseLoader())
        self._jinja_env = add_b64encode_filter(self._jinja_env)"""

if broken in content:
    content = content.replace(broken, fixed)
else:
    # Try with single spaces if it failed due to indentation mismatch
    print("Could not find exact broken block, attempting line-by-line fix")
    lines = content.split('\n')
    for i, line in enumerate(lines):
        if "initial_limit=max(1.0, self._max_inflight_commands / 2.0)" in line:
            lines[i] = line.replace('2.0)', '2.0),')
    content = '\n'.join(lines)

with open("noetl/worker/nats_worker.py", "w") as f:
    f.write(content)
