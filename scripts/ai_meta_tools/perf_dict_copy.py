import time

huge_payload = {"data": [{"id": i, "value": "a" * 100} for i in range(1000)]}

base_context = {
    "iter": {"page_data": huge_payload},
    "ctx": {"target_id": 500},
    "something": [1,2,3] * 1000,
    "payload": huge_payload
}

t0 = time.time()
for _ in range(50000):
    render_ctx = base_context.copy()
    render_ctx.update({})
    render_ctx.update({})
    render_ctx["ctx"] = base_context["ctx"]
    render_ctx["iter"] = base_context["iter"]

print(f"dict copy and update: {time.time() - t0:.3f}s")
