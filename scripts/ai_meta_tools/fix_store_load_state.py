import re

with open("repos/noetl/noetl/core/dsl/v2/engine/store.py", "r") as f:
    content = f.read()

# Replace load_state method definition
replacement = """    async def load_state(self, execution_id: str, conn=None) -> Optional[ExecutionState]:
        \"\"\"Load execution state from Postgres. Does NOT lock.\"\"\"
        if conn is None:
            async with get_pool_connection() as c:
                async with c.cursor(row_factory=dict_row) as cur:
                    await cur.execute(
                        "SELECT state, catalog_id FROM noetl.execution WHERE execution_id = %s",
                        (int(execution_id),)
                    )
                    row = await cur.fetchone()
                    
                    if row and row.get("state"):
                        catalog_id = row.get("catalog_id")
                        if catalog_id:
                            playbook = await self.playbook_repo.load_playbook_by_id(catalog_id, c)
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
                        playbook = await self.playbook_repo.load_playbook_by_id(catalog_id, c)
                        if playbook:
                            workload = init_event.get("context", {}).get("workload", {}) if init_event.get("context") else {}
                            state = ExecutionState(execution_id, playbook, workload, catalog_id)
                            return state
        else:
            async with conn.cursor(row_factory=dict_row) as cur:
                await cur.execute(
                    "SELECT state, catalog_id FROM noetl.execution WHERE execution_id = %s",
                    (int(execution_id),)
                )
                row = await cur.fetchone()
                
                if row and row.get("state"):
                    catalog_id = row.get("catalog_id")
                    if catalog_id:
                        playbook = await self.playbook_repo.load_playbook_by_id(catalog_id, conn)
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
                    playbook = await self.playbook_repo.load_playbook_by_id(catalog_id, conn)
                    if playbook:
                        workload = init_event.get("context", {}).get("workload", {}) if init_event.get("context") else {}
                        state = ExecutionState(execution_id, playbook, workload, catalog_id)
                        return state
        return None"""

content = re.sub(
    r'    async def load_state\(self, execution_id: str, conn=None\) -> Optional\[ExecutionState\]:.*?return None',
    replacement,
    content,
    flags=re.DOTALL
)

with open("repos/noetl/noetl/core/dsl/v2/engine/store.py", "w") as f:
    f.write(content)

