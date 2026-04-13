import re

filepath = "repos/noetl/noetl/server/app.py"
with open(filepath, "r") as f:
    content = f.read()

# Fix 1: RuntimeLease constructor
content = content.replace(
    '            )            auto_resume_lease = RuntimeLease(',
    '            )\n            auto_resume_lease = RuntimeLease('
)

# Fix 2: break break
content = content.replace(
    'break                        break',
    'break'
)

# Fix 3: empty except block around line 320
pattern = r'(            except Exception as e:\n\n)(            try:\n                logger\.info\(\"Starting auto-resume)'
replacement = r'            except Exception as e:\n                logger.exception(f"Failed to start task: {e}")\n\n\2'
content = re.sub(pattern, replacement, content)

with open(filepath, "w") as f:
    f.write(content)
with open(filepath, "r") as f:
    content = f.read()

content = content.replace(
    'logger.exception(f"Critical error during sweeper task shutdown: {e}")            if auto_resume_task:',
    'logger.exception(f"Critical error during sweeper task shutdown: {e}")\n            if auto_resume_task:'
)

with open(filepath, "w") as f:
    f.write(content)
with open(filepath, "r") as f:
    content = f.read()

content = content.replace(
    'await runtime_sweeper_lease.release()                await auto_resume_lease.release()                deregister_server_directly(instance_name)',
    'await runtime_sweeper_lease.release()\n                await auto_resume_lease.release()\n                deregister_server_directly(instance_name)'
)

with open(filepath, "w") as f:
    f.write(content)
