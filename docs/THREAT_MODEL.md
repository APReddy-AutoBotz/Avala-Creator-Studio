# Threat model

## Protected assets

- Voice and avatar source media
- Derived identity representations and generated media
- Content/scripts marked confidential
- Auth sessions and provider credentials
- Approval/audit integrity
- Consent and revocation state
- Provider/model/license and cost authority

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
- A research-only provider becoming executable because metadata exists
- Voice jobs executing after consent/provider/budget state changed
- Synthetic/mock evidence being mistaken for real provider output
- Model weights or provider credentials entering repository or build artifacts

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
- Audit consent, approval, revocation, deletion and provider-denial authority events without logging script text, private media paths, credentials or biometric material

## M3 Phase A voice boundary

M2 closed the consent/storage/deletion authority gate before M3. M3 Phase A does **not** enable real voice inference.

- Chatterbox Multilingual V3 is catalogued as the evaluation champion; Qwen3-TTS 12Hz 0.6B Base is fallback; Fun-CosyVoice3 is a specialist benchmark; OpenVoice V2 is a lightweight reference.
- Every real provider is structurally `research_only`, `not_installed`, execution-disabled and zero-runtime-budget in the Phase A catalog.
- The only executable adapter is an internal deterministic mock used for tests/demo. It creates a checksummed descriptor labelled `[SYNTHETIC MOCK VOICE DRAFT]`; it creates no audio/media.
- Mock voice-job creation additionally requires private server-side `test`/`demo` runtime policy. A browser flag cannot enable it.
- Voice-job creation binds the caller-owned active voice profile, validated sample IDs, exact latest approved script artifact/version/SHA, provider policy, a voice-manifest SHA and a hard budget.
- Trusted worker claim revalidates profile/sample/script/provider/runtime-policy/budget state immediately before leasing the job.
- Workers may create draft evidence only. No Phase A voice RPC creates an approval or transitions the product to `VOICE_GENERATING`/`VOICE_READY`.
- Real provider attempts are denied and audit-evidenced without storing script text, sample paths, media URLs or credentials.

## Phase B approval gate

Before any real provider package, model/checkpoint, GPU/CPU TTS inference or hosted TTS endpoint is used, record an explicit decision for:

1. current code license and model-weight license/commercial use;
2. selected model revision/checksum and supply-chain provenance;
3. provider/compute cost, per-job cap and aggregate budget;
4. privacy/data flow and retention/deletion behavior;
5. owner-only consent/sample binding revalidated at execution time;
6. explicit human-trigger requirement and immutable output review/revise/approve UX;
7. private output storage, rollback/deletion evidence and incident logging boundaries.

If any Phase B authority is absent or stale, real voice generation remains disabled.
