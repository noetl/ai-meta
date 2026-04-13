import re

with open("noetl/core/dsl/render.py", "r") as f:
    content = f.read()

# 1. Define tojson_filter outside add_b64encode_filter to avoid re-definition
new_tojson_def = """
def tojson_filter(obj):
    \"\"\"Custom tojson filter that unwraps TaskResultProxy objects and handles Undefined.\"\"\"
    from jinja2 import Undefined

    # Handle Jinja2 Undefined objects
    if isinstance(obj, Undefined):
        return 'null'

    # Recursively unwrap TaskResultProxy objects
    def unwrap_proxies(value):
        \"\"\"Recursively unwrap all TaskResultProxy objects in nested structures.\"\"\"
        value_type = type(value).__name__
        
        # Check for TaskResultProxy by class name
        if value_type == 'TaskResultProxy':
            if hasattr(value, '__dict__') and '_data' in value.__dict__:
                return unwrap_proxies(value.__dict__['_data'])
            elif hasattr(value, '_data'):
                return unwrap_proxies(value._data)
            else:
                return str(value)
        elif hasattr(value, '_data') and not isinstance(value, (dict, list, tuple, str, int, float, bool, type(None))):
            return unwrap_proxies(value._data)
        elif isinstance(value, dict):
            return {k: unwrap_proxies(v) for k, v in value.items()}
        elif isinstance(value, (list, tuple)):
            return type(value)(unwrap_proxies(item) for item in value)
        else:
            return value

    return json.dumps(unwrap_proxies(obj), cls=DateTimeEncoder)
"""

# 2. Update add_b64encode_filter to use the shared function
new_add_filter = """
def add_b64encode_filter(env: Environment) -> Environment:
    if 'b64encode' not in env.filters:
        env.filters['b64encode'] = lambda s: base64.b64encode(s.encode('utf-8')).decode('utf-8') if isinstance(s, str) else base64.b64encode(str(s).encode('utf-8')).decode('utf-8')
    if 'tojson' not in env.filters:
        env.filters['tojson'] = tojson_filter
    if 'encrypt_secret' not in env.filters:
        from noetl.core.secret import encrypt_json
        env.filters['encrypt_secret'] = lambda s: encrypt_json(json.loads(s) if isinstance(s, str) else s)
    return env
"""

# Replace the old functions
content = re.sub(r'def add_b64encode_filter\(env: Environment\) -> Environment:.*?return env', new_add_filter, content, flags=re.DOTALL)
content = content.replace(new_add_filter, new_tojson_def + new_add_filter)

with open("noetl/core/dsl/render.py", "w") as f:
    f.write(content)
