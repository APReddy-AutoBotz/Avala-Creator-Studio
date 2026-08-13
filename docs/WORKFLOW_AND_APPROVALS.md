# Workflow and approvals

## Stages

1. Content review and rights attestation
2. Script generation/edit/review and approval
3. Voice generation/listen/review and approval
4. Avatar generation/watch/review and approval
5. Edit generation/timeline and caption review and approval
6. Final render and final approval
7. Download

## Approval binding

Every approval stores the artifact ID, version number, SHA-256 digest, reviewer, decision, notes, and timestamp. Editing creates a new immutable version. Approval never carries forward to a new version.

## Revision semantics

A revision request records its target and reason. Every downstream artifact becomes stale, downstream approvals become invalidated rather than silently authoritative, and queued/running downstream jobs are cancelled. Audit history is retained.

## Concurrency and retry safety

Transitions include the expected stage. Stale clients receive a conflict and reload. Mutations/jobs use idempotency keys. Replayed callbacks cannot create duplicate authoritative effects.

## Authority

- Human: attest rights/consent, edit, approve, request revision, initiate authorized generation, revoke consent, delete private identity assets, download approved outputs.
- Worker: create draft output or record job failure.
- System: invalidate downstream authority, expire leases/assets, enforce deletion/retention.

Workers and service identities may never approve on behalf of the human owner.
