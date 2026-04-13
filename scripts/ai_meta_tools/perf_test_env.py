import time
from jinja2 import Environment

env = Environment()

t0 = time.time()
for _ in range(1000):
    temp_env = env.overlay()
    template_obj = temp_env.from_string("Hello {{ name }}")
    template_obj.render(name="world")
print(f"overlay+compile: {time.time() - t0:.3f}s")
