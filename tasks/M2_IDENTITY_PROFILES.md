# M2: Consent-Bound Identity Profiles and Private Media Intake

## Objective

Implement self-owned voice and avatar profiles so no real voice cloning or avatar generation can be enabled before explicit consent, private storage, validation, revocation, deletion, and audit controls exist.

## Required product behavior

1. A signed-in user can create a `voice` or `avatar` profile for themselves only.
2. Voice and avatar require separate consent records with a statement version and SHA-256 of the accepted statement/evidence payload.
3. The browser must not submit an owner/reviewer user ID.
4. Create owner-scoped private object paths. Never accept a public URL as profile media authority.
5. Validate declared MIME type, size, SHA-256, and filename/path metadata before accepting an upload registration.
6. Uploaded media begins in `pending_validation`; it cannot be used by a generation job.
7. Add a validation-result boundary so a future trusted worker can mark a sample `validated` or `rejected` without granting human approval authority.
8. Profile activation requires current unrevoked consent and at least one validated sample.
9. Revocation blocks new jobs immediately and invalidates/cancels all affected voice/avatar and downstream jobs/artifacts.
10. Deletion removes/schedules removal of source media and derived identity assets while retaining minimal non-sensitive audit evidence.
11. Add user-facing review screens for profile consent, sample status, revoke, and delete. No real sample is required in automated tests.
12. Use private Supabase Storage with owner-scoped RLS. Signed/authenticated access must be short lived.
13. Add idempotency to profile creation, upload registration, revocation, and deletion.
14. No real voice/avatar inference, model download, GPU, or social publishing code in this milestone.

## Security acceptance cases

- User A cannot read/write/delete User B profile rows or media.
- Anonymous callers cannot access identity profiles/media.
- A request containing `ownerId`, `reviewerId`, or a public media URL is rejected by schema/API design.
- Revoked consent cannot be reactivated implicitly and prevents generation eligibility.
- A sample in `pending_validation` or `rejected` cannot make a profile generation-eligible.
- Replaying the same idempotency key creates no duplicate profile/upload/revocation/deletion effect.
- Deleting/revoking a profile invalidates affected downstream authority but preserves non-sensitive audit history.
- Worker/service completion cannot create human approvals.
- No sensitive media is written to Git, logs, CI artifacts, or public buckets.

## Tests/evidence

- Contract/unit tests for consent and eligibility rules
- API input tests proving no owner/reviewer injection
- SQL/RLS runtime tests if a local/hosted test database is available
- Storage policy tests if a Supabase test instance is available
- Static SQL guardrails otherwise, clearly marked non-runtime
- Browser screenshots for desktop/mobile profile-management UX
- Exact commands/results and current head SHA
- Explicit statement that real voice/avatar inference remains unproven and disabled

## Codex Cloud delivery

Work on the current Draft PR. Commit intentionally and push if GitHub transport is available. If transport is unavailable, post a complete patch/diff in the PR conversation so the controller can apply it through the GitHub connector. Keep the PR Draft.
