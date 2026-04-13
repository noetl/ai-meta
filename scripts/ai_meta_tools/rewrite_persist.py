import re

with open("repos/noetl/noetl/core/dsl/v2/engine/lifecycle.py", "r") as f:
    content = f.read()

new_persist_event = """    async def _persist_event(self, event: Event, state: ExecutionState, conn=None):
        \"\"\"Persist event to database with state tracking.\"\"\"
        # Use catalog_id from state, or lookup from existing events
        catalog_id = state.catalog_id
        
        async def _do_persist(c):
            nonlocal catalog_id
            if not catalog_id:
                async with c.cursor() as cur:
                    await cur.execute("SELECT catalog_id FROM noetl.event WHERE execution_id = %s LIMIT 1", (int(event.execution_id),))
                    result = await cur.fetchone()
                    catalog_id = result['catalog_id'] if result else None
            
            if not catalog_id:
                logger.error(f"Cannot persist event - no catalog_id for execution {event.execution_id}")
                return
            
            parent_event_id = event.parent_event_id
            if parent_event_id is None:
                if event.step:
                    parent_event_id = state.step_event_ids.get(event.step)
                if not parent_event_id:
                    parent_event_id = state.last_event_id
            
            duration_ms = 0
            event_timestamp = event.timestamp or datetime.now(timezone.utc)
            
            is_loop_iteration_exit = (
                event.name == "step.exit"
                and event.step
                and (
                    event.step.endswith(":task_sequence")
                    or (event.step in state.loop_state if hasattr(state, 'loop_state') else False)
                )
            )
            
            if event.name == "step.exit" and event.step and not is_loop_iteration_exit:
                async with c.cursor() as cur:
                    await cur.execute("SELECT created_at FROM noetl.event WHERE execution_id = %s AND node_id = %s AND event_type = 'step.enter' ORDER BY event_id DESC LIMIT 1", (int(event.execution_id), event.step))
                    enter_event = await cur.fetchone()
                    if enter_event and enter_event['created_at']:
                        start_time = enter_event['created_at']
                        duration_ms = int((event_timestamp - start_time).total_seconds() * 1000)
            
            elif "completed" in event.name or "failed" in event.name:
                async with c.cursor() as cur:
                    init_event_type = "workflow_initialized" if "workflow_" in event.name else "playbook_initialized"
                    await cur.execute("SELECT created_at FROM noetl.event WHERE execution_id = %s AND event_type = %s ORDER BY event_id ASC LIMIT 1", (int(event.execution_id), init_event_type))
                    init_event = await cur.fetchone()
                    if init_event and init_event['created_at']:
                        start_time = init_event['created_at']
                        duration_ms = int((event_timestamp - start_time).total_seconds() * 1000)

            async with c.cursor() as cur:
                await cur.execute("SELECT noetl.snowflake_id() AS snowflake_id")
                _sf_row = await cur.fetchone()
                if not _sf_row:
                    raise RuntimeError("Failed to generate snowflake ID")
                event_id = int(_sf_row['snowflake_id'])
            
            status = event.payload.get("status") if event.payload else None
            if not status and "completed" in event.name:
                status = "COMPLETED"
            elif not status and "failed" in event.name:
                status = "FAILED"
            elif not status:
                status = "RUNNING"
            
            async with c.cursor() as cur:
                await cur.execute(
                    \"\"\"
                    INSERT INTO noetl.event (
                        event_id, execution_id, catalog_id, event_type, 
                        node_id, node_name, status, duration,
                        result, meta, error, worker_id, parent_event_id, parent_execution_id, created_at
                    ) VALUES (
                        %(event_id)s, %(execution_id)s, %(catalog_id)s, %(event_type)s,
                        %(node_id)s, %(node_name)s, %(status)s, %(duration)s,
                        %(result)s, %(meta)s, %(error)s, %(worker_id)s, %(parent_event_id)s, %(parent_execution_id)s, %(created_at)s
                    )
                    \"\"\",
                    {
                        "event_id": event_id,
                        "execution_id": int(event.execution_id),
                        "catalog_id": catalog_id,
                        "event_type": event.name,
                        "node_id": event.step,
                        "node_name": event.step,
                        "status": status,
                        "duration": duration_ms,
                        "result": Json(event.payload.get("result")) if event.payload and "result" in event.payload else None,
                        "meta": Json(event.meta) if event.meta else None,
                        "error": event.payload.get("error") if event.payload else None,
                        "worker_id": event.worker_id,
                        "parent_event_id": parent_event_id,
                        "parent_execution_id": state.parent_execution_id,
                        "created_at": event_timestamp
                    }
                )

            state.last_event_id = event_id
            if event.step:
                state.step_event_ids[event.step] = event_id

        if conn is None:
            async with get_pool_connection() as c:
                await _do_persist(c)
        else:
            await _do_persist(conn)
"""

content = re.sub(
    r'    async def _persist_event\(self, event: Event, state: ExecutionState, conn=None\):.*?state.step_event_ids\[event.step\] = event_id',
    new_persist_event,
    content,
    flags=re.DOTALL
)

with open("repos/noetl/noetl/core/dsl/v2/engine/lifecycle.py", "w") as f:
    f.write(content)

