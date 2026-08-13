import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const authority = readFileSync(new URL('../migrations/20260813124538_m3_voice_phase_a_authority.sql', import.meta.url), 'utf8');
const constraints = readFileSync(new URL('../migrations/20260813124552_m3_voice_phase_a_constraints.sql', import.meta.url), 'utf8');
const replayHardening = readFileSync(new URL('../migrations/20260813125246_m3_voice_replay_owner_scope_hardening.sql', import.meta.url), 'utf8');
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
assert.match(authority,/select \* into v_profile[\s\S]*for key share[\s\S]*select \* into v_project[\s\S]*for update[\s\S]*select \* into v_job[\s\S]*for update/is,'worker claim lock order must be profile -> project -> job');
assert.match(authority,/revoke all on function public\.creator_claim_mock_voice_job\(uuid,integer\) from public, anon, authenticated/is,'browser roles cannot claim voice jobs');
assert.match(authority,/grant execute on function public\.creator_claim_mock_voice_job\(uuid,integer\) to service_role/is,'only service_role can claim mock voice jobs');
assert.doesNotMatch(authority,/update public\.creator_projects set current_stage='VOICE_GENERATING'/i,'Phase A must not expose a real voice workflow transition');
assert.doesNotMatch(authority,/insert into public\.creator_artifacts[\s\S]*kind[^;]*'voice'/i,'Phase A claim must not create a real voice artifact');

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
