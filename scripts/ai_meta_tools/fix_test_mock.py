with open("repos/noetl/tests/unit/dsl/v2/test_engine.py", "r") as f:
    lines = f.readlines()

new_lines = []
mock_lines = []
for line in lines:
    if line.startswith("@pytest.fixture"):
        if "def mock_state_store_db" in "".join(lines):
            pass # already there
    new_lines.append(line)

with open("repos/noetl/tests/unit/dsl/v2/test_engine.py", "w") as f:
    f.writelines(lines[12:]) # remove my manual insert

import re
with open("repos/noetl/tests/unit/dsl/v2/test_engine.py", "r") as f:
    content = f.read()

# Find the engine_setup fixture
pattern = r'(@pytest.fixture\nasync def engine_setup\(\).*?return engine, playbook_repo, state_store)'

replacement = """@pytest.fixture
async def engine_setup(monkeypatch):
    playbook_repo = PlaybookRepo()
    state_store = StateStore(playbook_repo)
    
    # Mock Postgres for tests
    _test_states = {}
    async def mock_save(state, conn=None):
        _test_states[state.execution_id] = state
    async def mock_load(exec_id):
        return _test_states.get(exec_id)
    async def mock_load_update(exec_id, conn=None):
        return _test_states.get(exec_id)
        
    monkeypatch.setattr(state_store, "save_state", mock_save)
    monkeypatch.setattr(state_store, "load_state", mock_load)
    monkeypatch.setattr(state_store, "load_state_for_update", mock_load_update)
    
    engine = ControlFlowEngine(playbook_repo, state_store)
    
    # Mock pool connection for tests that call engine.handle_event
    from contextlib import asynccontextmanager
    @asynccontextmanager
    async def mock_conn():
        class MockConn:
            @asynccontextmanager
            async def transaction(self):
                yield self
            @asynccontextmanager
            async def cursor(self, *args, **kwargs):
                class MockCur:
                    async def execute(self, *args, **kwargs): pass
                    async def fetchone(self): return None
                yield MockCur()
        yield MockConn()
    monkeypatch.setattr("noetl.core.dsl.v2.engine.events.get_pool_connection", mock_conn)
    
    return engine, playbook_repo, state_store
"""

content = re.sub(pattern, replacement, content, flags=re.DOTALL)

with open("repos/noetl/tests/unit/dsl/v2/test_engine.py", "w") as f:
    f.write(content)

