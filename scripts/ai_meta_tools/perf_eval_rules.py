import time
from noetl.worker.task_sequence_executor import TaskSequenceExecutor
from noetl.core.dsl.render import render_template
from jinja2 import Environment

env = Environment()
def render_tmpl(tpl, ctx): return render_template(env, tpl, ctx)
def render_dct(dct, ctx): return render_template(env, dct, ctx)

async def dummy_tool(*args, **kwargs): return {"status": "ok"}
executor = TaskSequenceExecutor(dummy_tool, render_tmpl, render_dct)

huge_payload = {"data": [{"id": i, "value": "a" * 100} for i in range(5000)]}

output = {"status": "ok", "data": huge_payload}
render_ctx = {
    "output": output,
    "iter": {"page_data": huge_payload},
    "ctx": {}
}

rules = [
    {"when": "{{ output.status == 'error' and output.error.retryable }}", "then": {"do": "retry"}},
    {"when": "{{ output.status == 'error' }}", "then": {"do": "fail"}},
    {"else": {"then": {"do": "continue"}}}
]

t0 = time.time()
for _ in range(50):
    executor._evaluate_policy_rules(rules, render_ctx, output)
print(f"eval policy rules: {time.time() - t0:.3f}s")
