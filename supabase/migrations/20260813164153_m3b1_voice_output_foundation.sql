insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('creator-voice-output','creator-voice-output',false,25000000,array['audio/wav'])
on conflict (id) do update set public=false,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;

alter table public.creator_jobs add column if not exists completed_at timestamptz;
alter table public.creator_jobs add column if not exists actual_cost_microunits bigint;
alter table public.creator_jobs add column if not exists runtime_ms bigint;

create table creator_private.voice_job_leases(
  job_id uuid primary key references public.creator_jobs(id) on delete cascade,
  capability text not null check (capability ~ '^[a-f0-9]{64}$'),
  lease_generation integer not null default 1 check (lease_generation > 0),
  leased_until timestamptz not null,
  updated_at timestamptz not null default now()
);
revoke all on table creator_private.voice_job_leases from public,anon,authenticated;

create table creator_private.voice_completion_claims(
  job_id uuid not null references public.creator_jobs(id) on delete cascade,
  idempotency_key uuid not null,
  request_fingerprint text not null check (request_fingerprint ~ '^[a-f0-9]{64}$'),
  artifact_id uuid not null references public.creator_artifacts(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key(job_id,idempotency_key)
);
revoke all on table creator_private.voice_completion_claims from public,anon,authenticated;

create table public.creator_media_deletions(
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  project_id uuid not null references public.creator_projects(id) on delete cascade,
  artifact_id uuid not null references public.creator_artifacts(id) on delete cascade,
  bucket_id text not null check (bucket_id='creator-voice-output'),
  object_path text not null,
  reason text not null,
  status text not null default 'queued' check (status in ('queued','deleting','deleted','failed')),
  attempt_count integer not null default 0 check (attempt_count >= 0),
  leased_until timestamptz,
  requested_at timestamptz not null default now(),
  deleted_at timestamptz,
  error_code text,
  unique(bucket_id,object_path)
);
alter table public.creator_media_deletions enable row level security;
create policy creator_media_deletions_owner_select on public.creator_media_deletions
  for select to authenticated using (owner_id=(select auth.uid()));
revoke all on table public.creator_media_deletions from anon,authenticated;
grant select on table public.creator_media_deletions to authenticated;

create index creator_media_deletions_owner_status_idx
  on public.creator_media_deletions(owner_id,status,requested_at);

create policy creator_voice_output_owner_select on storage.objects
  for select to authenticated
  using (
    bucket_id='creator-voice-output'
    and exists (
      select 1 from public.creator_artifacts a
      join public.creator_projects p on p.id=a.project_id
      where a.private_storage_path=storage.objects.name
        and a.kind='voice'
        and a.stale_at is null
        and p.owner_id=(select auth.uid())
    )
  );

create or replace function creator_private.creator_queue_stale_voice_media()
returns trigger language plpgsql security definer set search_path=''
as $$
declare v_owner uuid;
begin
  if old.stale_at is null and new.stale_at is not null and new.kind='voice' and new.private_storage_path is not null then
    select owner_id into v_owner from public.creator_projects where id=new.project_id;
    if v_owner is not null then
      insert into public.creator_media_deletions(owner_id,project_id,artifact_id,bucket_id,object_path,reason)
      values(v_owner,new.project_id,new.id,'creator-voice-output',new.private_storage_path,'ARTIFACT_STALE')
      on conflict(bucket_id,object_path) do nothing;
    end if;
  end if;
  return new;
end;
$$;
revoke all on function creator_private.creator_queue_stale_voice_media() from public,anon,authenticated;
create trigger creator_queue_stale_voice_media after update of stale_at on public.creator_artifacts
for each row execute function creator_private.creator_queue_stale_voice_media();
