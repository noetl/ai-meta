# Tutorial: Claude ↔ Codex Bridge via noetl Local Playbooks

A walkthrough of the file-based agent bridge that lets Claude (running
in Cowork mode, locked to a sandbox) hand work over to Codex (running
on your host with full kubectl / noetl / git access). The bridge
uses noetl's local Rust runtime as the execution backend — no
NATS, no postgres, no server required.

## Why this exists

When Claude operates in Cowork mode, it can:

- Read and write files in `/Volumes/X10/projects/noetl/ai-meta` (and
  any folder you've mounted)
- Run shell commands inside its own Linux sandbox (no network egress
  beyond `claude.com` / `api.anthropic.com`, no kubectl, no cluster
  access)

What it cannot do:

- Reach your kind cluster, your noetl-server, your GitHub auth
- Run `noetl exec` or `kubectl` (binaries aren't in the sandbox; even
  if they were, they couldn't reach the cluster)
- Push to git (no auth context)

For everything in that second list, Claude has had to print commands
and wait for you to copy-paste them into a terminal. That's slow and
brittle.

The bridge solves this by turning the loop into:

```
Claude → file → Codex → file → Claude
```

…with the only manual step being approval-at-the-terminal for tasks
that mutate cluster state.

## Architecture

```
ai-meta/bridge/
  inbox/          ← Claude writes task files here
  outbox/         ← Codex writes result files here
  archive/        ← processed task+result pairs land here
  codex/
    watcher.sh    ← polls inbox/, dispatches each task
    handle_task.sh ← per-task dispatcher (noetl-local default)
    handle_task_bash.sh ← bash-only fallback (bootstrap recovery)
    bridge_lib.sh ← shared helpers: approval prompt, denylist

repos/ops/automation/agents/bridge/
  run_commands.yaml ← generic noetl playbook used as the executor for
                      bare-commands tasks
```

The watcher is the only long-running process. You start it once in a
terminal and leave it running. Claude writes tasks; the watcher picks
them up; Codex (or the user, depending on the approval mode) green-
lights each task; the watcher invokes `noetl exec --runtime local`;
the result lands in outbox/.

## Setup (once per machine)

```bash
# 1. The bridge directory ships in ai-meta. Pull it down.
cd /Volumes/X10/projects/noetl/ai-meta
git pull --recurse-submodules    # also pulls repos/ops which ships the run_commands playbook

# 2. Make the watcher scripts executable (one-time after fresh clone)
chmod +x bridge/codex/*.sh

# 3. Verify prerequisites
which noetl jq kubectl   # all three should resolve
noetl --version          # should report v2.35.2 or newer (FastAPI route fix)
```

That's it. **No catalog registration needed for local-runtime tasks** —
the noetl Rust CLI parses YAML files directly and runs them in
memory. Both Shape 1 (inline playbook in inbox) and Shape 2 (file
path reference in JSON envelope) resolve via the filesystem.

Catalog registration becomes relevant only when you switch the
bridge to distributed-runtime mode (a follow-up; same task files,
just `--runtime distributed` and the playbook needs to be in the
catalog so the noetl-server can dispatch it to a worker pod).

## Run the watcher (terminal A)

In one terminal, leave this running:

```bash
cd /Volumes/X10/projects/noetl/ai-meta
./bridge/codex/watcher.sh
```

You'll see:

```
[2026-05-05T...Z] WATCHER STARTED: inbox=.../bridge/inbox interval=1s once=false
[2026-05-05T...Z]   user=kadyapam
[2026-05-05T...Z]   jq: /opt/homebrew/bin/jq
[2026-05-05T...Z]   kubectl: /usr/local/bin/kubectl
[2026-05-05T...Z]   noetl: /usr/local/bin/noetl
```

The watcher polls `bridge/inbox/` every second. When Claude drops a
new task file, you'll see the approval prompt here.

## First demo — read-only smoke test (auto-approval)

In another terminal (or via Claude writing the file), drop a task:

```bash
cp bridge/examples/04_noetl_local_get_pods.task.yaml \
   bridge/inbox/$(date -u +%Y%m%d-%H%M%S)-get-pods.task.yaml
```

The example has `# bridge-approval: auto` in its header so the
watcher doesn't prompt. You'll see in terminal A:

```
[2026-05-05T...Z] TASK: id=20260505-... format=yaml executor=noetl-yaml ...
[2026-05-05T...Z]   RUN: noetl exec /Volumes/.../bridge/inbox/...task.yaml --runtime local --json
[2026-05-05T...Z]   noetl exit=0 overall=ok
[2026-05-05T...Z] DONE: 20260505-...
```

And the result file:

```bash
cat bridge/outbox/20260505-*-get-pods.result.json | jq .
```

Should show:

```json
{
  "id": "20260505-...",
  "from": "codex",
  "to": "claude-cowork",
  "completed_at": "...",
  "approval_status": "approved",
  "approved_by": "kadyapam",
  "overall_status": "ok",
  "executor": "noetl-local",
  "envelope": {
    "status": "ok",
    "data": {
      "exit_code": 0,
      "namespace": "noetl",
      "stdout": "NAME            READY   STATUS    ...",
      "stderr": ""
    },
    "summary": "NAME            READY   STATUS    ..."
  }
}
```

End-to-end demo works — Claude can now drop tasks and read results
without copy-paste.

## Second demo — mutating task with approval gate

The interesting case: Claude needs to do something that changes
cluster state. The approval gate makes sure you see the commands
before they run.

Copy `bridge/examples/05_run_commands_via_playbook.task.json` to
inbox:

```bash
cp bridge/examples/05_run_commands_via_playbook.task.json \
   bridge/inbox/$(date -u +%Y%m%d-%H%M%S)-bump-bridge.task.json
```

In terminal A you'll see:

```
============================================================
BRIDGE: new task awaiting approval
============================================================
{
  "id": "example-05-run-commands-via-playbook",
  "title": "Bump bridge to v2.35.2 + verify",
  ...
  "playbook_path": "automation/agents/bridge/run_commands",
  "workload": {
    "stop_on_error": true,
    "commands": [
      { "id": "set-image", "shell": "kubectl -n noetl set image ..." },
      { "id": "wait-rollout", "shell": "kubectl -n noetl rollout status ..." },
      { "id": "verify-jsonrpc", "shell": "kubectl -n noetl exec ..." }
    ]
  }
}
============================================================
Approve? (y = run, n = deny, s = skip-without-result, e = edit)
[y/n/s/e]:
```

You read the commands, type `y`, the watcher invokes:

```bash
noetl exec automation/agents/bridge/run_commands \
  --runtime local \
  --payload '{"stop_on_error": true, "commands": [...]}' \
  --json
```

The local Rust runtime parses the playbook, runs each command via
`kind: python` + subprocess, captures per-step exit_code / stdout /
stderr, returns the agent envelope.

Result file in `bridge/outbox/`:

```json
{
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
    "summary": "Ran 3 command(s) successfully"
  }
}
```

Claude reads the file, walks `envelope.data.results`, sees all three
steps succeeded, continues.

## Goal-directed loops (Codex iterates until expected state)

The bridge supports a "goal-directed" mode where Claude describes a
desired state and Codex iterates against the cluster until that
state is reached.

The simplest pattern: Claude writes a Shape 1 task whose playbook
runs the verify shell as its final step, returning `status: "ok"`
when the success_pattern matches. The watcher executes the playbook
once. If the result envelope's `status` is `error`, Claude looks at
the result, decides what to fix, writes a follow-up task, and the
loop continues.

For multi-iteration loops where Codex itself is the orchestrator
(deciding what to try next without going back to Claude every time),
see `bridge/codex/handle_goal_task.sh` — it's invoked when a task
has top-level `kind: "goal-directed"`. Codex reads the task's hints,
iterates against the cluster using the `verify_goal.sh` helper
between attempts, and writes the result file when it gets to GREEN
(or hands back with `max_iterations_exceeded`).

For most cases, the simpler "Claude writes task → result → Claude
reads → next task" loop is sufficient and easier to reason about.

## Approval modes

Per-task `approval` field controls the gate:

| Value      | Behavior                                                  |
|------------|-----------------------------------------------------------|
| `required` | Watcher prints the task and prompts y/n/s/e at terminal   |
| `auto`     | Watcher executes immediately. Use only for read-only ops  |
| `denied`   | Watcher writes a denied result without prompting          |

YAML tasks default to `required` unless they include the magic
header comment `# bridge-approval: auto` in their first 10 lines.
That comment is opt-in — you have to write it explicitly per task.

The `e` (edit) option opens the task file in `$EDITOR` and re-prompts
after you save. Useful for tweaking command quoting / paths before
running.

## Denylist

Before the approval prompt, every command is checked against a
denylist in `bridge/codex/bridge_lib.sh`. Currently blocks:

- `git push` (no autonomous publishing)
- `helm uninstall` (no release deletion)
- `kubectl delete namespace` / `kubectl delete ns` (no namespace delete)
- `kubectl delete clusterrole` (cluster-scoped delete)
- `rm -rf /` outside `/tmp` (no nuking the home directory)
- `rm -rf ~`
- `mkfs` (no filesystem nukes)
- `dd if=... of=/dev/...` (no raw disk writes)
- `:(){...` (fork bomb)

If a denylisted command is found, the watcher writes a `denied`
result and never prompts. This is defence-in-depth — the primary
safety mechanism is still the approval prompt, but the denylist
protects against accidental yes-clicks.

## Bootstrap recovery

If your noetl CLI itself is broken (chicken-and-egg: you need to fix
noetl, but you can't run a noetl-backed task to fix it), use the
bash-fallback executor by setting `executor: "bash"` in the task:

```json
{
  "id": "20260505-rescue",
  "title": "Restart noetl-server (noetl CLI is broken)",
  "executor": "bash",
  "approval": "required",
  "commands": [
    { "id": "restart", "shell": "kubectl -n noetl rollout restart deploy/noetl-server" }
  ]
}
```

The watcher dispatches to `handle_task_bash.sh` which uses raw
`bash -c` directly. Result envelope shape is the same minus the
`envelope` wrapper (results live at top-level instead).

Once noetl is healthy again, switch back to noetl-mode tasks.

## Troubleshooting

**Watcher reports "noetl: MISSING" at startup.** The Rust CLI isn't on
your PATH. `brew install noetl` (when the Homebrew tap is up to
date) or build from `repos/cli` and put the binary on PATH.

**Task is stuck in inbox/.** Check `bridge/codex/watcher.log` —
errors during dispatch land there. Common causes: jq not installed
(only for `.task.json`), task file's playbook_path doesn't exist in
the catalog, denylist match.

**`noetl exec --runtime local` errors with "playbook not found".**
Either the path is wrong (Shape 2 tasks reference registered
playbooks; the path must match exactly), or you forgot to register
the run_commands playbook (`noetl catalog register
repos/ops/automation/agents/bridge/run_commands.yaml`). For Shape 1
(inline yaml), the watcher passes the file path directly so no
catalog registration is needed.

**Result envelope is empty.** Sign that the noetl exec produced
non-JSON output (e.g., a stack trace). Check `bridge/codex/watcher.log`
for the captured stdout/stderr; the watcher writes them into the
result file when noetl exits non-zero, but a malformed exit-zero
output would slip through. File a bug if you hit this.

## What's next

Things the bridge could grow into, ranked by usefulness:

1. **Streaming output**: today's watcher captures full stdout/stderr
   per step then writes the result. For long-running tasks (e.g.,
   `kubectl logs -f`) we'd want incremental updates so Claude can
   read progress mid-task. Probably a `bridge/streams/{id}.log`
   tail file the watcher appends to during execution.
2. **Distributed-runtime mode**: when noetl-server is reachable,
   route tasks through the cluster instead of local runtime.
   Same task files, just `--runtime distributed`. Gives the GUI
   visibility benefit when wanted.
3. **MCP-tool exposure**: register the bridge's `run_commands`
   playbook as an MCP tool. Then any MCP client (Cursor, Claude
   Desktop, even a future Cowork mode with cluster access) can
   invoke it directly without the file-bus.
4. **Approval-via-MCP**: today the approval prompt is a terminal
   `read`. Could be a MCP tool the GUI's run dialog calls — operator
   approves in the browser, watcher unblocks.

For now the file-bus + local-runtime executor is the right
minimum-viable bridge.

## See also

- [`bridge/README.md`](../bridge/README.md) — protocol reference
- [`bridge/examples/`](../bridge/examples/) — five reference task
  files covering all four shapes
- [`repos/ops/automation/agents/bridge/run_commands.yaml`](../repos/ops/automation/agents/bridge/run_commands.yaml)
  — the generic command-runner playbook
- [Agent Orchestration architecture page](https://noetl.dev/docs/architecture/agent_orchestration)
  — the broader ecosystem this bridge plugs into
