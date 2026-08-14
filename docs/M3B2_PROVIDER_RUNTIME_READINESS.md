# M3 B2 — Chatterbox runtime, supply-chain and privacy readiness

## Decision

B2 prepares an adapter and deployment boundary but **does not approve installation or inference**. The current official `chatterbox-tts` package is version 0.1.7 and MIT-licensed, but it currently declares `resemble-perth` from a moving Git `master` ref. Upstream `from_pretrained` also downloads model files from Hugging Face revision `main`. Both behaviors violate Creator Studio's immutable-dependency/runtime-download policy.

Therefore:

- default worker and CI do not install Chatterbox or Torch;
- the B2 adapter fails before optional imports;
- future execution must use `ChatterboxMultilingualTTS.from_local` only;
- model files must be provisioned outside the application build and mounted read-only;
- a B3 release record must pin every executable Git dependency, model asset digest and runtime image digest;
- the existing database `real_provider_execution_enabled=false` gate remains unchanged.

## Current immutable evidence

The non-installable manifest is `services/render-worker/real-provider/chatterbox-runtime.lock.json`. Known core assets are recorded there. Missing SHA-256 values are intentional blockers rather than wildcards.

The current Perth `master` SHA captured during B2 is `ce86c49d029f42272c1902eccb675556b9ed2330`. It is only a candidate pin; B3 must re-verify and explicitly approve it.

## Runtime architecture for B3

`Supabase private input -> governed job/lease -> B3 GPU worker -> verified read-only local model cache -> local Chatterbox adapter -> private output -> existing B1 completion/VOICE_REVIEW -> human review`

The worker may not contact Hugging Face or another model host at inference time. The model cache is provisioned separately, verified before readiness and mounted read-only. A runtime image digest and complete cache-manifest digest become part of output provenance.

## Cost gate

B2 does not create a GPU resource and therefore measures no GPU cost. B3 must first select an on-demand/scale-to-zero GPU provider and obtain explicit cost confirmation. Before a real job starts, authority must bind a hard per-job ceiling. The worker must reject an estimate above that ceiling and record actual runtime/cost after completion.

## Threat model

### Supply-chain substitution
Moving Git refs, moving model revisions, mutable container tags and partially verified caches can replace executable/model content after approval. Mitigation: immutable commits, complete file hashes, image digest pinning and `from_local` only.

### Model/cache persistence
Voice samples or generated output must never be copied into a persistent model cache. Inputs are short-lived private objects; model cache is read-only; temporary working directories are deleted after job completion/failure.

### Sample/script exfiltration
No script text, signed/private media URL, sample path or raw provider payload is logged. Runtime network egress should be disabled except Supabase API/Storage endpoints required for the governed job.

### GPU host compromise
The future GPU worker receives only one job lease/capability, short-lived private input access and bounded output authority. It cannot create human approvals. Revoke/delete invalidates completion authority and queues output cleanup through B1 deletion accounting.

### Response loss
B1 idempotency, lease recovery, held-output ledger and reconciliation remain authoritative. A real adapter must reuse those mechanisms rather than invent a second completion system.

### Provider/runtime bypass
B2 contains a code-level `REAL_INFERENCE_NOT_APPROVED_B2` stop before optional imports. B3 must require both a versioned database runtime approval and a worker deployment approval; one environment variable alone must never activate inference.

## B3 acceptance before first real voice

1. Complete model-cache digest manifest, including tokenizer/auxiliary assets.
2. Immutable Perth/runtime dependency lock and dependency review.
3. Reviewed GPU image digest and vulnerability scan.
4. Explicit GPU provider/cost approval and hard per-job ceiling.
5. Network-egress and secret-scope proof.
6. Owner's active self-owned consent profile and validated sample only.
7. One manually triggered pilot job; no unattended scheduling.
8. Private output, immutable provenance, review/revise/approve and deletion proof.
9. Independent security/Codex review.
