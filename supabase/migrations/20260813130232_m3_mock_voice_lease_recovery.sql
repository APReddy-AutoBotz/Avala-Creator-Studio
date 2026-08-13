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

  select * into v_provider from creator_private.voice_provider_catalog where provider_id=v_job.provider;
  if not found then raise exception 'VOICE_PROVIDER_NOT_FOUND'; end if;
  select * into v_policy from creator_private.voice_runtime_policy where singleton=true;
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
