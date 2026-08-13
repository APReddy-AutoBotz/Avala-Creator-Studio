# Architecture

## Components

1. **Next.js web application**: authentication, editors, review/approval UX, profile consent controls, and approved downloads.
2. **Supabase**: Auth, PostgreSQL, RLS, private Storage, immutable artifact metadata, approvals, audit events, consent profiles, upload intents, and a durable job queue.
3. **Render worker**: isolated FastAPI service. It consumes authorized jobs, obtains short-lived access to private inputs, invokes a provider adapter, uploads private results, and reports draft completion.
4. **Provider adapters**: deterministic/manual script baseline; future voice, avatar, and FFmpeg composition adapters.

## Queue

V1 uses PostgreSQL for durable jobs, idempotency, leases, and transactional authority. Redis is not required for the first production pilot.

## Trust boundaries

- Browser input is untrusted and cannot choose owner/reviewer identity.
- User operations run with caller-scoped Supabase authority and RLS.
- Privileged workflow mutations are server/database controlled and must verify `auth.uid()`.
- Workers can create draft outputs but cannot create human approvals.
- Media remains in private storage; no permanent public media URL is authoritative.
- Provider secrets exist only in managed worker/server environments.

## Runtime modes

- `demo`: deterministic synthetic behavior, clearly labelled.
- `test`: deterministic test doubles.
- `preview`: real Supabase authority required; no implicit mock fallback.
- `production`: real authority, consent, storage, and provider gates required.

## Composition

FFmpeg is the baseline for deterministic composition, captions, overlays, loudness normalization, and aspect-ratio outputs. Remotion requires a separate licensing decision before adoption.
