import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const schema = readFileSync(new URL('../schema.sql', import.meta.url), 'utf8');
const extension = readFileSync(new URL('../m2_identity_extensions.sql', import.meta.url), 'utf8');
const combined = `${schema}\n${extension}`;

assert.match(combined, /creator_create_consent_profile/is, 'M2 requires consent-profile creation authority');
assert.match(combined, /creator_register_identity_sample/is, 'M2 requires private sample registration');
assert.match(combined, /pending_validation/is, 'new samples must start pending validation');
assert.match(combined, /VALIDATED_SAMPLE_REQUIRED/is, 'profile activation requires trusted validation');
assert.match(combined, /creator_revoke_consent_profile/is, 'M2 requires revocation');
assert.match(combined, /creator_delete_consent_profile/is, 'M2 requires deletion');
assert.match(combined, /object_path\s*=\s*null/is, 'deletion must clear active private object path metadata');
assert.match(combined, /sha256\s*=\s*null/is, 'deletion must clear active sample hash metadata');
assert.match(combined, /creator_record_identity_sample_validation/is, 'trusted validation boundary must exist');
assert.match(combined, /revoke all on function public\.creator_record_identity_sample_validation[^;]+authenticated/is, 'browser roles cannot validate samples');
assert.match(combined, /CONSENT_REVOKED/is, 'revocation cancels active work');
assert.match(combined, /PROFILE_DELETED/is, 'deletion cancels active work');
assert.doesNotMatch(combined, /getPublicUrl/i, 'M2 must not introduce public media URLs');

console.log('M2 consent/storage static guardrails: PASS');
