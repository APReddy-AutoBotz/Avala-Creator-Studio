create or replace function creator_private.creator_stage_rank(p_stage text)
returns integer
language sql
immutable
security invoker
set search_path = ''
as $$
  select case p_stage
    when 'CONTENT_REVIEW' then 1
    when 'CONTENT_APPROVED' then 2
    when 'SCRIPT_GENERATING' then 3
    when 'SCRIPT_REVIEW' then 4
    when 'SCRIPT_APPROVED' then 5
    when 'VOICE_GENERATING' then 6
    when 'VOICE_REVIEW' then 7
    when 'VOICE_APPROVED' then 8
    when 'AVATAR_GENERATING' then 9
    when 'AVATAR_REVIEW' then 10
    when 'AVATAR_APPROVED' then 11
    when 'EDIT_GENERATING' then 12
    when 'EDIT_REVIEW' then 13
    when 'EDIT_APPROVED' then 14
    when 'FINAL_RENDERING' then 15
    when 'FINAL_REVIEW' then 16
    when 'FINAL_APPROVED' then 17
    else 0
  end
$$;
revoke all on function creator_private.creator_stage_rank(text) from public, anon;
grant execute on function creator_private.creator_stage_rank(text) to authenticated;

create or replace function creator_private.creator_request_revision_impl(
  p_project_id uuid, p_target_kind text, p_reason text, p_idempotency_key uuid
) returns public.creator_projects
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_project public.creator_projects;
  v_boundary integer;
  v_existing public.creator_audit_events;
  v_reason text;
  v_target_rank integer;
begin
  if v_actor is null then raise exception 'UNAUTHORIZED'; end if;
  if p_target_kind not in ('content','script','voice','avatar','edit','final') then raise exception 'REVISION_TARGET_INVALID'; end if;
  if p_reason is null or char_length(btrim(p_reason)) not between 1 and 4000 then raise exception 'REVISION_REASON_INVALID'; end if;
  if p_idempotency_key is null then raise exception 'IDEMPOTENCY_KEY_REQUIRED'; end if;
  v_reason := btrim(p_reason);

  select * into v_project from public.creator_projects
  where id = p_project_id and owner_id = v_actor for update;
  if not found then raise exception 'PROJECT_NOT_FOUND'; end if;

  select * into v_existing from public.creator_audit_events
  where project_id = p_project_id and idempotency_key = p_idempotency_key;
  if found then
    if v_existing.event_code <> 'REVISION_REQUESTED'
      or v_existing.details->>'target_kind' is distinct from p_target_kind
      or v_existing.details->>'reason' is distinct from v_reason
    then raise exception 'IDEMPOTENCY_KEY_REUSED'; end if;
    return v_project;
  end if;

  v_target_rank := case p_target_kind
    when 'content' then 1 when 'script' then 4 when 'voice' then 7
    when 'avatar' then 10 when 'edit' then 13 else 16 end;
  if creator_private.creator_stage_rank(v_project.current_stage) < v_target_rank then
    raise exception 'REVISION_TARGET_NOT_REACHED';
  end if;

  v_boundary := array_position(array['content','script','voice','avatar','edit','final'], p_target_kind);
  update public.creator_artifacts set stale_at = coalesce(stale_at, now())
  where project_id = p_project_id
    and array_position(array['content','script','voice','avatar','edit','final'], kind) > v_boundary;
  update public.creator_reviews set invalidated_at = coalesce(invalidated_at, now()), invalidation_reason = 'UPSTREAM_REVISED'
  where project_id = p_project_id and invalidated_at is null and artifact_id in (
    select id from public.creator_artifacts where project_id = p_project_id and stale_at is not null
  );
  update public.creator_jobs set status = 'cancelled', error_code = 'UPSTREAM_REVISED', updated_at = now()
  where project_id = p_project_id and status in ('queued','leased','running');

  update public.creator_projects set current_stage = case p_target_kind
    when 'content' then 'CONTENT_REVIEW' when 'script' then 'SCRIPT_REVIEW' when 'voice' then 'VOICE_REVIEW'
    when 'avatar' then 'AVATAR_REVIEW' when 'edit' then 'EDIT_REVIEW' else 'FINAL_REVIEW' end,
    updated_at = now()
  where id = p_project_id returning * into v_project;

  insert into public.creator_audit_events(project_id, owner_id, actor_id, actor_kind, event_code, idempotency_key, details)
  values (p_project_id, v_actor, v_actor, 'human', 'REVISION_REQUESTED', p_idempotency_key,
          jsonb_build_object('target_kind', p_target_kind, 'reason', v_reason));
  return v_project;
end;
$$;

alter table public.creator_consent_profiles drop constraint creator_consent_profiles_status_check;
alter table public.creator_consent_profiles
  add constraint creator_consent_profiles_status_check
  check (status in ('draft','active','revoked','deleting','deleted'));

create or replace function creator_private.creator_storage_upload_allowed(p_name text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_profile_id uuid;
  v_profile public.creator_consent_profiles;
  v_intent public.creator_upload_intents;
begin
  if v_actor is null or p_name is null then return false; end if;

  select profile_id into v_profile_id
  from public.creator_upload_intents
  where owner_id = v_actor and object_path = p_name;
  if not found then return false; end if;

  select * into v_profile from public.creator_consent_profiles
  where id = v_profile_id and owner_id = v_actor
  for key share;
  if not found then return false; end if;

  select * into v_intent from public.creator_upload_intents
  where owner_id = v_actor and profile_id = v_profile_id and object_path = p_name
  for update;
  if not found then return false; end if;

  return v_intent.status = 'prepared'
    and v_intent.expires_at > now()
    and v_profile.status in ('draft','active')
    and v_profile.revoked_at is null
    and v_profile.deleted_at is null;
end;
$$;
revoke all on function creator_private.creator_storage_upload_allowed(text) from public, anon;
grant execute on function creator_private.creator_storage_upload_allowed(text) to authenticated;

drop policy if exists creator_private_insert on storage.objects;
create policy creator_private_insert on storage.objects for insert to authenticated
with check (
  bucket_id = 'creator-private'
  and (storage.foldername(name))[1] = (select auth.uid())::text
  and creator_private.creator_storage_upload_allowed(name)
);

create or replace function creator_private.creator_begin_delete_consent_profile_impl(
  p_profile_id uuid, p_idempotency_key uuid
) returns public.creator_consent_profiles
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_profile public.creator_consent_profiles;
  v_first boolean;
  v_effects jsonb;
begin
  if v_actor is null then raise exception 'UNAUTHORIZED'; end if;
  if p_idempotency_key is null then raise exception 'IDEMPOTENCY_KEY_REQUIRED'; end if;

  select * into v_profile from public.creator_consent_profiles
  where id = p_profile_id and owner_id = v_actor for update;
  if not found then raise exception 'PROFILE_NOT_FOUND'; end if;
  if v_profile.status = 'deleted' then return v_profile; end if;

  v_first := creator_private.claim_operation(v_actor, 'delete_profile', p_idempotency_key, p_profile_id);
  if not v_first then return v_profile; end if;

  update public.creator_consent_profiles
  set status = 'deleting'
  where id = p_profile_id returning * into v_profile;

  update public.creator_upload_intents
  set status = case when status = 'prepared' then 'expired' else status end
  where profile_id = p_profile_id and owner_id = v_actor;

  v_effects := creator_private.creator_invalidate_profile_dependents(p_profile_id, 'PROFILE_DELETE_PENDING');

  insert into public.creator_audit_events(owner_id, actor_id, actor_kind, event_code, profile_id, idempotency_key, details)
  values (v_actor, v_actor, 'human', 'CONSENT_PROFILE_DELETE_STARTED', p_profile_id, p_idempotency_key,
          jsonb_build_object('effects', v_effects));
  return v_profile;
end;
$$;

create or replace function creator_private.creator_finalize_delete_consent_profile_impl(
  p_profile_id uuid, p_idempotency_key uuid
) returns public.creator_consent_profiles
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_profile public.creator_consent_profiles;
  v_target uuid;
begin
  if v_actor is null then raise exception 'UNAUTHORIZED'; end if;
  if p_idempotency_key is null then raise exception 'IDEMPOTENCY_KEY_REQUIRED'; end if;

  select * into v_profile from public.creator_consent_profiles
  where id = p_profile_id and owner_id = v_actor for update;
  if not found then raise exception 'PROFILE_NOT_FOUND'; end if;
  if v_profile.status = 'deleted' then return v_profile; end if;
  if v_profile.status <> 'deleting' then raise exception 'PROFILE_DELETE_NOT_PREPARED'; end if;

  select target_id into v_target from creator_private.operation_claims
  where owner_id = v_actor and operation = 'delete_profile' and idempotency_key = p_idempotency_key;
  if v_target is null or v_target is distinct from p_profile_id then raise exception 'PROFILE_DELETE_NOT_PREPARED'; end if;

  perform 1 from public.creator_upload_intents
  where profile_id = p_profile_id and owner_id = v_actor
  for update;

  if exists (
    select 1
    from public.creator_upload_intents i
    join storage.objects o on o.bucket_id = 'creator-private' and o.name = i.object_path
    where i.profile_id = p_profile_id and i.owner_id = v_actor
  ) or exists (
    select 1
    from public.creator_identity_samples s
    join storage.objects o on o.bucket_id = 'creator-private' and o.name = s.object_path
    where s.profile_id = p_profile_id and s.owner_id = v_actor and s.object_path is not null
  ) then raise exception 'PRIVATE_MEDIA_DELETE_REQUIRED'; end if;

  update public.creator_identity_samples
  set status = 'deleted', deleted_at = now(), object_path = null, mime_type = null,
      byte_length = null, sha256 = null, rejection_code = null
  where profile_id = p_profile_id and owner_id = v_actor;

  update public.creator_upload_intents
  set status = 'deleted', deleted_at = now()
  where profile_id = p_profile_id and owner_id = v_actor;

  update public.creator_consent_profiles
  set status = 'deleted', deleted_at = now(), display_name = '[deleted]'
  where id = p_profile_id returning * into v_profile;

  insert into public.creator_audit_events(owner_id, actor_id, actor_kind, event_code, profile_id, idempotency_key)
  values (v_actor, v_actor, 'human', 'CONSENT_PROFILE_DELETE_COMPLETED', p_profile_id, p_idempotency_key);
  return v_profile;
end;
$$;

revoke all on function creator_private.creator_begin_delete_consent_profile_impl(uuid,uuid) from public, anon;
revoke all on function creator_private.creator_finalize_delete_consent_profile_impl(uuid,uuid) from public, anon;
grant execute on function creator_private.creator_begin_delete_consent_profile_impl(uuid,uuid) to authenticated;
grant execute on function creator_private.creator_finalize_delete_consent_profile_impl(uuid,uuid) to authenticated;

create or replace function public.creator_begin_delete_consent_profile(p_profile_id uuid, p_idempotency_key uuid)
returns public.creator_consent_profiles
language sql security invoker set search_path = ''
as $$ select creator_private.creator_begin_delete_consent_profile_impl(p_profile_id,p_idempotency_key) $$;
create or replace function public.creator_finalize_delete_consent_profile(p_profile_id uuid, p_idempotency_key uuid)
returns public.creator_consent_profiles
language sql security invoker set search_path = ''
as $$ select creator_private.creator_finalize_delete_consent_profile_impl(p_profile_id,p_idempotency_key) $$;
revoke all on function public.creator_begin_delete_consent_profile(uuid,uuid) from public, anon;
revoke all on function public.creator_finalize_delete_consent_profile(uuid,uuid) from public, anon;
grant execute on function public.creator_begin_delete_consent_profile(uuid,uuid) to authenticated;
grant execute on function public.creator_finalize_delete_consent_profile(uuid,uuid) to authenticated;

revoke all on function public.creator_delete_consent_profile(uuid,uuid) from authenticated, anon, public;
revoke all on function creator_private.creator_delete_consent_profile_impl(uuid,uuid) from authenticated, anon, public;

create or replace function creator_private.creator_activate_consent_profile_impl(p_profile_id uuid,p_idempotency_key uuid)
returns public.creator_consent_profiles
language plpgsql security definer set search_path=''
as $$
declare v_actor uuid:=auth.uid(); v_profile public.creator_consent_profiles; v_first boolean; begin
  if v_actor is null then raise exception 'UNAUTHORIZED'; end if;
  select * into v_profile from public.creator_consent_profiles where id=p_profile_id and owner_id=v_actor for update;
  if not found then raise exception 'PROFILE_NOT_FOUND'; end if;
  v_first:=creator_private.claim_operation(v_actor,'activate_profile',p_idempotency_key,p_profile_id); if not v_first then return v_profile; end if;
  if v_profile.status not in ('draft','active') or v_profile.revoked_at is not null or v_profile.deleted_at is not null then raise exception 'CONSENT_NOT_CURRENT'; end if;
  if not exists(select 1 from public.creator_identity_samples where profile_id=p_profile_id and owner_id=v_actor and status='validated' and deleted_at is null)
    then raise exception 'VALIDATED_SAMPLE_REQUIRED'; end if;
  update public.creator_consent_profiles set status='active',activated_at=coalesce(activated_at,now()) where id=p_profile_id returning * into v_profile;
  insert into public.creator_audit_events(owner_id,actor_id,actor_kind,event_code,profile_id,idempotency_key)
  values(v_actor,v_actor,'human','CONSENT_PROFILE_ACTIVATED',p_profile_id,p_idempotency_key);
  return v_profile;
end $$;

create or replace function creator_private.creator_revoke_consent_profile_impl(p_profile_id uuid,p_reason text,p_idempotency_key uuid)
returns public.creator_consent_profiles
language plpgsql security definer set search_path=''
as $$
declare v_actor uuid:=auth.uid(); v_profile public.creator_consent_profiles; v_first boolean; v_effects jsonb; v_existing public.creator_audit_events; v_reason text; begin
  if v_actor is null then raise exception 'UNAUTHORIZED'; end if;
  if p_reason is null or char_length(btrim(p_reason)) not between 1 and 1000 then raise exception 'REVOCATION_REASON_INVALID'; end if;
  v_reason:=btrim(p_reason);
  select * into v_profile from public.creator_consent_profiles where id=p_profile_id and owner_id=v_actor for update;
  if not found then raise exception 'PROFILE_NOT_FOUND'; end if;
  if v_profile.status='deleting' then raise exception 'PROFILE_DELETE_IN_PROGRESS'; end if;
  v_first:=creator_private.claim_operation(v_actor,'revoke_profile',p_idempotency_key,p_profile_id);
  if not v_first then
    select * into v_existing from public.creator_audit_events where owner_id=v_actor and event_code='CONSENT_PROFILE_REVOKED' and idempotency_key=p_idempotency_key;
    if not found or v_existing.profile_id is distinct from p_profile_id or v_existing.details->>'reason' is distinct from v_reason then raise exception 'IDEMPOTENCY_KEY_REUSED'; end if;
    return v_profile;
  end if;
  if v_profile.deleted_at is not null then raise exception 'PROFILE_DELETED'; end if;
  update public.creator_consent_profiles set status='revoked',revoked_at=coalesce(revoked_at,now()),revoked_reason=coalesce(revoked_reason,v_reason) where id=p_profile_id returning * into v_profile;
  v_effects:=creator_private.creator_invalidate_profile_dependents(p_profile_id,'CONSENT_REVOKED');
  update public.creator_upload_intents set status=case when status='prepared' then 'expired' else status end where profile_id=p_profile_id and owner_id=v_actor;
  insert into public.creator_audit_events(owner_id,actor_id,actor_kind,event_code,profile_id,idempotency_key,details)
  values(v_actor,v_actor,'human','CONSENT_PROFILE_REVOKED',p_profile_id,p_idempotency_key,jsonb_build_object('reason',v_reason,'effects',v_effects));
  return v_profile;
end $$;
