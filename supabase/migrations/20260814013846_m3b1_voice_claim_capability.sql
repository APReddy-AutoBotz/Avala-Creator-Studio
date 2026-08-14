create or replace function creator_private.creator_claim_mock_voice_job_b1_impl(
  p_job_id uuid,p_lease_seconds integer default 60
) returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  v_hint public.creator_jobs;
  v_profile public.creator_consent_profiles;
  v_project public.creator_projects;
  v_job public.creator_jobs;
  v_script public.creator_artifacts;
  v_provider creator_private.voice_provider_catalog;
  v_policy creator_private.voice_runtime_policy;
  v_lease creator_private.voice_job_leases;
  v_capability text;
  v_reclaimed boolean:=false;
  v_new_until timestamptz;
begin
  if auth.role()<>'service_role' then raise exception 'WORKER_AUTHORITY_REQUIRED'; end if;
  if p_lease_seconds is null or p_lease_seconds<10 or p_lease_seconds>600 then raise exception 'VOICE_LEASE_INVALID'; end if;

  select * into v_hint from public.creator_jobs where id=p_job_id;
  if not found or v_hint.job_type<>'voice' then raise exception 'VOICE_JOB_NOT_FOUND'; end if;

  select * into v_profile from public.creator_consent_profiles
    where id=v_hint.identity_profile_id for key share;
  if not found or v_profile.profile_kind<>'voice' or v_profile.status<>'active'
     or v_profile.revoked_at is not null or v_profile.deleted_at is not null
     then raise exception 'ACTIVE_VOICE_PROFILE_REQUIRED'; end if;

  select * into v_project from public.creator_projects where id=v_hint.project_id for update;
  if not found then raise exception 'PROJECT_NOT_FOUND'; end if;
  select * into v_job from public.creator_jobs where id=p_job_id for update;
  if not found then raise exception 'VOICE_JOB_NOT_FOUND'; end if;
  if v_job.identity_profile_id is distinct from v_profile.id
     or v_job.project_id is distinct from v_project.id
     or v_project.owner_id is distinct from v_profile.owner_id
     or v_job.requested_by is distinct from v_project.owner_id
     then raise exception 'VOICE_JOB_AUTHORITY_MISMATCH'; end if;
  if v_project.current_stage<>'VOICE_GENERATING' then raise exception 'STAGE_CONFLICT'; end if;

  select * into v_lease from creator_private.voice_job_leases where job_id=p_job_id for update;
  if v_job.status='leased' and v_job.leased_until is not null and v_job.leased_until>now() then
    if not found or v_lease.leased_until is distinct from v_job.leased_until
       then raise exception 'VOICE_LEASE_STATE_INVALID'; end if;
    return jsonb_build_object('job',to_jsonb(v_job),'capability',v_lease.capability,
      'replayed',true,'reclaimed_expired_lease',false);
  end if;
  if v_job.status='leased' and v_job.leased_until is not null and v_job.leased_until<=now() then
    v_reclaimed:=true;
  elsif v_job.status<>'queued' then
    raise exception 'VOICE_JOB_NOT_CLAIMABLE';
  end if;

  select * into v_script from public.creator_artifacts
  where id=v_job.input_artifact_id and project_id=v_job.project_id and kind='script' and stale_at is null;
  if not found then raise exception 'ARTIFACT_BINDING_INVALID'; end if;
  if v_script.version_number<>(select max(version_number) from public.creator_artifacts
      where project_id=v_job.project_id and kind='script' and stale_at is null)
    then raise exception 'LATEST_ARTIFACT_REQUIRED'; end if;
  if not exists(
    select 1 from public.creator_reviews r
    where r.project_id=v_job.project_id and r.artifact_id=v_script.id
      and r.reviewer_id=v_project.owner_id and r.decision='approved' and r.invalidated_at is null
      and r.artifact_version=v_script.version_number and r.artifact_sha256=v_script.sha256
  ) then raise exception 'SCRIPT_APPROVAL_REQUIRED'; end if;
  if exists(
    select 1 from unnest(v_job.voice_sample_ids) sample_id
    where not exists(
      select 1 from public.creator_identity_samples s
      where s.id=sample_id and s.profile_id=v_profile.id and s.owner_id=v_profile.owner_id
        and s.status='validated' and s.deleted_at is null
    )
  ) then raise exception 'VALIDATED_SAMPLE_REQUIRED'; end if;

  select * into v_provider from creator_private.voice_provider_catalog
    where provider_id=v_job.provider for share;
  if not found then raise exception 'VOICE_PROVIDER_NOT_FOUND'; end if;
  select * into v_policy from creator_private.voice_runtime_policy
    where singleton=true for share;
  if not found then raise exception 'VOICE_RUNTIME_POLICY_UNAVAILABLE'; end if;
  if v_job.provider<>'mock' or v_job.generation_mode<>'synthetic_mock'
    then raise exception 'REAL_PROVIDER_EXECUTION_BLOCKED_PHASE_A'; end if;
  if v_policy.mode not in ('test','demo') or not v_policy.mock_job_creation_enabled
    then raise exception 'MOCK_RUNTIME_MODE_REQUIRED'; end if;
  if v_provider.approval_state<>'approved_for_test'
     or v_provider.install_state<>'built_in'
     or not v_provider.execution_enabled
    then raise exception 'MOCK_PROVIDER_NOT_APPROVED'; end if;
  if v_job.max_cost_microunits<>0
     or v_job.estimated_cost_microunits<>0
     or v_provider.max_cost_microunits<>0
    then raise exception 'MOCK_PROVIDER_MUST_BE_ZERO_COST'; end if;

  v_new_until:=now()+make_interval(secs=>p_lease_seconds);
  v_capability:=encode(gen_random_bytes(32),'hex');
  update public.creator_jobs
    set status='leased',attempt_count=attempt_count+1,leased_until=v_new_until,updated_at=now()
    where id=p_job_id returning * into v_job;
  insert into creator_private.voice_job_leases(job_id,capability,lease_generation,leased_until,updated_at)
  values(p_job_id,v_capability,coalesce(v_lease.lease_generation,0)+1,v_new_until,now())
  on conflict(job_id) do update
    set capability=excluded.capability,
        lease_generation=creator_private.voice_job_leases.lease_generation+1,
        leased_until=excluded.leased_until,
        updated_at=now()
  returning * into v_lease;

  insert into public.creator_audit_events(project_id,owner_id,actor_kind,event_code,profile_id,details)
  values(v_job.project_id,v_project.owner_id,'worker','VOICE_JOB_CLAIMED_B1',v_profile.id,
    jsonb_build_object('job_id',v_job.id,'generation_mode','synthetic_mock',
                       'reclaimed_expired_lease',v_reclaimed));

  return jsonb_build_object('job',to_jsonb(v_job),'capability',v_lease.capability,
    'replayed',false,'reclaimed_expired_lease',v_reclaimed);
end;
$$;
revoke all on function creator_private.creator_claim_mock_voice_job_b1_impl(uuid,integer)
  from public,anon,authenticated;

create or replace function public.creator_claim_mock_voice_job_b1(
  p_job_id uuid,p_lease_seconds integer default 60
) returns jsonb language sql set search_path=''
as $$select creator_private.creator_claim_mock_voice_job_b1_impl(p_job_id,p_lease_seconds)$$;
revoke all on function public.creator_claim_mock_voice_job_b1(uuid,integer) from public,anon,authenticated;
grant execute on function public.creator_claim_mock_voice_job_b1(uuid,integer) to service_role;
