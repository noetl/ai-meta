import re

with open("noetl/core/cache/nats_kv.py", "r") as f:
    content = f.read()

# 1. Add loop collection methods to NATSKVCache
methods = """
    async def get_loop_collection(self, execution_id: str, step_name: str, loop_event_id: str) -> Optional[list]:
        \"\"\"Retrieve rendered loop collection from NATS KV.\"\"\"
        if not self._kv: await self.connect()
        key = f"loop_coll:{execution_id}:{step_name}:{loop_event_id}"
        try:
            entry = await self._kv.get(key)
            if entry:
                return json.loads(entry.value.decode())
        except Exception:
            pass
        return None

    async def save_loop_collection(self, execution_id: str, step_name: str, loop_event_id: str, collection: list):
        \"\"\"Save rendered loop collection to NATS KV.\"\"\"
        if not self._kv: await self.connect()
        key = f"loop_coll:{execution_id}:{step_name}:{loop_event_id}"
        try:
            data = json.dumps(collection).encode()
            await self._kv.put(key, data)
            logger.debug(f"[NATS-KV] Saved loop collection for {step_name} (size={len(data)} bytes)")
        except Exception as e:
            logger.warning(f"[NATS-KV] Failed to save loop collection: {e}")
"""

if "async def get_loop_collection" not in content:
    content = re.sub(r'(class NATSKVCache:.*?)(?=\n\n|\Z)', r'\1' + methods, content, flags=re.DOTALL)

with open("noetl/core/cache/nats_kv.py", "w") as f:
    f.write(content)
