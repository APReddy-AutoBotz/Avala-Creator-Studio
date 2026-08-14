-- M3 B1 authority hardening after controller/CI review.

create or replace function creator_private.creator_request_voice_job_b1_impl(
  p_project_id uuid,p_script_artifact_id uuid,p_script_sha256 text,p_profile_id uuid,
  p_provider_id text,p_voice_manifest_sha256 text,p_generation_mode text,p_max_cost_microunits bigint,
  p_human_triggered boolean,p_idempotency_key uuid
) returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  v_actor uuid:=auth.uid();
  v_result jsonb;
  v_project public.creator_projects;
  v_profile public.creator_consent_profiles;
  v_job_id uuid;
  v_job_status text;
begin
  if v_actor is null then raise exception 'UNAUTHORIZED'; end if;

  -- Serialize request authority with consent revoke/delete.
  select * into v_profile
  from public.creator_consent_profiles
  where id=p_profile_id and owner_id=v_actor and profile_kind='voice'
  for share;
  if not found
     or v_profile.status<>'active'
     or v_profile.revoked_at is not null
     or v_profile.deleted_at is not null
    then raise exception 'ACTIVE_VOICE_PROFILE_REQUIRED'; end if;

  v_result:=creator_private.creator_request_voice_job_impl(
    p_project_id,p_script_artifact_id,p_script_sha256,p_profile_id,p_provider_id,
    p_voice_manifest_sha256,p_generation_mode,p_max_cost_microunits,p_human_triggered,p_idempotency_key
  );

  if coalesce((v_result->>'accepted')::boolean,false) and p_provider_id='mock' then
    v_job_id:=(v_result->'job'->>'id')::uuid;
    v_job_status:=coalesce(v_result->'job'->>'status','');

    select * into v_project
    from public.creator_projects
    where id=p_project_id and owner_id=v_actor
    for update;
    if not found then raise exception 'PROJECT_NOT_FOUND'; end if;

    if v_project.current_stage='SCRIPT_APPROVED' then
      -- A response replay from an old succeeded/cancelled request must never restart generation.
      if v_job_status not in ('queued','leased') then
        return v_result || jsonb_build_object('project',to_jsonb(v_project));
      end if;
      update public.creator_projects
      set current_stage='VOICE_GENERATING',updated_at=now()
      where id=p_project_id
      returning * into v_project;
      insert into public.creator_audit_events(
        project_id,owner_id,actor_id,actor_kind,event_code,profile_id,details
      ) values(
        p_project_id,v_actor,v_actor,'human','START_VOICE',p_profile_id,
        jsonb_build_object('job_id',v_job_id,'generation_mode','synthetic_mock','provider_id','mock')
      );
    elsif v_project.current_stage='VOICE_GENERATING' then
      if v_job_status not in ('queued','leased') then raise exception 'STAGE_CONFLICT'; end if;
    elsif v_project.current_stage in ('VOICE_REVIEW','VOICE_APPROVED') then
      null;
    else
      raise exception 'STAGE_CONFLICT';
    end if;

    return v_result || jsonb_build_object('project',to_jsonb(v_project));
  end if;
  return v_result;
end;
$$;
revoke all on function creator_private.creator_request_voice_job_b1_impl(
  uuid,uuid,text,uuid,text,text,text,bigint,boolean,uuid
) from public,anon,authenticated;


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
  if p_lease_seconds is null or p_lease_seconds<10 or p_lease_seconds>600
    then raise exception 'VOICE_LEASE_INVALID'; end if;

  select * into v_hint from public.creator_jobs where id=p_job_id;
  if not found or v_hint.job_type<>'voice' then raise exception 'VOICE_JOB_NOT_FOUND'; end if;

  -- FOR SHARE blocks consent status mutation while worker authority is minted/recovered.
  select * into v_profile
  from public.creator_consent_profiles
  where id=v_hint.identity_profile_id
  for share;
  if not found
     or v_profile.profile_kind<>'voice'
     or v_profile.status<>'active'
     or v_profile.revoked_at is not null
     or v_profile.deleted_at is not null
    then raise exception 'ACTIVE_VOICE_PROFILE_REQUIRED'; end if;

  select * into v_project
  from public.creator_projects
  where id=v_hint.project_id
  for update;
  if not found then raise exception 'PROJECT_NOT_FOUND'; end if;

  select * into v_job
  from public.creator_jobs
  where id=p_job_id
  for update;
  if not found then raise exception 'VOICE_JOB_NOT_FOUND'; end if;
  if v_job.identity_profile_id is distinct from v_profile.id
     or v_job.project_id is distinct from v_project.id
     or v_project.owner_id is distinct from v_profile.owner_id
     or v_job.requested_by is distinct from v_project.owner_id
    then raise exception 'VOICE_JOB_AUTHORITY_MISMATCH'; end if;
  if v_project.current_stage<>'VOICE_GENERATING' then raise exception 'STAGE_CONFLICT'; end if;

  select * into v_lease
  from creator_private.voice_job_leases
  where job_id=p_job_id
  for update;

  if v_job.status='leased'
     and v_job.leased_until is not null
     and v_job.leased_until>now() then
    if not found or v_lease.leased_until is distinct from v_job.leased_until
      then raise exception 'VOICE_LEASE_STATE_INVALID'; end if;
    return jsonb_build_object(
      'job',to_jsonb(v_job),'capability',v_lease.capability,
      'replayed',true,'reclaimed_expired_lease',false
    );
  end if;

  if v_job.status='leased'
     and v_job.leased_until is not null
     and v_job.leased_until<=now() then
    v_reclaimed:=true;
  elsif v_job.status<>'queued' then
    raise exception 'VOICE_JOB_NOT_CLAIMABLE';
  end if;

  select * into v_script
  from public.creator_artifacts
  where id=v_job.input_artifact_id
    and project_id=v_job.project_id
    and kind='script'
    and stale_at is null;
  if not found then raise exception 'ARTIFACT_BINDING_INVALID'; end if;
  if v_script.version_number<>(
    select max(version_number)
    from public.creator_artifacts
    where project_id=v_job.project_id and kind='script' and stale_at is null
  ) then raise exception 'LATEST_ARTIFACT_REQUIRED'; end if;
  if not exists(
    select 1 from public.creator_reviews r
    where r.project_id=v_job.project_id
      and r.artifact_id=v_script.id
      and r.reviewer_id=v_project.owner_id
      and r.decision='approved'
      and r.invalidated_at is null
      and r.artifact_version=v_script.version_number
      and r.artifact_sha256=v_script.sha256
  ) then raise exception 'SCRIPT_APPROVAL_REQUIRED'; end if;

  if v_job.voice_sample_ids is null or cardinality(v_job.voice_sample_ids)<1 then
    raise exception 'VALIDATED_SAMPLE_REQUIRED';
  end if;
  if exists(
    select 1
    from unnest(v_job.voice_sample_ids) sample_id
    where not exists(
      select 1 from public.creator_identity_samples s
      where s.id=sample_id
        and s.profile_id=v_profile.id
        and s.owner_id=v_profile.owner_id
        and s.status='validated'
        and s.deleted_at is null
    )
  ) then raise exception 'VALIDATED_SAMPLE_REQUIRED'; end if;

  select * into v_provider
  from creator_private.voice_provider_catalog
  where provider_id=v_job.provider
  for share;
  if not found then raise exception 'VOICE_PROVIDER_NOT_FOUND'; end if;

  select * into v_policy
  from creator_private.voice_runtime_policy
  where singleton=true
  for share;
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
  set status='leased',
      attempt_count=attempt_count+1,
      leased_until=v_new_until,
      updated_at=now()
  where id=p_job_id
  returning * into v_job;

  insert into creator_private.voice_job_leases(
    job_id,capability,lease_generation,leased_until,updated_at
  ) values(
    p_job_id,v_capability,coalesce(v_lease.lease_generation,0)+1,v_new_until,now()
  )
  on conflict(job_id) do update
  set capability=excluded.capability,
      lease_generation=creator_private.voice_job_leases.lease_generation+1,
      leased_until=excluded.leased_until,
      updated_at=now()
  returning * into v_lease;

  insert into public.creator_audit_events(
    project_id,owner_id,actor_kind,event_code,profile_id,details
  ) values(
    v_job.project_id,v_project.owner_id,'worker','VOICE_JOB_CLAIMED_B1',v_profile.id,
    jsonb_build_object(
      'job_id',v_job.id,
      'generation_mode','synthetic_mock',
      'reclaimed_expired_lease',v_reclaimed
    )
  );

  return jsonb_build_object(
    'job',to_jsonb(v_job),
    'capability',v_lease.capability,
    'replayed',false,
    'reclaimed_expired_lease',v_reclaimed
  );
end;
$$;
revoke all on function creator_private.creator_claim_mock_voice_job_b1_impl(uuid,integer)
  from public,anon,authenticated;


create or replace function creator_private.creator_complete_mock_voice_job_impl(
  p_job_id uuid,
  p_capability text,
  p_idempotency_key uuid,
  p_object_path text,
  p_output_sha256 text,
  p_byte_length bigint,
  p_mime_type text,
  p_duration_ms integer,
  p_runtime_ms bigint,
  p_actual_cost_microunits bigint,
  p_synthetic_label text
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
  v_claim creator_private.voice_completion_claims;
  v_artifact public.creator_artifacts;
  v_object storage.objects;
  v_expected_path text;
  v_version integer;
  v_fingerprint text;
begin
  if auth.role()<>'service_role' then raise exception 'WORKER_AUTHORITY_REQUIRED'; end if;
  if p_idempotency_key is null then raise exception 'IDEMPOTENCY_KEY_REQUIRED'; end if;
  if p_capability is null or p_capability !~ '^[a-f0-9]{64}$'
    then raise exception 'VOICE_LEASE_CAPABILITY_INVALID'; end if;
  if p_output_sha256 is null or p_output_sha256 !~ '^[a-f0-9]{64}$'
    then raise exception 'VOICE_OUTPUT_DIGEST_INVALID'; end if;
  if p_mime_type<>'audio/wav' or p_byte_length<=0 or p_byte_length>25000000
    then raise exception 'VOICE_OUTPUT_METADATA_INVALID'; end if;
  if p_duration_ms<100 or p_duration_ms>600000 or p_runtime_ms<0 or p_actual_cost_microunits<>0
    then raise exception 'VOICE_OUTPUT_METADATA_INVALID'; end if;
  if p_synthetic_label<>'[SYNTHETIC MOCK VOICE DRAFT]'
    then raise exception 'SYNTHETIC_LABEL_REQUIRED'; end if;

  v_fingerprint:=encode(extensions.digest(convert_to(concat_ws('|',
    p_job_id::text,p_object_path,p_output_sha256,p_byte_length::text,p_mime_type,
    p_duration_ms::text,p_runtime_ms::text,p_actual_cost_microunits::text,p_synthetic_label
  ),'UTF8'),'sha256'),'hex');

  select * into v_claim
  from creator_private.voice_completion_claims
  where job_id=p_job_id and idempotency_key=p_idempotency_key;
  if found then
    if v_claim.request_fingerprint<>v_fingerprint then raise exception 'IDEMPOTENCY_KEY_REUSED'; end if;
    select * into v_artifact from public.creator_artifacts where id=v_claim.artifact_id;
    return jsonb_build_object('artifact',to_jsonb(v_artifact),'replayed',true);
  end if;

  select * into v_hint
  from public.creator_jobs
  where id=p_job_id;
  if not found or v_hint.job_type<>'voice' then raise exception 'VOICE_JOB_NOT_FOUND'; end if;

  -- Strong profile lock serializes completion with revoke/delete.
  select * into v_profile
  from public.creator_consent_profiles
  where id=v_hint.identity_profile_id
  for share;
  if not found
     or v_profile.profile_kind<>'voice'
     or v_profile.status<>'active'
     or v_profile.revoked_at is not null
     or v_profile.deleted_at is not null
    then raise exception 'ACTIVE_VOICE_PROFILE_REQUIRED'; end if;

  select * into v_project
  from public.creator_projects
  where id=v_hint.project_id
  for update;
  if not found then raise exception 'PROJECT_NOT_FOUND'; end if;

  select * into v_job
  from public.creator_jobs
  where id=p_job_id
  for update;
  if not found then raise exception 'VOICE_JOB_NOT_FOUND'; end if;

  -- A concurrent exact completion may have committed while we waited for the project/job lock.
  if v_job.status<>'leased'
     or v_job.leased_until is null
     or v_job.leased_until<=now() then
    select * into v_claim
    from creator_private.voice_completion_claims
    where job_id=p_job_id and idempotency_key=p_idempotency_key;
    if found then
      if v_claim.request_fingerprint<>v_fingerprint then raise exception 'IDEMPOTENCY_KEY_REUSED'; end if;
      select * into v_artifact from public.creator_artifacts where id=v_claim.artifact_id;
      return jsonb_build_object('artifact',to_jsonb(v_artifact),'replayed',true);
    end if;
    raise exception 'VOICE_JOB_NOT_COMPLETABLE';
  end if;

  select * into v_lease
  from creator_private.voice_job_leases
  where job_id=p_job_id
  for update;
  if not found
     or v_lease.capability<>p_capability
     or v_lease.leased_until is distinct from v_job.leased_until
    then raise exception 'VOICE_LEASE_CAPABILITY_INVALID'; end if;

  if v_project.current_stage<>'VOICE_GENERATING' then raise exception 'STAGE_CONFLICT'; end if;
  if v_job.identity_profile_id is distinct from v_profile.id
     or v_job.project_id is distinct from v_project.id
     or v_project.owner_id is distinct from v_profile.owner_id
     or v_job.requested_by is distinct from v_project.owner_id
    then raise exception 'VOICE_JOB_AUTHORITY_MISMATCH'; end if;

  select * into v_script
  from public.creator_artifacts
  where id=v_job.input_artifact_id
    and project_id=v_job.project_id
    and kind='script'
    and stale_at is null;
  if not found then raise exception 'ARTIFACT_BINDING_INVALID'; end if;
  if v_script.version_number<>(
    select max(version_number)
    from public.creator_artifacts
    where project_id=v_job.project_id and kind='script' and stale_at is null
  ) then raise exception 'LATEST_ARTIFACT_REQUIRED'; end if;
  if not exists(
    select 1 from public.creator_reviews r
    where r.project_id=v_job.project_id
      and r.artifact_id=v_script.id
      and r.reviewer_id=v_project.owner_id
      and r.decision='approved'
      and r.invalidated_at is null
      and r.artifact_version=v_script.version_number
      and r.artifact_sha256=v_script.sha256
  ) then raise exception 'SCRIPT_APPROVAL_REQUIRED'; end if;

  if v_job.voice_sample_ids is null or cardinality(v_job.voice_sample_ids)<1 then
    raise exception 'VALIDATED_SAMPLE_REQUIRED';
  end if;
  if exists(
    select 1 from unnest(v_job.voice_sample_ids) sample_id
    where not exists(
      select 1 from public.creator_identity_samples s
      where s.id=sample_id
        and s.profile_id=v_profile.id
        and s.owner_id=v_profile.owner_id
        and s.status='validated'
        and s.deleted_at is null
    )
  ) then raise exception 'VALIDATED_SAMPLE_REQUIRED'; end if;

  select * into v_provider
  from creator_private.voice_provider_catalog
  where provider_id=v_job.provider
  for share;
  if not found then raise exception 'VOICE_PROVIDER_NOT_FOUND'; end if;

  select * into v_policy
  from creator_private.voice_runtime_policy
  where singleton=true
  for share;
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
     or p_actual_cost_microunits<>0
    then raise exception 'MOCK_PROVIDER_MUST_BE_ZERO_COST'; end if;
  if v_job.provider_model_id is distinct from v_provider.upstream_model_id
     or v_job.provider_verified_at is distinct from v_provider.verified_at
    then raise exception 'VOICE_PROVIDER_SNAPSHOT_STALE'; end if;

  v_expected_path:=v_project.owner_id::text||'/'||v_project.id::text||'/'||
                   v_job.id::text||'/'||p_output_sha256||'.wav';
  if p_object_path<>v_expected_path then raise exception 'VOICE_OBJECT_BINDING_INVALID'; end if;

  select * into v_object
  from storage.objects
  where bucket_id='creator-voice-output' and name=p_object_path
  for share;
  if not found then raise exception 'PRIVATE_OBJECT_NOT_FOUND'; end if;
  if coalesce((v_object.metadata->>'size')::bigint,-1)<>p_byte_length
     or coalesce(v_object.metadata->>'mimetype','')<>p_mime_type
     or coalesce(v_object.user_metadata->>'sha256','')<>p_output_sha256
     or coalesce(v_object.user_metadata->>'job_id','')<>p_job_id::text
    then raise exception 'VOICE_OBJECT_METADATA_MISMATCH'; end if;

  select coalesce(max(version_number),0)+1
  into v_version
  from public.creator_artifacts
  where project_id=v_project.id and kind='voice';

  insert into public.creator_artifacts(
    project_id,kind,version_number,private_storage_path,sha256,
    client_request_id,identity_profile_id,metadata,created_by
  ) values(
    v_project.id,'voice',v_version,p_object_path,p_output_sha256,
    p_idempotency_key,v_profile.id,
    jsonb_build_object(
      'label',p_synthetic_label,
      'jobId',v_job.id,
      'generationMode','synthetic_mock',
      'providerId','mock',
      'providerModelId',v_job.provider_model_id,
      'providerModelRevision',v_job.provider_model_revision,
      'providerVerifiedAt',v_job.provider_verified_at,
      'script',jsonb_build_object(
        'projectId',v_project.id,
        'artifactId',v_script.id,
        'artifactVersion',v_script.version_number,
        'artifactSha256',v_script.sha256
      ),
      'profileId',v_profile.id,
      'sampleIds',v_job.voice_sample_ids,
      'voiceManifestSha256',v_job.voice_manifest_sha256,
      'outputSha256',p_output_sha256,
      'byteLength',p_byte_length,
      'mimeType',p_mime_type,
      'durationMs',p_duration_ms,
      'runtimeMs',p_runtime_ms,
      'costMicrounits',0,
      'currency','USD'
    ),
    null
  )
  returning * into v_artifact;

  update public.creator_jobs
  set status='succeeded',
      output_artifact_id=v_artifact.id,
      completed_at=now(),
      actual_cost_microunits=0,
      runtime_ms=p_runtime_ms,
      leased_until=null,
      updated_at=now()
  where id=v_job.id;

  update public.creator_projects
  set current_stage='VOICE_REVIEW',updated_at=now()
  where id=v_project.id
  returning * into v_project;

  insert into creator_private.voice_completion_claims(
    job_id,idempotency_key,request_fingerprint,artifact_id
  ) values(
    v_job.id,p_idempotency_key,v_fingerprint,v_artifact.id
  );

  delete from creator_private.voice_job_leases where job_id=v_job.id;

  insert into public.creator_audit_events(
    project_id,owner_id,actor_kind,event_code,artifact_id,profile_id,details
  ) values(
    v_project.id,v_project.owner_id,'worker','VOICE_READY',
    v_artifact.id,v_profile.id,
    jsonb_build_object(
      'job_id',v_job.id,
      'artifact_version',v_artifact.version_number,
      'output_sha256',v_artifact.sha256,
      'generation_mode','synthetic_mock',
      'runtime_ms',p_runtime_ms,
      'cost_microunits',0
    )
  );

  return jsonb_build_object(
    'project',to_jsonb(v_project),
    'artifact',to_jsonb(v_artifact),
    'replayed',false
  );
end;
$$;
revoke all on function creator_private.creator_complete_mock_voice_job_impl(
  uuid,text,uuid,text,text,bigint,text,integer,bigint,bigint,text
) from public,anon,authenticated;


create or replace function creator_private.creator_enforce_voice_human_approval()
returns trigger
language plpgsql security definer set search_path=''
as $$
declare
  v_artifact public.creator_artifacts;
  v_profile public.creator_consent_profiles;
begin
  if new.decision='approved' then
    select * into v_artifact
    from public.creator_artifacts
    where id=new.artifact_id;
    if found and v_artifact.kind='voice' then
      if auth.uid() is null or new.reviewer_id<>auth.uid()
        then raise exception 'HUMAN_APPROVAL_REQUIRED'; end if;
      select * into v_profile
      from public.creator_consent_profiles
      where id=v_artifact.identity_profile_id
      for share;
      if not found
         or v_profile.status<>'active'
         or v_profile.revoked_at is not null
         or v_profile.deleted_at is not null
        then raise exception 'ACTIVE_VOICE_PROFILE_REQUIRED'; end if;
    end if;
  end if;
  return new;
end;
$$;
revoke all on function creator_private.creator_enforce_voice_human_approval()
  from public,anon,authenticated;


create table if not exists creator_private.media_deletion_leases(
  deletion_id uuid primary key references public.creator_media_deletions(id) on delete cascade,
  capability text not null check (capability ~ '^[a-f0-9]{64}$'),
  lease_generation integer not null default 1 check (lease_generation>0),
  leased_until timestamptz not null,
  updated_at timestamptz not null default now()
);
revoke all on table creator_private.media_deletion_leases from public,anon,authenticated;

drop function if exists public.creator_claim_media_deletion(uuid,integer);
drop function if exists creator_private.creator_claim_media_deletion_impl(uuid,integer);

create function creator_private.creator_claim_media_deletion_impl(
  p_deletion_id uuid,p_lease_seconds integer default 60
) returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  v_row public.creator_media_deletions;
  v_lease creator_private.media_deletion_leases;
  v_capability text;
  v_until timestamptz;
  v_reclaimed boolean:=false;
begin
  if auth.role()<>'service_role' then raise exception 'WORKER_AUTHORITY_REQUIRED'; end if;
  if p_lease_seconds is null or p_lease_seconds<10 or p_lease_seconds>600
    then raise exception 'MEDIA_DELETE_LEASE_INVALID'; end if;

  select * into v_row
  from public.creator_media_deletions
  where id=p_deletion_id
  for update;
  if not found then raise exception 'MEDIA_DELETE_NOT_FOUND'; end if;

  select * into v_lease
  from creator_private.media_deletion_leases
  where deletion_id=p_deletion_id
  for update;

  if v_row.status='deleted' then
    return jsonb_build_object(
      'deletion',to_jsonb(v_row),
      'capability',case when found then v_lease.capability else null end,
      'replayed',true,
      'reclaimed_expired_lease',false
    );
  end if;

  if v_row.status='deleting'
     and v_row.leased_until is not null
     and v_row.leased_until>now() then
    if not found or v_lease.leased_until is distinct from v_row.leased_until
      then raise exception 'MEDIA_DELETE_LEASE_STATE_INVALID'; end if;
    return jsonb_build_object(
      'deletion',to_jsonb(v_row),
      'capability',v_lease.capability,
      'replayed',true,
      'reclaimed_expired_lease',false
    );
  end if;

  if v_row.status='deleting'
     and v_row.leased_until is not null
     and v_row.leased_until<=now() then
    v_reclaimed:=true;
  elsif v_row.status not in ('queued','failed') then
    raise exception 'MEDIA_DELETE_NOT_CLAIMABLE';
  end if;

  v_until:=now()+make_interval(secs=>p_lease_seconds);
  v_capability:=encode(gen_random_bytes(32),'hex');

  update public.creator_media_deletions
  set status='deleting',
      attempt_count=attempt_count+1,
      leased_until=v_until,
      error_code=null
  where id=p_deletion_id
  returning * into v_row;

  insert into creator_private.media_deletion_leases(
    deletion_id,capability,lease_generation,leased_until,updated_at
  ) values(
    p_deletion_id,v_capability,coalesce(v_lease.lease_generation,0)+1,v_until,now()
  )
  on conflict(deletion_id) do update
  set capability=excluded.capability,
      lease_generation=creator_private.media_deletion_leases.lease_generation+1,
      leased_until=excluded.leased_until,
      updated_at=now()
  returning * into v_lease;

  return jsonb_build_object(
    'deletion',to_jsonb(v_row),
    'capability',v_lease.capability,
    'replayed',false,
    'reclaimed_expired_lease',v_reclaimed
  );
end;
$$;
revoke all on function creator_private.creator_claim_media_deletion_impl(uuid,integer)
  from public,anon,authenticated;

create function public.creator_claim_media_deletion(
  p_deletion_id uuid,p_lease_seconds integer default 60
) returns jsonb
language sql set search_path=''
as $$select creator_private.creator_claim_media_deletion_impl(p_deletion_id,p_lease_seconds)$$;
revoke all on function public.creator_claim_media_deletion(uuid,integer)
  from public,anon,authenticated;
grant execute on function public.creator_claim_media_deletion(uuid,integer)
  to service_role;


drop function if exists public.creator_finish_media_deletion(uuid,boolean,text);
drop function if exists creator_private.creator_finish_media_deletion_impl(uuid,boolean,text);

create function creator_private.creator_finish_media_deletion_impl(
  p_deletion_id uuid,
  p_capability text,
  p_success boolean,
  p_error_code text default null
) returns public.creator_media_deletions
language plpgsql security definer set search_path=''
as $$
declare
  v_row public.creator_media_deletions;
  v_lease creator_private.media_deletion_leases;
begin
  if auth.role()<>'service_role' then raise exception 'WORKER_AUTHORITY_REQUIRED'; end if;
  if p_capability is null or p_capability !~ '^[a-f0-9]{64}$'
    then raise exception 'MEDIA_DELETE_LEASE_CAPABILITY_INVALID'; end if;

  select * into v_row
  from public.creator_media_deletions
  where id=p_deletion_id
  for update;
  if not found then raise exception 'MEDIA_DELETE_NOT_FOUND'; end if;

  select * into v_lease
  from creator_private.media_deletion_leases
  where deletion_id=p_deletion_id
  for update;
  if not found or v_lease.capability<>p_capability
    then raise exception 'MEDIA_DELETE_LEASE_CAPABILITY_INVALID'; end if;

  if v_row.status='deleted' then return v_row; end if;

  if v_row.status<>'deleting'
     or v_row.leased_until is null
     or v_row.leased_until<=now()
     or v_lease.leased_until is distinct from v_row.leased_until
    then raise exception 'MEDIA_DELETE_LEASE_EXPIRED'; end if;

  if p_success then
    if exists(
      select 1
      from storage.objects
      where bucket_id=v_row.bucket_id and name=v_row.object_path
    ) then raise exception 'PRIVATE_MEDIA_DELETE_REQUIRED'; end if;

    update public.creator_media_deletions
    set status='deleted',
        deleted_at=now(),
        leased_until=null,
        error_code=null
    where id=p_deletion_id
    returning * into v_row;

    update creator_private.media_deletion_leases
    set leased_until=now(),updated_at=now()
    where deletion_id=p_deletion_id;
  else
    update public.creator_media_deletions
    set status='failed',
        leased_until=null,
        error_code=coalesce(nullif(p_error_code,''),'DELETE_FAILED')
    where id=p_deletion_id
    returning * into v_row;

    delete from creator_private.media_deletion_leases
    where deletion_id=p_deletion_id;
  end if;

  return v_row;
end;
$$;
revoke all on function creator_private.creator_finish_media_deletion_impl(
  uuid,text,boolean,text
) from public,anon,authenticated;

create function public.creator_finish_media_deletion(
  p_deletion_id uuid,
  p_capability text,
  p_success boolean,
  p_error_code text default null
) returns public.creator_media_deletions
language sql set search_path=''
as $$select creator_private.creator_finish_media_deletion_impl(
  p_deletion_id,p_capability,p_success,p_error_code
)$$;
revoke all on function public.creator_finish_media_deletion(uuid,text,boolean,text)
  from public,anon,authenticated;
grant execute on function public.creator_finish_media_deletion(uuid,text,boolean,text)
  to service_role;
