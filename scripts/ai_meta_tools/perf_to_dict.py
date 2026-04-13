import time
from dataclasses import dataclass, field

@dataclass
class TaskSequenceContext:
    _task: str = ""
    _prev: str = None
    _attempt: int = 1
    output: dict = None
    results: dict = field(default_factory=dict)
    ctx: dict = field(default_factory=dict)
    iter: dict = field(default_factory=dict)

    def to_dict(self) -> dict:
        output_view = {}
        if isinstance(self.output, dict):
            output_view = {
                "status": self.output.get("status", "ok"),
                "data": self.output.get("data"),
                "ref": self.output.get("ref"),
                "error": self.output.get("error"),
            }
            for k in ("http", "pg", "py", "meta"):
                if k in self.output:
                    output_view[k] = self.output[k]
        return {
            "_task": self._task,
            "_prev": self._prev,
            "_attempt": self._attempt,
            "output": output_view,
            "results": self.results,
            "ctx": self.ctx,
            "iter": self.iter,
        }

ctx = TaskSequenceContext()
huge_payload = {"data": [{"id": i, "value": "a" * 100} for i in range(1000)]}
ctx.results = {"step1": huge_payload}
ctx.output = {"status": "ok", "data": huge_payload, "http": {"status": 200}}

t0 = time.time()
for _ in range(50000):
    ctx.to_dict()

print(f"to_dict overhead: {time.time() - t0:.3f}s")
