import re

with open("repos/noetl/noetl/core/dsl/v2/engine/lifecycle.py", "r") as f:
    content = f.read()

# Replace the nested connection block
replacement = """        if event.name == "step.exit" and event.step and not is_loop_iteration_exit:
            # Query for the corresponding step.enter event
            if conn is None:
                async with get_pool_connection() as duration_conn:
                    async with duration_conn.cursor() as cur:
                        await cur.execute("SELECT created_at FROM noetl.event WHERE execution_id = %s AND node_id = %s AND event_type = 'step.enter' ORDER BY event_id DESC LIMIT 1", (int(event.execution_id), event.step))
                        enter_event = await cur.fetchone()
                        if enter_event and enter_event['created_at']:
                            start_time = enter_event['created_at']
                            duration_ms = int((event_timestamp - start_time).total_seconds() * 1000)
            else:
                async with conn.cursor() as cur:
                    await cur.execute("SELECT created_at FROM noetl.event WHERE execution_id = %s AND node_id = %s AND event_type = 'step.enter' ORDER BY event_id DESC LIMIT 1", (int(event.execution_id), event.step))
                    enter_event = await cur.fetchone()
                    if enter_event and enter_event['created_at']:
                        start_time = enter_event['created_at']
                        duration_ms = int((event_timestamp - start_time).total_seconds() * 1000)"""

content = re.sub(
    r'        if event\.name == "step\.exit" and event\.step and not is_loop_iteration_exit:\n            # Query for the corresponding step\.enter event\n            async with get_pool_connection\(\) as conn:\n                async with conn\.cursor\(\) as cur:\n                    await cur\.execute\(\"\"\"\n                        SELECT created_at FROM noetl\.event \n                        WHERE execution_id = %s \n                          AND node_id = %s \n                          AND event_type = \'step\.enter\'\n                        ORDER BY event_id DESC\n                        LIMIT 1\n                    \"\"\", \(int\(event\.execution_id\), event\.step\)\)\n                    enter_event = await cur\.fetchone\(\)\n                    if enter_event and enter_event\[\'created_at\'\]:\n                        start_time = enter_event\[\'created_at\'\]\n                        duration_ms = int\(\(event_timestamp - start_time\)\.total_seconds\(\) \* 1000\)',
    replacement,
    content,
    flags=re.DOTALL
)

with open("repos/noetl/noetl/core/dsl/v2/engine/lifecycle.py", "w") as f:
    f.write(content)

