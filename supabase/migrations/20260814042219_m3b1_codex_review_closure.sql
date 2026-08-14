-- M3 B1 Codex review closure: callable wrappers and pre-completion output tracking.

alter table public.creator_media_deletions
  alter column artifact_id drop not null;

alter table public.creator_media_deletions
  add column if not exists job_id uuid references public.creator_jobs(id) on delete cascade,
  add column if not exists output_sha256 text,
  add column if not exists byte_length bigint,
  add column if not exists mime_type text;

alter table public.creator_media_deletions
  drop constraint if exists creator_media_deletions_status_check;
alter table public.creator_media_deletions
  add constraint creator_media_deletions_status_check
  check (status in ('held','retained','queued','deleting','deleted','failed'));

alter table public.creator_media_deletions
  drop constraint if exists creator_media_deletions_authority_ref_check;
alter table public.creator_media_deletions
  add constraint creator_media_deletions_authority_ref_check
  check (artifact_id is not null or job_id is not null);

alter table public.creator_media_deletions
  drop constraint if exists creator_media_deletions_output_sha_check;
alter table public.creator_media_deletions
  add constraint creator_media_deletions_output_sha_check
  check (output_sha256 is null or output_sha256 ~ '^[a-f0-9]{64}$');

alter table public.creator_media_deletions
  drop constraint if exists creator_media_deletions_byte_length_check;
alter table public.creator_media_deletions
  add constraint creator_media_deletions_byte_length_check
  check (byte_length is null or (byte_length > 0 and byte_length <= 25000000));

alter table public.creator_media_deletions
  drop constraint if exists creator_media_deletions_mime_type_check;
alter table public.creator_media_deletions
  add constraint creator_media_deletions_mime_type_check
  check (mime_type is null or mime_type = 'audio/wav');

create unique index if not exists creator_media_deletions_voice_job_uidx
  on public.creator_media_deletions(job_id)
  where job_id is not null;

create or replace function creator_private.creator_hold_mock_voice_output_impl(
  p_job_id uuid,
  p_capability text,
  p_object_path text,
  p_output_sha256 text,
  p_byte_length bigint,
  p_mime_type text
) returns public.creator_media_deletions
language plpgsql
security definer
set search_path=''
as $$
declare
  v_hint public.creator_jobs;
  v_profile public.creator_consent_profiles;
  v_project public.creator_projects;
  v_job public.creator_jobs;
  v_lease creator_private.voice_job_leases;
  v_row public.creator_media_deletions;
  v_expected_path text;
begin
  if auth.role() <> 'service_role' then raise exception 'WORKER_AUTHORITY_REQUIRED'; end if;
  if p_capability is null or p_capability !~ '^[a-f0-9]{64}$'
    then raise exception 'VOICE_LEASE_CAPABILITY_INVALID'; end if;
  if p_output_sha256 is null or p_output_sha256 !~ '^[a-f0-9]{64}$'
    then raise exception 'VOICE_OUTPUT_DIGEST_INVALID'; end if;
  if p_mime_type <> 'audio/wav' or p_byte_length <= 0 or p_byte_length > 25000000
    then raise exception 'VOICE_OUTPUT_METADATA_INVALID'; end if;

  select * into v_hint from public.creator_jobs where id=p_job_id;
  if not found or v_hint.job_type <> 'voice' then raise exception 'VOICE_JOB_NOT_FOUND'; end if;

  select * into v_profile
  from public.creator_consent_profiles
  where id=v_hint.identity_profile_id
  for share;
  if not found
     or v_profile.profile_kind <> 'voice'
     or v_profile.status <> 'active'
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
  if not found
     or v_job.status <> 'leased'
     or v_job.leased_until is null
     or v_job.leased_until <= now()
    then raise exception 'VOICE_JOB_NOT_PREPARABLE'; end if;

  select * into v_lease
  from creator_private.voice_job_leases
  where job_id=p_job_id
  for update;
  if not found
     or v_lease.capability <> p_capability
     or v_lease.leased_until is distinct from v_job.leased_until
    then raise exception 'VOICE_LEASE_CAPABILITY_INVALID'; end if;

  if v_project.current_stage <> 'VOICE_GENERATING' then raise exception 'STAGE_CONFLICT'; end if;
  if v_job.project_id is distinct from v_project.id
     or v_job.identity_profile_id is distinct from v_profile.id
     or v_job.requested_by is distinct from v_project.owner_id
     or v_profile.owner_id is distinct from v_project.owner_id
    then raise exception 'VOICE_JOB_AUTHORITY_MISMATCH'; end if;
  if v_job.provider <> 'mock' or v_job.generation_mode <> 'synthetic_mock'
    then raise exception 'REAL_PROVIDER_EXECUTION_BLOCKED_PHASE_A'; end if;

  v_expected_path := v_project.owner_id::text || '/' || v_project.id::text || '/' ||
                     v_job.id::text || '/' || p_output_sha256 || '.wav';
  if p_object_path <> v_expected_path then raise exception 'VOICE_OBJECT_BINDING_INVALID'; end if;

  select * into v_row
  from public.creator_media_deletions
  where job_id=p_job_id
  for update;

  if found then
    if v_row.bucket_id <> 'creator-voice-output'
       or v_row.object_path <> p_object_path
       or v_row.output_sha256 is distinct from p_output_sha256
       or v_row.byte_length is distinct from p_byte_length
       or v_row.mime_type is distinct from p_mime_type
       or v_row.status not in ('held','retained')
      then raise exception 'VOICE_OUTPUT_HOLD_CONFLICT'; end if;
    return v_row;
  end if;

  insert into public.creator_media_deletions(
    owner_id,project_id,artifact_id,job_id,bucket_id,object_path,reason,status,
    output_sha256,byte_length,mime_type
  ) values(
    v_project.owner_id,v_project.id,null,v_job.id,'creator-voice-output',p_object_path,
    'VOICE_OUTPUT_PENDING_COMPLETION','held',p_output_sha256,p_byte_length,p_mime_type
  )
  returning * into v_row;

  insert into public.creator_audit_events(
    project_id,owner_id,actor_kind,event_code,profile_id,details
  ) values(
    v_project.id,v_project.owner_id,'worker','VOICE_OUTPUT_HELD',v_profile.id,
    jsonb_build_object('job_id',v_job.id,'object_path',p_object_path,'output_sha256',p_output_sha256)
  );

  return v_row;
end;
$$;
revoke all on function creator_private.creator_hold_mock_voice_output_impl(
  uuid,text,text,text,bigint,text
) from public,anon,authenticated;

create or replace function public.creator_hold_mock_voice_output(
  p_job_id uuid,
  p_capability text,
  p_object_path text,
  p_output_sha256 text,
  p_byte_length bigint,
  p_mime_type text
) returns public.creator_media_deletions
language sql
security definer
set search_path=''
as $$
  select creator_private.creator_hold_mock_voice_output_impl(
    p_job_id,p_capability,p_object_path,p_output_sha256,p_byte_length,p_mime_type
  )
$$;
revoke all on function public.creator_hold_mock_voice_output(
  uuid,text,text,text,bigint,text
) from public,anon,authenticated;
grant execute on function public.creator_hold_mock_voice_output(
  uuid,text,text,text,bigint,text
) to service_role;

create or replace function creator_private.creator_bind_mock_voice_output_ledger()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  v_job_id uuid;
  v_updated uuid;
begin
  if new.kind='voice'
     and new.private_storage_path is not null
     and new.metadata->>'generationMode'='synthetic_mock' then
    begin
      v_job_id := (new.metadata->>'jobId')::uuid;
    exception when others then
      raise exception 'VOICE_OUTPUT_HOLD_REQUIRED';
    end;

    update public.creator_media_deletions
    set artifact_id=new.id,
        status='retained',
        reason='VOICE_OUTPUT_RETAINED',
        leased_until=null,
        error_code=null,
        output_sha256=coalesce(output_sha256,new.sha256)
    where job_id=v_job_id
      and bucket_id='creator-voice-output'
      and object_path=new.private_storage_path
      and output_sha256=new.sha256
      and status='held'
    returning id into v_updated;

    if v_updated is null then raise exception 'VOICE_OUTPUT_HOLD_REQUIRED'; end if;
  end if;
  return new;
end;
$$;
revoke all on function creator_private.creator_bind_mock_voice_output_ledger()
  from public,anon,authenticated;

drop trigger if exists creator_bind_mock_voice_output_ledger on public.creator_artifacts;
create trigger creator_bind_mock_voice_output_ledger
after insert on public.creator_artifacts
for each row execute function creator_private.creator_bind_mock_voice_output_ledger();

create or replace function creator_private.creator_queue_stale_voice_media()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  v_owner uuid;
  v_job_id uuid;
  v_bytes bigint;
  v_mime text;
begin
  if old.stale_at is null
     and new.stale_at is not null
     and new.kind='voice'
     and new.private_storage_path is not null then
    select owner_id into v_owner from public.creator_projects where id=new.project_id;
    if v_owner is not null then
      begin
        v_job_id := nullif(new.metadata->>'jobId','')::uuid;
      exception when others then
        v_job_id := null;
      end;
      begin
        v_bytes := nullif(new.metadata->>'byteLength','')::bigint;
      exception when others then
        v_bytes := null;
      end;
      v_mime := nullif(new.metadata->>'mimeType','');

      insert into public.creator_media_deletions(
        owner_id,project_id,artifact_id,job_id,bucket_id,object_path,reason,status,
        output_sha256,byte_length,mime_type
      ) values(
        v_owner,new.project_id,new.id,v_job_id,'creator-voice-output',
        new.private_storage_path,'ARTIFACT_STALE','queued',
        new.sha256,v_bytes,v_mime
      )
      on conflict(bucket_id,object_path) do update
      set artifact_id=excluded.artifact_id,
          job_id=coalesce(public.creator_media_deletions.job_id,excluded.job_id),
          reason=excluded.reason,
          status=case
            when public.creator_media_deletions.status='deleted' then 'deleted'
            else 'queued'
          end,
          requested_at=case
            when public.creator_media_deletions.status='deleted'
              then public.creator_media_deletions.requested_at
            else now()
          end,
          leased_until=null,
          error_code=null,
          output_sha256=coalesce(public.creator_media_deletions.output_sha256,excluded.output_sha256),
          byte_length=coalesce(public.creator_media_deletions.byte_length,excluded.byte_length),
          mime_type=coalesce(public.creator_media_deletions.mime_type,excluded.mime_type);
    end if;
  end if;
  return new;
end;
$$;
revoke all on function creator_private.creator_queue_stale_voice_media()
  from public,anon,authenticated;

create or replace function creator_private.creator_queue_terminated_voice_output()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
begin
  if new.job_type='voice'
     and new.status in ('cancelled','failed')
     and old.status is distinct from new.status then
    update public.creator_media_deletions
    set status='queued',
        reason=coalesce(nullif(new.error_code,''),'VOICE_JOB_TERMINATED'),
        requested_at=now(),
        leased_until=null,
        error_code=null
    where job_id=new.id and status='held';
  end if;
  return new;
end;
$$;
revoke all on function creator_private.creator_queue_terminated_voice_output()
  from public,anon,authenticated;

drop trigger if exists creator_queue_terminated_voice_output on public.creator_jobs;
create trigger creator_queue_terminated_voice_output
after update of status on public.creator_jobs
for each row execute function creator_private.creator_queue_terminated_voice_output();

create or replace function creator_private.creator_reconcile_held_voice_output_impl(
  p_job_id uuid,
  p_abandon_after_seconds integer default 900
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_hint public.creator_jobs;
  v_profile public.creator_consent_profiles;
  v_project public.creator_projects;
  v_job public.creator_jobs;
  v_row public.creator_media_deletions;
  v_artifact public.creator_artifacts;
  v_profile_active boolean:=false;
begin
  if auth.role() <> 'service_role' then raise exception 'WORKER_AUTHORITY_REQUIRED'; end if;
  if p_abandon_after_seconds is null or p_abandon_after_seconds < 60 or p_abandon_after_seconds > 86400
    then raise exception 'VOICE_RECONCILE_WINDOW_INVALID'; end if;

  select * into v_hint from public.creator_jobs where id=p_job_id;
  if not found or v_hint.job_type <> 'voice' then raise exception 'VOICE_JOB_NOT_FOUND'; end if;

  select * into v_profile
  from public.creator_consent_profiles
  where id=v_hint.identity_profile_id
  for share;
  v_profile_active := found
    and v_profile.profile_kind='voice'
    and v_profile.status='active'
    and v_profile.revoked_at is null
    and v_profile.deleted_at is null;

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

  select * into v_row
  from public.creator_media_deletions
  where job_id=p_job_id
  for update;
  if not found then
    return jsonb_build_object('tracked',false,'queued_for_deletion',false,'deferred',false);
  end if;

  if v_row.status in ('retained','deleted') then
    return jsonb_build_object(
      'tracked',true,'status',v_row.status,'queued_for_deletion',false,'deferred',false
    );
  end if;
  if v_row.status in ('queued','deleting','failed') then
    return jsonb_build_object(
      'tracked',true,'status',v_row.status,'queued_for_deletion',true,'deferred',false
    );
  end if;

  if v_job.status='succeeded' and v_job.output_artifact_id is not null then
    select * into v_artifact
    from public.creator_artifacts
    where id=v_job.output_artifact_id
      and project_id=v_job.project_id
      and kind='voice';
    if not found
       or v_artifact.private_storage_path is distinct from v_row.object_path
       or v_artifact.sha256 is distinct from v_row.output_sha256
      then raise exception 'VOICE_OUTPUT_STATE_INCONSISTENT'; end if;

    update public.creator_media_deletions
    set artifact_id=v_artifact.id,status='retained',reason='VOICE_OUTPUT_RETAINED',
        leased_until=null,error_code=null
    where id=v_row.id
    returning * into v_row;

    return jsonb_build_object(
      'tracked',true,'status',v_row.status,'queued_for_deletion',false,'deferred',false
    );
  end if;

  if v_job.status in ('cancelled','failed')
     or v_project.current_stage <> 'VOICE_GENERATING'
     or not v_profile_active then
    update public.creator_media_deletions
    set status='queued',reason='VOICE_OUTPUT_ABANDONED',requested_at=now(),
        leased_until=null,error_code=null
    where id=v_row.id
    returning * into v_row;
    return jsonb_build_object(
      'tracked',true,'status',v_row.status,'queued_for_deletion',true,'deferred',false
    );
  end if;

  if v_job.status='leased'
     and v_job.leased_until is not null
     and v_job.leased_until <= now()
     and v_row.requested_at <= now() - make_interval(secs=>p_abandon_after_seconds) then
    update public.creator_jobs
    set status='failed',error_code='VOICE_OUTPUT_ABANDONED',leased_until=null,updated_at=now()
    where id=v_job.id;
    delete from creator_private.voice_job_leases where job_id=v_job.id;

    update public.creator_media_deletions
    set status='queued',reason='VOICE_OUTPUT_ABANDONED',requested_at=now(),
        leased_until=null,error_code=null
    where id=v_row.id
    returning * into v_row;

    return jsonb_build_object(
      'tracked',true,'status',v_row.status,'queued_for_deletion',true,'deferred',false
    );
  end if;

  return jsonb_build_object(
    'tracked',true,'status',v_row.status,'queued_for_deletion',false,'deferred',true
  );
end;
$$;
revoke all on function creator_private.creator_reconcile_held_voice_output_impl(uuid,integer)
  from public,anon,authenticated;

create or replace function public.creator_reconcile_held_voice_output(
  p_job_id uuid,
  p_abandon_after_seconds integer default 900
) returns jsonb
language sql
security definer
set search_path=''
as $$
  select creator_private.creator_reconcile_held_voice_output_impl(
    p_job_id,p_abandon_after_seconds
  )
$$;
revoke all on function public.creator_reconcile_held_voice_output(uuid,integer)
  from public,anon,authenticated;
grant execute on function public.creator_reconcile_held_voice_output(uuid,integer)
  to service_role;

-- Public wrappers must be callable without exposing creator_private implementations.
create or replace function public.creator_request_voice_job(
  p_project_id uuid,p_script_artifact_id uuid,p_script_sha256 text,p_profile_id uuid,
  p_provider_id text,p_voice_manifest_sha256 text,p_generation_mode text,p_max_cost_microunits bigint,
  p_human_triggered boolean,p_idempotency_key uuid
) returns jsonb
language sql
security definer
set search_path=''
as $$
  select creator_private.creator_request_voice_job_b1_impl(
    p_project_id,p_script_artifact_id,p_script_sha256,p_profile_id,p_provider_id,
    p_voice_manifest_sha256,p_generation_mode,p_max_cost_microunits,p_human_triggered,p_idempotency_key
  )
$$;
revoke all on function public.creator_request_voice_job(
  uuid,uuid,text,uuid,text,text,text,bigint,boolean,uuid
) from public,anon;
grant execute on function public.creator_request_voice_job(
  uuid,uuid,text,uuid,text,text,text,bigint,boolean,uuid
) to authenticated,service_role;

create or replace function public.creator_claim_mock_voice_job_b1(
  p_job_id uuid,p_lease_seconds integer default 60
) returns jsonb
language sql
security definer
set search_path=''
as $$
  select creator_private.creator_claim_mock_voice_job_b1_impl(p_job_id,p_lease_seconds)
$$;
revoke all on function public.creator_claim_mock_voice_job_b1(uuid,integer)
  from public,anon,authenticated;
grant execute on function public.creator_claim_mock_voice_job_b1(uuid,integer)
  to service_role;

create or replace function public.creator_complete_mock_voice_job(
  p_job_id uuid,p_capability text,p_idempotency_key uuid,p_object_path text,
  p_output_sha256 text,p_byte_length bigint,p_mime_type text,p_duration_ms integer,
  p_runtime_ms bigint,p_actual_cost_microunits bigint,p_synthetic_label text
) returns jsonb
language sql
security definer
set search_path=''
as $$
  select creator_private.creator_complete_mock_voice_job_impl(
    p_job_id,p_capability,p_idempotency_key,p_object_path,p_output_sha256,
    p_byte_length,p_mime_type,p_duration_ms,p_runtime_ms,p_actual_cost_microunits,p_synthetic_label
  )
$$;
revoke all on function public.creator_complete_mock_voice_job(
  uuid,text,uuid,text,text,bigint,text,integer,bigint,bigint,text
) from public,anon,authenticated;
grant execute on function public.creator_complete_mock_voice_job(
  uuid,text,uuid,text,text,bigint,text,integer,bigint,bigint,text
) to service_role;

create or replace function public.creator_request_voice_revision(
  p_project_id uuid,p_artifact_id uuid,p_artifact_sha256 text,p_reason text,p_idempotency_key uuid
) returns public.creator_projects
language sql
security definer
set search_path=''
as $$
  select creator_private.creator_request_voice_revision_impl(
    p_project_id,p_artifact_id,p_artifact_sha256,p_reason,p_idempotency_key
  )
$$;
revoke all on function public.creator_request_voice_revision(uuid,uuid,text,text,uuid)
  from public,anon;
grant execute on function public.creator_request_voice_revision(uuid,uuid,text,text,uuid)
  to authenticated,service_role;

create or replace function public.creator_claim_media_deletion(
  p_deletion_id uuid,p_lease_seconds integer default 60
) returns jsonb
language sql
security definer
set search_path=''
as $$
  select creator_private.creator_claim_media_deletion_impl(p_deletion_id,p_lease_seconds)
$$;
revoke all on function public.creator_claim_media_deletion(uuid,integer)
  from public,anon,authenticated;
grant execute on function public.creator_claim_media_deletion(uuid,integer)
  to service_role;

create or replace function public.creator_finish_media_deletion(
  p_deletion_id uuid,p_capability text,p_success boolean,p_error_code text default null
) returns public.creator_media_deletions
language sql
security definer
set search_path=''
as $$
  select creator_private.creator_finish_media_deletion_impl(
    p_deletion_id,p_capability,p_success,p_error_code
  )
$$;
revoke all on function public.creator_finish_media_deletion(uuid,text,boolean,text)
  from public,anon,authenticated;
grant execute on function public.creator_finish_media_deletion(uuid,text,boolean,text)
  to service_role;
