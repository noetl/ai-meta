import re

with open("repos/noetl/noetl/core/cache/nats_kv.py", "r") as f:
    content = f.read()

kv_methods = """
    async def get_execution_state(self, execution_id: str) -> Optional[dict[str, Any]]:
        \"\"\"Get the serialized ExecutionState dictionary from NATS KV.\"\"\"
        if not self._kv:
            await self.connect()
        key = self._make_key(execution_id, "state")
        try:
            entry = await self._kv.get(key)
            if entry:
                return json.loads(entry.value.decode("utf-8"))
        except Exception:
            pass
        return None

    async def save_execution_state(self, execution_id: str, state_dict: dict[str, Any]):
        \"\"\"Save the serialized ExecutionState dictionary to NATS KV.\"\"\"
        if not self._kv:
            await self.connect()
        key = self._make_key(execution_id, "state")
        value = json.dumps(state_dict).encode("utf-8")
        try:
            # Upsert without revision check for global state pointer.
            # Using NATS KV as the transient cache for the linked-list state.
            await self._kv.put(key, value)
        except Exception as e:
            logger.warning(f"Failed to save execution state to NATS KV for {execution_id}: {e}")

    async def delete_execution_state(self, execution_id: str):
        if not self._kv:
            await self.connect()
        key = self._make_key(execution_id, "state")
        try:
            await self._kv.delete(key)
        except Exception:
            pass
"""

content = content.replace("async def get_command(", kv_methods + "\n    async def get_command(")

with open("repos/noetl/noetl/core/cache/nats_kv.py", "w") as f:
    f.write(content)

