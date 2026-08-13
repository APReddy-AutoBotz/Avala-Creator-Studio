import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';

const migrationsDir = new URL('../migrations/', import.meta.url);
const sql = readdirSync(migrationsDir)
  .filter(name => name.endsWith('.sql')).sort()
  .map(name => readFileSync(new URL(name, migrationsDir), 'utf8')).join('\n');

for (const table of [
  'creator_projects','creator_artifacts','creator_rights_attestations','creator_reviews',
  'creator_consent_profiles','creator_identity_samples','creator_jobs','creator_audit_events','creator_upload_intents',
]) {
  assert.match(sql,new RegExp(`alter table public\\.${table} enable row level security`,'i'),`${table} must enable RLS`);
}
assert.match(sql,/create schema if not exists creator_private/i,'privileged implementations need a non-exposed schema');
assert.match(sql,/language sql security invoker/i,'public RPC wrappers must be security invoker');
assert.match(sql,/security definer/is,'private authoritative implementations are expected');
assert.match(sql,/set search_path\s*=\s*''/is,'privileged functions need fixed empty search path');
assert.match(sql,/revoke all on function public\.creator_record_identity_sample_validation[^;]+authenticated/is,'browser validation execute must be revoked');
assert.match(sql,/grant execute on function public\.creator_record_identity_sample_validation[^;]+service_role/is,'trusted service role must validate samples');
assert.match(sql,/'creator-private'\s*,\s*'creator-private'\s*,\s*false/i,'identity bucket must be private');
assert.match(sql,/storage\.foldername\(name\).*auth\.uid\(\)/is,'Storage policies must bind paths to auth.uid()');
assert.doesNotMatch(sql,/create policy[^;]+using\s*\(\s*true\s*\)/is,'No allow-all policy is permitted');
assert.doesNotMatch(sql,/public\s*=\s*true/i,'No public media bucket is allowed');
console.log('Supabase migration static security guardrails: PASS');
