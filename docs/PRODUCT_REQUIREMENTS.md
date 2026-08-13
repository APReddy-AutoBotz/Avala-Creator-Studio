# Product requirements

## Outcome

A creator supplies content they own or are authorized to adapt. The system helps transform it into a polished video using the creator's explicitly consented voice and avatar profiles. The creator reviews, edits, and approves every stage. The final result is an approved downloadable video for manual publishing.

## V1 scope

- Project dashboard and governed stage timeline
- Content paste/upload and rights attestation
- Script drafting, editing, immutable versioning, review, and approval
- Self-owned voice profile consent and private sample management
- Self-owned avatar profile consent and private sample management
- Consent revocation and deletion
- Voice generation, listen/review/approval after provider gate
- Avatar generation, watch/review/approval after provider gate
- B-roll, captions, aspect ratios, branding, preview and final rendering
- Approved MP4/captions/thumbnail download
- Complete audit trail and retention/deletion controls

## Out of scope

- Automated social publishing or social OAuth
- Autonomous approval
- Cloning another person's voice or likeness without verified consent
- Public voice/face marketplace
- Scraping/adapting third-party content without rights attestation
- Foundation-model training
- Indefinite retention of identity samples
- Treating the ChatGPT consumer UI as an automated runtime API

## Acceptance principle

Generated output is always a draft. It never unlocks the next authoritative stage until the owner reviews and approves the exact immutable artifact version.
