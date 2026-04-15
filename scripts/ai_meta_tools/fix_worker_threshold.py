import re

path = "repos/noetl/noetl/worker/nats_worker.py"
with open(path, "r") as f:
    text = f.read()

# Change the hardcoded 0 to 16KB for event payload inlining
old_line = '                event_output_config["inline_max_bytes"] = 0'
new_line = '                # Allow small results (e.g. claim rows) inline for engine transitions\n                event_output_config["inline_max_bytes"] = 16384'
text = text.replace(old_line, new_line)

with open(path, "w") as f:
    f.write(text)
print("Successfully patched nats_worker.py")
