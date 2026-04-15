import re

file_path = "repos/noetl/noetl/core/cache/nats_kv.py"
with open(file_path, "r") as f:
    text = f.read()

batch_claim_code = """
    async def claim_next_loop_indices(
        self,
        execution_id: str,
        step_name: str,
        collection_size: int,
        max_in_flight: int,
        requested_count: int = 1,
        event_id: Optional[str] = None,
    ) -> list[int]:
        \"\"\"Atomically claim multiple loop iteration indices with backpressure control.\"\"\"
        if not self._kv:
            await self.connect()

        key_suffix = f"loop:{step_name}:{event_id}" if event_id else f"loop:{step_name}"
        key = self._make_key(execution_id, key_suffix)

        safe_collection_size = max(0, int(collection_size or 0))
        safe_max_in_flight = max(1, int(max_in_flight or 1))
        safe_requested_count = max(1, int(requested_count))

        max_retries = 5
        for attempt in range(max_retries):
            try:
                entry = await self._kv.get(key)
                if not entry:
                    return []

                state = json.loads(entry.value.decode("utf-8"))
                completed_count = int(state.get("completed_count", 0) or 0)
                scheduled_count = int(state.get("scheduled_count", completed_count) or completed_count)

                if scheduled_count < completed_count:
                    scheduled_count = completed_count
                
                existing_collection_size = int(state.get("collection_size", 0) or 0)
                if safe_collection_size <= 0 and existing_collection_size > 0:
                    safe_collection_size = existing_collection_size

                if safe_collection_size <= 0:
                    return []

                if scheduled_count >= safe_collection_size:
                    return []

                in_flight = max(0, scheduled_count - completed_count)
                available_slots = safe_max_in_flight - in_flight
                
                if available_slots <= 0:
                    return []

                claim_count = min(safe_requested_count, available_slots, safe_collection_size - scheduled_count)
                
                if claim_count <= 0:
                    return []

                claimed_indices = list(range(scheduled_count, scheduled_count + claim_count))
                
                state["collection_size"] = safe_collection_size
                state["completed_count"] = completed_count
                state["scheduled_count"] = scheduled_count + claim_count
                now_iso = _utcnow_iso()
                state["last_claimed_at"] = now_iso
                state["last_progress_at"] = now_iso
                state["updated_at"] = now_iso

                value = json.dumps(state).encode("utf-8")
                await self._kv.update(key, value, last=entry.revision)
                
                return claimed_indices

            except Exception as e:
                if "wrong last sequence" in str(e).lower() and attempt < max_retries - 1:
                    await asyncio.sleep(0.01 * (attempt + 1))
                    continue
                logger.error(f"Failed to claim next loop indices: {e}")
                return []
        return []
"""

# Insert after release_loop_slot or near claim_next_loop_index
text = text.replace("    async def release_loop_slot(", batch_claim_code + "\n    async def release_loop_slot(")

with open(file_path, "w") as f:
    f.write(text)

print("Successfully added claim_next_loop_indices to nats_kv.py")
