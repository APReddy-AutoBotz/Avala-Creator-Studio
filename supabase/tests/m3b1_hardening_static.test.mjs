import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const hardening = readFileSync(
  new URL('../migrations/20260814014204_m3b1_authority_concurrency_hardening.sql', import.meta.url),
  'utf8',
);
const pgcryptoFix = readFileSync(
  new URL('../migrations/20260814014815_m3b1_pgcrypto_capability_search_path.sql', import.meta.url),
  'utf8',
);
const closure = readFileSync(
  new URL('../migrations/20260814042219_m3b1_codex_review_closure.sql', import.meta.url),
  'utf8',
);
const requestRoute = readFileSync(
  new URL('../../apps/web/src/app/api/creator/projects/[projectId]/voice/request/route.ts', import.meta.url),
  'utf8',
);
const previewRoute = readFileSync(
  new URL('../../apps/web/src/app/api/creator/projects/[projectId]/voice/[artifactId]/preview/route.ts', import.meta.url),
  'utf8',
);
const workerRuntime = readFileSync(
  new URL('../../services/render-worker/src/creator_worker/b1_runtime.py', import.meta.url),
  'utf8',
);

assert.match(
  hardening,
  /creator_request_voice_job_b1_impl[\s\S]*profile_kind='voice'[\s\S]*for share/is,
  'request must serialize with profile revoke/delete',
);
assert.match(
  hardening,
  /v_job_status not in \('queued','leased'\)[\s\S]*return v_result/is,
  'old completed/cancelled request replay must not restart generation',
);
assert.match(
  hardening,
  /creator_claim_mock_voice_job_b1_impl[\s\S]*creator_consent_profiles[\s\S]*for share/is,
  'claim must strongly lock profile authority',
);
assert.match(
  hardening,
  /creator_complete_mock_voice_job_impl[\s\S]*creator_consent_profiles[\s\S]*for share/is,
  'completion must strongly lock profile authority',
);
assert.match(
  hardening,
  /v_job\.status<>'leased'[\s\S]*voice_completion_claims[\s\S]*replayed',true/is,
  'completion must recover an exact concurrent response-loss replay after waiting on locks',
);
assert.match(
  hardening,
  /storage\.objects[\s\S]*for share/is,
  'completion must lock the bound storage object while creating the authoritative artifact',
);
assert.match(
  hardening,
  /creator_enforce_voice_human_approval[\s\S]*creator_consent_profiles[\s\S]*for share/is,
  'human approval must serialize against consent revoke/delete',
);
assert.match(
  hardening,
  /media_deletion_leases/is,
  'media deletion must use private lease authority',
);
assert.match(
  hardening,
  /creator_finish_media_deletion_impl\([\s\S]*p_capability text/is,
  'media deletion completion must bind a private capability',
);
assert.match(
  hardening,
  /MEDIA_DELETE_LEASE_CAPABILITY_INVALID/is,
  'stale media-deletion workers must fail closed',
);
assert.match(
  hardening,
  /PRIVATE_MEDIA_DELETE_REQUIRED/is,
  'SQL may only finalize successful deletion after Storage confirms the object is gone',
);
assert.doesNotMatch(
  hardening,
  /delete from storage\.objects/is,
  'SQL must never bypass the Storage API',
);
assert.doesNotMatch(
  hardening,
  /approved_for_runtime|real_provider_execution_enabled\s*=\s*true/is,
  'B1 hardening must not enable real-provider execution',
);
assert.match(
  pgcryptoFix,
  /creator_claim_mock_voice_job_b1_impl\(uuid,integer\)[\s\S]*search_path\s*=\s*'extensions'/is,
  'voice lease capability entropy must resolve from the trusted extensions schema',
);
assert.match(
  pgcryptoFix,
  /creator_claim_media_deletion_impl\(uuid,integer\)[\s\S]*search_path\s*=\s*'extensions'/is,
  'media deletion capability entropy must resolve from the trusted extensions schema',
);
assert.doesNotMatch(
  pgcryptoFix,
  /search_path\s*=\s*'public'/is,
  'capability-generating security-definer functions must not trust the public schema',
);

assert.doesNotMatch(
  requestRoute,
  /currentStage\s*!==\s*['"]SCRIPT_APPROVED['"]/is,
  'HTTP request route must not block exact response-loss retries before the authoritative RPC',
);
assert.match(
  requestRoute,
  /client\.rpc\(['"]creator_request_voice_job['"]/is,
  'voice request replay authority must remain database authoritative',
);
assert.doesNotMatch(
  previewRoute,
  /createSignedUrl/is,
  'voice preview must never return a Storage bearer signed URL',
);
assert.match(
  previewRoute,
  /\.download\(path\)/is,
  'voice preview bytes must be fetched through authenticated Storage RLS',
);
assert.match(
  previewRoute,
  /cache-control['"]?\s*:\s*['"]private,\s*no-store/is,
  'voice preview must be non-cacheable',
);
assert.match(
  previewRoute,
  /currentPreviewPath[\s\S]*download\(path\)[\s\S]*currentPreviewPath/is,
  'preview must recheck current consent/artifact authority before returning bytes',
);

for (const fn of [
  'creator_request_voice_job',
  'creator_claim_mock_voice_job_b1',
  'creator_complete_mock_voice_job',
  'creator_request_voice_revision',
  'creator_claim_media_deletion',
  'creator_finish_media_deletion',
]) {
  assert.match(
    closure,
    new RegExp(`create or replace function public\\\\.${fn}\\\\([\\\\s\\\\S]*?security definer`, 'i'),
    `${fn} public gateway must be security definer while private implementation stays hidden`,
  );
}
assert.match(
  closure,
  /creator_hold_mock_voice_output_impl[\s\S]*status='held'|['"]held['"]/is,
  'worker output must be durably held before upload/completion',
);
assert.match(
  closure,
  /creator_bind_mock_voice_output_ledger[\s\S]*status='retained'/is,
  'successful artifact creation must bind the held object as retained',
);
assert.match(
  closure,
  /creator_queue_terminated_voice_output[\s\S]*new\.status in \('cancelled','failed'\)[\s\S]*status='queued'/is,
  'terminated voice jobs must queue held output for deletion',
);
assert.match(
  closure,
  /creator_reconcile_held_voice_output_impl/is,
  'response-loss/abandonment cleanup requires an authoritative reconciler',
);
assert.doesNotMatch(
  closure,
  /real_provider_execution_enabled\s*=\s*true|approved_for_runtime/is,
  'Codex closure must not enable real-provider execution',
);

const holdIndex = workerRuntime.indexOf('creator_hold_mock_voice_output');
const uploadIndex = workerRuntime.indexOf('client.upload_voice_object');
const completionIndex = workerRuntime.indexOf('creator_complete_mock_voice_job');
assert.ok(holdIndex >= 0 && uploadIndex > holdIndex && completionIndex > uploadIndex,
  'worker must hold output before upload and complete only after upload');
assert.match(
  workerRuntime,
  /creator_reconcile_held_voice_output/is,
  'worker must reconcile failed/ambiguous output completion',
);
assert.doesNotMatch(
  workerRuntime,
  /\b(import|from)\s+(chatterbox|qwen|cosyvoice|openvoice|torch|transformers|huggingface_hub)\b/i,
  'B1 closure must not import real TTS runtime packages',
);

console.log('M3 B1 concurrency and Codex review closure guardrails: PASS');
