create table creator_private.rights_statements (
  statement_version text primary key,
  statement_text text not null,
  statement_sha256 text not null check (statement_sha256 ~ '^[a-f0-9]{64}$'),
  active boolean not null default true,
  created_at timestamptz not null default now()
);
revoke all on table creator_private.rights_statements from public, anon, authenticated;

insert into creator_private.rights_statements(statement_version, statement_text, statement_sha256)
values (
  'content-rights-v1',
  'I own this content or have permission to adapt it into a video.',
  '42250e837adc94788c9a403c5e49362eac5c6914279ba74bfdc83c588bc2cb80'
);

alter table public.creator_rights_attestations add column statement_sha256 text;
update public.creator_rights_attestations r
set statement_sha256 = s.statement_sha256
from creator_private.rights_statements s
where s.statement_version = r.statement_version and r.statement_sha256 is null;
alter table public.creator_rights_attestations
  add constraint creator_rights_statement_sha256_check check (statement_sha256 ~ '^[a-f0-9]{64}$');
alter table public.creator_rights_attestations alter column statement_sha256 set not null;

create table creator_private.transition_claims (
  owner_id uuid not null,
  project_id uuid not null,
  idempotency_key uuid not null,
  expected_stage text not null,
  event_code text not null,
  artifact_id uuid,
  artifact_sha256 text,
  notes text,
  created_at timestamptz not null default now(),
  primary key(owner_id, project_id, idempotency_key)
);
revoke all on table creator_private.transition_claims from public, anon, authenticated;

create or replace function creator_private.creator_create_artifact_version_impl(
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
  v_normalized_text text;
  v_expected_sha256 text;
begin
  if v_actor is null then raise exception 'UNAUTHORIZED'; end if;
  if p_kind not in ('content','script') then raise exception 'ARTIFACT_KIND_NOT_ENABLED'; end if;
  if p_inline_text is null or char_length(btrim(p_inline_text)) not between 1 and 100000 then raise exception 'ARTIFACT_TEXT_INVALID'; end if;
  if p_sha256 is null or p_sha256 !~ '^[a-f0-9]{64}$' then raise exception 'SHA256_INVALID'; end if;
  if p_client_request_id is null then raise exception 'CLIENT_REQUEST_ID_REQUIRED'; end if;

  v_normalized_text := btrim(p_inline_text);
  v_expected_sha256 := encode(extensions.digest(convert_to(v_normalized_text, 'UTF8'), 'sha256'), 'hex');
  if p_sha256 is distinct from v_expected_sha256 then raise exception 'ARTIFACT_DIGEST_MISMATCH'; end if;

  select * into v_project from public.creator_projects
  where id = p_project_id and owner_id = v_actor for update;
  if not found then raise exception 'PROJECT_NOT_FOUND'; end if;

  select * into v_artifact from public.creator_artifacts
  where project_id = p_project_id and client_request_id = p_client_request_id;
  if found then
    if v_artifact.kind <> p_kind
      or v_artifact.inline_text is distinct from v_normalized_text
      or v_artifact.sha256 <> v_expected_sha256
    then raise exception 'IDEMPOTENCY_KEY_REUSED'; end if;
    return jsonb_build_object('project', to_jsonb(v_project), 'artifact', to_jsonb(v_artifact), 'replayed', true);
  end if;

  if p_kind = 'content' and v_project.current_stage <> 'CONTENT_REVIEW' then raise exception 'STAGE_CONFLICT'; end if;
  if p_kind = 'script' and v_project.current_stage <> 'SCRIPT_REVIEW' then raise exception 'STAGE_CONFLICT'; end if;

  select coalesce(max(version_number),0) + 1 into v_version
  from public.creator_artifacts where project_id = p_project_id and kind = p_kind;

  insert into public.creator_artifacts(project_id, kind, version_number, inline_text, sha256, client_request_id, created_by)
  values (p_project_id, p_kind, v_version, v_normalized_text, v_expected_sha256, p_client_request_id, v_actor)
  returning * into v_artifact;

  if v_version > 1 then
    update public.creator_reviews r
    set invalidated_at = now(), invalidation_reason = 'NEW_VERSION_CREATED'
    where r.project_id = p_project_id and r.invalidated_at is null and r.artifact_id in (
      select a.id from public.creator_artifacts a
      where a.project_id = p_project_id and a.kind = p_kind and a.id <> v_artifact.id
    );
  end if;

  insert into public.creator_audit_events(project_id, owner_id, actor_id, actor_kind, event_code, artifact_id, details)
  values (p_project_id, v_actor, v_actor, 'human', 'ARTIFACT_VERSION_CREATED', v_artifact.id,
          jsonb_build_object('kind', p_kind, 'version', v_artifact.version_number, 'sha256', v_expected_sha256));

  return jsonb_build_object('project', to_jsonb(v_project), 'artifact', to_jsonb(v_artifact), 'replayed', false);
end;
$$;

create or replace function creator_private.creator_attest_rights_impl(
  p_project_id uuid, p_artifact_id uuid, p_statement_version text, p_client_request_id uuid
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_artifact public.creator_artifacts;
  v_statement_sha256 text;
  v_existing public.creator_rights_attestations;
begin
  if v_actor is null then raise exception 'UNAUTHORIZED'; end if;
  if p_client_request_id is null then raise exception 'CLIENT_REQUEST_ID_REQUIRED'; end if;

  select statement_sha256 into v_statement_sha256
  from creator_private.rights_statements
  where statement_version = p_statement_version and active = true;
  if v_statement_sha256 is null then raise exception 'RIGHTS_STATEMENT_INVALID'; end if;

  select * into v_existing from public.creator_rights_attestations
  where attested_by = v_actor and client_request_id = p_client_request_id;
  if found then
    if v_existing.project_id <> p_project_id
      or v_existing.artifact_id <> p_artifact_id
      or v_existing.statement_version <> p_statement_version
      or v_existing.statement_sha256 <> v_statement_sha256
    then raise exception 'IDEMPOTENCY_KEY_REUSED'; end if;
    return;
  end if;

  select a.* into v_artifact
  from public.creator_artifacts a
  join public.creator_projects p on p.id = a.project_id
  where a.id = p_artifact_id and a.project_id = p_project_id and a.kind = 'content'
    and a.stale_at is null and p.owner_id = v_actor;
  if not found then raise exception 'ARTIFACT_BINDING_INVALID'; end if;

  insert into public.creator_rights_attestations(
    project_id, artifact_id, attested_by, statement_version, statement_sha256, artifact_sha256, client_request_id
  ) values (
    p_project_id, p_artifact_id, v_actor, p_statement_version, v_statement_sha256, v_artifact.sha256, p_client_request_id
  );

  insert into public.creator_audit_events(project_id, owner_id, actor_id, actor_kind, event_code, artifact_id, details)
  values (p_project_id, v_actor, v_actor, 'human', 'RIGHTS_ATTESTED', p_artifact_id,
          jsonb_build_object('statement_version', p_statement_version, 'statement_sha256', v_statement_sha256,
                             'artifact_sha256', v_artifact.sha256));
end;
$$;

create or replace function creator_private.creator_transition_project_impl(
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
  v_claim creator_private.transition_claims;
begin
  if v_actor is null then raise exception 'UNAUTHORIZED'; end if;
  if p_idempotency_key is null then raise exception 'IDEMPOTENCY_KEY_REQUIRED'; end if;

  select * into v_project from public.creator_projects
  where id = p_project_id and owner_id = v_actor for update;
  if not found then raise exception 'PROJECT_NOT_FOUND'; end if;

  begin
    insert into creator_private.transition_claims(
      owner_id, project_id, idempotency_key, expected_stage, event_code, artifact_id, artifact_sha256, notes
    ) values (
      v_actor, p_project_id, p_idempotency_key, p_expected_stage, p_event, p_artifact_id, p_artifact_sha256, p_notes
    );
  exception when unique_violation then
    select * into v_claim from creator_private.transition_claims
    where owner_id = v_actor and project_id = p_project_id and idempotency_key = p_idempotency_key;
    if v_claim.expected_stage <> p_expected_stage
      or v_claim.event_code <> p_event
      or v_claim.artifact_id is distinct from p_artifact_id
      or v_claim.artifact_sha256 is distinct from p_artifact_sha256
      or v_claim.notes is distinct from p_notes
    then raise exception 'IDEMPOTENCY_KEY_REUSED'; end if;
    return v_project;
  end;

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
    if v_artifact.version_number <> (
      select max(version_number) from public.creator_artifacts
      where project_id = p_project_id and kind = v_expected_kind and stale_at is null
    ) then raise exception 'LATEST_ARTIFACT_REQUIRED'; end if;
    if p_event = 'APPROVE_CONTENT' and not exists (
      select 1 from public.creator_rights_attestations
      where project_id = p_project_id and artifact_id = p_artifact_id and attested_by = v_actor
        and artifact_sha256 = p_artifact_sha256
    ) then raise exception 'RIGHTS_ATTESTATION_REQUIRED'; end if;

    insert into public.creator_reviews(project_id, artifact_id, reviewer_id, decision, artifact_version, artifact_sha256, notes)
    values (p_project_id, p_artifact_id, v_actor, 'approved', v_artifact.version_number, p_artifact_sha256, p_notes);
  end if;

  update public.creator_projects set current_stage = v_next_stage, updated_at = now()
  where id = p_project_id returning * into v_project;

  insert into public.creator_audit_events(project_id, owner_id, actor_id, actor_kind, event_code, artifact_id, idempotency_key, details)
  values (p_project_id, v_actor, v_actor, 'human', p_event, p_artifact_id, p_idempotency_key,
          jsonb_build_object('expected_stage', p_expected_stage, 'next_stage', v_next_stage,
                             'artifact_sha256', p_artifact_sha256));
  return v_project;
end;
$$;
