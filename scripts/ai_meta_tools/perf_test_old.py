import time
import json

def unwrap(value):
    if isinstance(value, (str, int, float, bool, type(None))):
        return value
    if isinstance(value, dict):
        if hasattr(value, '_data') and not isinstance(value, dict):
             return unwrap(value._data)
        return {k: unwrap(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [unwrap(item) for item in value]
    v_type = type(value).__name__
    if v_type == 'TaskResultProxy':
        if hasattr(value, '__dict__') and '_data' in value.__dict__:
            return unwrap(value.__dict__['_data'])
        elif hasattr(value, '_data'):
            return unwrap(value._data)
        return str(value)
    if hasattr(value, '_data'):
        return unwrap(value._data)
    return value

huge_payload = {"data": [{"id": i, "value": "a" * 100} for i in range(10000)]}

t0 = time.time()
for _ in range(10):
    unwrap(huge_payload)
print(f"unwrap old: {time.time() - t0:.3f}s")
