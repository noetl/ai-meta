with open("noetl/server/api/core/batch.py", "r") as f:
    content = f.read()

# Fix the broken line in batch.py
broken = "await _publish_commands_with_recovery(publish_items, server_url=server_url) for exec_id, step, cid, evt_id in publish_items], server_url=server_url)"
fixed = "await _publish_commands_with_recovery(publish_items, server_url=server_url)"

content = content.replace(broken, fixed)

with open("noetl/server/api/core/batch.py", "w") as f:
    f.write(content)
