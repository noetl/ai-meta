import re

with open("repos/noetl/noetl/core/dsl/v2/engine/lifecycle.py", "r") as f:
    content = f.read()

content = content.replace(
    'async def _persist_event(self, event: Event, state: ExecutionState):',
    'async def _persist_event(self, event: Event, state: ExecutionState, conn=None):'
)

# Fix the two blocks in _persist_event that do async with get_pool_connection
content = re.sub(
    r'        if not catalog_id:\n            # Fallback: lookup from existing events\n            async with get_pool_connection\(\) as conn:\n                async with conn.cursor\(\) as cur:',
    '        if not catalog_id:\n            if conn is None:\n                async with get_pool_connection() as c:\n                    async with c.cursor() as cur:\n                        await cur.execute("SELECT catalog_id FROM noetl.event WHERE execution_id = %s LIMIT 1", (int(event.execution_id),))\n                        result = await cur.fetchone()\n                        catalog_id = result[\'catalog_id\'] if result else None\n            else:\n                async with conn.cursor() as cur:\n                    await cur.execute("SELECT catalog_id FROM noetl.event WHERE execution_id = %s LIMIT 1", (int(event.execution_id),))\n                    result = await cur.fetchone()\n                    catalog_id = result[\'catalog_id\'] if result else None',
    content,
    flags=re.DOTALL
)

# Clean up the old execute block that was replaced
content = re.sub(
    r'                        await cur.execute\(\"\"\"\n                        SELECT catalog_id FROM noetl.event \n                        WHERE execution_id = %s \n                        LIMIT 1\n                    \"\"\", \(int\(event.execution_id\),\)\)\n                    result = await cur.fetchone\(\)\n                    catalog_id = result\[\'catalog_id\'\] if result else None',
    '',
    content,
    flags=re.DOTALL
)

# Fix the second block
replacement = """
        if conn is None:
            async with get_pool_connection() as c:
                async with c.cursor() as cur:
                    await cur.execute(
                        \"\"\"
                        INSERT INTO noetl.event (
                            execution_id, catalog_id, event_type, 
                            node_id, node_name, status,
                            result, meta, error, worker_id
                        ) VALUES (
                            %(execution_id)s, %(catalog_id)s, %(event_type)s,
                            %(node_id)s, %(node_name)s, %(status)s,
                            %(result)s, %(meta)s, %(error)s, %(worker_id)s
                        )
                        \"\"\",
                        {
                            "execution_id": int(event.execution_id),
                            "catalog_id": catalog_id,
                            "event_type": event.name,
                            "node_id": event.step,
                            "node_name": event.step,
                            "status": status,
                            "result": Json(event.payload.get("result")) if event.payload and "result" in event.payload else None,
                            "meta": Json(event.meta) if event.meta else None,
                            "error": event.payload.get("error") if event.payload else None,
                            "worker_id": event.worker_id
                        }
                    )
        else:
            async with conn.cursor() as cur:
                await cur.execute(
                    \"\"\"
                    INSERT INTO noetl.event (
                        execution_id, catalog_id, event_type, 
                        node_id, node_name, status,
                        result, meta, error, worker_id
                    ) VALUES (
                        %(execution_id)s, %(catalog_id)s, %(event_type)s,
                        %(node_id)s, %(node_name)s, %(status)s,
                        %(result)s, %(meta)s, %(error)s, %(worker_id)s
                    )
                    \"\"\",
                    {
                        "execution_id": int(event.execution_id),
                        "catalog_id": catalog_id,
                        "event_type": event.name,
                        "node_id": event.step,
                        "node_name": event.step,
                        "status": status,
                        "result": Json(event.payload.get("result")) if event.payload and "result" in event.payload else None,
                        "meta": Json(event.meta) if event.meta else None,
                        "error": event.payload.get("error") if event.payload else None,
                        "worker_id": event.worker_id
                    }
                )
"""

content = re.sub(
    r'        async with get_pool_connection\(\) as conn:\n            async with conn.cursor\(\) as cur:\n                await cur.execute\(\n                    \"\"\"\n                    INSERT INTO noetl.event.*?\"worker_id\": event.worker_id\n                    \}\n                \)',
    replacement.strip(),
    content,
    flags=re.DOTALL
)

with open("repos/noetl/noetl/core/dsl/v2/engine/lifecycle.py", "w") as f:
    f.write(content)

