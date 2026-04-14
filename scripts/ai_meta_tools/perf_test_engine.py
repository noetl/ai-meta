import re
with open("repos/noetl/noetl/core/dsl/engine/executor/events.py", "r") as f:
    text = f.read()

# Add logging to measure time spent in handle_event
replacement = """    async def handle_event(self, event: Event, conn=None) -> list[Command]:
        import time
        t0 = time.time()
        try:
"""
text = text.replace("    async def handle_event(self, event: Event, conn=None) -> list[Command]:", replacement)

replacement2 = """        finally:
            logger.info(f"[PERF] Engine handle_event for {event.name} took {time.time() - t0:.3f}s")
"""
text = text.replace("        # Process side-effects and cleanup", replacement2 + "\n        # Process side-effects and cleanup")

with open("repos/noetl/noetl/core/dsl/engine/executor/events.py", "w") as f:
    f.write(text)
print("Updated events.py")
