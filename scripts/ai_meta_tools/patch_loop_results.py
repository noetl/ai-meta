import re

with open("repos/noetl/noetl/core/cache/nats_kv.py", "r") as f:
    content = f.read()

new_methods = """
    async def add_loop_result(
        self, execution_id: str, step_name: str, event_id: str, result: dict, failed: bool = False
    ):
        \"\"\"Atomically add an iteration result to the NATS KV loop state.\"\"\"
        if not self._kv:
            await self.connect()

        key_suffix = f"loop:{step_name}:{event_id}" if event_id else f"loop:{step_name}"
        key = self._make_key(execution_id, key_suffix)

        max_retries = 10
        for attempt in range(max_retries):
            try:
                entry = await self._kv.get(key)
                if not entry:
                    # Initialize if missing
                    state = {
                        "completed_count": 0,
                        "scheduled_count": 0,
                        "collection_size": 0,
                        "results": [],
                        "failed_count": 0,
                        "updated_at": _utcnow_iso()
                    }
                    revision = None
                else:
                    state = json.loads(entry.value.decode("utf-8"))
                    revision = entry.revision

                # Append result
                results = state.get("results", [])
                results.append(result)
                state["results"] = results
                
                if failed:
                    state["failed_count"] = int(state.get("failed_count", 0)) + 1
                    
                state["updated_at"] = _utcnow_iso()

                value = json.dumps(state).encode("utf-8")
                
                if revision is None:
                    await self._kv.put(key, value)
                    return
                else:
                    await self._kv.update(key, value, last=revision)
                    return
            except Exception as e:
                # KeyWrongLastSequenceError triggers retry
                if attempt == max_retries - 1:
                    logger.warning(f"Failed to add loop result to NATS KV after {max_retries} attempts: {e}")
                    raise
"""

content = content.replace("async def get_loop_state(", new_methods + "\n    async def get_loop_state(")

with open("repos/noetl/noetl/core/cache/nats_kv.py", "w") as f:
    f.write(content)

