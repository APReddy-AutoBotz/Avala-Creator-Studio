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
      where id=v_artifact.identity_profile_id;
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
create trigger creator_enforce_voice_human_approval
before insert on public.creator_reviews
for each row execute function creator_private.creator_enforce_voice_human_approval();

create or replace function creator_private.creator_request_voice_revision_impl(
  p_project_id uuid,
  p_artifact_id uuid,
  p_artifact_sha256 text,
  p_reason text,
  p_idempotency_key uuid
) returns public.creator_projects
language plpgsql security definer set search_path=''
as $$
declare
  v_actor uuid:=auth.uid();
  v_project public.creator_projects;
  v_artifact public.creator_artifacts;
  v_existing public.creator_audit_events;
  v_reason text;
begin
  if v_actor is null then raise exception 'UNAUTHORIZED'; end if;
  if p_idempotency_key is null then raise exception 'IDEMPOTENCY_KEY_REQUIRED'; end if;
  if p_artifact_sha256 is null or p_artifact_sha256 !~ '^[a-f0-9]{64}$'
    then raise exception 'SHA256_INVALID'; end if;
  if p_reason is null or char_length(btrim(p_reason)) not between 1 and 4000
    then raise exception 'REVISION_REASON_INVALID'; end if;
  v_reason:=btrim(p_reason);

  select * into v_project
  from public.creator_projects
  where id=p_project_id and owner_id=v_actor
  for update;
  if not found then raise exception 'PROJECT_NOT_FOUND'; end if;

  select * into v_existing
  from public.creator_audit_events
  where project_id=p_project_id and idempotency_key=p_idempotency_key;
  if found then
    if v_existing.event_code<>'VOICE_REVISION_REQUESTED'
       or v_existing.artifact_id is distinct from p_artifact_id
       or v_existing.details->>'artifact_sha256' is distinct from p_artifact_sha256
       or v_existing.details->>'reason' is distinct from v_reason
      then raise exception 'IDEMPOTENCY_KEY_REUSED'; end if;
    return v_project;
  end if;

  if v_project.current_stage not in ('VOICE_REVIEW','VOICE_APPROVED')
    then raise exception 'STAGE_CONFLICT'; end if;

  select * into v_artifact
  from public.creator_artifacts
  where id=p_artifact_id
    and project_id=p_project_id
    and kind='voice'
    and sha256=p_artifact_sha256
    and stale_at is null;
  if not found then raise exception 'ARTIFACT_BINDING_INVALID'; end if;
  if v_artifact.version_number<>(
    select max(version_number)
    from public.creator_artifacts
    where project_id=p_project_id and kind='voice' and stale_at is null
  ) then raise exception 'LATEST_ARTIFACT_REQUIRED'; end if;

  update public.creator_artifacts
  set stale_at=coalesce(stale_at,now())
  where project_id=p_project_id
    and kind in ('voice','avatar','edit','final')
    and stale_at is null;

  update public.creator_reviews
  set invalidated_at=coalesce(invalidated_at,now()),
      invalidation_reason='VOICE_REVISED'
  where project_id=p_project_id
    and invalidated_at is null
    and artifact_id in(
      select id
      from public.creator_artifacts
      where project_id=p_project_id and stale_at is not null
    );

  update public.creator_jobs
  set status='cancelled',error_code='VOICE_REVISED',updated_at=now()
  where project_id=p_project_id
    and status in ('queued','leased','running');

  update public.creator_projects
  set current_stage='SCRIPT_APPROVED',updated_at=now()
  where id=p_project_id
  returning * into v_project;

  insert into public.creator_audit_events(
    project_id,owner_id,actor_id,actor_kind,event_code,
    artifact_id,idempotency_key,details
  ) values(
    p_project_id,v_actor,v_actor,'human','VOICE_REVISION_REQUESTED',
    p_artifact_id,p_idempotency_key,
    jsonb_build_object('artifact_sha256',p_artifact_sha256,'reason',v_reason)
  );

  return v_project;
end;
$$;
revoke all on function creator_private.creator_request_voice_revision_impl(
  uuid,uuid,text,text,uuid
) from public,anon,authenticated;

create or replace function public.creator_request_voice_revision(
  p_project_id uuid,
  p_artifact_id uuid,
  p_artifact_sha256 text,
  p_reason text,
  p_idempotency_key uuid
) returns public.creator_projects
language sql set search_path=''
as $$select creator_private.creator_request_voice_revision_impl(
  p_project_id,p_artifact_id,p_artifact_sha256,p_reason,p_idempotency_key
)$$;
revoke all on function public.creator_request_voice_revision(
  uuid,uuid,text,text,uuid
) from public,anon;
grant execute on function public.creator_request_voice_revision(
  uuid,uuid,text,text,uuid
) to authenticated;

create or replace function creator_private.creator_claim_media_deletion_impl(
  p_deletion_id uuid,p_lease_seconds integer default 60
) returns public.creator_media_deletions
language plpgsql security definer set search_path=''
as $$
declare v_row public.creator_media_deletions;
begin
  if auth.role()<>'service_role' then raise exception 'WORKER_AUTHORITY_REQUIRED'; end if;
  if p_lease_seconds is null or p_lease_seconds<10 or p_lease_seconds>600
    then raise exception 'MEDIA_DELETE_LEASE_INVALID'; end if;
  select * into v_row
  from public.creator_media_deletions
  where id=p_deletion_id
  for update;
  if not found then raise exception 'MEDIA_DELETE_NOT_FOUND'; end if;
  if v_row.status='deleted' then return v_row; end if;
  if v_row.status='deleting' and v_row.leased_until is not null and v_row.leased_until>now()
    then raise exception 'MEDIA_DELETE_NOT_CLAIMABLE'; end if;

  update public.creator_media_deletions
  set status='deleting',
      attempt_count=attempt_count+1,
      leased_until=now()+make_interval(secs=>p_lease_seconds),
      error_code=null
  where id=p_deletion_id
  returning * into v_row;
  return v_row;
end;
$$;
revoke all on function creator_private.creator_claim_media_deletion_impl(uuid,integer)
  from public,anon,authenticated;

create or replace function public.creator_claim_media_deletion(
  p_deletion_id uuid,p_lease_seconds integer default 60
) returns public.creator_media_deletions
language sql set search_path=''
as $$select creator_private.creator_claim_media_deletion_impl(
  p_deletion_id,p_lease_seconds
)$$;
revoke all on function public.creator_claim_media_deletion(uuid,integer)
  from public,anon,authenticated;
grant execute on function public.creator_claim_media_deletion(uuid,integer)
  to service_role;

create or replace function creator_private.creator_finish_media_deletion_impl(
  p_deletion_id uuid,p_success boolean,p_error_code text default null
) returns public.creator_media_deletions
language plpgsql security definer set search_path=''
as $$
declare v_row public.creator_media_deletions;
begin
  if auth.role()<>'service_role' then raise exception 'WORKER_AUTHORITY_REQUIRED'; end if;
  select * into v_row
  from public.creator_media_deletions
  where id=p_deletion_id
  for update;
  if not found then raise exception 'MEDIA_DELETE_NOT_FOUND'; end if;
  if v_row.status='deleted' then return v_row; end if;
  if v_row.status<>'deleting' then raise exception 'MEDIA_DELETE_NOT_CLAIMED'; end if;

  if p_success then
    if exists(
      select 1 from storage.objects
      where bucket_id=v_row.bucket_id and name=v_row.object_path
    ) then raise exception 'PRIVATE_MEDIA_DELETE_REQUIRED'; end if;
    update public.creator_media_deletions
    set status='deleted',deleted_at=now(),leased_until=null,error_code=null
    where id=p_deletion_id
    returning * into v_row;
  else
    update public.creator_media_deletions
    set status='failed',
        leased_until=null,
        error_code=coalesce(nullif(p_error_code,''),'DELETE_FAILED')
    where id=p_deletion_id
    returning * into v_row;
  end if;

  return v_row;
end;
$$;
revoke all on function creator_private.creator_finish_media_deletion_impl(
  uuid,boolean,text
) from public,anon,authenticated;

create or replace function public.creator_finish_media_deletion(
  p_deletion_id uuid,p_success boolean,p_error_code text default null
) returns public.creator_media_deletions
language sql set search_path=''
as $$select creator_private.creator_finish_media_deletion_impl(
  p_deletion_id,p_success,p_error_code
)$$;
revoke all on function public.creator_finish_media_deletion(uuid,boolean,text)
  from public,anon,authenticated;
grant execute on function public.creator_finish_media_deletion(uuid,boolean,text)
  to service_role;
