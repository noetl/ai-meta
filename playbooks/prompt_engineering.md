# Prompt Engineering Playbook

Canonical checklist for adding or revising a prompt in the shared library
so it stays testable and durable instead of living only in chat history.

## Inputs

- Intent: what the prompt should accomplish and for which model(s)
- Representative inputs to test against, including edge cases

## New prompt

1. `/prompt-new <name> "<intent>"` — scaffold the prompt file.
2. Fill in Inputs / Variables and the literal Prompt Body.
3. Test against representative inputs. Record results in Eval Notes before
   changing `status` away from `draft`.
4. Commit: `prompt(add): <name>`.

## Revising a prompt

1. `/prompt-iterate <name>` — never edit `prompts/library/<name>.md`
   directly; the skill enforces the version bump and append-only changelog.
2. Describe what changed and why; the skill appends a Changelog line.
3. Re-test; the skill appends an Eval Notes line with the result.
4. Promote `status` to `stable` only once eval notes support it.
5. Commit: `prompt(iterate): <name> vN`.

## Output

- A versioned prompt file with a copy-pasteable body, eval notes, and a
  changelog a future agent can read to understand why the prompt looks the
  way it does.

See `agents/rules/prompt-engineering.md`.
