# Claude ↔ Codex Bridge

A file-based message bus that lets Claude (running in Cowork mode) hand
work over to Codex (running on the same host), and Codex hand results
back. Both agents share the `ai-meta` filesystem; the bridge directory
is the protocol surface between them.

## Why this exists

Claude in Cowork mode runs in a sandboxed Linux VM with no network
access to the user's cluster, no `kubectl`, no `noetl` CLI, no GitHub
auth. To touch any of those, Claude has to print commands and wait for
the user to copy-paste them into a terminal.

Codex (or any local agent like it) runs on the user's actual machine
and has all those tools. The bridge turns the "Claude ↔ User ↔ Codex"
copy-paste loop into "Claude → file → Codex → file → Claude", with
the user only stepping in for explicit approvals.

## Layout

```
bridge/
  README.md                  ← this file
  .gitignore                 ← ignore inbox/outbox/archive contents
  inbox/                     ← Claude → Codex task files
  outbox/                    ← Codex → Claude result files
  archive/                   ← processed task+result pairs
  codex/
    watcher.sh               ← polls inbox/ + processes new tasks
    handle_task.sh           ← processes a single task file
    bridge_lib.sh            ← shared bash helpers
  examples/
    01_kubectl_get_pods.task.json    ← reference example
    02_noetl_exec.task.json
    03_approval_required.task.json
```

## Protocol (v1 — noetl-backed)

The bridge runs every task through `noetl exec --runtime local` by
default. The Rust CLI is the executor; no NATS, no postgres, no
server required. Bash-only fallback stays available for bootstrap
recovery (when noetl itself is broken).

### Filenames

Every task gets an `id`. The watcher scans `inbox/` for files
matching `*.task.{yaml,json}` and routes by extension + content.

- `inbox/{id}.task.yaml` — file IS a noetl playbook (Claude writes
  this for free-form tasks)
- `inbox/{id}.task.json` — JSON envelope referencing a registered
  playbook + workload, OR (legacy) a bare `commands` list
- `outbox/{id}.result.json` — bridge result, includes the noetl
  envelope verbatim plus bridge metadata (id, completed_at,
  approved_by, executor)
- `archive/{id}.task.{ext}` + `archive/{id}.result.json` — moved
  here after the result is written

### Task formats

The watcher recognizes four task shapes (auto-detected). All four
share the approval gate, denylist, and result envelope.

#### Shape 1 — Inline noetl playbook (`.task.yaml`)

The whole file IS a noetl playbook. Watcher does
`noetl exec --runtime local <file> --json`. Most flexible: Claude
can write any DSL the local runtime supports (kind:shell,
kind:python, kind:http, conditional `next.arcs`, etc.).

```yaml
# inbox/{id}.task.yaml
# bridge-approval: auto    ← optional opt-in to skip approval prompt

apiVersion: noetl.io/v2
kind: Playbook
metadata:
  name: my_task
  path: bridge/runtime/{id}
executor:
  profile: local
workload:
  namespace: noetl
workflow:
  - step: do_thing
    tool:
      kind: python
      code: |
        import subprocess
        proc = subprocess.run(["kubectl","-n",namespace,"get","pods"], capture_output=True, text=True)
        result = {"status": "ok", "data": {"stdout": proc.stdout}, "summary": "Listed pods"}
      args:
        namespace: "{{ workload.namespace }}"
    next:
      arcs: [{step: end}]
  - step: end
```

#### Shape 2 — Playbook reference + workload (`.task.json`)

JSON envelope pointing at a playbook by **file path** (resolved
locally without catalog registration) or **catalog reference**
(resolved by the noetl-server when running in distributed runtime).
Watcher does `noetl exec --runtime local <playbook> --payload <workload> --json`.

For local-runtime tasks, the file-path form is unambiguous and
needs zero setup:

```json
{
  "id": "20260505-001-bump-image",
  "title": "Bump components to v2.35.2",
  "approval": "required",
  "playbook": "repos/ops/automation/agents/noetl/lifecycle/bump_image.yaml",
  "workload": {
    "target_tag": "v2.35.2",
    "components": ["ollama-bridge"]
  }
}
```

The legacy field name `playbook_path` is also accepted as an alias
for `playbook`.

#### Shape 3 — Bare commands list (`.task.json`, legacy)

JSON with a top-level `commands` array. Watcher wraps it through
the generic `repos/ops/automation/agents/bridge/run_commands.yaml`
playbook (file path; no registration needed).

```json
{
  "id": "20260505-002-list-pods",
  "title": "List pods",
  "approval": "auto",
  "commands": [
    { "id": "list", "shell": "kubectl -n noetl get pods" }
  ]
}
```

#### Shape 4 — Bash bootstrap (`.task.json` with `executor: "bash"`)

Same as Shape 3 but explicitly skips noetl. Used only when noetl
itself is broken and you need to fix it via the bridge. Identical
output envelope (so Claude doesn't have to special-case bash mode).

```json
{
  "id": "20260505-003-rescue",
  "title": "Restart noetl-server (bootstrap recovery)",
  "executor": "bash",
  "approval": "required",
  "commands": [
    { "id": "restart", "shell": "kubectl -n noetl rollout restart deploy/noetl-server" }
  ]
}
```

### Task file (Claude → Codex) — full Shape 2 example

```json
{
  "id": "20260505-015100-bump-bridge-v2-35-2",
  "from": "claude-cowork",
  "to": "codex",
  "created_at": "2026-05-05T01:51:00Z",
  "title": "Bump ollama-bridge image to v2.35.2 + verify",

  "description": "Apply the FastAPI route fix (noetl#410) to the running cluster by bumping the bridge to v2.35.2, wait for rollout, then exercise /jsonrpc to confirm the 422 is gone.",

  "approval": "required",

  "timeout_seconds": 600,

  "commands": [
    {
      "id": "set-image",
      "shell": "kubectl -n noetl set image deploy/ollama-bridge ollama-bridge=ghcr.io/noetl/noetl:v2.35.2",
      "capture_stdout": true,
      "capture_stderr": true
    },
    {
      "id": "wait-rollout",
      "shell": "kubectl -n noetl rollout status deploy/ollama-bridge --timeout=120s",
      "capture_stdout": true,
      "capture_stderr": true
    },
    {
      "id": "verify-jsonrpc",
      "shell": "kubectl -n noetl exec deploy/ollama-bridge -- python3 -c \"import json,urllib.request; req=urllib.request.Request('http://localhost:8765/jsonrpc', data=json.dumps({'jsonrpc':'2.0','id':1,'method':'tools/list'}).encode(), headers={'Content-Type':'application/json'}, method='POST'); print(urllib.request.urlopen(req, timeout=10).read().decode())\"",
      "capture_stdout": true,
      "capture_stderr": true
    }
  ]
}
```

### Result file (Codex → Claude)

For noetl-backed executors (Shapes 1, 2, 3), the noetl envelope
is wrapped with bridge metadata:

```json
{
  "id": "20260505-001-bump-bridge",
  "from": "codex",
  "to": "claude-cowork",
  "completed_at": "2026-05-05T01:54:18Z",
  "approval_status": "approved",
  "approved_by": "kadyapam",
  "overall_status": "ok",
  "executor": "noetl-local",
  "envelope": {
    "status": "ok",
    "data": {
      "results": [
        { "step_id": "set-image",     "exit_code": 0, "stdout": "...", "stderr": "" },
        { "step_id": "wait-rollout",  "exit_code": 0, "stdout": "...", "stderr": "" },
        { "step_id": "verify-jsonrpc","exit_code": 0, "stdout": "...", "stderr": "" }
      ],
      "command_count": 3,
      "stopped_on_error": false
    },
    "summary": "Ran 3 command(s) successfully",
    "text": "Ran 3 command(s) successfully"
  }
}
```

For Shape 4 (bash bootstrap), the structure is flat (no `envelope`
wrapper) — `results` is at the top level. Either way, Claude can
walk to per-step results uniformly:

```python
# Claude-side parsing helper
result = json.load(open("outbox/{id}.result.json"))
if "envelope" in result:
    steps = result["envelope"].get("data", {}).get("results", [])
else:
    steps = result.get("results", [])
```

### Approval semantics

- **`"approval": "required"`** — Codex pauses and prints the task to
  the user's terminal; the user must type `y` (or whatever the
  watcher's prompt expects). User can edit the commands inline or
  reject. Approval status + approver land in the result file.
- **`"approval": "auto"`** — Codex runs immediately. Use this only
  for read-only commands (kubectl get, jq, etc.) or for tasks the
  user has explicitly pre-approved a category of.
- **`"approval": "denied"`** — Codex skips the task and writes a
  result file with `overall_status: "denied"`.

The watcher's policy is configurable; default is "every task with
`approval: required` waits for explicit y/n at the terminal."

### Execution semantics

- Each command runs sequentially. If a command exits non-zero, the
  watcher stops there and writes the result file with
  `overall_status: "failed"`.
- `timeout_seconds` on the task applies to the *whole* command list
  (sum of all command durations + waits). Per-command timeouts can
  be added in v1.
- `capture_stdout` / `capture_stderr` default to `true`. Set to
  `false` when stdout would be huge (e.g., `kubectl logs`) — the
  watcher writes a separate `outbox/{id}.transcript.log` instead.

### Polling cadence

The watcher polls `inbox/` every 1 second by default. New `.task.json`
files are processed in mtime order (oldest first). Files whose `id`
already has a matching `outbox/{id}.result.json` are skipped (so a
restart doesn't re-execute completed work).

## How to run the watcher (Codex side)

In a long-lived shell on the user's host:

```bash
cd /Volumes/X10/projects/noetl/ai-meta
./bridge/codex/watcher.sh
```

Or to bind it to a specific Codex session, the user can wrap it:

```bash
codex exec --watch bridge/inbox/ ./bridge/codex/handle_task.sh
```

(The watcher script is plain bash + jq; nothing Codex-specific. Any
local agent that wants to fulfill the contract can run it.)

## How to write a task (Claude side)

Claude writes a single JSON file to `bridge/inbox/`:

```bash
cat > bridge/inbox/$(date -u +%Y%m%d-%H%M%S)-<slug>.task.json <<'EOF'
{ ... }
EOF
```

Then prints to chat: "I've queued task `<id>`. Check `bridge/outbox/<id>.result.json`
when it's done."

The user runs the watcher in a terminal; Codex picks up the task, asks
for approval if needed, executes, writes the result. Claude reads the
result and continues.

## Safety

The bridge inherits the user's terminal's permissions — Codex runs as
the user, so anything the user could do via copy-paste, Codex can do
via the bridge. The approval gate is the primary safety mechanism:

- **Default**: every task requires explicit user approval at the
  terminal. The watcher prints the commands and waits for `y/n`.
- **`approval: "auto"` is opt-in per task** and should be used only
  for clearly-bounded read-only commands.
- **The watcher prints the full command list before asking for
  approval** so the user can spot anything suspicious before saying
  yes.

What the bridge will *not* do without explicit user opt-in:
- `git push` or any operation that publishes outside the local repo
- `kubectl delete` of namespace / cluster-scoped resources
- `helm uninstall` of a release
- Any `rm -rf` outside `/tmp` or the bridge archive

(These restrictions are enforced by a denylist in `handle_task.sh`;
see that script for the regex patterns.)

## Versioning

This document is v0. Future versions will be tagged in
`bridge/PROTOCOL_VERSION` so producers + consumers can negotiate.
Current consumers (Claude, Codex) should accept and ignore unknown
top-level fields for forward-compat.
