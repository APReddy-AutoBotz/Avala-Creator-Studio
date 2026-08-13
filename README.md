# Avala Creator Studio

A cloud-first, human-approved workflow for creating videos from authorized content using the creator's consent-bound voice and avatar profiles.

## Product contract

- Every stage requires explicit human review and approval.
- Publishing is out of scope. V1 ends with an approved downloadable video.
- Voice and avatar media are sensitive private assets and must never be committed to Git.
- Generated artifacts are drafts until the exact immutable version is approved.
- Revising an upstream artifact invalidates every downstream artifact, approval, and active job.
- Real voice/avatar inference remains disabled until consent, storage, deletion, security, and cost gates pass.

## Workflow

`Content -> Script -> Voice -> Avatar -> Edit -> Final -> Download`

## Stack

- Next.js + TypeScript
- Zod contracts
- Supabase Auth, PostgreSQL, RLS, and private Storage
- FastAPI render-worker boundary
- FFmpeg composition baseline
- Future provider adapters for voice and avatar generation
- GitHub + Codex Cloud development workflow

## Repository status

This repository is public during early code-only development. Do not commit credentials, customer material, voice samples, face/avatar source media, generated private media, embeddings, model weights, or signed URLs.

The current implementation uses deterministic mocks for development/test and fails closed for real generation in production-like modes.
