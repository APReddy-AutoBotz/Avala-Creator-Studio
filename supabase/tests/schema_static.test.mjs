import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const sql = readFileSync(new URL('../schema.sql', import.meta.url), 'utf8');

for (const table of [
  'creator_projects', 'creator_artifacts', 'creator_rights_attestations', 'creator_reviews',
  'creator_consent_profiles', 'creator_identity_samples', 'creator_jobs', 'creator_audit_events',
]) {
  assert.match(sql, new RegExp(`alter table public\\.${table} enable row level security`, 'i'), `${table} must enable RLS`);
}

assert.match(sql, /'creator-private'\s*,\s*'creator-private'\s*,\s*false/i, 'identity media bucket must be private');
assert.match(sql, /storage\.foldername\(name\).*auth\.uid\(\)/is, 'Storage policies must bind the first folder to auth.uid()');
assert.doesNotMatch(sql, /create policy[^;]+using\s*\(\s*true\s*\)/is, 'No allow-all RLS policy is permitted');
assert.match(sql, /security definer/is, 'authoritative RPCs are expected');
assert.match(sql, /set search_path = ''/is, 'SECURITY DEFINER RPCs need a fixed empty search path');
assert.match(sql, /revoke all on function public\.creator_create_consent_profile[^;]+from public, anon/is, 'RPCs must revoke PUBLIC/anon execute');
assert.match(sql, /revoke all on function public\.creator_record_identity_sample_validation[^;]+authenticated/is, 'worker validation boundary must not be browser-callable');
assert.match(sql, /CONSENT_REVOKED/i, 'revocation must cancel active work');
assert.match(sql, /status in \('pending_validation','validated','rejected','deleted'\)/i, 'identity samples require validation state');
assert.doesNotMatch(sql, /public\s*=\s*true/i, 'no public media bucket is allowed');

console.log('Supabase schema static security guardrails: PASS');
