-- M2 reference extensions. This is NOT an applied migration.
-- When a Supabase project is authorized, use the Supabase CLI to create a real
-- migration and combine/review schema.sql plus this extension before applying.

alter table public.creator_identity_samples alter column object_path drop not null;
alter table public.creator_identity_samples alter column mime_type drop not null;
alter table public.creator_identity_samples alter column byte_length drop not null;
alter table public.creator_identity_samples alter column sha256 drop not null;

create unique index if not exists creator_audit_owner_idempotency
  on public.creator_audit_events(owner_id, event_code, idempotency_key)
  where owner_id is not null and idempotency_key is not null;

create or replace function public.creator_delete_consent_profile(p_profile_id uuid, p_idempotency_key uuid)
returns public.creator_consent_profiles
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_profile public.creator_consent_profiles;
begin
  if v_actor is null then raise exception 'UNAUTHORIZED'; end if;
  if p_idempotency_key is null then raise exception 'IDEMPOTENCY_KEY_REQUIRED'; end if;
  select * into v_profile from public.creator_consent_profiles where id = p_profile_id and owner_id = v_actor for update;
  if not found then raise exception 'PROFILE_NOT_FOUND'; end if;
  if v_profile.deleted_at is not null then return v_profile; end if;

  update public.creator_jobs set status = 'cancelled', error_code = 'PROFILE_DELETED', updated_at = now()
    where identity_profile_id = p_profile_id and status in ('queued','leased','running');
  update public.creator_artifacts set stale_at = coalesce(stale_at, now())
    where identity_profile_id = p_profile_id and stale_at is null;
  update public.creator_identity_samples set status = 'deleted', deleted_at = now(),
    object_path = null, mime_type = null, byte_length = null, sha256 = null, rejection_code = null
    where profile_id = p_profile_id and owner_id = v_actor;
  update public.creator_consent_profiles set status = 'deleted', deleted_at = now(), display_name = '[deleted]'
    where id = p_profile_id returning * into v_profile;
  insert into public.creator_audit_events(owner_id, actor_id, actor_kind, event_code, profile_id, idempotency_key)
    values (v_actor, v_actor, 'human', 'CONSENT_PROFILE_DELETED', p_profile_id, p_idempotency_key)
    on conflict do nothing;
  return v_profile;
end;
$$;

revoke all on function public.creator_delete_consent_profile(uuid,uuid) from public, anon;
grant execute on function public.creator_delete_consent_profile(uuid,uuid) to authenticated;
