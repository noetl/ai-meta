import time
from jinja2 import Undefined

def _handle_undefined_values(value):
    if isinstance(value, Undefined):
        return None
    elif isinstance(value, dict):
        return {k: _handle_undefined_values(v) for k, v in value.items()}
    elif isinstance(value, list):
        return [_handle_undefined_values(item) for item in value]
    return value

huge_payload = {"data": [{"id": i, "value": "a" * 100} for i in range(10000)]}
ctx = {"payload": huge_payload, "loop_collection": [huge_payload]*10}

t0 = time.time()
for _ in range(1):
    _handle_undefined_values(ctx)
print(f"undef old: {time.time() - t0:.3f}s")
