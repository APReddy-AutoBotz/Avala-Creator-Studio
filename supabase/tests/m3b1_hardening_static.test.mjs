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

console.log('M3 B1 concurrency hardening guardrails: PASS');