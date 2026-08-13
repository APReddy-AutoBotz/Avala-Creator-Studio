import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';

const migrationsDir=new URL('../migrations/',import.meta.url);
const combined=readdirSync(migrationsDir).filter(name=>name.endsWith('.sql')).sort()
  .map(name=>readFileSync(new URL(name,migrationsDir),'utf8')).join('\n');

assert.match(combined,/creator_private\.consent_statements/is,'consent must be bound to server-known evidence');
assert.match(combined,/0b8f3516bacfbd4275c6f950e5ce9625f914db9916b77f08cf2264f28329d19b/i,'voice consent digest must be governed');
assert.match(combined,/312d2299b85694391156bdc63daf9a21ea699b8ea4942d9be708185b22a194fa/i,'avatar consent digest must be governed');
assert.match(combined,/creator_upload_intents/is,'prepared uploads must be tracked');
assert.match(combined,/creator_prepare_identity_upload/is,'server-authoritative upload preparation must exist');
assert.match(combined,/UPLOAD_INTENT_REQUIRED/is,'registration must bind to a prepared intent');
assert.match(combined,/PRIVATE_OBJECT_NOT_FOUND/is,'physical object must exist before registration or validation');
assert.match(combined,/status='prepared'.*expires_at>now\(\)/is,'Storage insert must require a live prepared intent');
assert.match(combined,/p\.status in \('draft','active'\).*p\.revoked_at is null.*p\.deleted_at is null/is,'Storage insert must require current consent profile');
assert.match(combined,/creator_private\.operation_claims/is,'destructive idempotency keys must be claimed before mutation');
assert.match(combined,/IDEMPOTENCY_KEY_REUSED/is,'cross-target key reuse must be rejected');
assert.match(combined,/creator_invalidate_profile_dependents/is,'revocation/deletion require full downstream invalidation');
assert.match(combined,/creator_reviews r set invalidated_at/is,'downstream reviews must be invalidated');
assert.match(combined,/job_type in \('voice','avatar','edit','final'\)/is,'voice revocation must cancel downstream jobs');
assert.match(combined,/then 'SCRIPT_APPROVED'/is,'voice revocation must rewind project stage');
assert.match(combined,/then 'VOICE_APPROVED'/is,'avatar revocation must rewind project stage');
assert.match(combined,/object_path=null.*sha256=null/is,'deletion must clear sensitive sample metadata');
assert.match(combined,/PRIVATE_MEDIA_DELETE_REQUIRED/is,'database deletion must fail closed while tracked media exists');
assert.doesNotMatch(combined,/getPublicUrl/i,'M2 must not introduce public media URLs');
console.log('M2 consent/storage static guardrails: PASS');
