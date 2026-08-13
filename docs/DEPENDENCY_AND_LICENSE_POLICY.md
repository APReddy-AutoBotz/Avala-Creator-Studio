# Dependency and license policy

Every code library, model implementation, model weight, checkpoint, dataset-derived artifact, codec, and binary must be reviewed separately. A permissive code license does not automatically grant rights to model weights, training data, or generated outputs.

## Candidate components

- FFmpeg: composition baseline; retain required notices and review enabled codecs.
- Chatterbox: candidate voice adapter; verify current code/model terms before pinning or commercial use.
- MuseTalk: candidate avatar/lip-sync adapter; verify current code, weights, and transitive assets before pinning or commercial use.
- Supabase and Next.js SDKs: pin through a committed lockfile and dependency scanning before production.

## Explicit hold

Do not introduce Remotion until its licensing is separately reviewed for the intended product/business use.

## Supply-chain requirements

- Commit lockfiles before production deployment.
- Dependency review/security scanning on PRs.
- No unpinned Git dependencies.
- Track model checksums, provenance, source URL, license snapshot, and deployment approval outside the public source tree when necessary.
