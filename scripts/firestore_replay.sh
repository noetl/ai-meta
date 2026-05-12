#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  firestore_replay.sh events <thread_path> [--from N] [--to N] [--type-filter type1,type2]
  firestore_replay.sh thread-list [--limit N]
  firestore_replay.sh doc <doc_path>

Environment:
  FIRESTORE_PROJECT    GCP project id (default: noetl-demo-19700101)
  FIRESTORE_DATABASE   Firestore database id (default: (default))
USAGE
}

PROJECT="${FIRESTORE_PROJECT:-noetl-demo-19700101}"
DATABASE="${FIRESTORE_DATABASE:-(default)}"
MODE="${1:-}"
shift || true

if [[ -z "${MODE}" || "${MODE}" == "-h" || "${MODE}" == "--help" ]]; then
  usage
  exit 0
fi

TOKEN="$(gcloud auth print-access-token)"
export FIRESTORE_PROJECT_VALUE="${PROJECT}"
export FIRESTORE_DATABASE_VALUE="${DATABASE}"
export FIRESTORE_ACCESS_TOKEN="${TOKEN}"

python3 - "$MODE" "$@" <<'PY'
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

mode = sys.argv[1]
args = sys.argv[2:]
project = os.environ["FIRESTORE_PROJECT_VALUE"]
database = os.environ["FIRESTORE_DATABASE_VALUE"]
token = os.environ["FIRESTORE_ACCESS_TOKEN"]
root = f"https://firestore.googleapis.com/v1/projects/{project}/databases/{urllib.parse.quote(database, safe='()')}/documents"


def die(message, code=2):
    print(message, file=sys.stderr)
    sys.exit(code)


def request(method, url, payload=None):
    headers = {"Authorization": f"Bearer {token}", "Accept": "application/json"}
    body = None
    if payload is not None:
        headers["Content-Type"] = "application/json"
        body = json.dumps(payload, separators=(",", ":")).encode()
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read().decode()
            return resp.status, json.loads(raw or "{}")
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode(errors="replace")
        try:
            parsed = json.loads(raw or "{}")
        except Exception:
            parsed = {"raw": raw[:2000]}
        return exc.code, parsed


def decode_value(value):
    if not isinstance(value, dict):
        return value
    if "nullValue" in value:
        return None
    if "booleanValue" in value:
        return bool(value["booleanValue"])
    if "integerValue" in value:
        return int(value["integerValue"])
    if "doubleValue" in value:
        return float(value["doubleValue"])
    if "stringValue" in value:
        return value["stringValue"]
    if "timestampValue" in value:
        return value["timestampValue"]
    if "referenceValue" in value:
        return value["referenceValue"]
    if "geoPointValue" in value:
        return value["geoPointValue"]
    if "arrayValue" in value:
        return [decode_value(item) for item in value.get("arrayValue", {}).get("values", [])]
    if "mapValue" in value:
        return {key: decode_value(item) for key, item in value.get("mapValue", {}).get("fields", {}).items()}
    return value


def doc_to_plain(doc):
    fields = doc.get("fields", {}) if isinstance(doc, dict) else {}
    path = str(doc.get("name", "")).split("/documents/", 1)[-1]
    return {
        "path": path,
        "createTime": doc.get("createTime"),
        "updateTime": doc.get("updateTime"),
        "data": {key: decode_value(value) for key, value in fields.items()},
    }


def parse_options(items):
    options = {}
    i = 0
    while i < len(items):
        item = items[i]
        if item.startswith("--"):
            if i + 1 >= len(items):
                die(f"missing value for {item}")
            options[item[2:]] = items[i + 1]
            i += 2
        else:
            options.setdefault("_pos", []).append(item)
            i += 1
    return options


def collection_parent(collection_path):
    parts = [part for part in collection_path.strip("/").split("/") if part]
    if not parts or len(parts) % 2 == 0:
        die("collection path must identify a collection")
    collection_id = parts[-1]
    parent_doc = "/".join(parts[:-1])
    parent = root
    if parent_doc:
        parent += "/" + urllib.parse.quote(parent_doc, safe="/")
    return parent, collection_id


def run_query(collection_path, query):
    parent, collection_id = collection_parent(collection_path)
    query.setdefault("from", [{"collectionId": collection_id}])
    status, payload = request("POST", parent + ":runQuery", {"structuredQuery": query})
    if status >= 400:
        die(json.dumps(payload, indent=2), status)
    return [doc_to_plain(row["document"]) for row in payload if isinstance(row, dict) and isinstance(row.get("document"), dict)]


if mode == "doc":
    if len(args) != 1:
        die("doc requires <doc_path>")
    status, payload = request("GET", root + "/" + urllib.parse.quote(args[0].strip("/"), safe="/"))
    if status == 404:
        print(json.dumps({"found": False, "path": args[0]}, indent=2, sort_keys=True))
    elif status >= 400:
        die(json.dumps(payload, indent=2), status)
    else:
        print(json.dumps({"found": True, "document": doc_to_plain(payload)}, indent=2, sort_keys=True))
elif mode == "events":
    opts = parse_options(args)
    pos = opts.get("_pos", [])
    if len(pos) != 1:
        die("events requires <thread_path>")
    seq_from = int(opts.get("from", 0))
    seq_to = opts.get("to")
    type_filter = [item for item in opts.get("type-filter", "").split(",") if item]
    filters = [{"fieldFilter": {"field": {"fieldPath": "seq"}, "op": "GREATER_THAN_OR_EQUAL", "value": {"integerValue": str(seq_from)}}}]
    query = {
        "where": filters[0],
        "orderBy": [{"field": {"fieldPath": "seq"}, "direction": "ASCENDING"}],
        "limit": 500,
    }
    docs = run_query(f"{pos[0].strip('/')}/events", query)
    events = []
    for doc in docs:
        data = doc.get("data", {})
        if seq_to is not None and int(data.get("seq", 0)) > int(seq_to):
            continue
        if type_filter and data.get("type") not in type_filter:
            continue
        events.append({"path": doc["path"], **data})
    print(json.dumps({"thread_path": pos[0], "count": len(events), "events": events}, indent=2, sort_keys=True))
elif mode == "thread-list":
    opts = parse_options(args)
    limit = int(opts.get("limit", 50))
    docs = run_query("chat_threads", {"limit": max(1, min(limit, 500))})
    print(json.dumps({"count": len(docs), "threads": docs}, indent=2, sort_keys=True))
else:
    die(f"unknown mode: {mode}")
PY
