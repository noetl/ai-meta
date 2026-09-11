# Context Engineering

Context is a scarce, explicit resource, not an afterthought. As memory,
specs, prompts, loops, and handoff threads accumulate, an agent's context
window is the thing all of them compete for. This rule governs what an
agent loads, in what order, and what it deliberately leaves out.

## Principle

Prefer pointers and summaries over full reproduction. Load only what the
current task needs to make a correct decision; pull in more only when a
specific question requires it, not as a precaution.

## Load order for a new session or task

1. Hard rules and safety boundaries (`AGENTS.md`,
   [`safety.md`](safety.md), [`execution-model.md`](execution-model.md)).
2. Active working state: `memory/current.md`, and only the specific
   `specs/active/<slug>/spec.md` or `loops/active/<slug>/loop.md` the
   current task concerns — not every active spec/loop, only the relevant
   one(s).
3. The rule files directly relevant to the task at hand (e.g.
   [`submodules.md`](submodules.md) only when touching linked repos).
4. Historical material — `memory/archive/`, `memory/compactions/`,
   `handoffs/archive/`, `specs/archive/`, `loops/archive/`,
   `evals/scenarios/` — only on demand, when the active task explicitly
   needs precedent, never loaded by default.

## Rules

- Don't load an archived spec, loop, or handoff thread into context unless
  the active task cites it. If it's needed, load only the section that
  answers the question, not the whole file.
- When referencing external knowledge (a wiki/Confluence page, a large
  log), summarize and link rather than reproducing it in full — the same
  discipline [`memory-workflow.md`](memory-workflow.md) applies to memory
  entries applies to anything staged for an agent's own context.
- A loop's checkpoint cadence ([`loop-engineering.md`](loop-engineering.md))
  should record enough to resume, not a full transcript of every
  iteration; verbose per-iteration output belongs in an external log the
  loop file links to, not inline.
- Do compaction ([`memory-workflow.md`](memory-workflow.md)) before, not
  after, a large task — stale, uncompacted inbox entries are context cost
  with no signal.
- If a task's context requirement can't be satisfied within a reasonable
  budget, that's a signal to scope the task down or split it — see
  [`spec-driven-development.md`](spec-driven-development.md) and
  [`loop-engineering.md`](loop-engineering.md) for splitting large work
  into smaller, separately-scoped units.

## Coordination with other rules

- [`memory-workflow.md`](memory-workflow.md) — compaction keeps active
  memory small.
- [`spec-driven-development.md`](spec-driven-development.md) — a spec's
  Verification Plan should reference current state, not require reloading
  the spec's full history.
- [`loop-engineering.md`](loop-engineering.md) — checkpoint cadence should
  stay light per iteration.
- [`prompt-engineering.md`](prompt-engineering.md) — a prompt's
  Inputs/Variables section should declare exactly what context it needs,
  so callers don't over-supply it.
- [`agent-regression-testing.md`](agent-regression-testing.md) — a
  scenario's Expected Behavior should be checkable without reloading
  unrelated history.
