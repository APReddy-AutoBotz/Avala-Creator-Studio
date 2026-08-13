import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const authority = readFileSync(new URL('../migrations/20260813124538_m3_voice_phase_a_authority.sql', import.meta.url), 'utf8');
const constraints = readFileSync(new URL('../migrations/20260813124552_m3_voice_phase_a_constraints.sql', import.meta.url), 'utf8');
const replayHardening = readFileSync(new URL('../migrations/20260813125246_m3_voice_replay_owner_scope_hardening.sql', import.meta.url), 'utf8');
const leaseRecovery = readFileSync(new URL('../migrations/20260813130232_m3_mock_voice_lease_recovery.sql', import.meta.url), 'utf8');
const finalConcurrency = readFileSync(new URL('../migrations/20260813150724_m3_final_review_concurrency_closure.sql', import.meta.url), 'utf8');
const voiceContracts = readFileSync(new URL('../../packages/contracts/src/voice.ts', import.meta.url), 'utf8');
const workerVoice = readFileSync(new URL('../../services/render-worker/src/creator_worker/voice.py', import.meta.url), 'utf8');

assert.match(authority,/voice_provider_catalog/is,'M3 requires a private provider catalog');
assert.match(authority,/voice_runtime_policy/is,'M3 requires server-side runtime mode authority');
assert.match(authority,/real_provider_execution_enabled boolean not null default false check \(real_provider_execution_enabled = false\)/is,'Phase A must make real runtime structurally disabled');
assert.match(authority,/provider_id = 'mock'[\s\S]*approval_state = 'research_only'[\s\S]*install_state = 'not_installed'[\s\S]*execution_enabled = false[\s\S]*max_cost_microunits = 0/is,'all real provider rows must be constrained research-only/not-installed/disabled/zero-cost');
assert.match(authority,/'chatterbox_multilingual_v3'.*'champion'/is,'Chatterbox V3 must be the evaluation champion');
assert.match(authority,/'qwen3_tts_12hz_0_6b_base'.*'fallback'/is,'Qwen 0.6B Base must be the fallback');
assert.match(authority,/'fun_cosyvoice3_0_5b_2512'.*'specialist'/is,'CosyVoice3 must remain a specialist benchmark');
assert.match(authority,/'openvoice_v2'.*'reference'/is,'OpenVoice V2 must remain a lightweight reference');

assert.match(authority,/creator_request_voice_job_impl/is,'M3 requires caller-scoped voice job authority');
assert.match(authority,/v_actor uuid := auth\.uid\(\)/is,'voice job ownership must derive from auth.uid()');
assert.match(authority,/profile_kind = 'voice'[\s\S]*for key share/is,'voice jobs must lock and validate an owned voice profile first');
assert.match(authority,/current_stage <> 'SCRIPT_APPROVED'/is,'voice jobs require SCRIPT_APPROVED');
assert.match(authority,/LATEST_ARTIFACT_REQUIRED/is,'voice jobs must bind the latest script artifact');
assert.match(authority,/decision = 'approved'.*invalidated_at is null/is,'voice jobs require a current human approval');
assert.match(authority,/status = 'validated'/is,'voice jobs require validated identity samples');
assert.match(authority,/VOICE_JOB_DENIED/is,'denied real-provider attempts must be audit-evidenced without creating jobs');
assert.match(authority,/PROVIDER_RESEARCH_ONLY/is,'research-only providers must fail closed');
assert.match(authority,/MOCK_RUNTIME_MODE_REQUIRED/is,'mock job creation must require server-authoritative test/demo mode');
assert.match(authority,/MOCK_PROVIDER_MUST_BE_ZERO_COST/is,'Phase A mock jobs must be zero cost');
assert.match(authority,/on conflict \(project_id,idempotency_key\) do nothing/is,'voice job creation must recover concurrent exact retries');
assert.match(authority,/request_fingerprint/is,'voice job replay must bind exact request authority');
assert.match(constraints,/voice_sample_ids is not null.*cardinality\(voice_sample_ids\) > 0/is,'voice jobs must bind at least one sample id');
assert.match(replayHardening,/creator_jobs[\s\S]*requested_by = v_actor/is,'existing voice-job replay must be scoped to the authenticated owner');
assert.match(replayHardening,/creator_audit_events[\s\S]*owner_id = v_actor[\s\S]*idempotency_key = p_idempotency_key/is,'denied-audit replay must be scoped to the authenticated owner');
assert.match(replayHardening,/project_id=p_project_id and idempotency_key=p_idempotency_key and requested_by=v_actor/is,'concurrent job replay recovery must stay owner scoped');

assert.match(authority,/creator_claim_mock_voice_job_impl/is,'M3 requires a trusted worker claim boundary');
assert.match(authority,/revoke all on function public\.creator_claim_mock_voice_job\(uuid,integer\) from public, anon, authenticated/is,'browser roles cannot claim voice jobs');
assert.match(authority,/grant execute on function public\.creator_claim_mock_voice_job\(uuid,integer\) to service_role/is,'only service_role can claim mock voice jobs');
assert.match(leaseRecovery,/select \* into v_profile[\s\S]*for key share[\s\S]*select \* into v_project[\s\S]*for update[\s\S]*select \* into v_job[\s\S]*for update/is,'worker claim and lease recovery lock order must stay profile -> project -> job');
assert.match(leaseRecovery,/v_job\.status = 'queued'[\s\S]*v_job\.status = 'leased' and v_job\.leased_until is not null and v_job\.leased_until <= now\(\)/is,'worker must allow queued claims and expired-lease recovery only');
assert.match(leaseRecovery,/raise exception 'VOICE_JOB_NOT_CLAIMABLE'/is,'active/nonrecoverable leases must fail closed');
assert.match(leaseRecovery,/reclaimed_expired_lease',v_reclaimed/is,'lease recovery must be audit-labelled');
assert.match(leaseRecovery,/attempt_count=attempt_count\+1/is,'lease recovery must increment the worker attempt counter');
assert.doesNotMatch(leaseRecovery,/update public\.creator_projects set current_stage=/i,'lease recovery must not advance workflow state');
assert.doesNotMatch(leaseRecovery,/insert into public\.creator_artifacts/is,'lease recovery must not create a voice artifact');

assert.match(finalConcurrency,/voice_provider_catalog[\s\S]*for share/is,'request/claim provider authority must be row locked');
assert.match(finalConcurrency,/voice_runtime_policy[\s\S]*for share/is,'runtime kill-switch authority must be row locked');
assert.match(finalConcurrency,/on conflict do nothing[\s\S]*returning \* into v_audit[\s\S]*if found[\s\S]*'replayed',false[\s\S]*'replayed',true/is,'denial conflict recovery must distinguish a new denial from an exact replay');
assert.match(finalConcurrency,/requested_by = v_actor/is,'final request replay must remain owner scoped');
assert.match(finalConcurrency,/v_job\.status = 'leased'[\s\S]*v_job\.leased_until is not null[\s\S]*v_job\.leased_until <= now\(\)/is,'final worker claim must retain expired-lease recovery');
assert.doesNotMatch(finalConcurrency,/update public\.creator_projects set current_stage=/i,'final concurrency closure must not advance workflow state');
assert.doesNotMatch(finalConcurrency,/insert into public\.creator_artifacts/is,'final concurrency closure must not create media artifacts');

assert.match(voiceContracts,/\[SYNTHETIC MOCK VOICE DRAFT\]/,'TypeScript mock output must be visibly synthetic');
assert.match(voiceContracts,/mediaCreated: z\.literal\(false\)/,'TypeScript mock adapter must not create media');
assert.match(voiceContracts,/approvalState: 'research_only'/,'real provider contract defaults must remain research-only');
assert.match(workerVoice,/SYNTHETIC_VOICE_LABEL = "\[SYNTHETIC MOCK VOICE DRAFT\]"/,'Python mock output must be visibly synthetic');
assert.match(workerVoice,/media_created=False/,'Python mock adapter must not create media');
assert.match(workerVoice,/REAL_PROVIDER_EXECUTION_BLOCKED_PHASE_A/,'worker must fail closed for real providers');
assert.doesNotMatch(workerVoice,/\b(import|from)\s+(chatterbox|qwen|cosyvoice|openvoice|torch|transformers|huggingface_hub)\b/i,'Phase A must not import a real model/runtime dependency');

assert.doesNotMatch(authority,/signed_url|storage_path|object_path.*details/is,'voice denial/job audit must not log private media paths or signed URLs');
assert.doesNotMatch(authority,/START_VOICE|VOICE_READY/,'M3 Phase A migration must not enable real voice workflow transitions');

console.log('M3 voice Phase A static guardrails: PASS');
