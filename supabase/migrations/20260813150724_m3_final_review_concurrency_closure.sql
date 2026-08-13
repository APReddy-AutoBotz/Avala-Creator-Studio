create or replace function creator_private.creator_request_voice_job_impl(
  p_project_id uuid,
  p_script_artifact_id uuid,
  p_script_sha256 text,
  p_profile_id uuid,
  p_provider_id text,
  p_voice_manifest_sha256 text,
  p_generation_mode text,
  p_max_cost_microunits bigint,
  p_human_triggered boolean,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_profile public.creator_consent_profiles;
  v_project public.creator_projects;
  v_script public.creator_artifacts;
  v_provider creator_private.voice_provider_catalog;
  v_policy creator_private.voice_runtime_policy;
  v_job public.creator_jobs;
  v_audit public.creator_audit_events;
  v_sample_ids uuid[];
  v_fingerprint text;
  v_denial text;
begin
  if v_actor is null then raise exception 'UNAUTHORIZED'; end if;
  if p_idempotency_key is null then raise exception 'IDEMPOTENCY_KEY_REQUIRED'; end if;
  if p_human_triggered is distinct from true then raise exception 'HUMAN_TRIGGER_REQUIRED'; end if;
  if p_script_sha256 is null or p_script_sha256 !~ '^[a-f0-9]{64}$' then raise exception 'SHA256_INVALID'; end if;
  if p_voice_manifest_sha256 is null or p_voice_manifest_sha256 !~ '^[a-f0-9]{64}$' then raise exception 'VOICE_MANIFEST_DIGEST_INVALID'; end if;
  if p_generation_mode not in ('synthetic_mock','real_provider') then raise exception 'VOICE_GENERATION_MODE_INVALID'; end if;
  if p_max_cost_microunits is null or p_max_cost_microunits < 0 then raise exception 'VOICE_BUDGET_INVALID'; end if;

  v_fingerprint := creator_private.voice_request_fingerprint(
    p_project_id,p_script_artifact_id,p_script_sha256,p_profile_id,p_provider_id,
    p_voice_manifest_sha256,p_generation_mode,p_max_cost_microunits
  );

  select * into v_job from public.creator_jobs
  where project_id = p_project_id and idempotency_key = p_idempotency_key and requested_by = v_actor;
  if found then
    if v_job.job_type <> 'voice' or v_job.request_fingerprint is distinct from v_fingerprint then
      raise exception 'IDEMPOTENCY_KEY_REUSED';
    end if;
    return jsonb_build_object('accepted',true,'replayed',true,'job',to_jsonb(v_job));
  end if;

  select * into v_audit from public.creator_audit_events
  where project_id = p_project_id and owner_id = v_actor and idempotency_key = p_idempotency_key;
  if found then
    if v_audit.event_code = 'VOICE_JOB_DENIED'
      and v_audit.details->>'request_fingerprint' = v_fingerprint
    then
      return jsonb_build_object('accepted',false,'replayed',true,'code',v_audit.details->>'denial_code');
    end if;
    raise exception 'IDEMPOTENCY_KEY_REUSED';
  end if;

  select * into v_profile from public.creator_consent_profiles
  where id = p_profile_id and owner_id = v_actor and profile_kind = 'voice'
  for key share;
  if not found or v_profile.status <> 'active' or v_profile.revoked_at is not null or v_profile.deleted_at is not null then
    raise exception 'ACTIVE_VOICE_PROFILE_REQUIRED';
  end if;

  select * into v_project from public.creator_projects
  where id = p_project_id and owner_id = v_actor
  for update;
  if not found then raise exception 'PROJECT_NOT_FOUND'; end if;
  if v_project.current_stage <> 'SCRIPT_APPROVED' then raise exception 'SCRIPT_APPROVAL_REQUIRED'; end if;

  select * into v_script from public.creator_artifacts
  where id = p_script_artifact_id and project_id = p_project_id and kind = 'script'
    and sha256 = p_script_sha256 and stale_at is null;
  if not found then raise exception 'ARTIFACT_BINDING_INVALID'; end if;
  if v_script.version_number <> (
    select max(version_number) from public.creator_artifacts
    where project_id = p_project_id and kind = 'script' and stale_at is null
  ) then raise exception 'LATEST_ARTIFACT_REQUIRED'; end if;
  if not exists (
    select 1 from public.creator_reviews r
    where r.project_id = p_project_id and r.artifact_id = v_script.id
      and r.reviewer_id = v_actor and r.decision = 'approved' and r.invalidated_at is null
      and r.artifact_version = v_script.version_number and r.artifact_sha256 = v_script.sha256
  ) then raise exception 'SCRIPT_APPROVAL_REQUIRED'; end if;

  select array_agg(id order by id) into v_sample_ids
  from public.creator_identity_samples
  where owner_id = v_actor and profile_id = p_profile_id and status = 'validated' and deleted_at is null;
  if coalesce(cardinality(v_sample_ids),0) < 1 then raise exception 'VALIDATED_SAMPLE_REQUIRED'; end if;

  select * into v_provider from creator_private.voice_provider_catalog
  where provider_id = p_provider_id
  for share;
  if not found then raise exception 'VOICE_PROVIDER_NOT_FOUND'; end if;
  select * into v_policy from creator_private.voice_runtime_policy
  where singleton = true
  for share;
  if not found then raise exception 'VOICE_RUNTIME_POLICY_UNAVAILABLE'; end if;

  if p_provider_id <> 'mock' then
    v_denial := case
      when v_provider.approval_state = 'research_only' then 'PROVIDER_RESEARCH_ONLY'
      when v_provider.install_state <> 'installed' then 'PROVIDER_NOT_INSTALLED'
      when not v_provider.execution_enabled then 'PROVIDER_EXECUTION_DISABLED'
      else 'REAL_PROVIDER_EXECUTION_BLOCKED_PHASE_A' end;
  elsif p_generation_mode <> 'synthetic_mock' then
    v_denial := 'MOCK_GENERATION_MODE_REQUIRED';
  elsif v_policy.mode not in ('test','demo') or not v_policy.mock_job_creation_enabled then
    v_denial := 'MOCK_RUNTIME_MODE_REQUIRED';
  elsif v_provider.approval_state <> 'approved_for_test' or v_provider.install_state <> 'built_in' or not v_provider.execution_enabled then
    v_denial := 'MOCK_PROVIDER_NOT_APPROVED';
  elsif p_max_cost_microunits <> 0 or v_provider.max_cost_microunits <> 0 then
    v_denial := 'MOCK_PROVIDER_MUST_BE_ZERO_COST';
  end if;

  if v_denial is not null then
    insert into public.creator_audit_events(
      project_id,owner_id,actor_id,actor_kind,event_code,profile_id,idempotency_key,details
    ) values (
      p_project_id,v_actor,v_actor,'human','VOICE_JOB_DENIED',p_profile_id,p_idempotency_key,
      jsonb_build_object('provider_id',p_provider_id,'denial_code',v_denial,'request_fingerprint',v_fingerprint)
    ) on conflict do nothing
    returning * into v_audit;

    if found then
      return jsonb_build_object('accepted',false,'replayed',false,'code',v_denial);
    end if;

    select * into v_audit from public.creator_audit_events
    where project_id=p_project_id and owner_id=v_actor and idempotency_key=p_idempotency_key;
    if not found or v_audit.event_code <> 'VOICE_JOB_DENIED'
      or v_audit.details->>'request_fingerprint' is distinct from v_fingerprint
    then raise exception 'IDEMPOTENCY_KEY_REUSED'; end if;
    return jsonb_build_object('accepted',false,'replayed',true,'code',v_audit.details->>'denial_code');
  end if;

  insert into public.creator_jobs(
    project_id,identity_profile_id,job_type,status,idempotency_key,input_artifact_id,provider,
    generation_mode,requested_by,voice_manifest_sha256,voice_sample_ids,provider_model_id,
    provider_model_revision,provider_verified_at,provider_approval_state,max_cost_microunits,
    estimated_cost_microunits,request_fingerprint
  ) values (
    p_project_id,p_profile_id,'voice','queued',p_idempotency_key,p_script_artifact_id,p_provider_id,
    p_generation_mode,v_actor,p_voice_manifest_sha256,v_sample_ids,v_provider.upstream_model_id,
    v_provider.model_revision,v_provider.verified_at,v_provider.approval_state,p_max_cost_microunits,
    0,v_fingerprint
  ) on conflict (project_id,idempotency_key) do nothing
  returning * into v_job;

  if not found then
    select * into v_job from public.creator_jobs
    where project_id=p_project_id and idempotency_key=p_idempotency_key and requested_by=v_actor;
    if not found or v_job.job_type <> 'voice' or v_job.request_fingerprint is distinct from v_fingerprint then
      raise exception 'IDEMPOTENCY_KEY_REUSED'; end if;
    return jsonb_build_object('accepted',true,'replayed',true,'job',to_jsonb(v_job));
  end if;

  insert into public.creator_audit_events(
    project_id,owner_id,actor_id,actor_kind,event_code,profile_id,idempotency_key,details
  ) values (
    p_project_id,v_actor,v_actor,'human','VOICE_JOB_QUEUED_MOCK',p_profile_id,p_idempotency_key,
    jsonb_build_object('job_id',v_job.id,'provider_id',p_provider_id,'generation_mode',p_generation_mode,
                       'script_artifact_id',p_script_artifact_id,'script_sha256',p_script_sha256,
                       'voice_manifest_sha256',p_voice_manifest_sha256,'request_fingerprint',v_fingerprint,
                       'max_cost_microunits',p_max_cost_microunits)
  );
  return jsonb_build_object('accepted',true,'replayed',false,'job',to_jsonb(v_job));
end;
$$;

create or replace function creator_private.creator_claim_mock_voice_job_impl(
  p_job_id uuid,p_lease_seconds integer default 60
) returns public.creator_jobs
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hint public.creator_jobs;
  v_profile public.creator_consent_profiles;
  v_project public.creator_projects;
  v_job public.creator_jobs;
  v_script public.creator_artifacts;
  v_provider creator_private.voice_provider_catalog;
  v_policy creator_private.voice_runtime_policy;
  v_reclaimed boolean := false;
begin
  if p_lease_seconds is null or p_lease_seconds < 10 or p_lease_seconds > 600 then raise exception 'VOICE_LEASE_INVALID'; end if;

  select * into v_hint from public.creator_jobs where id=p_job_id;
  if not found then raise exception 'VOICE_JOB_NOT_FOUND'; end if;
  if v_hint.job_type <> 'voice' then raise exception 'VOICE_JOB_NOT_FOUND'; end if;

  select * into v_profile from public.creator_consent_profiles
  where id=v_hint.identity_profile_id
  for key share;
  if not found or v_profile.profile_kind <> 'voice' or v_profile.status <> 'active'
    or v_profile.revoked_at is not null or v_profile.deleted_at is not null
  then raise exception 'ACTIVE_VOICE_PROFILE_REQUIRED'; end if;

  select * into v_project from public.creator_projects where id=v_hint.project_id for update;
  if not found then raise exception 'PROJECT_NOT_FOUND'; end if;

  select * into v_job from public.creator_jobs where id=p_job_id for update;
  if not found then raise exception 'VOICE_JOB_NOT_CLAIMABLE'; end if;
  if v_job.status = 'queued' then
    v_reclaimed := false;
  elsif v_job.status = 'leased' and v_job.leased_until is not null and v_job.leased_until <= now() then
    v_reclaimed := true;
  else
    raise exception 'VOICE_JOB_NOT_CLAIMABLE';
  end if;
  if v_job.identity_profile_id is distinct from v_profile.id or v_job.project_id is distinct from v_project.id then
    raise exception 'VOICE_JOB_AUTHORITY_MISMATCH'; end if;
  if v_project.owner_id is distinct from v_profile.owner_id or v_job.requested_by is distinct from v_project.owner_id then
    raise exception 'VOICE_JOB_AUTHORITY_MISMATCH'; end if;
  if v_project.current_stage <> 'SCRIPT_APPROVED' then raise exception 'SCRIPT_APPROVAL_REQUIRED'; end if;

  select * into v_script from public.creator_artifacts
  where id=v_job.input_artifact_id and project_id=v_job.project_id and kind='script' and stale_at is null;
  if not found then raise exception 'ARTIFACT_BINDING_INVALID'; end if;
  if v_script.version_number <> (
    select max(version_number) from public.creator_artifacts
    where project_id=v_job.project_id and kind='script' and stale_at is null
  ) then raise exception 'LATEST_ARTIFACT_REQUIRED'; end if;
  if not exists (
    select 1 from public.creator_reviews r
    where r.project_id=v_job.project_id and r.artifact_id=v_script.id and r.reviewer_id=v_project.owner_id
      and r.decision='approved' and r.invalidated_at is null
      and r.artifact_version=v_script.version_number and r.artifact_sha256=v_script.sha256
  ) then raise exception 'SCRIPT_APPROVAL_REQUIRED'; end if;

  if not exists (
    select 1 from public.creator_identity_samples s
    where s.owner_id=v_profile.owner_id and s.profile_id=v_profile.id and s.status='validated'
      and s.deleted_at is null and s.id = any(v_job.voice_sample_ids)
  ) then raise exception 'VALIDATED_SAMPLE_REQUIRED'; end if;

  select * into v_provider from creator_private.voice_provider_catalog
  where provider_id=v_job.provider
  for share;
  if not found then raise exception 'VOICE_PROVIDER_NOT_FOUND'; end if;
  select * into v_policy from creator_private.voice_runtime_policy
  where singleton=true
  for share;
  if not found then raise exception 'VOICE_RUNTIME_POLICY_UNAVAILABLE'; end if;
  if v_job.provider <> 'mock' or v_job.generation_mode <> 'synthetic_mock' then raise exception 'REAL_PROVIDER_EXECUTION_BLOCKED_PHASE_A'; end if;
  if v_policy.mode not in ('test','demo') or not v_policy.mock_job_creation_enabled then raise exception 'MOCK_RUNTIME_MODE_REQUIRED'; end if;
  if v_provider.approval_state <> 'approved_for_test' or v_provider.install_state <> 'built_in' or not v_provider.execution_enabled then
    raise exception 'MOCK_PROVIDER_NOT_APPROVED'; end if;
  if v_job.max_cost_microunits <> 0 or v_job.estimated_cost_microunits <> 0 or v_provider.max_cost_microunits <> 0 then
    raise exception 'MOCK_PROVIDER_MUST_BE_ZERO_COST'; end if;

  update public.creator_jobs
  set status='leased',attempt_count=attempt_count+1,leased_until=now()+make_interval(secs=>p_lease_seconds),updated_at=now()
  where id=p_job_id returning * into v_job;

  insert into public.creator_audit_events(project_id,owner_id,actor_kind,event_code,profile_id,details)
  values (v_job.project_id,v_project.owner_id,'worker','VOICE_JOB_CLAIMED_MOCK',v_profile.id,
          jsonb_build_object('job_id',v_job.id,'provider_id','mock','generation_mode','synthetic_mock',
                             'voice_manifest_sha256',v_job.voice_manifest_sha256,'reclaimed_expired_lease',v_reclaimed));
  return v_job;
end;
$$;
