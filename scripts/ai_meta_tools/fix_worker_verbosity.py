import re

with open("noetl/worker/nats_worker.py", "r") as f:
    content = f.read()

# Change LoggingContext to not include the full notification in every log entry
old_ctx = 'with LoggingContext(logger, notification=notification, execution_id=notification.get("execution_id")):'
new_ctx = 'with LoggingContext(logger, execution_id=notification.get("execution_id"), command_id=notification.get("command_id")):'

content = content.replace(old_ctx, new_ctx)

with open("noetl/worker/nats_worker.py", "w") as f:
    f.write(content)
