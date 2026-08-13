# Threat model

## Protected assets

- Voice and avatar source media
- Derived identity representations and generated media
- Content/scripts marked confidential
- Auth sessions and provider credentials
- Approval/audit integrity
- Consent and revocation state

## Primary threats

- Cross-user object access (IDOR/BOLA)
- Browser-supplied ownership/reviewer spoofing
- Public or long-lived media URLs
- Consent replay after revocation
- Stage skipping or approval reuse against a newer artifact version
- Duplicate effects from retries/callbacks
- Storage path traversal or overwrite
- Sensitive-data leakage into logs/Git/CI artifacts
- Worker/service identity approving human decisions
- Malicious or malformed media reaching a future inference worker

## Required mitigations

- RLS with owner predicates on exposed rows and Storage objects
- Server/database-derived authenticated identity
- Immutable versions and exact digest-bound approval
- Explicit consent status checks at job creation and execution time
- Idempotency keys and transactional invalidation
- Private immutable object names and short-lived access
- Validation/quarantine state before an uploaded identity sample is usable
- Fail closed when authority/provider state is missing
- Separate worker and human capabilities
- Audit every consent, approval, revocation, deletion, and download authority event

M2 must close the consent/storage/deletion threats before M3 enables actual voice inference.
