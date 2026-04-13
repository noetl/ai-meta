import re

with open("repos/noetl/noetl/core/dsl/v2/engine/lifecycle.py", "r") as f:
    content = f.read()

# Fix the INSERT query to include context and map payload correctly
new_insert = """                await cur.execute(
                    \"\"\"
                    INSERT INTO noetl.event (
                        event_id, execution_id, catalog_id, event_type, 
                        node_id, node_name, status, duration,
                        context, result, meta, error, worker_id, 
                        parent_event_id, parent_execution_id, created_at
                    ) VALUES (
                        %(event_id)s, %(execution_id)s, %(catalog_id)s, %(event_type)s,
                        %(node_id)s, %(node_name)s, %(status)s, %(duration)s,
                        %(context)s, %(result)s, %(meta)s, %(error)s, %(worker_id)s,
                        %(parent_event_id)s, %(parent_execution_id)s, %(created_at)s
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
                        "context": Json(event.payload) if event.payload else None,
                        "result": Json(event.payload.get("result")) if event.payload and isinstance(event.payload, dict) and "result" in event.payload else None,
                        "meta": Json(event.meta) if event.meta else None,
                        "error": event.payload.get("error") if event.payload and isinstance(event.payload, dict) else None,
                        "worker_id": event.worker_id,
                        "parent_event_id": parent_event_id,
                        "parent_execution_id": state.parent_execution_id,
                        "created_at": event_timestamp
                    }
                )"""

content = re.sub(
    r'await cur\.execute\(\n\s+\"\"\"\n\s+INSERT INTO noetl\.event \(.*?\) VALUES \(.*?\)\n\s+\"\"\",\n\s+\{.*?\}\n\s+\)',
    new_insert,
    content,
    flags=re.DOTALL
)

with open("repos/noetl/noetl/core/dsl/v2/engine/lifecycle.py", "w") as f:
    f.write(content)

