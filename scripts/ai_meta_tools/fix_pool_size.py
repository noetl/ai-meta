import re

# Increase server pool size
with open("noetl/server/api/core/core.py", "r") as f:
    content = f.read()
content = content.replace('os.getenv("NOETL_POSTGRES_POOL_MAX_SIZE", "24")', 'os.getenv("NOETL_POSTGRES_POOL_MAX_SIZE", "64")')
with open("noetl/server/api/core/core.py", "w") as f:
    f.write(content)

# Increase worker semaphore
with open("noetl/worker/nats_worker.py", "r") as f:
    content = f.read()
content = content.replace('os.getenv("NOETL_WORKER_DB_SEMAPHORE", "16")', 'os.getenv("NOETL_WORKER_DB_SEMAPHORE", "32")')
with open("noetl/worker/nats_worker.py", "w") as f:
    f.write(content)
