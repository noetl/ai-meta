# Prompt Engineering

Treat prompts — system prompts, reusable task prompts, subagent briefs, eval
prompts — as versioned artifacts, not throwaway chat text. A prompt that
works today and silently rots after a model swap or a scope change is a bug
with no stack trace.

## Where prompts live

- `prompts/library/<name>.md` — one file per prompt, scaffolded from
  `prompts/templates/prompt.md`.
- Use the `prompt-new` skill to create one, `prompt-iterate` to revise one.

## Required shape

Every prompt file declares, in frontmatter: `name`, `version`, `status`
(`draft` / `stable` / `deprecated`), `target_models`, `created`. The body
declares:

1. **Intent** — what the prompt is for and when to use it.
2. **Inputs/Variables** — every `{{placeholder}}` the prompt expects.
3. **Prompt Body** — the literal text, in a fenced block, copy-pasteable
   as-is. Do not describe the prompt; include it.
4. **Known Failure Modes** — how it breaks, on what inputs.
5. **Eval Notes** — what was tested, against what inputs, with what result.
6. **Changelog** — append-only, one line per version bump.

## Iteration workflow

1. Draft (`status: draft`) against a first-pass intent.
2. Test against representative inputs, including edge cases and adversarial
   inputs, not only the happy path.
3. Record the outcome in **Eval Notes** before changing status.
4. Promote to `stable` only after eval notes show it holding up across the
   inputs it will actually see in production use.
5. Any semantic change to the prompt body is a version bump with a new
   **Changelog** line — never a silent edit. Prior versions stay in the
   changelog; do not delete or rewrite past entries.
6. Mark `deprecated` (do not delete) once superseded; note the replacement's
   name/version in the changelog line.

## Rules

- Never bake secrets, tokens, or credentials into a prompt body. If a prompt
  needs a credential at runtime, reference it the way
  [`no-default-connection.md`](no-default-connection.md) requires — by alias,
  substituted at execution time.
- Never promote `draft` to `stable` without at least one recorded eval pass.
- A prompt used inside an agentic loop's stop condition (see
  [`loop-engineering.md`](loop-engineering.md)) must have its own eval notes
  updated whenever the loop's success/failure signal changes meaning.
- A prompt change that satisfies a spec's acceptance criteria (see
  [`spec-driven-development.md`](spec-driven-development.md)) should be cited
  from that spec's Verification Plan.

## Coordination with other rules

- [`loop-engineering.md`](loop-engineering.md) — a self-correction or
  verification loop's stop condition is frequently "the prompt passes eval."
- [`spec-driven-development.md`](spec-driven-development.md) — a spec's
  acceptance criteria may require a specific prompt revision.
- [`memory-workflow.md`](memory-workflow.md) — record a memory entry when a
  stable prompt is deprecated or replaced; that is a durable decision.
- [`writing-style.md`](writing-style.md) — applies to prompt bodies too.
