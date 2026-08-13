-- Avala Creator Studio reference schema.
-- This file is the reviewed source-of-truth for the fresh standalone repository.
-- Before applying to a real project, create a migration with the Supabase CLI and
-- verify the resulting migration, RLS behavior, Storage policies, and advisors.

create extension if not exists pgcrypto;

create table if not exists public.creator_projects (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  title text not null check (char_length(title) between 1 and 160),
  current_stage text not null default 'CONTENT_REVIEW' check (current_stage in (
    'CONTENT_REVIEW','CONTENT_APPROVED','SCRIPT_GENERATING','SCRIPT_REVIEW','SCRIPT_APPROVED',
    'VOICE_GENERATING','VOICE_REVIEW','VOICE_APPROVED','AVATAR_GENERATING','AVATAR_REVIEW',
    'AVATAR_APPROVED','EDIT_GENERATING','EDIT_REVIEW','EDIT_APPROVED','FINAL_RENDERING',
    'FINAL_REVIEW','FINAL_APPROVED'
  )),
  client_request_id uuid not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(owner_id, client_request_id)
);

create table if not exists public.creator_artifacts (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.creator_projects(id) on delete cascade,
  kind text not null check (kind in ('content','script','voice','avatar','edit','final')),
  version_number integer not null check (version_number > 0),
  inline_text text,
  private_storage_path text,
  sha256 text not null check (sha256 ~ '^[a-f0-9]{64}$'),
  client_request_id uuid not null,
  identity_profile_id uuid,
  metadata jsonb not null default '{}'::jsonb,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  stale_at timestamptz,
  unique(project_id, kind, version_number),
  unique(project_id, client_request_id),
  check (private_storage_path is null or (private_storage_path !~* '^https?://' and private_storage_path !~ '(^|/)\.\.(/|$)'))
);

create table if not exists public.creator_rights_attestations (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.creator_projects(id) on delete cascade,
  artifact_id uuid not null references public.creator_artifacts(id) on delete restrict,
  attested_by uuid not null references auth.users(id) on delete cascade,
  statement_version text not null check (char_length(statement_version) between 1 and 64),
  artifact_sha256 text not null check (artifact_sha256 ~ '^[a-f0-9]{64}$'),
  client_request_id uuid not null,
  attested_at timestamptz not null default now(),
  unique(attested_by, client_request_id)
);

create table if not exists public.creator_reviews (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.creator_projects(id) on delete cascade,
  artifact_id uuid not null references public.creator_artifacts(id) on delete restrict,
  reviewer_id uuid not null references auth.users(id) on delete cascade,
  decision text not null check (decision in ('approved','revision_requested')),
  artifact_version integer not null check (artifact_version > 0),
  artifact_sha256 text not null check (artifact_sha256 ~ '^[a-f0-9]{64}$'),
  notes text,
  created_at timestamptz not null default now(),
  invalidated_at timestamptz,
  invalidation_reason text
);

create unique index if not exists creator_one_current_approval_per_artifact
  on public.creator_reviews(artifact_id)
  where decision = 'approved' and invalidated_at is null;

create table if not exists public.creator_consent_profiles (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  profile_kind text not null check (profile_kind in ('voice','avatar')),
  display_name text not null check (char_length(display_name) between 1 and 120),
  consent_statement_version text not null check (char_length(consent_statement_version) between 1 and 64),
  consent_sha256 text not null check (consent_sha256 ~ '^[a-f0-9]{64}$'),
  status text not null default 'draft' check (status in ('draft','active','revoked','deleted')),
  client_request_id uuid not null,
  created_at timestamptz not null default now(),
  activated_at timestamptz,
  revoked_at timestamptz,
  revoked_reason text,
  deleted_at timestamptz,
  unique(owner_id, client_request_id)
);

alter table public.creator_artifacts
  drop constraint if exists creator_artifacts_identity_profile_id_fkey;
alter table public.creator_artifacts
  add constraint creator_artifacts_identity_profile_id_fkey
  foreign key (identity_profile_id) references public.creator_consent_profiles(id) on delete set null;

create table if not exists public.creator_identity_samples (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  profile_id uuid not null references public.creator_consent_profiles(id) on delete cascade,
  object_path text not null,
  mime_type text not null check (char_length(mime_type) between 1 and 120),
  byte_length bigint not null check (byte_length > 0 and byte_length <= 250000000),
  sha256 text not null check (sha256 ~ '^[a-f0-9]{64}$'),
  status text not null default 'pending_validation' check (status in ('pending_validation','validated','rejected','deleted')),
  client_request_id uuid not null,
  created_at timestamptz not null default now(),
  validated_at timestamptz,
  rejection_code text,
  deleted_at timestamptz,
  unique(owner_id, client_request_id),
  unique(owner_id, object_path),
  check (object_path !~* '^https?://' and object_path !~ '(^|/)\.\.(/|$)')
);

create table if not exists public.creator_jobs (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.creator_projects(id) on delete cascade,
  identity_profile_id uuid references public.creator_consent_profiles(id) on delete restrict,
  job_type text not null check (job_type in ('script','voice','avatar','edit','final')),
  status text not null default 'queued' check (status in ('queued','leased','running','succeeded','failed','cancelled')),
  idempotency_key uuid not null,
  input_artifact_id uuid references public.creator_artifacts(id) on delete restrict,
  output_artifact_id uuid references public.creator_artifacts(id) on delete set null,
  provider text not null default 'mock',
  attempt_count integer not null default 0,
  leased_until timestamptz,
  error_code text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(project_id, idempotency_key)
);

create table if not exists public.creator_audit_events (
  id bigint generated always as identity primary key,
  project_id uuid references public.creator_projects(id) on delete cascade,
  owner_id uuid references auth.users(id) on delete set null,
  actor_id uuid references auth.users(id) on delete set null,
  actor_kind text not null check (actor_kind in ('human','worker','system')),
  event_code text not null,
  artifact_id uuid references public.creator_artifacts(id) on delete set null,
  profile_id uuid references public.creator_consent_profiles(id) on delete set null,
  idempotency_key uuid,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create unique index if not exists creator_audit_project_idempotency
  on public.creator_audit_events(project_id, idempotency_key)
  where project_id is not null and idempotency_key is not null;

alter table public.creator_projects enable row level security;
alter table public.creator_artifacts enable row level security;
alter table public.creator_rights_attestations enable row level security;
alter table public.creator_reviews enable row level security;
alter table public.creator_consent_profiles enable row level security;
alter table public.creator_identity_samples enable row level security;
alter table public.creator_jobs enable row level security;
alter table public.creator_audit_events enable row level security;

revoke all on public.creator_projects from anon, authenticated;
revoke all on public.creator_artifacts from anon, authenticated;
revoke all on public.creator_rights_attestations from anon, authenticated;
revoke all on public.creator_reviews from anon, authenticated;
revoke all on public.creator_consent_profiles from anon, authenticated;
revoke all on public.creator_identity_samples from anon, authenticated;
revoke all on public.creator_jobs from anon, authenticated;
revoke all on public.creator_audit_events from anon, authenticated;

grant select on public.creator_projects to authenticated;
grant select on public.creator_artifacts to authenticated;
grant select on public.creator_rights_attestations to authenticated;
grant select on public.creator_reviews to authenticated;
grant select on public.creator_consent_profiles to authenticated;
grant select on public.creator_identity_samples to authenticated;
grant select on public.creator_jobs to authenticated;
grant select on public.creator_audit_events to authenticated;

drop policy if exists creator_projects_owner_select on public.creator_projects;
create policy creator_projects_owner_select on public.creator_projects
  for select to authenticated using ((select auth.uid()) = owner_id);

drop policy if exists creator_artifacts_owner_select on public.creator_artifacts;
create policy creator_artifacts_owner_select on public.creator_artifacts
  for select to authenticated using (exists (
    select 1 from public.creator_projects p where p.id = project_id and p.owner_id = (select auth.uid())
  ));

drop policy if exists creator_rights_owner_select on public.creator_rights_attestations;
create policy creator_rights_owner_select on public.creator_rights_attestations
  for select to authenticated using (attested_by = (select auth.uid()));

drop policy if exists creator_reviews_owner_select on public.creator_reviews;
create policy creator_reviews_owner_select on public.creator_reviews
  for select to authenticated using (reviewer_id = (select auth.uid()));

drop policy if exists creator_profiles_owner_select on public.creator_consent_profiles;
create policy creator_profiles_owner_select on public.creator_consent_profiles
  for select to authenticated using (owner_id = (select auth.uid()));

drop policy if exists creator_samples_owner_select on public.creator_identity_samples;
create policy creator_samples_owner_select on public.creator_identity_samples
  for select to authenticated using (owner_id = (select auth.uid()));

drop policy if exists creator_jobs_owner_select on public.creator_jobs;
create policy creator_jobs_owner_select on public.creator_jobs
  for select to authenticated using (exists (
    select 1 from public.creator_projects p where p.id = project_id and p.owner_id = (select auth.uid())
  ));

drop policy if exists creator_audit_owner_select on public.creator_audit_events;
create policy creator_audit_owner_select on public.creator_audit_events
  for select to authenticated using (owner_id = (select auth.uid()));

create or replace function public.creator_create_project(p_title text, p_client_request_id uuid)
returns public.creator_projects
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_project public.creator_projects;
begin
  if v_actor is null then raise exception 'UNAUTHORIZED'; end if;
  if p_title is null or char_length(btrim(p_title)) not between 1 and 160 then raise exception 'PROJECT_TITLE_INVALID'; end if;
  if p_client_request_id is null then raise exception 'CLIENT_REQUEST_ID_REQUIRED'; end if;

  select * into v_project from public.creator_projects
  where owner_id = v_actor and client_request_id = p_client_request_id;
  if found then return v_project; end if;

  insert into public.creator_projects(owner_id, title, client_request_id)
  values (v_actor, btrim(p_title), p_client_request_id)
  returning * into v_project;

  insert into public.creator_audit_events(project_id, owner_id, actor_id, actor_kind, event_code)
  values (v_project.id, v_actor, v_actor, 'human', 'PROJECT_CREATED');
  return v_project;
end;
$$;

create or replace function public.creator_create_artifact_version(
  p_project_id uuid, p_kind text, p_inline_text text, p_sha256 text, p_client_request_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_project public.creator_projects;
  v_artifact public.creator_artifacts;
  v_version integer;
begin
  if v_actor is null then raise exception 'UNAUTHORIZED'; end if;
  if p_kind not in ('content','script') then raise exception 'ARTIFACT_KIND_NOT_ENABLED'; end if;
  if p_inline_text is null or char_length(btrim(p_inline_text)) not between 1 and 100000 then raise exception 'ARTIFACT_TEXT_INVALID'; end if;
  if p_sha256 is null or p_sha256 !~ '^[a-f0-9]{64}$' then raise exception 'SHA256_INVALID'; end if;
  if p_client_request_id is null then raise exception 'CLIENT_REQUEST_ID_REQUIRED'; end if;

  select * into v_project from public.creator_projects
  where id = p_project_id and owner_id = v_actor for update;
  if not found then raise exception 'PROJECT_NOT_FOUND'; end if;

  select * into v_artifact from public.creator_artifacts
  where project_id = p_project_id and client_request_id = p_client_request_id;
  if found then
    return jsonb_build_object('project', to_jsonb(v_project), 'artifact', to_jsonb(v_artifact), 'replayed', true);
  end if;

  if p_kind = 'content' and v_project.current_stage <> 'CONTENT_REVIEW' then raise exception 'STAGE_CONFLICT'; end if;
  if p_kind = 'script' and v_project.current_stage <> 'SCRIPT_REVIEW' then raise exception 'STAGE_CONFLICT'; end if;

  select coalesce(max(version_number),0) + 1 into v_version
  from public.creator_artifacts where project_id = p_project_id and kind = p_kind;

  insert into public.creator_artifacts(project_id, kind, version_number, inline_text, sha256, client_request_id, created_by)
  values (p_project_id, p_kind, v_version, btrim(p_inline_text), p_sha256, p_client_request_id, v_actor)
  returning * into v_artifact;

  if v_version > 1 then
    update public.creator_reviews r set invalidated_at = now(), invalidation_reason = 'NEW_VERSION_CREATED'
    where r.project_id = p_project_id and r.invalidated_at is null and r.artifact_id in (
      select a.id from public.creator_artifacts a
      where a.project_id = p_project_id and a.kind = p_kind and a.id <> v_artifact.id
    );
  end if;

  insert into public.creator_audit_events(project_id, owner_id, actor_id, actor_kind, event_code, artifact_id)
  values (p_project_id, v_actor, v_actor, 'human', 'ARTIFACT_VERSION_CREATED', v_artifact.id);
  return jsonb_build_object('project', to_jsonb(v_project), 'artifact', to_jsonb(v_artifact), 'replayed', false);
end;
$$;

create or replace function public.creator_attest_rights(
  p_project_id uuid, p_artifact_id uuid, p_statement_version text, p_client_request_id uuid
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_artifact public.creator_artifacts;
begin
  if v_actor is null then raise exception 'UNAUTHORIZED'; end if;
  if p_statement_version is null or char_length(btrim(p_statement_version)) not between 1 and 64 then raise exception 'RIGHTS_STATEMENT_INVALID'; end if;
  if exists (select 1 from public.creator_rights_attestations where attested_by = v_actor and client_request_id = p_client_request_id) then return; end if;

  select a.* into v_artifact from public.creator_artifacts a
  join public.creator_projects p on p.id = a.project_id
  where a.id = p_artifact_id and a.project_id = p_project_id and a.kind = 'content'
    and a.stale_at is null and p.owner_id = v_actor;
  if not found then raise exception 'ARTIFACT_BINDING_INVALID'; end if;

  insert into public.creator_rights_attestations(project_id, artifact_id, attested_by, statement_version, artifact_sha256, client_request_id)
  values (p_project_id, p_artifact_id, v_actor, btrim(p_statement_version), v_artifact.sha256, p_client_request_id);

  insert into public.creator_audit_events(project_id, owner_id, actor_id, actor_kind, event_code, artifact_id)
  values (p_project_id, v_actor, v_actor, 'human', 'RIGHTS_ATTESTED', p_artifact_id);
end;
$$;

create or replace function public.creator_transition_project(
  p_project_id uuid, p_expected_stage text, p_event text, p_artifact_id uuid,
  p_artifact_sha256 text, p_idempotency_key uuid, p_notes text default null
) returns public.creator_projects
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_project public.creator_projects;
  v_artifact public.creator_artifacts;
  v_next_stage text;
  v_expected_kind text;
begin
  if v_actor is null then raise exception 'UNAUTHORIZED'; end if;
  if p_idempotency_key is null then raise exception 'IDEMPOTENCY_KEY_REQUIRED'; end if;

  select * into v_project from public.creator_projects
  where id = p_project_id and owner_id = v_actor for update;
  if not found then raise exception 'PROJECT_NOT_FOUND'; end if;

  if exists (select 1 from public.creator_audit_events where project_id = p_project_id and idempotency_key = p_idempotency_key) then
    return v_project;
  end if;
  if v_project.current_stage <> p_expected_stage then raise exception 'STAGE_CONFLICT'; end if;

  select t.next_stage, t.expected_kind into v_next_stage, v_expected_kind from (values
    ('CONTENT_REVIEW','APPROVE_CONTENT','CONTENT_APPROVED','content'),
    ('CONTENT_APPROVED','START_SCRIPT','SCRIPT_GENERATING',null),
    ('SCRIPT_REVIEW','APPROVE_SCRIPT','SCRIPT_APPROVED','script'),
    ('SCRIPT_APPROVED','START_VOICE','VOICE_GENERATING',null),
    ('VOICE_REVIEW','APPROVE_VOICE','VOICE_APPROVED','voice'),
    ('VOICE_APPROVED','START_AVATAR','AVATAR_GENERATING',null),
    ('AVATAR_REVIEW','APPROVE_AVATAR','AVATAR_APPROVED','avatar'),
    ('AVATAR_APPROVED','START_EDIT','EDIT_GENERATING',null),
    ('EDIT_REVIEW','APPROVE_EDIT','EDIT_APPROVED','edit'),
    ('EDIT_APPROVED','START_FINAL','FINAL_RENDERING',null),
    ('FINAL_REVIEW','APPROVE_FINAL','FINAL_APPROVED','final')
  ) as t(current_stage,event_code,next_stage,expected_kind)
  where t.current_stage = p_expected_stage and t.event_code = p_event;
  if v_next_stage is null then raise exception 'INVALID_WORKFLOW_TRANSITION'; end if;

  if v_expected_kind is not null then
    if p_artifact_id is null or p_artifact_sha256 is null then raise exception 'APPROVAL_BINDING_REQUIRED'; end if;
    select * into v_artifact from public.creator_artifacts
    where id = p_artifact_id and project_id = p_project_id and kind = v_expected_kind
      and sha256 = p_artifact_sha256 and stale_at is null;
    if not found then raise exception 'ARTIFACT_BINDING_INVALID'; end if;
    if v_artifact.version_number <> (select max(version_number) from public.creator_artifacts where project_id = p_project_id and kind = v_expected_kind and stale_at is null)
      then raise exception 'LATEST_ARTIFACT_REQUIRED'; end if;
    if p_event = 'APPROVE_CONTENT' and not exists (
      select 1 from public.creator_rights_attestations where project_id = p_project_id
        and artifact_id = p_artifact_id and attested_by = v_actor and artifact_sha256 = p_artifact_sha256
    ) then raise exception 'RIGHTS_ATTESTATION_REQUIRED'; end if;

    insert into public.creator_reviews(project_id, artifact_id, reviewer_id, decision, artifact_version, artifact_sha256, notes)
    values (p_project_id, p_artifact_id, v_actor, 'approved', v_artifact.version_number, p_artifact_sha256, p_notes);
  end if;

  update public.creator_projects set current_stage = v_next_stage, updated_at = now()
  where id = p_project_id returning * into v_project;
  insert into public.creator_audit_events(project_id, owner_id, actor_id, actor_kind, event_code, artifact_id, idempotency_key)
  values (p_project_id, v_actor, v_actor, 'human', p_event, p_artifact_id, p_idempotency_key);
  return v_project;
end;
$$;

create or replace function public.creator_request_revision(
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
begin
  if v_actor is null then raise exception 'UNAUTHORIZED'; end if;
  if p_target_kind not in ('content','script','voice','avatar','edit','final') then raise exception 'REVISION_TARGET_INVALID'; end if;
  if p_reason is null or char_length(btrim(p_reason)) not between 1 and 4000 then raise exception 'REVISION_REASON_INVALID'; end if;

  select * into v_project from public.creator_projects where id = p_project_id and owner_id = v_actor for update;
  if not found then raise exception 'PROJECT_NOT_FOUND'; end if;
  if exists (select 1 from public.creator_audit_events where project_id = p_project_id and idempotency_key = p_idempotency_key) then return v_project; end if;

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
    when 'content' then 'CONTENT_REVIEW'
    when 'script' then 'SCRIPT_REVIEW'
    when 'voice' then 'VOICE_REVIEW'
    when 'avatar' then 'AVATAR_REVIEW'
    when 'edit' then 'EDIT_REVIEW'
    else 'FINAL_REVIEW' end,
    updated_at = now()
  where id = p_project_id returning * into v_project;

  insert into public.creator_audit_events(project_id, owner_id, actor_id, actor_kind, event_code, idempotency_key, details)
  values (p_project_id, v_actor, v_actor, 'human', 'REVISION_REQUESTED', p_idempotency_key, jsonb_build_object('target_kind',p_target_kind,'reason',btrim(p_reason)));
  return v_project;
end;
$$;

create or replace function public.creator_create_consent_profile(
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
begin
  if v_actor is null then raise exception 'UNAUTHORIZED'; end if;
  if p_kind not in ('voice','avatar') then raise exception 'PROFILE_KIND_INVALID'; end if;
  if p_display_name is null or char_length(btrim(p_display_name)) not between 1 and 120 then raise exception 'PROFILE_NAME_INVALID'; end if;
  if p_consent_statement_version is null or char_length(btrim(p_consent_statement_version)) not between 1 and 64 then raise exception 'CONSENT_STATEMENT_INVALID'; end if;
  if p_consent_sha256 is null or p_consent_sha256 !~ '^[a-f0-9]{64}$' then raise exception 'SHA256_INVALID'; end if;

  select * into v_profile from public.creator_consent_profiles where owner_id = v_actor and client_request_id = p_client_request_id;
  if found then return v_profile; end if;
  insert into public.creator_consent_profiles(owner_id, profile_kind, display_name, consent_statement_version, consent_sha256, client_request_id)
  values (v_actor, p_kind, btrim(p_display_name), btrim(p_consent_statement_version), p_consent_sha256, p_client_request_id)
  returning * into v_profile;
  insert into public.creator_audit_events(owner_id, actor_id, actor_kind, event_code, profile_id)
  values (v_actor, v_actor, 'human', 'CONSENT_PROFILE_CREATED', v_profile.id);
  return v_profile;
end;
$$;

create or replace function public.creator_register_identity_sample(
  p_profile_id uuid, p_object_path text, p_mime_type text, p_byte_length bigint,
  p_sha256 text, p_client_request_id uuid
) returns public.creator_identity_samples
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_profile public.creator_consent_profiles;
  v_sample public.creator_identity_samples;
  v_prefix text;
begin
  if v_actor is null then raise exception 'UNAUTHORIZED'; end if;
  select * into v_profile from public.creator_consent_profiles
  where id = p_profile_id and owner_id = v_actor and status in ('draft','active') and revoked_at is null and deleted_at is null;
  if not found then raise exception 'PROFILE_NOT_AVAILABLE'; end if;
  v_prefix := v_actor::text || '/';
  if p_object_path is null or left(p_object_path, char_length(v_prefix)) <> v_prefix
    or p_object_path ~* '^https?://' or p_object_path ~ '(^|/)\.\.(/|$)' then raise exception 'PRIVATE_OBJECT_PATH_REQUIRED'; end if;
  if p_mime_type is null or char_length(p_mime_type) not between 1 and 120 then raise exception 'MIME_TYPE_INVALID'; end if;
  if p_byte_length is null or p_byte_length <= 0 or p_byte_length > 250000000 then raise exception 'FILE_SIZE_INVALID'; end if;
  if p_sha256 is null or p_sha256 !~ '^[a-f0-9]{64}$' then raise exception 'SHA256_INVALID'; end if;

  select * into v_sample from public.creator_identity_samples where owner_id = v_actor and client_request_id = p_client_request_id;
  if found then return v_sample; end if;
  insert into public.creator_identity_samples(owner_id, profile_id, object_path, mime_type, byte_length, sha256, client_request_id)
  values (v_actor, p_profile_id, p_object_path, p_mime_type, p_byte_length, p_sha256, p_client_request_id)
  returning * into v_sample;
  insert into public.creator_audit_events(owner_id, actor_id, actor_kind, event_code, profile_id)
  values (v_actor, v_actor, 'human', 'IDENTITY_SAMPLE_REGISTERED', p_profile_id);
  return v_sample;
end;
$$;

create or replace function public.creator_activate_consent_profile(p_profile_id uuid, p_idempotency_key uuid)
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
  select * into v_profile from public.creator_consent_profiles where id = p_profile_id and owner_id = v_actor for update;
  if not found then raise exception 'PROFILE_NOT_FOUND'; end if;
  if v_profile.revoked_at is not null or v_profile.deleted_at is not null then raise exception 'CONSENT_NOT_CURRENT'; end if;
  if not exists (select 1 from public.creator_identity_samples where profile_id = p_profile_id and owner_id = v_actor and status = 'validated' and deleted_at is null)
    then raise exception 'VALIDATED_SAMPLE_REQUIRED'; end if;
  if v_profile.status <> 'active' then
    update public.creator_consent_profiles set status = 'active', activated_at = now() where id = p_profile_id returning * into v_profile;
    insert into public.creator_audit_events(owner_id, actor_id, actor_kind, event_code, profile_id, idempotency_key)
    values (v_actor, v_actor, 'human', 'CONSENT_PROFILE_ACTIVATED', p_profile_id, p_idempotency_key)
    on conflict do nothing;
  end if;
  return v_profile;
end;
$$;

create or replace function public.creator_revoke_consent_profile(p_profile_id uuid, p_reason text, p_idempotency_key uuid)
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
  if p_reason is null or char_length(btrim(p_reason)) not between 1 and 1000 then raise exception 'REVOCATION_REASON_INVALID'; end if;
  select * into v_profile from public.creator_consent_profiles where id = p_profile_id and owner_id = v_actor for update;
  if not found then raise exception 'PROFILE_NOT_FOUND'; end if;
  if v_profile.deleted_at is not null then raise exception 'PROFILE_DELETED'; end if;
  if v_profile.revoked_at is null then
    update public.creator_consent_profiles set status = 'revoked', revoked_at = now(), revoked_reason = btrim(p_reason)
    where id = p_profile_id returning * into v_profile;
    update public.creator_jobs set status = 'cancelled', error_code = 'CONSENT_REVOKED', updated_at = now()
    where identity_profile_id = p_profile_id and status in ('queued','leased','running');
    update public.creator_artifacts set stale_at = coalesce(stale_at, now())
    where identity_profile_id = p_profile_id and stale_at is null;
    insert into public.creator_audit_events(owner_id, actor_id, actor_kind, event_code, profile_id, idempotency_key)
    values (v_actor, v_actor, 'human', 'CONSENT_PROFILE_REVOKED', p_profile_id, p_idempotency_key)
    on conflict do nothing;
  end if;
  return v_profile;
end;
$$;

-- Worker validation boundary. It is intentionally not granted to browser roles.
create or replace function public.creator_record_identity_sample_validation(
  p_sample_id uuid, p_valid boolean, p_rejection_code text default null
) returns public.creator_identity_samples
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_sample public.creator_identity_samples;
begin
  select * into v_sample from public.creator_identity_samples where id = p_sample_id for update;
  if not found then raise exception 'SAMPLE_NOT_FOUND'; end if;
  if v_sample.status <> 'pending_validation' then return v_sample; end if;
  update public.creator_identity_samples set
    status = case when p_valid then 'validated' else 'rejected' end,
    validated_at = now(), rejection_code = case when p_valid then null else coalesce(p_rejection_code,'VALIDATION_REJECTED') end
  where id = p_sample_id returning * into v_sample;
  insert into public.creator_audit_events(owner_id, actor_kind, event_code, profile_id)
  values (v_sample.owner_id, 'worker', case when p_valid then 'IDENTITY_SAMPLE_VALIDATED' else 'IDENTITY_SAMPLE_REJECTED' end, v_sample.profile_id);
  return v_sample;
end;
$$;

-- Private Storage bucket and owner-scoped browser policies.
insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values (
  'creator-private', 'creator-private', false, 250000000,
  array['audio/wav','audio/mpeg','audio/mp4','audio/x-m4a','video/mp4','video/quicktime','image/jpeg','image/png','image/webp']
)
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists creator_private_select on storage.objects;
create policy creator_private_select on storage.objects for select to authenticated
  using (bucket_id = 'creator-private' and (storage.foldername(name))[1] = (select auth.uid())::text);

drop policy if exists creator_private_insert on storage.objects;
create policy creator_private_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'creator-private' and (storage.foldername(name))[1] = (select auth.uid())::text);

drop policy if exists creator_private_delete on storage.objects;
create policy creator_private_delete on storage.objects for delete to authenticated
  using (bucket_id = 'creator-private' and (storage.foldername(name))[1] = (select auth.uid())::text);

-- Harden RPC execute privileges. PostgreSQL grants new functions to PUBLIC by default.
revoke all on function public.creator_create_project(text,uuid) from public, anon;
revoke all on function public.creator_create_artifact_version(uuid,text,text,text,uuid) from public, anon;
revoke all on function public.creator_attest_rights(uuid,uuid,text,uuid) from public, anon;
revoke all on function public.creator_transition_project(uuid,text,text,uuid,text,uuid,text) from public, anon;
revoke all on function public.creator_request_revision(uuid,text,text,uuid) from public, anon;
revoke all on function public.creator_create_consent_profile(text,text,text,text,uuid) from public, anon;
revoke all on function public.creator_register_identity_sample(uuid,text,text,bigint,text,uuid) from public, anon;
revoke all on function public.creator_activate_consent_profile(uuid,uuid) from public, anon;
revoke all on function public.creator_revoke_consent_profile(uuid,text,uuid) from public, anon;
revoke all on function public.creator_record_identity_sample_validation(uuid,boolean,text) from public, anon, authenticated;

grant execute on function public.creator_create_project(text,uuid) to authenticated;
grant execute on function public.creator_create_artifact_version(uuid,text,text,text,uuid) to authenticated;
grant execute on function public.creator_attest_rights(uuid,uuid,text,uuid) to authenticated;
grant execute on function public.creator_transition_project(uuid,text,text,uuid,text,uuid,text) to authenticated;
grant execute on function public.creator_request_revision(uuid,text,text,uuid) to authenticated;
grant execute on function public.creator_create_consent_profile(text,text,text,text,uuid) to authenticated;
grant execute on function public.creator_register_identity_sample(uuid,text,text,bigint,text,uuid) to authenticated;
grant execute on function public.creator_activate_consent_profile(uuid,uuid) to authenticated;
grant execute on function public.creator_revoke_consent_profile(uuid,text,uuid) to authenticated;
