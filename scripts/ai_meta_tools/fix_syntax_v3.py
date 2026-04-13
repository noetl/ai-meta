with open("noetl/worker/nats_worker.py", "r") as f:
    content = f.read()

# Remove the orphaned try:
content = content.replace("                try:\n                from noetl.core.dsl.render import _get_compiled_template", "                from noetl.core.dsl.render import _get_compiled_template")

with open("noetl/worker/nats_worker.py", "w") as f:
    f.write(content)
