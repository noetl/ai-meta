import re

with open("repos/noetl/noetl/core/dsl/v2/engine/store.py", "r") as f:
    content = f.read()

new_store_code = """
class StateStore:
    \"\"\"Stores and retrieves execution state using Postgres JSONB column with row locking.\"\"\"

    def __init__(self, playbook_repo: 'PlaybookRepo'):
        self.playbook_repo = playbook_repo
        self._stale_probe_last_checked_at: dict[str, float] = {}

    async def save_state(self, state: ExecutionState, conn=None):
        \"\"\"Save execution state to Postgres execution table.\"\"\"
        state_dict = state.to_dict()
        
        # Save to Postgres. The row is locked by load_state_for_update.
        if conn is None:
            async with get_pool_connection() as c:
                async with c.cursor() as cur:
                    await cur.execute(
                        "UPDATE noetl.execution SET state = %s, updated_at = CURRENT_TIMESTAMP WHERE execution_id = %s",
                        (json.dumps(state_dict), int(state.execution_id))
                    )
        else:
            async with conn.cursor() as cur:
                await cur.execute(
                    "UPDATE noetl.execution SET state = %s, updated_at = CURRENT_TIMESTAMP WHERE execution_id = %s",
                    (json.dumps(state_dict), int(state.execution_id))
                )

        logger.debug(f"[STATE-SAVE] State saved to Postgres for execution {state.execution_id}")

    async def should_refresh_cached_state(
        self,
        execution_id: str,
        last_event_id: Optional[int],
        *,
        allowed_missing_events: int = 1,
    ) -> bool:
        return False
    
    async def load_state(self, execution_id: str) -> Optional[ExecutionState]:
        \"\"\"Load execution state from Postgres. Does NOT lock.\"\"\"
        async with get_pool_connection() as conn:
            async with conn.cursor(row_factory=dict_row) as cur:
                await cur.execute(
                    "SELECT state, catalog_id FROM noetl.execution WHERE execution_id = %s",
                    (int(execution_id),)
                )
                row = await cur.fetchone()
                
                if row and row.get("state"):
                    catalog_id = row.get("catalog_id")
                    if catalog_id:
                        playbook = await self.playbook_repo.load_playbook_by_id(catalog_id)
                        if playbook:
                            logger.debug(f"[STATE-LOAD] execution_id={execution_id} loaded from Postgres state")
                            return ExecutionState.from_dict(row["state"], playbook)

                logger.debug(f"[STATE-LOAD-MISS] Execution {execution_id}: no state in Postgres, trying to rebuild from init event")
                
                # Ultimate fallback for very first playbook.initialized event
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
                        return state
                        
        return None

    async def load_state_for_update(self, execution_id: str, conn) -> Optional[ExecutionState]:
        \"\"\"Load execution state and lock the row FOR UPDATE. Must be used within a transaction.\"\"\"
        async with conn.cursor(row_factory=dict_row) as cur:
            await cur.execute(
                "SELECT state, catalog_id FROM noetl.execution WHERE execution_id = %s FOR UPDATE",
                (int(execution_id),)
            )
            row = await cur.fetchone()
            
            if row and row.get("state"):
                catalog_id = row.get("catalog_id")
                if catalog_id:
                    playbook = await self.playbook_repo.load_playbook_by_id(catalog_id)
                    if playbook:
                        return ExecutionState.from_dict(row["state"], playbook)

            # Fallback to init event
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
                    return state
                    
        return None

    def get_state(self, execution_id: str) -> Optional[ExecutionState]:
        \"\"\"DEPRECATED.\"\"\"
        return None

    async def evict_completed(self, execution_id: str):
        \"\"\"No-op. Postgres state is durable.\"\"\"
        pass

    async def invalidate_state(self, execution_id: str, reason: str = "manual") -> bool:
        \"\"\"No-op. Postgres state is always consistent.\"\"\"
        return True
"""

# Replace the StateStore class
content = re.sub(r'class StateStore:.*?(?=class |$)', new_store_code, content, flags=re.DOTALL)

with open("repos/noetl/noetl/core/dsl/v2/engine/store.py", "w") as f:
    f.write(content)

