import re

with open("repos/noetl/noetl/core/dsl/engine/executor/common.py", "r") as f:
    text = f.read()

new_func = """def _loop_results_total(loop_state: dict[str, Any]) -> int:
    \"\"\"Return authoritative local loop completion count.\"\"\"
    return loop_state.get("completed_count", 0) + loop_state.get("omitted_results_count", 0)
"""

text = re.sub(r'def _loop_results_total.*?return len\(buffered_results\) \+ max\(0, omitted\)\n', new_func, text, flags=re.DOTALL)

with open("repos/noetl/noetl/core/dsl/engine/executor/common.py", "w") as f:
    f.write(text)
print("Updated common.py")
