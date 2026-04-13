import re

# Replicate the regex and sanitization logic from PR #372
_NATS_KEY_INVALID_RE = re.compile(r"[^-/_=.a-zA-Z0-9]")

def sanitize_key_nats_kv(execution_id: str, key_type: str) -> str:
    # Replace colons with dots (primary separator conversion), then
    # replace any remaining invalid character with '_'.
    safe_exec_id = _NATS_KEY_INVALID_RE.sub("_", str(execution_id).replace(":", "."))
    safe_key_type = _NATS_KEY_INVALID_RE.sub("_", str(key_type).replace(":", "."))
    # Strip leading/trailing dots so the composite key is always valid.
    safe_exec_id = safe_exec_id.strip(".")
    safe_key_type = safe_key_type.strip(".")
    return f"exec.{safe_exec_id}.{safe_key_type}"

def sanitize_session_token(token: str) -> str:
    KEY_PREFIX = "session."
    safe_token = _NATS_KEY_INVALID_RE.sub("_", str(token))
    return f"{KEY_PREFIX}{safe_token}"

# Test cases
test_cases = [
    ("exec:123", "loop:step:event", "exec.exec.123.loop.step.event"),
    ("exec/456", "some@invalid#key", "exec.exec/456.some_invalid_key"),
    (".leading.dot.", ".trailing.dot.", "exec.leading.dot.trailing.dot"),
    ("spaced id", "special!chars", "exec.spaced_id.special_chars"),
    ("valid-id_123", "valid.type", "exec.valid-id_123.valid.type"),
]

print("Validating NATS KV Key Sanitization:")
for eid, ktype, expected in test_cases:
    result = sanitize_key_nats_kv(eid, ktype)
    print(f"ID: '{eid}', Type: '{ktype}' -> result: '{result}'")
    assert result == expected, f"Expected {expected}, got {result}"

session_test_cases = [
    ("token:with:colons", "session.token_with_colons"),
    ("token/with/slashes", "session.token/with/slashes"),
    ("token@with#special!", "session.token_with_special_"),
]

print("\nValidating Session Token Sanitization:")
for token, expected in session_test_cases:
    result = sanitize_session_token(token)
    print(f"Token: '{token}' -> result: '{result}'")
    assert result == expected, f"Expected {expected}, got {result}"

print("\nAll tests passed!")
