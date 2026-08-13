create or replace function creator_private.creator_create_consent_profile_impl(
  p_kind text, p_display_name text, p_consent_statement_version text,
  p_consent_sha256 text, p_client_request_id uuid
) returns public.creator_consent_profiles
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_profile public.creator_consent_profiles;
  v_expected text;
  v_name text;
begin
  if v_actor is null then raise exception 'UNAUTHORIZED'; end if;
  if p_kind not in ('voice','avatar') then raise exception 'PROFILE_KIND_INVALID'; end if;
  if p_display_name is null or char_length(btrim(p_display_name)) not between 1 and 120 then raise exception 'PROFILE_NAME_INVALID'; end if;
  if p_client_request_id is null then raise exception 'CLIENT_REQUEST_ID_REQUIRED'; end if;
  v_name := btrim(p_display_name);

  select statement_sha256 into v_expected from creator_private.consent_statements
  where profile_kind = p_kind and statement_version = p_consent_statement_version and active = true;
  if v_expected is null or p_consent_sha256 is distinct from v_expected then raise exception 'CONSENT_EVIDENCE_INVALID'; end if;

  insert into public.creator_consent_profiles(
    owner_id, profile_kind, display_name, consent_statement_version, consent_sha256, client_request_id
  ) values (
    v_actor, p_kind, v_name, p_consent_statement_version, p_consent_sha256, p_client_request_id
  )
  on conflict (owner_id, client_request_id) do nothing
  returning * into v_profile;

  if found then
    insert into public.creator_audit_events(owner_id, actor_id, actor_kind, event_code, profile_id)
    values (v_actor, v_actor, 'human', 'CONSENT_PROFILE_CREATED', v_profile.id);
    return v_profile;
  end if;

  select * into v_profile from public.creator_consent_profiles
  where owner_id = v_actor and client_request_id = p_client_request_id;
  if not found then raise exception 'CONSENT_PROFILE_REPLAY_LOST'; end if;
  if v_profile.profile_kind <> p_kind
    or v_profile.display_name <> v_name
    or v_profile.consent_statement_version <> p_consent_statement_version
    or v_profile.consent_sha256 <> p_consent_sha256
  then raise exception 'IDEMPOTENCY_KEY_REUSED'; end if;
  return v_profile;
end;
$$;

create or replace function creator_private.creator_prepare_identity_upload_impl(
  p_profile_id uuid, p_file_name text, p_mime_type text, p_byte_length bigint,
  p_sha256 text, p_client_request_id uuid
) returns public.creator_upload_intents
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_profile public.creator_consent_profiles;
  v_intent public.creator_upload_intents;
  v_extension text;
  v_path text;
begin
  if v_actor is null then raise exception 'UNAUTHORIZED'; end if;
  if p_client_request_id is null then raise exception 'CLIENT_REQUEST_ID_REQUIRED'; end if;
  if p_file_name is null or char_length(p_file_name) not between 1 and 120 or p_file_name !~ '^[A-Za-z0-9][A-Za-z0-9._-]*$' then raise exception 'FILE_NAME_INVALID'; end if;
  if p_byte_length is null or p_byte_length <= 0 or p_byte_length > 250000000 then raise exception 'FILE_SIZE_INVALID'; end if;
  if p_sha256 is null or p_sha256 !~ '^[a-f0-9]{64}$' then raise exception 'SHA256_INVALID'; end if;

  select * into v_profile from public.creator_consent_profiles
  where id = p_profile_id and owner_id = v_actor and status in ('draft','active')
    and revoked_at is null and deleted_at is null
  for key share;
  if not found then raise exception 'PROFILE_NOT_AVAILABLE'; end if;

  if v_profile.profile_kind = 'voice' then
    if p_mime_type not in ('audio/wav','audio/mpeg','audio/mp4','audio/x-m4a') then raise exception 'MIME_TYPE_NOT_ALLOWED'; end if;
    v_extension := case p_mime_type when 'audio/wav' then 'wav' when 'audio/mpeg' then 'mp3' else 'm4a' end;
  else
    if p_mime_type not in ('video/mp4','video/quicktime','image/jpeg','image/png','image/webp') then raise exception 'MIME_TYPE_NOT_ALLOWED'; end if;
    v_extension := case p_mime_type when 'video/mp4' then 'mp4' when 'video/quicktime' then 'mov' when 'image/jpeg' then 'jpg' when 'image/png' then 'png' else 'webp' end;
  end if;

  v_path := v_actor::text || '/' || p_profile_id::text || '/' || p_client_request_id::text || '/sample.' || v_extension;

  insert into public.creator_upload_intents(
    owner_id, profile_id, object_path, original_file_name, mime_type, byte_length,
    sha256, client_request_id, expires_at
  ) values (
    v_actor, p_profile_id, v_path, p_file_name, p_mime_type, p_byte_length,
    p_sha256, p_client_request_id, now() + interval '2 hours'
  )
  on conflict (owner_id, client_request_id) do nothing
  returning * into v_intent;

  if found then
    insert into public.creator_audit_events(owner_id, actor_id, actor_kind, event_code, profile_id, details)
    values (v_actor, v_actor, 'human', 'IDENTITY_UPLOAD_PREPARED', p_profile_id,
            jsonb_build_object('intent_id', v_intent.id, 'expires_at', v_intent.expires_at));
    return v_intent;
  end if;

  select * into v_intent from public.creator_upload_intents
  where owner_id = v_actor and client_request_id = p_client_request_id;
  if not found then raise exception 'UPLOAD_PREPARATION_REPLAY_LOST'; end if;
  if v_intent.profile_id <> p_profile_id
    or v_intent.object_path <> v_path
    or v_intent.original_file_name <> p_file_name
    or v_intent.mime_type <> p_mime_type
    or v_intent.byte_length <> p_byte_length
    or v_intent.sha256 <> p_sha256
  then raise exception 'IDEMPOTENCY_KEY_REUSED'; end if;
  return v_intent;
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
  where id = p_profile_id and owner_id = v_actor and status in ('draft','active')
    and revoked_at is null and deleted_at is null
  for key share;
  if not found then raise exception 'PROFILE_NOT_AVAILABLE'; end if;

  select * into v_intent from public.creator_upload_intents
  where owner_id = v_actor and profile_id = p_profile_id and client_request_id = p_client_request_id
  for update;
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
