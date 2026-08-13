# Implementation plan

## M0: Foundation

- Standalone repository and Codex Cloud workflow
- Monorepo, contracts, CI, security/repository boundary checks
- Supabase authority design and deterministic mock worker

## M1: Content and script gates

- Projects, content rights attestation, immutable versions
- Script editor/generation adapter boundary
- Human approve/revise and audit trail
- Retry/idempotency and downstream invalidation

## M2: Consent-bound identity profiles

- Separate voice/avatar consent UX
- Owner-scoped private media intake
- File metadata validation and validation-state boundary
- Profile activation only after consent and sample validation
- Revocation, deletion, retention, audit, and downstream invalidation
- No real inference in M2

## M3: Voice generation

- Review current voice model/license and select adapter
- Pronunciation dictionary, segmentation, retries, quality checks
- On-demand GPU execution and cost evidence
- Human listen/review/approve

## M4: Avatar generation

- Review current avatar model/license and select adapter
- Source preparation and lip-sync generation
- Visual quality checks and human watch/review/approve

## M5: Composition

- FFmpeg timeline manifest, captions, B-roll, logo, music ducking, aspect-ratio presets
- Edit review, final render, final approval, controlled download

## M6: Production pilot

- Retention/deletion jobs, backup/restore, observability, abuse controls, rate limits
- Real-user pilot with self-owned profiles only
- Cost report and production go/no-go evidence

A milestone is not complete merely because code exists. It requires declared tests, security evidence, and human product review.
