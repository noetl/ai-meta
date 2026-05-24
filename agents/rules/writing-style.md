---
paths:
  - "**"
---

# Writing Style

User preferences for prose written by agents — wiki pages, PR
descriptions, decision docs, handoff bodies, anything human-facing.

## Banned words

Do not use these in any doc, PR body, commit message body, or
handoff prose. They are vague, self-promotional, or carry
unwanted connotations.

- **canonical** — say "primary", "source-of-truth", "the
  install path we support", or describe the role concretely.
  Don't dress up a path with the word.

When tempted to reach for a banned word, replace it with the
concrete role the thing actually plays.

## Tone

- Concrete over abstract. Name the file, the command, the
  outcome.
- Active voice. "The chart renders the ScaledObject" beats
  "The ScaledObject is rendered by the chart".
- Cut intensifiers ("very", "extremely", "simply"). They add
  nothing and sometimes mislead.
- No sales language. We document for operators; we don't pitch.
