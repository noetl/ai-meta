# SLM journey outcome — real MLX LoRA v1→v3, constrained-decoding-beats-scale

- Date: 2026-06-27 UTC
- Issue: noetl/ai-meta#141 (umbrella) / #139 (platform)
- ai-meta submodules bumped: `repos/ops`, `repos/travel`, `repos/worker`, `repos/tools`, `repos/e2e`
- Tags: slm, mlops, finetune, constrained-decoding, mlx, wrap-up

## Summary

Wrap-up of the travel-domain SLM journey. The headline result: a real
fine-tuned multitask LoRA, trained locally via MLX on Apple Silicon
(`finetune.yaml mode=mlx`, qwen2.5-1.5b/3b), evaluated under grammar-
constrained decoding across v1→v3 data-scaling iterations. All work
landed on ops/travel main; ai-meta pointers bumped.

The journey shape:

1. **Teacher pivot OpenAI → Vertex Gemini.** Distillation teacher cut
   over to a pluggable Vertex Gemini provider (ops#216 / travel#75).
2. **Teacher-below-floor → constrained-decoding-beats-scale.** Raw
   `gemini-2.5-pro` scored *below* the deterministic-oracle floor
   (0%/49%; emitted `tool_id` not `tool`). Schema-constrained decoding
   (Vertex `responseSchema`) on the smaller `flash` then hit 100%
   widget-envelope + 100% extract. The lever is the decode-time
   constraint, not model scale.
3. **Deterministic oracle = authoritative labeler.** `repos/travel
   automation/mlops/slm/travel/oracle.py` derives ground-truth labels
   deterministically and is the floor every candidate must beat — labels
   are not trusted from the teacher.
4. **MLOps-as-playbooks pipeline.** finetune / eval(SLM) / package run as
   generic config-driven NoETL playbooks on the G1 (container/GPU Job) /
   G2 (poll-completion) / G3 (registry+artifacts) foundations.
5. **Real local training via MLX.** `mode=mlx` runs an actual on-device
   LoRA — the path that produced v1/v2/v3 real models, vs the CPU stub
   (`mode=local`) and the gated cluster GPU (`mode=container`).

## v1 → v3 results (single multitask LoRA, constrained decode, 144-turn eval)

- v1 `travel-mlx-v1` — first real fine-tune, 45-turn seed corpus.
- v2 `travel-mlx-v2` — data scaling 45 → 701 turns.
- v3 `travel-mlx-v3` — targeted data + true logit-level grammar-constrained
  decoding (`lib/slm_constrain.py`, lmfe schema sanitizer), extract-only.

v3 constrained gated metrics (target in parens):

- `tool_match` **0.94** (0.98)
- `render_intent_match` **0.92** (0.98)
- `arg_fidelity` **0.94** (0.95)
- `slot_update_match` **0.94** (0.95)
- `widget_type_match` **0.79** (0.98)  ← blocker
- **100% schema validity** across the board (extract / widget_schema /
  tool_vocab / render_intent_vocab all = 1.0).

## Current blocker → next iteration

`widget_type_match` ~0.79 is the sole long pole — the data-bearing /
render widgets (show_flights 15/21, show_hotels 18/20) get the wrong
widget *type*. Schema validity is maxed; the gap is which widget, not
whether it's well-formed. Next iteration = targeted data for
render-intent → widget-type disambiguation on data-bearing widgets.
Still below the 0.98/0.95 gate → not a Muno drop-in yet.

## Repos

- ops PR#220 — mlx-local + full v1/v2/v3 (squash `2c7d5a4` captured the
  ENTIRE branch incl. constrained decode / lmfe sanitizer / v2/v3 results,
  not just the first commit). `git diff origin/main..branch` empty.
- travel PR#76 (v2+v3 corpus generator), travel PR#69 (RFC).
- Latency track: worker#135 (blocking claim) + #136 (coldstart warmup) →
  v5.47.1; tools#79 (NATS conn reuse) + #82 (G1/G2) → v3.19.1.
- e2e#82 (auth0 check_playbook_access accessors).

ai-meta pointer bumps (old → new):

- ops `176124c` → `2c7d5a4`
- travel `c55c1f5` → `af6c9f8`
- worker `32b0e96` → `0b1396f` (v5.47.1)
- tools `f36d020` → `57e70ba` (v3.19.1)
- e2e `36dced2` → `83e922e`
- server `1d86464`, gateway `8abef26` — unchanged.

## Boundary

Additive code/docs merges + semantic-release publishes only. No prod GKE
deploy, no prod flag flips, no OQ5 gate / result_store / dual-write /
NATS / IAM / secrets touch.

## Related

- memory/inbox SLM Phase B spine (#141 finetune+eval+package)
- memory/inbox SLM Phase 1 constrained teacher (#140)
- noetl/ai-meta#139 Domain-Specific SLM platform umbrella
