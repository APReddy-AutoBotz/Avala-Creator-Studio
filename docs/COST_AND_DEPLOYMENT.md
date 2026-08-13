# Cost and deployment

## Near-zero fixed-cost target

- GitHub + Codex Cloud for implementation
- Free-tier web hosting during preview where practical
- Supabase free tier for early auth/database/private-storage use where practical
- Deterministic mocks for normal development and CI
- No always-on GPU

## M3 Phase A provider decision

The provider catalog is research metadata only. No provider runtime package, checkpoint, tokenizer or model weight is installed by M3 Phase A and no hosted TTS endpoint is called.

- Evaluation champion: Chatterbox Multilingual V3
- Fallback: Qwen3-TTS 12Hz 0.6B Base
- Specialist benchmark: Fun-CosyVoice3 0.5B
- Lightweight reference: OpenVoice V2

Every real provider is `research_only`, `not_installed`, execution-disabled and has a Phase A runtime budget of zero. The internal deterministic mock is built in, zero-cost and may run only when private server-side runtime policy is explicitly `test`/`demo`.

**Runtime provider spend in Phase A: $0.**

## Variable cost

Real voice/avatar inference requires compute. The intended design uses an on-demand worker that can scale to zero. Before real inference is enabled, the product must show an estimated per-job cost and the authority layer must enforce a hard per-job ceiling plus an aggregate/monthly budget outside the browser trust boundary.

## Laptop impact

The normal development, CI, database, and render workflow is cloud-first. A developer laptop should only need a browser for routine operation.

## Phase B cost gate

No real provider execution is approved merely because its adapter/catalog entry exists. Before changing any provider from `research_only`, record:

1. current code + model-weight commercial-use decision;
2. selected runtime (self-hosted/on-demand/hosted) and current price evidence;
3. expected cold-start/runtime footprint and measured cost per minute/job;
4. hard per-job budget and aggregate/monthly budget;
5. scale-to-zero and idle-cost behavior;
6. private storage/retention/deletion cost;
7. rollback/disable procedure if pricing or licensing changes.

A missing, zero, exceeded, or stale budget/provider approval fails closed. No paid provider resource is created in Phase A.

## General cost gates

- Prove the governed workflow with deterministic mocks before any GPU/provider spend.
- Measure actual rendering duration/cost before production approval.
- Expire superseded previews and avoid retaining duplicate media indefinitely.
