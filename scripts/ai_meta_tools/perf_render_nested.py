import time
from noetl.core.dsl.render import render_template
from jinja2 import Environment

env = Environment()

config = {
    "url": "http://api/{{ ctx.target_id }}",
    "method": "POST",
    "json": {
        "items": "{{ iter.page_data.data | map(attribute='id') | list }}"
    },
    "headers": {
        "Authorization": "Bearer {{ ctx.token }}"
    }
}

huge_payload = {"data": [{"id": i, "value": "a" * 50} for i in range(1000)]}

ctx = {
    "iter": {"page_data": huge_payload},
    "ctx": {"target_id": 500, "token": "xyz123"},
    "output": {"status": "ok"}
}

t0 = time.time()
for _ in range(50):
    render_template(env, config, ctx)
print(f"render_dict payload: {time.time() - t0:.3f}s")
