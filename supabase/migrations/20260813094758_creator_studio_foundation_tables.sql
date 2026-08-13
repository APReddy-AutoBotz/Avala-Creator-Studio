create extension if not exists pgcrypto;

create schema if not exists creator_private;
revoke all on schema creator_private from public, anon;
grant usage on schema creator_private to authenticated, service_role;

create table public.creator_projects (
  id uuid primary key default gen_random_uuid(), owner_id uuid not null references auth.users(id) on delete cascade,
  title text not null check (char_length(title) between 1 and 160),
  current_stage text not null default 'CONTENT_REVIEW' check (current_stage in (
    'CONTENT_REVIEW','CONTENT_APPROVED','SCRIPT_GENERATING','SCRIPT_REVIEW','SCRIPT_APPROVED','VOICE_GENERATING','VOICE_REVIEW','VOICE_APPROVED',
    'AVATAR_GENERATING','AVATAR_REVIEW','AVATAR_APPROVED','EDIT_GENERATING','EDIT_REVIEW','EDIT_APPROVED','FINAL_RENDERING','FINAL_REVIEW','FINAL_APPROVED')),
  client_request_id uuid not null, created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  unique(owner_id, client_request_id)
);

create table public.creator_consent_profiles (
  id uuid primary key default gen_random_uuid(), owner_id uuid not null references auth.users(id) on delete cascade,
  profile_kind text not null check (profile_kind in ('voice','avatar')), display_name text not null check (char_length(display_name) between 1 and 120),
  consent_statement_version text not null check (char_length(consent_statement_version) between 1 and 64), consent_sha256 text not null check (consent_sha256 ~ '^[a-f0-9]{64}$'),
  status text not null default 'draft' check (status in ('draft','active','revoked','deleted')), client_request_id uuid not null,
  created_at timestamptz not null default now(), activated_at timestamptz, revoked_at timestamptz, revoked_reason text, deleted_at timestamptz,
  unique(owner_id, client_request_id)
);

create table public.creator_artifacts (
  id uuid primary key default gen_random_uuid(), project_id uuid not null references public.creator_projects(id) on delete cascade,
  kind text not null check (kind in ('content','script','voice','avatar','edit','final')), version_number integer not null check (version_number > 0),
  inline_text text, private_storage_path text, sha256 text not null check (sha256 ~ '^[a-f0-9]{64}$'), client_request_id uuid not null,
  identity_profile_id uuid references public.creator_consent_profiles(id) on delete set null, metadata jsonb not null default '{}'::jsonb,
  created_by uuid references auth.users(id) on delete set null, created_at timestamptz not null default now(), stale_at timestamptz,
  unique(project_id, kind, version_number), unique(project_id, client_request_id),
  check (private_storage_path is null or (private_storage_path !~* '^https?://' and private_storage_path !~ '(^|/)\.\.(/|$)'))
);

create table public.creator_rights_attestations (
  id uuid primary key default gen_random_uuid(), project_id uuid not null references public.creator_projects(id) on delete cascade,
  artifact_id uuid not null references public.creator_artifacts(id) on delete restrict, attested_by uuid not null references auth.users(id) on delete cascade,
  statement_version text not null check (char_length(statement_version) between 1 and 64), artifact_sha256 text not null check (artifact_sha256 ~ '^[a-f0-9]{64}$'),
  client_request_id uuid not null, attested_at timestamptz not null default now(), unique(attested_by, client_request_id)
);

create table public.creator_reviews (
  id uuid primary key default gen_random_uuid(), project_id uuid not null references public.creator_projects(id) on delete cascade,
  artifact_id uuid not null references public.creator_artifacts(id) on delete restrict, reviewer_id uuid not null references auth.users(id) on delete cascade,
  decision text not null check (decision in ('approved','revision_requested')), artifact_version integer not null check (artifact_version > 0),
  artifact_sha256 text not null check (artifact_sha256 ~ '^[a-f0-9]{64}$'), notes text, created_at timestamptz not null default now(),
  invalidated_at timestamptz, invalidation_reason text
);
create unique index creator_one_current_approval_per_artifact on public.creator_reviews(artifact_id) where decision='approved' and invalidated_at is null;

create table public.creator_identity_samples (
  id uuid primary key default gen_random_uuid(), owner_id uuid not null references auth.users(id) on delete cascade,
  profile_id uuid not null references public.creator_consent_profiles(id) on delete cascade, object_path text, mime_type text, byte_length bigint, sha256 text,
  status text not null default 'pending_validation' check (status in ('pending_validation','validated','rejected','deleted')), client_request_id uuid not null,
  created_at timestamptz not null default now(), validated_at timestamptz, rejection_code text, deleted_at timestamptz,
  unique(owner_id, client_request_id), unique(owner_id, object_path),
  check (object_path is null or (object_path !~* '^https?://' and object_path !~ '(^|/)\.\.(/|$)')),
  check (mime_type is null or char_length(mime_type) between 1 and 120),
  check (byte_length is null or (byte_length > 0 and byte_length <= 250000000)), check (sha256 is null or sha256 ~ '^[a-f0-9]{64}$'),
  check (status='deleted' or (object_path is not null and mime_type is not null and byte_length is not null and sha256 is not null))
);

create table public.creator_jobs (
  id uuid primary key default gen_random_uuid(), project_id uuid not null references public.creator_projects(id) on delete cascade,
  identity_profile_id uuid references public.creator_consent_profiles(id) on delete restrict,
  job_type text not null check (job_type in ('script','voice','avatar','edit','final')), status text not null default 'queued' check (status in ('queued','leased','running','succeeded','failed','cancelled')),
  idempotency_key uuid not null, input_artifact_id uuid references public.creator_artifacts(id) on delete restrict,
  output_artifact_id uuid references public.creator_artifacts(id) on delete set null, provider text not null default 'mock', attempt_count integer not null default 0,
  leased_until timestamptz, error_code text, created_at timestamptz not null default now(), updated_at timestamptz not null default now(), unique(project_id,idempotency_key)
);

create table public.creator_audit_events (
  id bigint generated always as identity primary key, project_id uuid references public.creator_projects(id) on delete cascade,
  owner_id uuid references auth.users(id) on delete set null, actor_id uuid references auth.users(id) on delete set null,
  actor_kind text not null check (actor_kind in ('human','worker','system')), event_code text not null,
  artifact_id uuid references public.creator_artifacts(id) on delete set null, profile_id uuid references public.creator_consent_profiles(id) on delete set null,
  idempotency_key uuid, details jsonb not null default '{}'::jsonb, created_at timestamptz not null default now()
);
create unique index creator_audit_project_idempotency on public.creator_audit_events(project_id,idempotency_key) where project_id is not null and idempotency_key is not null;
create unique index creator_audit_owner_idempotency on public.creator_audit_events(owner_id,event_code,idempotency_key) where owner_id is not null and idempotency_key is not null;
create index creator_projects_owner_idx on public.creator_projects(owner_id);
create index creator_artifacts_project_idx on public.creator_artifacts(project_id);
create index creator_profiles_owner_status_idx on public.creator_consent_profiles(owner_id,status);
create index creator_samples_owner_profile_status_idx on public.creator_identity_samples(owner_id,profile_id,status);
create index creator_jobs_project_status_idx on public.creator_jobs(project_id,status);
create index creator_jobs_profile_status_idx on public.creator_jobs(identity_profile_id,status) where identity_profile_id is not null;
create index creator_audit_owner_created_idx on public.creator_audit_events(owner_id,created_at desc);

alter table public.creator_projects enable row level security; alter table public.creator_artifacts enable row level security;
alter table public.creator_rights_attestations enable row level security; alter table public.creator_reviews enable row level security;
alter table public.creator_consent_profiles enable row level security; alter table public.creator_identity_samples enable row level security;
alter table public.creator_jobs enable row level security; alter table public.creator_audit_events enable row level security;
revoke all on table public.creator_projects,public.creator_artifacts,public.creator_rights_attestations,public.creator_reviews,public.creator_consent_profiles,public.creator_identity_samples,public.creator_jobs,public.creator_audit_events from anon,authenticated;
grant select on table public.creator_projects,public.creator_artifacts,public.creator_rights_attestations,public.creator_reviews,public.creator_consent_profiles,public.creator_identity_samples,public.creator_jobs,public.creator_audit_events to authenticated;
create policy creator_projects_owner_select on public.creator_projects for select to authenticated using ((select auth.uid()) is not null and (select auth.uid())=owner_id);
create policy creator_artifacts_owner_select on public.creator_artifacts for select to authenticated using (exists(select 1 from public.creator_projects p where p.id=project_id and p.owner_id=(select auth.uid())));
create policy creator_rights_owner_select on public.creator_rights_attestations for select to authenticated using ((select auth.uid()) is not null and attested_by=(select auth.uid()));
create policy creator_reviews_owner_select on public.creator_reviews for select to authenticated using ((select auth.uid()) is not null and reviewer_id=(select auth.uid()));
create policy creator_profiles_owner_select on public.creator_consent_profiles for select to authenticated using ((select auth.uid()) is not null and owner_id=(select auth.uid()));
create policy creator_samples_owner_select on public.creator_identity_samples for select to authenticated using ((select auth.uid()) is not null and owner_id=(select auth.uid()));
create policy creator_jobs_owner_select on public.creator_jobs for select to authenticated using (exists(select 1 from public.creator_projects p where p.id=project_id and p.owner_id=(select auth.uid())));
create policy creator_audit_owner_select on public.creator_audit_events for select to authenticated using ((select auth.uid()) is not null and owner_id=(select auth.uid()));
