import time
from pydantic import BaseModel, Field
from typing import Any

class Event(BaseModel):
    payload: Any

huge_payload = {"data": [{"id": i, "value": "a" * 100} for i in range(10000)]}
event = Event(payload=huge_payload)

t0 = time.time()
for _ in range(50):
    event.model_dump_json(exclude_none=True)
print(f"pydantic model_dump_json: {time.time() - t0:.3f}s")
