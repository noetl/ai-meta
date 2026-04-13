import time
from noetl.core.dsl.render import render_template, tojson_filter
from jinja2 import Environment

env = Environment()
huge_payload = {"data": [{"id": i, "value": "a" * 100} for i in range(10000)]}

ctx = {"iter": {"page_data": huge_payload}}

t0 = time.time()
for _ in range(10):
    tojson_filter(ctx["iter"]["page_data"])
print(f"tojson_filter: {time.time() - t0:.3f}s")

t0 = time.time()
for _ in range(10):
    render_template(env, "{{ iter.page_data | tojson }}", ctx)
print(f"render_template: {time.time() - t0:.3f}s")
