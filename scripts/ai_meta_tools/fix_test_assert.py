import re

with open("repos/noetl/tests/unit/dsl/engine/test_engine.py", "r") as f:
    content = f.read()

# Fix mock for state_replay test
replacement = """            async def fetchone(self):
                if "noetl.execution" in self.query:
                    return None
                if "playbook.initialized" in self.query:
                    return {
                        "catalog_id": 101,
                        "context": {"workload": {}},
                        "result": None,
                    }
                raise AssertionError(f"Unexpected fetchone query: {self.query}")"""

content = re.sub(
    r'            async def fetchone\(self\):\n                if "playbook\.initialized" in self\.query:\n                    return \{\n                        "catalog_id": 101,\n                        "context": \{"workload": \{\}\},\n                        "result": None,\n                    \}\n                raise AssertionError\(f"Unexpected fetchone query: \{self\.query\}"\)',
    replacement,
    content
)

# And fix the 'exec-trans' issue
def _make_int_state(match):
    return match.group(0).replace('"exec-', '"1000')

content = re.sub(r'ExecutionState\(\s*execution_id="exec-[^"]+"', _make_int_state, content)

with open("repos/noetl/tests/unit/dsl/engine/test_engine.py", "w") as f:
    f.write(content)
