import re

with open("noetl/core/cache/nats_kv.py", "r") as f:
    content = f.read()

# 1. Restore _make_key docstring
broken_pattern = r'def _make_key\(self, execution_id: str, key_type: str\) -> str:\n\s+"""Create namespaced key for execution state.\n\s+async def get_loop_collection'
restored_docstring = '    def _make_key(self, execution_id: str, key_type: str) -> str:\n        """Create namespaced key for execution state.\n\n        NATS K/V valid characters: [-/_=.a-zA-Z0-9].  Keys must not start or\n        end with \'.\'.  Format: exec.{execution_id}.{key_type}\n        """'

content = re.sub(broken_pattern, restored_docstring + '\n    async def get_loop_collection', content)

with open("noetl/core/cache/nats_kv.py", "w") as f:
    f.write(content)
