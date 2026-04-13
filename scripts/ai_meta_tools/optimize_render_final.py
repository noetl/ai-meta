import re

with open("noetl/core/dsl/render.py", "r") as f:
    content = f.read()

# 1. Implement template cache at module level
cache_code = """
from functools import lru_cache

@lru_cache(maxsize=1024)
def _get_compiled_template(env, template_str):
    return env.from_string(template_str)
"""

if "_get_compiled_template" not in content:
    content = cache_code + content

# 2. Optimize unwrap_proxies to avoid recursion on basic types
# and only recurse if custom objects are detected.
new_tojson = """
def tojson_filter(obj):
    \"\"\"Optimized tojson filter.\"\"\"
    from jinja2 import Undefined
    if isinstance(obj, Undefined):
        return 'null'

    def unwrap(value):
        # Fast path for basic types
        if isinstance(value, (str, int, float, bool, type(None))):
            return value
        
        # Only recurse for collections
        if isinstance(value, dict):
            # Shallow check for proxy-like objects
            if hasattr(value, '_data') and not isinstance(value, dict):
                 return unwrap(value._data)
            return {k: unwrap(v) for k, v in value.items()}
        
        if isinstance(value, (list, tuple)):
            return [unwrap(item) for item in value]
            
        # Check for TaskResultProxy by name (slow path for custom objects)
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

    return json.dumps(unwrap(obj), cls=DateTimeEncoder)
"""

# Replace tojson_filter and add_b64encode_filter
content = re.sub(r'def tojson_filter\(obj\):.*?return json\.dumps\(unwrap_proxies\(obj\), cls=DateTimeEncoder\)', new_tojson, content, flags=re.DOTALL)

# 3. Update render_template to use cache
content = content.replace(
    '        rendered = env.from_string(template).render(**render_ctx)',
    '        rendered = _get_compiled_template(env, template).render(**render_ctx)'
)

with open("noetl/core/dsl/render.py", "w") as f:
    f.write(content)

# 4. Update nats_worker.py to use the same cache mechanism
with open("noetl/worker/nats_worker.py", "r") as f:
    worker_content = f.read()

# Add the cache function to worker too or import it
worker_content = worker_content.replace(
    'rendered = self._jinja_env.from_string(template).render(**ctx)',
    'from noetl.core.dsl.render import _get_compiled_template\\n                rendered = _get_compiled_template(self._jinja_env, template).render(**ctx)'
)

with open("noetl/worker/nats_worker.py", "w") as f:
    f.write(worker_content)
