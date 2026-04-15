import json

def _estimate_json_size(obj): return len(json.dumps(obj))
_EVENT_RESULT_CONTEXT_MAX_BYTES = 10240

def _bounded_context(context_obj):
    if not isinstance(context_obj, dict): return None
    if _estimate_json_size(context_obj) > _EVENT_RESULT_CONTEXT_MAX_BYTES: return None
    return context_obj

def _collect_compact_context(payload):
    keys = ("command_id", "loop_event_id", "request_id", "event_ids", "commands_generated", "error_code", "message", "worker_id", "batch_request_id")
    compact = {k: payload[k] for k in keys if k in payload and payload[k] is not None}
    return compact or None

def _normalize_result_status(status):
    return status.upper() if status else "UNKNOWN"

def _build_reference_only_result(*, payload, status):
    result_obj = {"status": _normalize_result_status(status)}
    payload_result = payload.get("result") or payload.get("response")
    if isinstance(payload_result, dict):
        payload_status = payload_result.get("status")
        if isinstance(payload_status, str) and payload_status.strip():
            result_obj["status"] = _normalize_result_status(payload_status)
        if isinstance(payload_result.get("reference"), dict):
            result_obj["reference"] = payload_result.get("reference")
        context = _bounded_context(payload_result.get('context') or payload_result)
        if isinstance(context, dict): result_obj["context"] = context
    else:
        if isinstance(payload.get("reference"), dict):
            result_obj["reference"] = payload.get("reference")
        direct_context = _bounded_context(payload.get('context') or payload.get('response') or payload)
        if isinstance(direct_context, dict): result_obj["context"] = direct_context
        
    compact = _collect_compact_context(payload)
    if compact:
        existing_context = result_obj.get("context")
        if isinstance(existing_context, dict):
            merged = {**compact, **existing_context}
            if _estimate_json_size(merged) <= _EVENT_RESULT_CONTEXT_MAX_BYTES:
                result_obj["context"] = merged
        else:
            if _estimate_json_size(compact) <= _EVENT_RESULT_CONTEXT_MAX_BYTES:
                result_obj["context"] = compact
    return result_obj

# The payload the worker logged
payload = {
    "response": {
        "status": "success",
        "command_0": {
            "status": "success", 
            "rows": [{"facility_mapping_id": 1, "facility_name": "Test Facility 1", "facility_id": 1, "facility_org_uuid": "org-1"}], 
            "row_count": 1, 
            "columns": ["facility_mapping_id", "facility_name", "facility_id", "facility_org_uuid"]
        },
        "statement_count": 1
    },
    "command_id": "605158114882486723:load_next_facility:605158130032312789",
    "case_handled": True
}

print(json.dumps(_build_reference_only_result(payload=payload, status="COMPLETED"), indent=2))
