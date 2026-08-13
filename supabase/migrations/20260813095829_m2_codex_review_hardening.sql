create table creator_private.consent_statements (
  profile_kind text not null check (profile_kind in ('voice','avatar')),
  statement_version text not null,
  statement_text text not null,
  statement_sha256 text not null check (statement_sha256 ~ '^[a-f0-9]{64}$'),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  primary key(profile_kind,statement_version)
);
revoke all on table creator_private.consent_statements from public,anon,authenticated;
insert into creator_private.consent_statements(profile_kind,statement_version,statement_text,statement_sha256)
values
('voice','self-owned-v1','I confirm that this is my own voice and authorize Avala Creator Studio to use the submitted sample only for my requested synthetic narration workflow.','0b8f3516bacfbd4275c6f950e5ce9625f914db9916b77f08cf2264f28329d19b'),
('avatar','self-owned-v1','I confirm that this is my own likeness and authorize Avala Creator Studio to use the submitted sample only for my requested synthetic avatar workflow.','312d2299b85694391156bdc63daf9a21ea699b8ea4942d9be708185b22a194fa');

create table creator_private.operation_claims (
  owner_id uuid not null, operation text not null, idempotency_key uuid not null, target_id uuid not null,
  created_at timestamptz not null default now(), primary key(owner_id,operation,idempotency_key)
);
revoke all on table creator_private.operation_claims from public,anon,authenticated;

create table public.creator_upload_intents (
  id uuid primary key default gen_random_uuid(), owner_id uuid not null references auth.users(id) on delete cascade,
  profile_id uuid not null references public.creator_consent_profiles(id) on delete cascade, object_path text not null,
  original_file_name text not null check (char_length(original_file_name) between 1 and 120),
  mime_type text not null check (char_length(mime_type) between 1 and 120),
  byte_length bigint not null check (byte_length>0 and byte_length<=250000000),
  sha256 text not null check (sha256~'^[a-f0-9]{64}$'),
  status text not null default 'prepared' check (status in ('prepared','registered','deleted','expired')),
  client_request_id uuid not null, sample_id uuid references public.creator_identity_samples(id) on delete set null,
  expires_at timestamptz not null, created_at timestamptz not null default now(), registered_at timestamptz, deleted_at timestamptz,
  unique(owner_id,client_request_id), unique(owner_id,object_path),
  check (object_path !~* '^https?://' and object_path !~ '(^|/)\.\.(/|$)')
);
create index creator_upload_intents_profile_status_idx on public.creator_upload_intents(profile_id,status);
create index creator_upload_intents_owner_status_idx on public.creator_upload_intents(owner_id,status);
alter table public.creator_upload_intents enable row level security;
revoke all on table public.creator_upload_intents from anon,authenticated;
grant select on table public.creator_upload_intents to authenticated;
create policy creator_upload_intents_owner_select on public.creator_upload_intents for select to authenticated
using ((select auth.uid()) is not null and owner_id=(select auth.uid()));

create or replace function creator_private.claim_operation(p_owner_id uuid,p_operation text,p_idempotency_key uuid,p_target_id uuid)
returns boolean language plpgsql security definer set search_path=''
as $$
declare v_target uuid; begin
  if p_idempotency_key is null then raise exception 'IDEMPOTENCY_KEY_REQUIRED'; end if;
  begin
    insert into creator_private.operation_claims(owner_id,operation,idempotency_key,target_id)
    values(p_owner_id,p_operation,p_idempotency_key,p_target_id);
    return true;
  exception when unique_violation then
    select target_id into v_target from creator_private.operation_claims
    where owner_id=p_owner_id and operation=p_operation and idempotency_key=p_idempotency_key;
    if v_target is distinct from p_target_id then raise exception 'IDEMPOTENCY_KEY_REUSED'; end if;
    return false;
  end;
end $$;
revoke all on function creator_private.claim_operation(uuid,text,uuid,uuid) from public,anon,authenticated;

create or replace function creator_private.creator_invalidate_profile_dependents(p_profile_id uuid,p_reason text)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare
  v_kind text; v_projects uuid[]; v_artifacts integer:=0; v_reviews integer:=0; v_jobs integer:=0; v_projects_updated integer:=0;
begin
  select profile_kind into v_kind from public.creator_consent_profiles where id=p_profile_id;
  if v_kind is null then raise exception 'PROFILE_NOT_FOUND'; end if;
  select array_agg(distinct project_id) into v_projects from (
    select project_id from public.creator_artifacts where identity_profile_id=p_profile_id
    union select project_id from public.creator_jobs where identity_profile_id=p_profile_id
  ) affected;
  if coalesce(array_length(v_projects,1),0)=0 then return jsonb_build_object('projects',0,'artifacts',0,'reviews',0,'jobs',0); end if;

  if v_kind='voice' then
    update public.creator_artifacts set stale_at=coalesce(stale_at,now())
      where project_id=any(v_projects) and kind in ('voice','avatar','edit','final') and stale_at is null;
    get diagnostics v_artifacts=row_count;
    update public.creator_reviews r set invalidated_at=coalesce(r.invalidated_at,now()),invalidation_reason=p_reason
      where r.project_id=any(v_projects) and r.invalidated_at is null
        and exists(select 1 from public.creator_artifacts a where a.id=r.artifact_id and a.kind in ('voice','avatar','edit','final'));
    get diagnostics v_reviews=row_count;
    update public.creator_jobs set status='cancelled',error_code=p_reason,updated_at=now()
      where project_id=any(v_projects) and job_type in ('voice','avatar','edit','final') and status in ('queued','leased','running');
    get diagnostics v_jobs=row_count;
    update public.creator_projects set current_stage=case when current_stage in (
      'VOICE_GENERATING','VOICE_REVIEW','VOICE_APPROVED','AVATAR_GENERATING','AVATAR_REVIEW','AVATAR_APPROVED',
      'EDIT_GENERATING','EDIT_REVIEW','EDIT_APPROVED','FINAL_RENDERING','FINAL_REVIEW','FINAL_APPROVED'
    ) then 'SCRIPT_APPROVED' else current_stage end,updated_at=now() where id=any(v_projects);
    get diagnostics v_projects_updated=row_count;
  else
    update public.creator_artifacts set stale_at=coalesce(stale_at,now())
      where project_id=any(v_projects) and kind in ('avatar','edit','final') and stale_at is null;
    get diagnostics v_artifacts=row_count;
    update public.creator_reviews r set invalidated_at=coalesce(r.invalidated_at,now()),invalidation_reason=p_reason
      where r.project_id=any(v_projects) and r.invalidated_at is null
        and exists(select 1 from public.creator_artifacts a where a.id=r.artifact_id and a.kind in ('avatar','edit','final'));
    get diagnostics v_reviews=row_count;
    update public.creator_jobs set status='cancelled',error_code=p_reason,updated_at=now()
      where project_id=any(v_projects) and job_type in ('avatar','edit','final') and status in ('queued','leased','running');
    get diagnostics v_jobs=row_count;
    update public.creator_projects set current_stage=case when current_stage in (
      'AVATAR_GENERATING','AVATAR_REVIEW','AVATAR_APPROVED','EDIT_GENERATING','EDIT_REVIEW','EDIT_APPROVED','FINAL_RENDERING','FINAL_REVIEW','FINAL_APPROVED'
    ) then 'VOICE_APPROVED' else current_stage end,updated_at=now() where id=any(v_projects);
    get diagnostics v_projects_updated=row_count;
  end if;
  return jsonb_build_object('projects',v_projects_updated,'artifacts',v_artifacts,'reviews',v_reviews,'jobs',v_jobs);
end $$;
revoke all on function creator_private.creator_invalidate_profile_dependents(uuid,text) from public,anon,authenticated;

create or replace function creator_private.creator_create_consent_profile_impl(
  p_kind text,p_display_name text,p_consent_statement_version text,p_consent_sha256 text,p_client_request_id uuid
) returns public.creator_consent_profiles language plpgsql security definer set search_path=''
as $$
declare v_actor uuid:=auth.uid(); v_profile public.creator_consent_profiles; v_expected text; begin
  if v_actor is null then raise exception 'UNAUTHORIZED'; end if;
  if p_kind not in ('voice','avatar') then raise exception 'PROFILE_KIND_INVALID'; end if;
  if p_display_name is null or char_length(btrim(p_display_name)) not between 1 and 120 then raise exception 'PROFILE_NAME_INVALID'; end if;
  if p_client_request_id is null then raise exception 'CLIENT_REQUEST_ID_REQUIRED'; end if;
  select statement_sha256 into v_expected from creator_private.consent_statements
  where profile_kind=p_kind and statement_version=p_consent_statement_version and active=true;
  if v_expected is null or p_consent_sha256 is distinct from v_expected then raise exception 'CONSENT_EVIDENCE_INVALID'; end if;
  select * into v_profile from public.creator_consent_profiles where owner_id=v_actor and client_request_id=p_client_request_id;
  if found then
    if v_profile.profile_kind<>p_kind or v_profile.display_name<>btrim(p_display_name)
      or v_profile.consent_statement_version<>p_consent_statement_version or v_profile.consent_sha256<>p_consent_sha256
    then raise exception 'IDEMPOTENCY_KEY_REUSED'; end if;
    return v_profile;
  end if;
  insert into public.creator_consent_profiles(owner_id,profile_kind,display_name,consent_statement_version,consent_sha256,client_request_id)
  values(v_actor,p_kind,btrim(p_display_name),p_consent_statement_version,p_consent_sha256,p_client_request_id) returning * into v_profile;
  insert into public.creator_audit_events(owner_id,actor_id,actor_kind,event_code,profile_id)
  values(v_actor,v_actor,'human','CONSENT_PROFILE_CREATED',v_profile.id);
  return v_profile;
end $$;

create or replace function creator_private.creator_prepare_identity_upload_impl(
  p_profile_id uuid,p_file_name text,p_mime_type text,p_byte_length bigint,p_sha256 text,p_client_request_id uuid
) returns public.creator_upload_intents language plpgsql security definer set search_path=''
as $$
declare v_actor uuid:=auth.uid(); v_profile public.creator_consent_profiles; v_intent public.creator_upload_intents; v_extension text; v_path text; begin
  if v_actor is null then raise exception 'UNAUTHORIZED'; end if;
  if p_client_request_id is null then raise exception 'CLIENT_REQUEST_ID_REQUIRED'; end if;
  if p_file_name is null or char_length(p_file_name) not between 1 and 120 or p_file_name !~ '^[A-Za-z0-9][A-Za-z0-9._-]*$' then raise exception 'FILE_NAME_INVALID'; end if;
  if p_byte_length is null or p_byte_length<=0 or p_byte_length>250000000 then raise exception 'FILE_SIZE_INVALID'; end if;
  if p_sha256 is null or p_sha256!~'^[a-f0-9]{64}$' then raise exception 'SHA256_INVALID'; end if;
  select * into v_profile from public.creator_consent_profiles
    where id=p_profile_id and owner_id=v_actor and status in ('draft','active') and revoked_at is null and deleted_at is null;
  if not found then raise exception 'PROFILE_NOT_AVAILABLE'; end if;
  if v_profile.profile_kind='voice' then
    if p_mime_type not in ('audio/wav','audio/mpeg','audio/mp4','audio/x-m4a') then raise exception 'MIME_TYPE_NOT_ALLOWED'; end if;
    v_extension:=case p_mime_type when 'audio/wav' then 'wav' when 'audio/mpeg' then 'mp3' else 'm4a' end;
  else
    if p_mime_type not in ('video/mp4','video/quicktime','image/jpeg','image/png','image/webp') then raise exception 'MIME_TYPE_NOT_ALLOWED'; end if;
    v_extension:=case p_mime_type when 'video/mp4' then 'mp4' when 'video/quicktime' then 'mov' when 'image/jpeg' then 'jpg' when 'image/png' then 'png' else 'webp' end;
  end if;
  select * into v_intent from public.creator_upload_intents where owner_id=v_actor and client_request_id=p_client_request_id;
  if found then
    if v_intent.profile_id<>p_profile_id or v_intent.original_file_name<>p_file_name or v_intent.mime_type<>p_mime_type
      or v_intent.byte_length<>p_byte_length or v_intent.sha256<>p_sha256 then raise exception 'IDEMPOTENCY_KEY_REUSED'; end if;
    return v_intent;
  end if;
  v_path:=v_actor::text||'/'||p_profile_id::text||'/'||p_client_request_id::text||'/sample.'||v_extension;
  insert into public.creator_upload_intents(owner_id,profile_id,object_path,original_file_name,mime_type,byte_length,sha256,client_request_id,expires_at)
  values(v_actor,p_profile_id,v_path,p_file_name,p_mime_type,p_byte_length,p_sha256,p_client_request_id,now()+interval '2 hours') returning * into v_intent;
  insert into public.creator_audit_events(owner_id,actor_id,actor_kind,event_code,profile_id,details)
  values(v_actor,v_actor,'human','IDENTITY_UPLOAD_PREPARED',p_profile_id,jsonb_build_object('intent_id',v_intent.id,'expires_at',v_intent.expires_at));
  return v_intent;
end $$;

create or replace function creator_private.creator_register_identity_sample_impl(p_profile_id uuid,p_client_request_id uuid)
returns public.creator_identity_samples language plpgsql security definer set search_path=''
as $$
declare v_actor uuid:=auth.uid(); v_profile public.creator_consent_profiles; v_intent public.creator_upload_intents; v_sample public.creator_identity_samples; begin
  if v_actor is null then raise exception 'UNAUTHORIZED'; end if;
  if p_client_request_id is null then raise exception 'CLIENT_REQUEST_ID_REQUIRED'; end if;
  select * into v_profile from public.creator_consent_profiles where id=p_profile_id and owner_id=v_actor and status in ('draft','active') and revoked_at is null and deleted_at is null;
  if not found then raise exception 'PROFILE_NOT_AVAILABLE'; end if;
  select * into v_intent from public.creator_upload_intents where owner_id=v_actor and profile_id=p_profile_id and client_request_id=p_client_request_id for update;
  if not found then raise exception 'UPLOAD_INTENT_REQUIRED'; end if;
  if v_intent.status='registered' then
    select * into v_sample from public.creator_identity_samples where id=v_intent.sample_id;
    if not found then raise exception 'UPLOAD_INTENT_CORRUPT'; end if;
    return v_sample;
  end if;
  if v_intent.status<>'prepared' then raise exception 'UPLOAD_INTENT_NOT_AVAILABLE'; end if;
  if not exists(select 1 from storage.objects o where o.bucket_id='creator-private' and o.name=v_intent.object_path and o.owner_id=v_actor::text)
  then raise exception 'PRIVATE_OBJECT_NOT_FOUND'; end if;
  insert into public.creator_identity_samples(owner_id,profile_id,object_path,mime_type,byte_length,sha256,client_request_id)
  values(v_actor,p_profile_id,v_intent.object_path,v_intent.mime_type,v_intent.byte_length,v_intent.sha256,p_client_request_id) returning * into v_sample;
  update public.creator_upload_intents set status='registered',sample_id=v_sample.id,registered_at=now() where id=v_intent.id;
  insert into public.creator_audit_events(owner_id,actor_id,actor_kind,event_code,profile_id,details)
  values(v_actor,v_actor,'human','IDENTITY_SAMPLE_REGISTERED',p_profile_id,jsonb_build_object('intent_id',v_intent.id,'sample_id',v_sample.id));
  return v_sample;
end $$;

create or replace function creator_private.creator_activate_consent_profile_impl(p_profile_id uuid,p_idempotency_key uuid)
returns public.creator_consent_profiles language plpgsql security definer set search_path=''
as $$
declare v_actor uuid:=auth.uid(); v_profile public.creator_consent_profiles; v_first boolean; begin
  if v_actor is null then raise exception 'UNAUTHORIZED'; end if;
  select * into v_profile from public.creator_consent_profiles where id=p_profile_id and owner_id=v_actor for update;
  if not found then raise exception 'PROFILE_NOT_FOUND'; end if;
  v_first:=creator_private.claim_operation(v_actor,'activate_profile',p_idempotency_key,p_profile_id); if not v_first then return v_profile; end if;
  if v_profile.revoked_at is not null or v_profile.deleted_at is not null then raise exception 'CONSENT_NOT_CURRENT'; end if;
  if not exists(select 1 from public.creator_identity_samples where profile_id=p_profile_id and owner_id=v_actor and status='validated' and deleted_at is null)
  then raise exception 'VALIDATED_SAMPLE_REQUIRED'; end if;
  update public.creator_consent_profiles set status='active',activated_at=coalesce(activated_at,now()) where id=p_profile_id returning * into v_profile;
  insert into public.creator_audit_events(owner_id,actor_id,actor_kind,event_code,profile_id,idempotency_key)
  values(v_actor,v_actor,'human','CONSENT_PROFILE_ACTIVATED',p_profile_id,p_idempotency_key);
  return v_profile;
end $$;

create or replace function creator_private.creator_revoke_consent_profile_impl(p_profile_id uuid,p_reason text,p_idempotency_key uuid)
returns public.creator_consent_profiles language plpgsql security definer set search_path=''
as $$
declare v_actor uuid:=auth.uid(); v_profile public.creator_consent_profiles; v_first boolean; v_effects jsonb; begin
  if v_actor is null then raise exception 'UNAUTHORIZED'; end if;
  if p_reason is null or char_length(btrim(p_reason)) not between 1 and 1000 then raise exception 'REVOCATION_REASON_INVALID'; end if;
  select * into v_profile from public.creator_consent_profiles where id=p_profile_id and owner_id=v_actor for update;
  if not found then raise exception 'PROFILE_NOT_FOUND'; end if;
  v_first:=creator_private.claim_operation(v_actor,'revoke_profile',p_idempotency_key,p_profile_id); if not v_first then return v_profile; end if;
  if v_profile.deleted_at is not null then raise exception 'PROFILE_DELETED'; end if;
  update public.creator_consent_profiles set status='revoked',revoked_at=coalesce(revoked_at,now()),revoked_reason=coalesce(revoked_reason,btrim(p_reason))
    where id=p_profile_id returning * into v_profile;
  v_effects:=creator_private.creator_invalidate_profile_dependents(p_profile_id,'CONSENT_REVOKED');
  update public.creator_upload_intents set status=case when status='prepared' then 'expired' else status end where profile_id=p_profile_id and owner_id=v_actor;
  insert into public.creator_audit_events(owner_id,actor_id,actor_kind,event_code,profile_id,idempotency_key,details)
  values(v_actor,v_actor,'human','CONSENT_PROFILE_REVOKED',p_profile_id,p_idempotency_key,jsonb_build_object('reason',btrim(p_reason),'effects',v_effects));
  return v_profile;
end $$;

create or replace function creator_private.creator_delete_consent_profile_impl(p_profile_id uuid,p_idempotency_key uuid)
returns public.creator_consent_profiles language plpgsql security definer set search_path=''
as $$
declare v_actor uuid:=auth.uid(); v_profile public.creator_consent_profiles; v_first boolean; v_effects jsonb; begin
  if v_actor is null then raise exception 'UNAUTHORIZED'; end if;
  select * into v_profile from public.creator_consent_profiles where id=p_profile_id and owner_id=v_actor for update;
  if not found then raise exception 'PROFILE_NOT_FOUND'; end if;
  v_first:=creator_private.claim_operation(v_actor,'delete_profile',p_idempotency_key,p_profile_id); if not v_first then return v_profile; end if;
  if v_profile.deleted_at is not null then return v_profile; end if;
  if exists(select 1 from public.creator_upload_intents i join storage.objects o on o.bucket_id='creator-private' and o.name=i.object_path
    where i.profile_id=p_profile_id and i.owner_id=v_actor and i.status<>'deleted') then raise exception 'PRIVATE_MEDIA_DELETE_REQUIRED'; end if;
  v_effects:=creator_private.creator_invalidate_profile_dependents(p_profile_id,'PROFILE_DELETED');
  update public.creator_identity_samples set status='deleted',deleted_at=now(),object_path=null,mime_type=null,byte_length=null,sha256=null,rejection_code=null
    where profile_id=p_profile_id and owner_id=v_actor;
  update public.creator_upload_intents set status='deleted',deleted_at=now() where profile_id=p_profile_id and owner_id=v_actor;
  update public.creator_consent_profiles set status='deleted',deleted_at=now(),display_name='[deleted]' where id=p_profile_id returning * into v_profile;
  insert into public.creator_audit_events(owner_id,actor_id,actor_kind,event_code,profile_id,idempotency_key,details)
  values(v_actor,v_actor,'human','CONSENT_PROFILE_DELETED',p_profile_id,p_idempotency_key,jsonb_build_object('effects',v_effects));
  return v_profile;
end $$;

revoke all on function creator_private.creator_prepare_identity_upload_impl(uuid,text,text,bigint,text,uuid),creator_private.creator_register_identity_sample_impl(uuid,uuid) from public,anon;
grant execute on function creator_private.creator_prepare_identity_upload_impl(uuid,text,text,bigint,text,uuid),creator_private.creator_register_identity_sample_impl(uuid,uuid) to authenticated;
drop function if exists public.creator_register_identity_sample(uuid,text,text,bigint,text,uuid);
drop function if exists creator_private.creator_register_identity_sample_impl(uuid,text,text,bigint,text,uuid);

create or replace function public.creator_prepare_identity_upload(p_profile_id uuid,p_file_name text,p_mime_type text,p_byte_length bigint,p_sha256 text,p_client_request_id uuid)
returns public.creator_upload_intents language sql security invoker set search_path='' as $$select creator_private.creator_prepare_identity_upload_impl(p_profile_id,p_file_name,p_mime_type,p_byte_length,p_sha256,p_client_request_id)$$;
create or replace function public.creator_register_identity_sample(p_profile_id uuid,p_client_request_id uuid)
returns public.creator_identity_samples language sql security invoker set search_path='' as $$select creator_private.creator_register_identity_sample_impl(p_profile_id,p_client_request_id)$$;
revoke all on function public.creator_prepare_identity_upload(uuid,text,text,bigint,text,uuid),public.creator_register_identity_sample(uuid,uuid) from public,anon;
grant execute on function public.creator_prepare_identity_upload(uuid,text,text,bigint,text,uuid),public.creator_register_identity_sample(uuid,uuid) to authenticated;

drop policy if exists creator_private_insert on storage.objects;
create policy creator_private_insert on storage.objects for insert to authenticated
with check(
  bucket_id='creator-private' and (storage.foldername(name))[1]=(select auth.uid())::text
  and exists(
    select 1 from public.creator_upload_intents i join public.creator_consent_profiles p on p.id=i.profile_id
    where i.owner_id=(select auth.uid()) and i.object_path=name and i.status='prepared' and i.expires_at>now()
      and p.owner_id=(select auth.uid()) and p.status in ('draft','active') and p.revoked_at is null and p.deleted_at is null
  )
);
