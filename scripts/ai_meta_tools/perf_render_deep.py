import time
from noetl.core.dsl.render import render_template
from jinja2 import Environment

env = Environment()

# We test with a medium payload
huge_payload = {"data": [{"id": i, "value": "a" * 50} for i in range(1000)]}

ctx = {
    "iter": {"page_data": huge_payload},
    "ctx": {"target_id": 500},
    "output": {"status": "ok"}
}

template_str = """
{
  "matches": {{ iter.page_data.data | selectattr("id", "equalto", ctx.target_id) | list | length > 0 }},
  "status": "{{ output.status }}"
}
"""

t0 = time.time()
for _ in range(50):
    render_template(env, template_str, ctx)
print(f"render_template deep payload: {time.time() - t0:.3f}s")
