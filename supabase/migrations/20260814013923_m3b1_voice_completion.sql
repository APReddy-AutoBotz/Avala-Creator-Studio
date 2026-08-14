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

  select * into v_hint from public.creator_jobs where id=p_job_id;
  if not found or v_hint.job_type<>'voice' then raise exception 'VOICE_JOB_NOT_FOUND'; end if;

  select * into v_profile
  from public.creator_consent_profiles
  where id=v_hint.identity_profile_id
  for key share;
  if not found or v_profile.profile_kind<>'voice' or v_profile.status<>'active'
     or v_profile.revoked_at is not null or v_profile.deleted_at is not null
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
  if not found
     or v_job.status<>'leased'
     or v_job.leased_until is null
     or v_job.leased_until<=now()
    then raise exception 'VOICE_JOB_NOT_COMPLETABLE'; end if;

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
  where bucket_id='creator-voice-output' and name=p_object_path;
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

create or replace function public.creator_complete_mock_voice_job(
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
) returns jsonb language sql set search_path=''
as $$select creator_private.creator_complete_mock_voice_job_impl(
  p_job_id,p_capability,p_idempotency_key,p_object_path,p_output_sha256,
  p_byte_length,p_mime_type,p_duration_ms,p_runtime_ms,p_actual_cost_microunits,p_synthetic_label
)$$;
revoke all on function public.creator_complete_mock_voice_job(
  uuid,text,uuid,text,text,bigint,text,integer,bigint,bigint,text
) from public,anon,authenticated;
grant execute on function public.creator_complete_mock_voice_job(
  uuid,text,uuid,text,text,bigint,text,integer,bigint,bigint,text
) to service_role;
