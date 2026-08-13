# Security and privacy

Voice recordings and facial/avatar source media are high-impact private identity assets.

## Required controls

- Voice and avatar consent are separate, explicit, versioned records.
- V1 identity profiles are self-owned only.
- Consent is bound to a specific profile purpose and statement version.
- Revocation immediately blocks new generation and invalidates affected downstream work.
- Storage buckets are private; object paths are owner-scoped and immutable.
- Use authenticated access or short-lived signed access; never permanent public media URLs.
- No credentials, samples, embeddings, model weights, signed URLs, or generated private media in Git.
- Content rights attestation is required before content approval/generation.
- Artifact versions and approvals are immutable; invalidation is separately recorded.
- Project authority cannot be mutated by arbitrary browser table updates.
- Download and deletion events are audited.
- Deletion removes or irreversibly schedules deletion of samples and derived outputs according to retention policy.

## Abuse prevention

Do not support URL ingestion of another person's face/voice, a public identity marketplace, or consent bypass. Any future delegated/third-party likeness support requires a separate identity-verification, legal, privacy, and threat-model milestone.

## Logging

Log event codes, opaque IDs, timing, and outcome. Do not log sensitive scripts, signed URLs, tokens, raw provider responses containing media, embeddings, or private object paths.
