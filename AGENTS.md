# Codex instructions for Avala Creator Studio

## Product invariants

1. Publishing integrations are out of scope.
2. Every stage requires explicit human review and approval before downstream work becomes authoritative.
3. Workers may create draft artifacts; workers may never approve artifacts.
4. An approval must bind to an immutable artifact ID, version, and SHA-256 digest.
5. Revising an upstream artifact invalidates downstream artifacts, approvals, and active jobs without deleting audit history.
6. No voice sample, avatar source media, credential, token, signed URL, model weight, embedding, or generated private media may enter Git history.
7. All media storage must be private and owner-scoped.
8. Real generation fails closed when provider/consent authority is unavailable. Never silently fall back to mock output in preview/production.
9. Mock output must be visibly and structurally labelled synthetic/mock.
10. ChatGPT/Codex subscriptions are development tooling, not runtime API entitlements.
11. Browser inputs must never select an owner ID, reviewer ID, or privileged workflow authority.
12. No self-owned voice/avatar profile can be used after consent revocation.

## Supabase rules

- Use caller-scoped Supabase clients with the publishable key and RLS for user operations.
- Never expose a Supabase secret/service-role key to the browser.
- Enable RLS on every exposed table and include ownership predicates.
- If a SECURITY DEFINER RPC is unavoidable, revoke PUBLIC execute, explicitly grant only the required role, use a fixed search_path, and perform `auth.uid()` ownership checks inside the function.
- Keep Storage buckets private and owner-scoped. Do not generate permanent public media URLs.

## Engineering rules

- Strict TypeScript and Python typing.
- Validate all trust-boundary inputs.
- Idempotency keys for mutation retries and jobs.
- Do not log scripts marked confidential, private object paths, signed URLs, tokens, voice embeddings, or biometric samples.
- Keep providers behind interfaces; baseline must run without a GPU.
- FFmpeg is the composition baseline. Do not introduce Remotion without a separate licensing decision.

## Required checks

```bash
corepack enable
pnpm install --no-frozen-lockfile
pnpm check
python -m pip install -e 'services/render-worker[dev]'
python -m pytest services/render-worker/tests -q
python -m compileall -q services/render-worker/src services/render-worker/tests
```

For database changes, additionally run the available Supabase/Postgres runtime tests and security advisors. If the environment cannot run them, state that limitation rather than claiming runtime proof.

## Pull request discipline

- Keep implementation PRs Draft until declared checks are green.
- Report changed files, migrations/schema changes, security impact, provider/cost impact, and evidence.
- Real biometric/media inference requires an explicit milestone gate even if code exists.
