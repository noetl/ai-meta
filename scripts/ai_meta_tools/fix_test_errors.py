import re

with open("repos/noetl/tests/unit/dsl/engine/test_engine.py", "r") as f:
    content = f.read()

# Fix mock for state save error 'invalid literal for int' -> test uses string IDs like 'exec-trans'
content = content.replace("monkeypatch.setattr(state_store, \"save_state\", mock_save)", "monkeypatch.setattr(StateStore, \"save_state\", mock_save)")
content = content.replace("monkeypatch.setattr(state_store, \"load_state\", mock_load)", "monkeypatch.setattr(StateStore, \"load_state\", mock_load)")
content = content.replace("monkeypatch.setattr(state_store, \"load_state_for_update\", mock_load_update)", "monkeypatch.setattr(StateStore, \"load_state_for_update\", mock_load_update)")

# Or just redefine ExecutionState to mock the int conversion for these tests
with open("repos/noetl/tests/unit/dsl/engine/test_engine.py", "w") as f:
    f.write(content)

