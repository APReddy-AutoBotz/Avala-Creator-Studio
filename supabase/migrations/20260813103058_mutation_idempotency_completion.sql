create or replace function creator_private.creator_create_project_impl(p_title text, p_client_request_id uuid)
returns public.creator_projects
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_project public.creator_projects;
  v_title text;
begin
  if v_actor is null then raise exception 'UNAUTHORIZED'; end if;
  if p_title is null or char_length(btrim(p_title)) not between 1 and 160 then raise exception 'PROJECT_TITLE_INVALID'; end if;
  if p_client_request_id is null then raise exception 'CLIENT_REQUEST_ID_REQUIRED'; end if;
  v_title := btrim(p_title);

  select * into v_project from public.creator_projects
  where owner_id = v_actor and client_request_id = p_client_request_id;
  if found then
    if v_project.title <> v_title then raise exception 'IDEMPOTENCY_KEY_REUSED'; end if;
    return v_project;
  end if;

  insert into public.creator_projects(owner_id, title, client_request_id)
  values (v_actor, v_title, p_client_request_id)
  returning * into v_project;

  insert into public.creator_audit_events(project_id, owner_id, actor_id, actor_kind, event_code, details)
  values (v_project.id, v_actor, v_actor, 'human', 'PROJECT_CREATED', jsonb_build_object('title', v_title));
  return v_project;
end;
$$;

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

create or replace function creator_private.creator_revoke_consent_profile_impl(
  p_profile_id uuid, p_reason text, p_idempotency_key uuid
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
  v_existing public.creator_audit_events;
  v_reason text;
begin
  if v_actor is null then raise exception 'UNAUTHORIZED'; end if;
  if p_reason is null or char_length(btrim(p_reason)) not between 1 and 1000 then raise exception 'REVOCATION_REASON_INVALID'; end if;
  v_reason := btrim(p_reason);

  select * into v_profile from public.creator_consent_profiles
  where id = p_profile_id and owner_id = v_actor for update;
  if not found then raise exception 'PROFILE_NOT_FOUND'; end if;

  v_first := creator_private.claim_operation(v_actor, 'revoke_profile', p_idempotency_key, p_profile_id);
  if not v_first then
    select * into v_existing from public.creator_audit_events
    where owner_id = v_actor and event_code = 'CONSENT_PROFILE_REVOKED' and idempotency_key = p_idempotency_key;
    if not found
      or v_existing.profile_id is distinct from p_profile_id
      or v_existing.details->>'reason' is distinct from v_reason
    then raise exception 'IDEMPOTENCY_KEY_REUSED'; end if;
    return v_profile;
  end if;
  if v_profile.deleted_at is not null then raise exception 'PROFILE_DELETED'; end if;

  update public.creator_consent_profiles
  set status = 'revoked', revoked_at = coalesce(revoked_at, now()), revoked_reason = coalesce(revoked_reason, v_reason)
  where id = p_profile_id returning * into v_profile;
  v_effects := creator_private.creator_invalidate_profile_dependents(p_profile_id, 'CONSENT_REVOKED');
  update public.creator_upload_intents set status = case when status = 'prepared' then 'expired' else status end
  where profile_id = p_profile_id and owner_id = v_actor;
  insert into public.creator_audit_events(owner_id, actor_id, actor_kind, event_code, profile_id, idempotency_key, details)
  values (v_actor, v_actor, 'human', 'CONSENT_PROFILE_REVOKED', p_profile_id, p_idempotency_key,
          jsonb_build_object('reason', v_reason, 'effects', v_effects));
  return v_profile;
end;
$$;

create or replace function creator_private.creator_register_identity_sample_impl(
  p_profile_id uuid, p_client_request_id uuid
) returns public.creator_identity_samples
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_profile public.creator_consent_profiles;
  v_intent public.creator_upload_intents;
  v_sample public.creator_identity_samples;
begin
  if v_actor is null then raise exception 'UNAUTHORIZED'; end if;
  if p_client_request_id is null then raise exception 'CLIENT_REQUEST_ID_REQUIRED'; end if;
  select * into v_profile from public.creator_consent_profiles
  where id = p_profile_id and owner_id = v_actor and status in ('draft','active') and revoked_at is null and deleted_at is null;
  if not found then raise exception 'PROFILE_NOT_AVAILABLE'; end if;

  select * into v_intent from public.creator_upload_intents
  where owner_id = v_actor and profile_id = p_profile_id and client_request_id = p_client_request_id for update;
  if not found then raise exception 'UPLOAD_INTENT_REQUIRED'; end if;
  if v_intent.status = 'registered' then
    select * into v_sample from public.creator_identity_samples where id = v_intent.sample_id;
    if not found then raise exception 'UPLOAD_INTENT_CORRUPT'; end if;
    return v_sample;
  end if;
  if v_intent.status <> 'prepared' then raise exception 'UPLOAD_INTENT_NOT_AVAILABLE'; end if;
  if v_intent.expires_at <= now() then
    update public.creator_upload_intents set status = 'expired' where id = v_intent.id;
    raise exception 'UPLOAD_INTENT_EXPIRED';
  end if;
  if not exists (
    select 1 from storage.objects o
    where o.bucket_id = 'creator-private' and o.name = v_intent.object_path and o.owner_id = v_actor::text
  ) then raise exception 'PRIVATE_OBJECT_NOT_FOUND'; end if;

  insert into public.creator_identity_samples(owner_id, profile_id, object_path, mime_type, byte_length, sha256, client_request_id)
  values (v_actor, p_profile_id, v_intent.object_path, v_intent.mime_type, v_intent.byte_length, v_intent.sha256, p_client_request_id)
  returning * into v_sample;
  update public.creator_upload_intents set status = 'registered', sample_id = v_sample.id, registered_at = now() where id = v_intent.id;
  insert into public.creator_audit_events(owner_id, actor_id, actor_kind, event_code, profile_id, details)
  values (v_actor, v_actor, 'human', 'IDENTITY_SAMPLE_REGISTERED', p_profile_id,
          jsonb_build_object('intent_id', v_intent.id, 'sample_id', v_sample.id));
  return v_sample;
end;
$$;
