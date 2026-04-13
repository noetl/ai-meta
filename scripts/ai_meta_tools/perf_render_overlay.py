import time
from jinja2 import Environment

env = Environment()
huge_payload = {"data": [{"id": i, "value": "a" * 100} for i in range(1000)]}

ctx = {
    "iter": {"page_data": huge_payload},
    "ctx": {"target_id": 500},
}

t0 = time.time()
for _ in range(500):
    temp_env = env.overlay()
    template_obj = temp_env.from_string("Hello {{ ctx.target_id }}")
    template_obj.render(**ctx)
print(f"overlay: {time.time() - t0:.3f}s")

t0 = time.time()
for _ in range(500):
    template_obj = env.from_string("Hello {{ ctx.target_id }}")
    template_obj.render(**ctx)
print(f"no overlay: {time.time() - t0:.3f}s")

