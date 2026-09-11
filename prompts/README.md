# Prompts

A versioned library of prompts: system prompts, reusable task prompts,
subagent briefs, and eval prompts. Prompts are durable artifacts, tracked
the same way memory and specs are.

## Structure

- `templates/prompt.md` — scaffold for a new prompt.
- `library/<name>.md` — one file per prompt, with frontmatter
  (`version`, `status`, `target_models`), the literal prompt body, known
  failure modes, eval notes, and an append-only changelog.

## Rules

See [`agents/rules/prompt-engineering.md`](../agents/rules/prompt-engineering.md).

1. Never bake secrets or credentials into a prompt body.
2. Any semantic change is a version bump with a new changelog line; never
   silently edit a prompt in place.
3. Promote `draft` to `stable` only after eval notes show it holding up
   against representative and adversarial inputs.
4. Mark `deprecated`, don't delete, once superseded.

## Commands

Create a new prompt:

```
/prompt-new <name> "<one-line intent>"
```

Revise an existing prompt (version bump + changelog + eval note):

```
/prompt-iterate <name>
```
