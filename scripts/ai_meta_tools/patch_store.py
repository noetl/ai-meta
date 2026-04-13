import re

with open("repos/noetl/noetl/core/dsl/v2/engine/store.py", "r") as f:
    content = f.read()

new_store_code = """
class StateStore:
    \"\"\"Stores and retrieves execution state using NATS KV and Postgres indexed lookup.\"\"\"

    def __init__(self, playbook_repo: 'PlaybookRepo'):
        self.playbook_repo = playbook_repo
        self._stale_probe_last_checked_at: dict[str, float] = {}

    async def save_state(self, state: ExecutionState):
        \"\"\"Save execution state to NATS KV.\"\"\"
        from noetl.core.cache import get_nats_cache
        nats_cache = await get_nats_cache()
        state_dict = state.to_dict()
        await nats_cache.save_execution_state(str(state.execution_id), state_dict)
        logger.debug(f"[STATE-SAVE] State cached in NATS KV for execution {state.execution_id}")

    async def should_refresh_cached_state(
        self,
        execution_id: str,
        last_event_id: Optional[int],
        *,
        allowed_missing_events: int = 1,
    ) -> bool:
        # Since we use NATS KV and latest-event lookup directly, we don't use stale logic here.
        # Return False to avoid unnecessary thrashes.
        return False
    
    async def _load_state_from_event_meta(self, cur, execution_id: str, event_id: int) -> Optional[ExecutionState]:
        \"\"\"Rebuild the state using a linked list traversal to find the latest valid state snapshot.\"\"\"
        from noetl.core.cache import get_nats_cache
        nats_cache = await get_nats_cache()
        
        # Traverse the linked list of events backwards
        curr_id = event_id
        while curr_id is not None:
            await cur.execute(\"\"\"
                SELECT parent_event_id, meta, event_type
                FROM noetl.event
                WHERE event_id = %s
            \"\"\", (curr_id,))
            row = await cur.fetchone()
            if not row:
                break
            
            meta_data = row.get("meta") or {}
            state_ref = meta_data.get("state_ref")
            
            # If the event meta has a reference to the state in KV, load it
            if state_ref:
                state_dict = await nats_cache.get_execution_state(execution_id)
                if state_dict:
                    catalog_id = state_dict.get("catalog_id")
                    playbook = await self.playbook_repo.load_playbook_by_id(catalog_id)
                    if playbook:
                        return ExecutionState.from_dict(state_dict, playbook)
            
            # Or if the state is fully embedded in the meta (for testing/future-proofing)
            if "execution_state" in meta_data:
                catalog_id = meta_data["execution_state"].get("catalog_id")
                playbook = await self.playbook_repo.load_playbook_by_id(catalog_id)
                if playbook:
                    return ExecutionState.from_dict(meta_data["execution_state"], playbook)
            
            curr_id = row.get("parent_event_id")
            
        return None

    async def load_state(self, execution_id: str) -> Optional[ExecutionState]:
        \"\"\"Load execution state from NATS KV or reconstruct from latest event index.\"\"\"
        from noetl.core.cache import get_nats_cache
        nats_cache = await get_nats_cache()
        
        # 1. Check NATS KV cache first
        state_dict = await nats_cache.get_execution_state(str(execution_id))
        if state_dict:
            catalog_id = state_dict.get("catalog_id")
            if catalog_id:
                playbook = await self.playbook_repo.load_playbook_by_id(catalog_id)
                if playbook:
                    logger.debug(f"[STATE-CACHE-HIT] execution_id={execution_id} loaded from NATS KV")
                    return ExecutionState.from_dict(state_dict, playbook)

        logger.debug(f"[STATE-CACHE-MISS] Execution {execution_id}: looking up latest event via index")
        
        # 2. If NATS KV missed, fallback to index-based query for latest event
        # (No scanning! Relies on idx_event_exec_id_event_id_desc)
        async with get_pool_connection() as conn:
            async with conn.cursor(row_factory=dict_row) as cur:
                await cur.execute(\"\"\"
                    SELECT event_id
                    FROM noetl.event
                    WHERE execution_id = %s
                    ORDER BY event_id DESC
                    LIMIT 1
                \"\"\", (int(execution_id),))
                latest_event = await cur.fetchone()
                
                if latest_event:
                    # Traverse the linked list of events using parent_event_id
                    # to find the last valid state snapshot.
                    state = await self._load_state_from_event_meta(cur, execution_id, latest_event["event_id"])
                    if state:
                        # Re-warm the cache
                        await self.save_state(state)
                        return state
                        
                # 3. Ultimate fallback for very first playbook.initialized event
                # (When there's only one event and it has no state_ref yet)
                await cur.execute(\"\"\"
                    SELECT catalog_id, context, result
                    FROM noetl.event
                    WHERE execution_id = %s AND event_type = 'playbook.initialized'
                    LIMIT 1
                \"\"\", (int(execution_id),))
                init_event = await cur.fetchone()
                if init_event:
                    catalog_id = init_event.get("catalog_id")
                    playbook = await self.playbook_repo.load_playbook_by_id(catalog_id)
                    if playbook:
                        workload = init_event.get("context", {}).get("workload", {}) if init_event.get("context") else {}
                        state = ExecutionState(execution_id, playbook, workload, catalog_id)
                        await self.save_state(state)
                        return state
                        
        return None

    def get_state(self, execution_id: str) -> Optional[ExecutionState]:
        \"\"\"Get state from memory cache (sync) - DEPRECATED, memory cache removed.\"\"\"
        # Not possible in fully async NATS KV, but used by transient callers.
        # Fallback to None, forcing callers to await load_state.
        return None

    async def evict_completed(self, execution_id: str):
        \"\"\"Remove completed execution from NATS KV to free space.\"\"\"
        from noetl.core.cache import get_nats_cache
        nats_cache = await get_nats_cache()
        await nats_cache.delete_execution_state(str(execution_id))
        logger.info(f"Evicted completed execution {execution_id} from NATS KV")

    async def invalidate_state(self, execution_id: str, reason: str = "manual") -> bool:
        \"\"\"Invalidate NATS KV cached execution state so next load reconstructs from events.\"\"\"
        from noetl.core.cache import get_nats_cache
        nats_cache = await get_nats_cache()
        await nats_cache.delete_execution_state(str(execution_id))
        logger.warning(
            "[STATE-CACHE-INVALIDATE] execution_id=%s reason=%s",
            execution_id,
            reason,
        )
        return True
"""

# Replace the entire StateStore class
content = re.sub(r'class StateStore:.*?(?=class |$)', new_store_code, content, flags=re.DOTALL)

with open("repos/noetl/noetl/core/dsl/v2/engine/store.py", "w") as f:
    f.write(content)

