import asyncio
import time
from noetl.worker.task_sequence_executor import TaskSequenceExecutor
from noetl.core.dsl.render import render_template
from jinja2 import Environment

env = Environment()
def render_tmpl(tpl, ctx): return render_template(env, tpl, ctx)
def render_dct(dct, ctx): return render_template(env, dct, ctx)

async def dummy_tool(kind, config, ctx):
    return {"status": "ok", "data": {"id": 123}}

executor = TaskSequenceExecutor(dummy_tool, render_tmpl, render_dct)

huge_payload = {"data": [{"id": i, "value": "a" * 50} for i in range(1000)]}

tasks = [
    {
        "name": "fetch",
        "kind": "http",
        "url": "http://api/{{ ctx.target_id }}",
        "json": {"items": "{{ iter.page_data.data | map(attribute='id') | list }}"},
        "spec": {
            "policy": {
                "rules": [
                    {"when": "{{ output.status == 'error' }}", "then": {"do": "fail"}},
                    {"else": {"then": {"do": "continue", "set": {"ctx.fetched": True}}}}
                ]
            }
        }
    },
    {
        "name": "transform",
        "kind": "python",
        "code": "result = _prev",
        "spec": {
            "policy": {
                "rules": [
                    {"when": "{{ output.status == 'error' }}", "then": {"do": "fail"}},
                    {"else": {"then": {"do": "continue"}}}
                ]
            }
        }
    }
]

base_context = {
    "iter": {"page_data": huge_payload},
    "ctx": {"target_id": 500},
}

async def run():
    t0 = time.time()
    for _ in range(50):
        await executor.execute(tasks, base_context)
    print(f"executor deep payload 50 iterations: {time.time() - t0:.3f}s")

asyncio.run(run())
