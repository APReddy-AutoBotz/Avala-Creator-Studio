import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const foundation = readFileSync(new URL('../migrations/20260813164153_m3b1_voice_output_foundation.sql', import.meta.url), 'utf8');
const deletionIndex = readFileSync(new URL('../migrations/20260813165624_m3b1_media_deletion_owner_status_index.sql', import.meta.url), 'utf8');
const requestStage = readFileSync(new URL('../migrations/20260813165000_m3b1_voice_request_stage.sql', import.meta.url), 'utf8');
const claim = readFileSync(new URL('../migrations/20260813165001_m3b1_voice_claim_capability.sql', import.meta.url), 'utf8');
const completion = readFileSync(new URL('../migrations/20260813165002_m3b1_voice_completion.sql', import.meta.url), 'utf8');
const reviewRetention = readFileSync(new URL('../migrations/20260813165003_m3b1_voice_review_and_retention.sql', import.meta.url), 'utf8');
const workflow = readFileSync(new URL('../../packages/contracts/src/workflow.ts', import.meta.url), 'utf8');
const runtimeContracts = readFileSync(new URL('../../packages/contracts/src/voice-runtime.ts', import.meta.url), 'utf8');
const workerVoice = readFileSync(new URL('../../services/render-worker/src/creator_worker/voice.py', import.meta.url), 'utf8');

assert.match(foundation,/creator-voice-output','creator-voice-output',false/is,'voice output bucket must be private');
assert.match(foundation,/creator_media_deletions/is,'B1 requires a durable deletion ledger');
assert.match(foundation,/creator_voice_output_owner_select/is,'private voice output must be owner-readable only');
assert.match(foundation,/a\.stale_at is null/is,'stale audio must not remain preview-authoritative');
assert.doesNotMatch(foundation,/for insert to authenticated[\s\S]*creator-voice-output/is,'browser must not upload voice output');
assert.doesNotMatch(foundation,/delete from storage\.objects/is,'SQL must not bypass the Storage API');
assert.doesNotMatch(foundation,/create index creator_media_deletions_owner_status_idx/is,'foundation history must match the applied live migration');
assert.match(deletionIndex,/create index creator_media_deletions_owner_status_idx[\s\S]*creator_media_deletions\(owner_id,status,requested_at\)/is,'deletion index must be tracked as its own live migration');

assert.match(requestStage,/creator_request_voice_job_impl/is,'B1 must retain Phase A request authority');
assert.match(requestStage,/current_stage='VOICE_GENERATING'/is,'accepted mock request must enter VOICE_GENERATING');
assert.match(requestStage,/p_provider_id='mock'/is,'only mock request may enter the B1 generation stage');
assert.doesNotMatch(requestStage,/PROVIDER_RESEARCH_ONLY[\s\S]*current_stage='VOICE_GENERATING'/is,'real-provider denial must not advance stage');

assert.match(claim,/auth\.role\(\)<>'service_role'/is,'browser roles cannot claim B1 jobs');
assert.match(claim,/current_stage<>'VOICE_GENERATING'/is,'B1 claim must bind the expected stage');
assert.match(claim,/voice_job_leases/is,'claim response-loss recovery needs a private lease capability');
assert.match(claim,/v_job\.status='leased'[\s\S]*leased_until>now\(\)[\s\S]*replayed',true/is,'active lease replay must recover the same capability');
assert.match(claim,/leased_until<=now\(\)[\s\S]*v_reclaimed:=true/is,'expired lease must be reclaimable');
assert.match(claim,/provider_id=v_job\.provider for share/is,'claim must lock provider authority');
assert.match(claim,/singleton=true for share/is,'claim must lock runtime policy authority');
assert.match(claim,/status='validated'/is,'claim must revalidate captured samples');
assert.match(claim,/decision='approved'[\s\S]*invalidated_at is null/is,'claim must revalidate the current human-approved script');

assert.match(completion,/creator_complete_mock_voice_job_impl/is,'B1 requires trusted completion authority');
assert.match(completion,/auth\.role\(\)<>'service_role'/is,'browser cannot complete voice jobs');
assert.match(completion,/voice_completion_claims/is,'completion must support response-loss replay');
assert.match(completion,/VOICE_LEASE_CAPABILITY_INVALID/is,'completion must bind the private lease capability');
assert.match(completion,/storage\.objects/is,'completion must bind an existing private output object');
assert.match(completion,/user_metadata->>'sha256'/is,'completion must bind Storage metadata to output digest');
assert.match(completion,/user_metadata->>'job_id'/is,'completion must bind Storage metadata to job authority');
assert.match(completion,/current_stage<>'VOICE_GENERATING'/is,'completion must fail if stage moved');
assert.match(completion,/current_stage='VOICE_REVIEW'/is,'trusted completion may move only to VOICE_REVIEW');
assert.match(completion,/'kind','voice'|,'voice',v_version/is,'completion must create an immutable voice artifact');
assert.match(completion,/'costMicrounits',0/is,'mock completion must remain zero-cost');
assert.match(completion,/REAL_PROVIDER_EXECUTION_BLOCKED_PHASE_A/is,'real providers remain blocked in B1');
assert.doesNotMatch(completion,/insert into public\.creator_reviews/is,'worker completion must never approve');

assert.match(reviewRetention,/creator_enforce_voice_human_approval/is,'voice approval needs a human-only defense');
assert.match(reviewRetention,/new\.reviewer_id<>auth\.uid\(\)/is,'reviewer identity must derive from the authenticated human');
assert.match(reviewRetention,/ACTIVE_VOICE_PROFILE_REQUIRED/is,'revoked profiles cannot be approved');
assert.match(reviewRetention,/kind in \('voice','avatar','edit','final'\)/is,'voice revision must stale the voice artifact and downstream work');
assert.match(reviewRetention,/current_stage='SCRIPT_APPROVED'/is,'voice revision must return to approved script authority');
assert.match(reviewRetention,/PRIVATE_MEDIA_DELETE_REQUIRED/is,'deletion completion must prove Storage deletion happened');
assert.doesNotMatch(reviewRetention,/delete from storage\.objects/is,'deletion worker SQL must not bypass Storage API');

assert.match(workflow,/from:\s*'VOICE_REVIEW'\s*,\s*event:\s*'APPROVE_VOICE'\s*,\s*to:\s*'VOICE_APPROVED'\s*,\s*actor:\s*'human'/is,'voice approval remains human-only');
assert.match(runtimeContracts,/SYNTHETIC MOCK VOICE DRAFT/,'B1 contracts require visible synthetic labelling');
assert.match(runtimeContracts,/actualCostMicrounits: z\.literal\(0\)/,'B1 completion contract requires zero cost');
assert.match(workerVoice,/create_synthetic_wav_fixture/is,'worker must provide a deterministic synthetic WAV test fixture');
assert.doesNotMatch(workerVoice,/\b(import|from)\s+(chatterbox|qwen|cosyvoice|openvoice|torch|transformers|huggingface_hub)\b/i,'B1 must not import a real TTS runtime');

console.log('M3 B1 static guardrails: PASS');
