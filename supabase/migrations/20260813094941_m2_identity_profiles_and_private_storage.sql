insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('creator-private','creator-private',false,250000000,array[
  'audio/wav','audio/mpeg','audio/mp4','audio/x-m4a','video/mp4','video/quicktime','image/jpeg','image/png','image/webp'
])
on conflict(id) do update set public=false,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;

create policy creator_private_select on storage.objects for select to authenticated
using(bucket_id='creator-private' and (storage.foldername(name))[1]=(select auth.uid())::text and owner_id=(select auth.uid())::text);
create policy creator_private_insert on storage.objects for insert to authenticated
with check(bucket_id='creator-private' and (storage.foldername(name))[1]=(select auth.uid())::text);
create policy creator_private_delete on storage.objects for delete to authenticated
using(bucket_id='creator-private' and (storage.foldername(name))[1]=(select auth.uid())::text and owner_id=(select auth.uid())::text);

create or replace function creator_private.creator_create_consent_profile_impl(
  p_kind text,p_display_name text,p_consent_statement_version text,p_consent_sha256 text,p_client_request_id uuid
) returns public.creator_consent_profiles
language plpgsql security definer set search_path=''
as $$
declare v_actor uuid:=auth.uid(); v_profile public.creator_consent_profiles; begin
  if v_actor is null then raise exception 'UNAUTHORIZED'; end if;
  if p_kind not in ('voice','avatar') then raise exception 'PROFILE_KIND_INVALID'; end if;
  if p_display_name is null or char_length(btrim(p_display_name)) not between 1 and 120 then raise exception 'PROFILE_NAME_INVALID'; end if;
  if p_consent_statement_version is null or char_length(btrim(p_consent_statement_version)) not between 1 and 64 then raise exception 'CONSENT_STATEMENT_INVALID'; end if;
  if p_consent_sha256 is null or p_consent_sha256 !~ '^[a-f0-9]{64}$' then raise exception 'SHA256_INVALID'; end if;
  if p_client_request_id is null then raise exception 'CLIENT_REQUEST_ID_REQUIRED'; end if;
  select * into v_profile from public.creator_consent_profiles where owner_id=v_actor and client_request_id=p_client_request_id;
  if found then return v_profile; end if;
  insert into public.creator_consent_profiles(owner_id,profile_kind,display_name,consent_statement_version,consent_sha256,client_request_id)
  values(v_actor,p_kind,btrim(p_display_name),btrim(p_consent_statement_version),p_consent_sha256,p_client_request_id) returning * into v_profile;
  insert into public.creator_audit_events(owner_id,actor_id,actor_kind,event_code,profile_id)
  values(v_actor,v_actor,'human','CONSENT_PROFILE_CREATED',v_profile.id);
  return v_profile;
end $$;

create or replace function creator_private.creator_register_identity_sample_impl(
  p_profile_id uuid,p_object_path text,p_mime_type text,p_byte_length bigint,p_sha256 text,p_client_request_id uuid
) returns public.creator_identity_samples
language plpgsql security definer set search_path=''
as $$
declare v_actor uuid:=auth.uid(); v_profile public.creator_consent_profiles; v_sample public.creator_identity_samples; v_prefix text; begin
  if v_actor is null then raise exception 'UNAUTHORIZED'; end if;
  if p_client_request_id is null then raise exception 'CLIENT_REQUEST_ID_REQUIRED'; end if;
  select * into v_profile from public.creator_consent_profiles where id=p_profile_id and owner_id=v_actor and status in ('draft','active') and revoked_at is null and deleted_at is null;
  if not found then raise exception 'PROFILE_NOT_AVAILABLE'; end if;
  v_prefix:=v_actor::text||'/';
  if p_object_path is null or left(p_object_path,char_length(v_prefix))<>v_prefix or p_object_path~*'^https?://' or p_object_path~'(^|/)\.\.(/|$)' then raise exception 'PRIVATE_OBJECT_PATH_REQUIRED'; end if;
  if p_mime_type is null or char_length(p_mime_type) not between 1 and 120 then raise exception 'MIME_TYPE_INVALID'; end if;
  if p_byte_length is null or p_byte_length<=0 or p_byte_length>250000000 then raise exception 'FILE_SIZE_INVALID'; end if;
  if p_sha256 is null or p_sha256!~'^[a-f0-9]{64}$' then raise exception 'SHA256_INVALID'; end if;
  if v_profile.profile_kind='voice' and p_mime_type not in ('audio/wav','audio/mpeg','audio/mp4','audio/x-m4a') then raise exception 'MIME_TYPE_NOT_ALLOWED'; end if;
  if v_profile.profile_kind='avatar' and p_mime_type not in ('video/mp4','video/quicktime','image/jpeg','image/png','image/webp') then raise exception 'MIME_TYPE_NOT_ALLOWED'; end if;
  select * into v_sample from public.creator_identity_samples where owner_id=v_actor and client_request_id=p_client_request_id;
  if found then return v_sample; end if;
  if not exists(select 1 from storage.objects o where o.bucket_id='creator-private' and o.name=p_object_path and o.owner_id=v_actor::text) then raise exception 'PRIVATE_OBJECT_NOT_FOUND'; end if;
  insert into public.creator_identity_samples(owner_id,profile_id,object_path,mime_type,byte_length,sha256,client_request_id)
  values(v_actor,p_profile_id,p_object_path,p_mime_type,p_byte_length,p_sha256,p_client_request_id) returning * into v_sample;
  insert into public.creator_audit_events(owner_id,actor_id,actor_kind,event_code,profile_id)
  values(v_actor,v_actor,'human','IDENTITY_SAMPLE_REGISTERED',p_profile_id);
  return v_sample;
end $$;

create or replace function creator_private.creator_activate_consent_profile_impl(p_profile_id uuid,p_idempotency_key uuid)
returns public.creator_consent_profiles
language plpgsql security definer set search_path=''
as $$
declare v_actor uuid:=auth.uid(); v_profile public.creator_consent_profiles; begin
  if v_actor is null then raise exception 'UNAUTHORIZED'; end if;
  if p_idempotency_key is null then raise exception 'IDEMPOTENCY_KEY_REQUIRED'; end if;
  select * into v_profile from public.creator_consent_profiles where id=p_profile_id and owner_id=v_actor for update;
  if not found then raise exception 'PROFILE_NOT_FOUND'; end if;
  if v_profile.revoked_at is not null or v_profile.deleted_at is not null then raise exception 'CONSENT_NOT_CURRENT'; end if;
  if not exists(select 1 from public.creator_identity_samples where profile_id=p_profile_id and owner_id=v_actor and status='validated' and deleted_at is null) then raise exception 'VALIDATED_SAMPLE_REQUIRED'; end if;
  if v_profile.status<>'active' then
    update public.creator_consent_profiles set status='active',activated_at=now() where id=p_profile_id returning * into v_profile;
    insert into public.creator_audit_events(owner_id,actor_id,actor_kind,event_code,profile_id,idempotency_key)
    values(v_actor,v_actor,'human','CONSENT_PROFILE_ACTIVATED',p_profile_id,p_idempotency_key) on conflict do nothing;
  end if;
  return v_profile;
end $$;

create or replace function creator_private.creator_revoke_consent_profile_impl(p_profile_id uuid,p_reason text,p_idempotency_key uuid)
returns public.creator_consent_profiles
language plpgsql security definer set search_path=''
as $$
declare v_actor uuid:=auth.uid(); v_profile public.creator_consent_profiles; begin
  if v_actor is null then raise exception 'UNAUTHORIZED'; end if;
  if p_idempotency_key is null then raise exception 'IDEMPOTENCY_KEY_REQUIRED'; end if;
  if p_reason is null or char_length(btrim(p_reason)) not between 1 and 1000 then raise exception 'REVOCATION_REASON_INVALID'; end if;
  select * into v_profile from public.creator_consent_profiles where id=p_profile_id and owner_id=v_actor for update;
  if not found then raise exception 'PROFILE_NOT_FOUND'; end if;
  if v_profile.deleted_at is not null then raise exception 'PROFILE_DELETED'; end if;
  if v_profile.revoked_at is null then
    update public.creator_consent_profiles set status='revoked',revoked_at=now(),revoked_reason=btrim(p_reason) where id=p_profile_id returning * into v_profile;
    update public.creator_jobs set status='cancelled',error_code='CONSENT_REVOKED',updated_at=now() where identity_profile_id=p_profile_id and status in ('queued','leased','running');
    update public.creator_artifacts set stale_at=coalesce(stale_at,now()) where identity_profile_id=p_profile_id and stale_at is null;
    insert into public.creator_audit_events(owner_id,actor_id,actor_kind,event_code,profile_id,idempotency_key)
    values(v_actor,v_actor,'human','CONSENT_PROFILE_REVOKED',p_profile_id,p_idempotency_key) on conflict do nothing;
  end if;
  return v_profile;
end $$;

create or replace function creator_private.creator_delete_consent_profile_impl(p_profile_id uuid,p_idempotency_key uuid)
returns public.creator_consent_profiles
language plpgsql security definer set search_path=''
as $$
declare v_actor uuid:=auth.uid(); v_profile public.creator_consent_profiles; begin
  if v_actor is null then raise exception 'UNAUTHORIZED'; end if;
  if p_idempotency_key is null then raise exception 'IDEMPOTENCY_KEY_REQUIRED'; end if;
  select * into v_profile from public.creator_consent_profiles where id=p_profile_id and owner_id=v_actor for update;
  if not found then raise exception 'PROFILE_NOT_FOUND'; end if;
  if v_profile.deleted_at is not null then return v_profile; end if;
  if exists(select 1 from public.creator_identity_samples s join storage.objects o on o.bucket_id='creator-private' and o.name=s.object_path where s.profile_id=p_profile_id and s.owner_id=v_actor and s.status<>'deleted') then raise exception 'PRIVATE_MEDIA_DELETE_REQUIRED'; end if;
  update public.creator_jobs set status='cancelled',error_code='PROFILE_DELETED',updated_at=now() where identity_profile_id=p_profile_id and status in ('queued','leased','running');
  update public.creator_artifacts set stale_at=coalesce(stale_at,now()) where identity_profile_id=p_profile_id and stale_at is null;
  update public.creator_identity_samples set status='deleted',deleted_at=now(),object_path=null,mime_type=null,byte_length=null,sha256=null,rejection_code=null where profile_id=p_profile_id and owner_id=v_actor;
  update public.creator_consent_profiles set status='deleted',deleted_at=now(),display_name='[deleted]' where id=p_profile_id returning * into v_profile;
  insert into public.creator_audit_events(owner_id,actor_id,actor_kind,event_code,profile_id,idempotency_key)
  values(v_actor,v_actor,'human','CONSENT_PROFILE_DELETED',p_profile_id,p_idempotency_key) on conflict do nothing;
  return v_profile;
end $$;

create or replace function creator_private.creator_record_identity_sample_validation_impl(p_sample_id uuid,p_valid boolean,p_rejection_code text default null)
returns public.creator_identity_samples
language plpgsql security definer set search_path=''
as $$
declare v_sample public.creator_identity_samples; begin
  select * into v_sample from public.creator_identity_samples where id=p_sample_id for update;
  if not found then raise exception 'SAMPLE_NOT_FOUND'; end if;
  if v_sample.status<>'pending_validation' then return v_sample; end if;
  if not exists(select 1 from storage.objects o where o.bucket_id='creator-private' and o.name=v_sample.object_path and o.owner_id=v_sample.owner_id::text) then raise exception 'PRIVATE_OBJECT_NOT_FOUND'; end if;
  update public.creator_identity_samples set status=case when p_valid then 'validated' else 'rejected' end,validated_at=now(),rejection_code=case when p_valid then null else coalesce(nullif(btrim(p_rejection_code),''),'VALIDATION_REJECTED') end where id=p_sample_id returning * into v_sample;
  insert into public.creator_audit_events(owner_id,actor_kind,event_code,profile_id)
  values(v_sample.owner_id,'worker',case when p_valid then 'IDENTITY_SAMPLE_VALIDATED' else 'IDENTITY_SAMPLE_REJECTED' end,v_sample.profile_id);
  return v_sample;
end $$;

revoke all on function creator_private.creator_create_consent_profile_impl(text,text,text,text,uuid),creator_private.creator_register_identity_sample_impl(uuid,text,text,bigint,text,uuid),creator_private.creator_activate_consent_profile_impl(uuid,uuid),creator_private.creator_revoke_consent_profile_impl(uuid,text,uuid),creator_private.creator_delete_consent_profile_impl(uuid,uuid) from public,anon;
revoke all on function creator_private.creator_record_identity_sample_validation_impl(uuid,boolean,text) from public,anon,authenticated;
grant execute on function creator_private.creator_create_consent_profile_impl(text,text,text,text,uuid),creator_private.creator_register_identity_sample_impl(uuid,text,text,bigint,text,uuid),creator_private.creator_activate_consent_profile_impl(uuid,uuid),creator_private.creator_revoke_consent_profile_impl(uuid,text,uuid),creator_private.creator_delete_consent_profile_impl(uuid,uuid) to authenticated;
grant execute on function creator_private.creator_record_identity_sample_validation_impl(uuid,boolean,text) to service_role;

create or replace function public.creator_create_consent_profile(p_kind text,p_display_name text,p_consent_statement_version text,p_consent_sha256 text,p_client_request_id uuid) returns public.creator_consent_profiles language sql security invoker set search_path='' as $$select creator_private.creator_create_consent_profile_impl(p_kind,p_display_name,p_consent_statement_version,p_consent_sha256,p_client_request_id)$$;
create or replace function public.creator_register_identity_sample(p_profile_id uuid,p_object_path text,p_mime_type text,p_byte_length bigint,p_sha256 text,p_client_request_id uuid) returns public.creator_identity_samples language sql security invoker set search_path='' as $$select creator_private.creator_register_identity_sample_impl(p_profile_id,p_object_path,p_mime_type,p_byte_length,p_sha256,p_client_request_id)$$;
create or replace function public.creator_activate_consent_profile(p_profile_id uuid,p_idempotency_key uuid) returns public.creator_consent_profiles language sql security invoker set search_path='' as $$select creator_private.creator_activate_consent_profile_impl(p_profile_id,p_idempotency_key)$$;
create or replace function public.creator_revoke_consent_profile(p_profile_id uuid,p_reason text,p_idempotency_key uuid) returns public.creator_consent_profiles language sql security invoker set search_path='' as $$select creator_private.creator_revoke_consent_profile_impl(p_profile_id,p_reason,p_idempotency_key)$$;
create or replace function public.creator_delete_consent_profile(p_profile_id uuid,p_idempotency_key uuid) returns public.creator_consent_profiles language sql security invoker set search_path='' as $$select creator_private.creator_delete_consent_profile_impl(p_profile_id,p_idempotency_key)$$;
create or replace function public.creator_record_identity_sample_validation(p_sample_id uuid,p_valid boolean,p_rejection_code text default null) returns public.creator_identity_samples language sql security invoker set search_path='' as $$select creator_private.creator_record_identity_sample_validation_impl(p_sample_id,p_valid,p_rejection_code)$$;
revoke all on function public.creator_create_consent_profile(text,text,text,text,uuid),public.creator_register_identity_sample(uuid,text,text,bigint,text,uuid),public.creator_activate_consent_profile(uuid,uuid),public.creator_revoke_consent_profile(uuid,text,uuid),public.creator_delete_consent_profile(uuid,uuid) from public,anon;
revoke all on function public.creator_record_identity_sample_validation(uuid,boolean,text) from public,anon,authenticated;
grant execute on function public.creator_create_consent_profile(text,text,text,text,uuid),public.creator_register_identity_sample(uuid,text,text,bigint,text,uuid),public.creator_activate_consent_profile(uuid,uuid),public.creator_revoke_consent_profile(uuid,text,uuid),public.creator_delete_consent_profile(uuid,uuid) to authenticated;
grant execute on function public.creator_record_identity_sample_validation(uuid,boolean,text) to service_role;
