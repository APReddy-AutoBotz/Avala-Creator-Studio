# M3 Phase B1 — Governed Voice Runtime Readiness

## Goal

Complete the product-grade voice stage without enabling real TTS inference. The system must support a human-triggered voice request, trusted worker completion with an explicitly synthetic private audio artifact, human listening/revision/approval, and safe stale/deletion behavior.

## Hard boundary

B1 must not install or import Chatterbox, Qwen, CosyVoice, OpenVoice, Torch, Transformers or Hugging Face runtime packages; must not download model weights/checkpoints/tokenizers; must not run CPU/GPU/MPS TTS; must not call hosted/paid TTS; and must not add avatar or publishing integrations. Real-provider execution remains disabled.

## Required workflow

`SCRIPT_APPROVED -> VOICE_GENERATING -> VOICE_REVIEW -> VOICE_APPROVED`

- Only the authenticated owner may request the voice stage.
- A request must bind the exact current human-approved script artifact/version/SHA, active self-owned voice profile, captured validated sample IDs, provider/runtime authority, voice manifest digest, budget and idempotency key.
- B1 may queue only the existing zero-cost synthetic mock provider.
- Only service-role worker authority may complete a voice job.
- Worker completion creates a draft voice artifact only; it may never approve.
- Human approval binds the exact immutable voice artifact/version/SHA.
- Requesting revision must invalidate/stale the voice artifact and downstream work without deleting audit history.

## Private audio artifact

Add a private output-audio storage path and a trusted completion contract. A completed artifact must bind at minimum:

- project ID and job ID
- script artifact ID/version/SHA
- voice profile ID and validated sample IDs
- provider/model/revision/verified-at snapshot
- generation mode and visible synthetic label
- audio SHA-256, byte length, MIME type, duration and object path
- voice manifest SHA-256
- runtime milliseconds and zero-cost evidence
- immutable artifact version

No public bucket or permanent media URL is allowed. The browser receives only short-lived owner-authorized preview access.

## Completion authority

Implement trusted completion with exact replay semantics and response-loss recovery. Revalidate immediately before completion:

- project is still at the expected voice stage
- profile remains active and not revoked/deleting/deleted
- all captured samples remain validated/current
- bound script is still latest/current/human-approved
- job remains authoritative and is leased to a trusted worker
- mock provider/runtime policy is still enabled for test/demo
- budget remains zero
- output object metadata and digest match the completion payload

A stale or revoked job fails closed and cannot create a current artifact.

## Review UX

Add a responsive Voice Review surface showing:

- clear `[SYNTHETIC MOCK VOICE DRAFT]` status for mock artifacts
- audio player using short-lived private access
- script/version/provider/provenance summary
- Approve and Request revision actions
- no auto-advance without explicit human approval

The UI must make stale/revoked/deleting states obvious and disable invalid actions.

## Retention and deletion

Implement a durable deletion queue/ledger for private output audio. SQL may schedule deletion but must not bypass Storage API deletion. Profile revocation/deletion and upstream revision must cancel active jobs, stale affected artifacts and schedule stale/private outputs for deletion. Final deletion evidence must be auditable and idempotent.

## Required tests

Cover at least:

- cross-user request/read/preview/approval denial
- worker cannot approve
- browser cannot complete jobs
- exact request/completion/approval replay
- conflicting idempotency-key reuse
- worker response-loss recovery
- active lease versus expired lease recovery
- completion after profile revoke/delete is denied
- completion after script revision is denied
- non-latest/unapproved script is denied
- output digest/object mismatch is denied
- private preview requires owner authority
- approving voice version 1 does not approve version 2
- revision invalidates voice approval and downstream authority
- deletion queue replay is idempotent
- no real-provider execution path becomes enabled

## Verification

Run all existing checks plus new TypeScript/Python/static/database tests and production build. Where connected Supabase is available, run live runtime/RLS/storage/advisor tests. Keep the PR Draft.

## Exit evidence

Report exact head SHA, changed files, migrations, live database evidence, test/build results, security impact, cost impact and known limitations. Real provider inference remains a separate B2 gate.