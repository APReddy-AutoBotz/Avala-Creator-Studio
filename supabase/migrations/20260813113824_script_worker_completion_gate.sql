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
    ('VOICE_REVIEW','APPROVE_VOICE','VOICE_APPROVED','voice'),
    ('AVATAR_REVIEW','APPROVE_AVATAR','AVATAR_APPROVED','avatar'),
    ('EDIT_REVIEW','APPROVE_EDIT','EDIT_APPROVED','edit'),
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

create or replace function creator_private.creator_record_script_draft_impl(
  p_project_id uuid, p_inline_text text, p_sha256 text, p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_project public.creator_projects;
  v_artifact public.creator_artifacts;
  v_existing public.creator_audit_events;
  v_text text;
  v_digest text;
  v_version integer;
begin
  if p_idempotency_key is null then raise exception 'IDEMPOTENCY_KEY_REQUIRED'; end if;
  if p_inline_text is null or char_length(btrim(p_inline_text)) not between 1 and 100000 then raise exception 'ARTIFACT_TEXT_INVALID'; end if;
  v_text := btrim(p_inline_text);
  v_digest := encode(extensions.digest(convert_to(v_text,'UTF8'),'sha256'),'hex');
  if p_sha256 is null or p_sha256 <> v_digest then raise exception 'ARTIFACT_DIGEST_MISMATCH'; end if;

  select * into v_project from public.creator_projects where id = p_project_id for update;
  if not found then raise exception 'PROJECT_NOT_FOUND'; end if;

  select * into v_existing from public.creator_audit_events
  where project_id = p_project_id and idempotency_key = p_idempotency_key;
  if found then
    if v_existing.event_code <> 'SCRIPT_READY'
      or v_existing.details->>'artifact_sha256' is distinct from v_digest
      or v_existing.artifact_id is null
    then raise exception 'IDEMPOTENCY_KEY_REUSED'; end if;
    select * into v_artifact from public.creator_artifacts where id = v_existing.artifact_id and project_id = p_project_id;
    if not found or v_artifact.kind <> 'script' or v_artifact.inline_text is distinct from v_text or v_artifact.sha256 <> v_digest
      then raise exception 'WORKER_COMPLETION_EVIDENCE_INVALID'; end if;
    return jsonb_build_object('project',to_jsonb(v_project),'artifact',to_jsonb(v_artifact),'replayed',true);
  end if;

  if v_project.current_stage <> 'SCRIPT_GENERATING' then raise exception 'STAGE_CONFLICT'; end if;

  select coalesce(max(version_number),0)+1 into v_version
  from public.creator_artifacts where project_id = p_project_id and kind = 'script';

  insert into public.creator_artifacts(
    project_id, kind, version_number, inline_text, sha256, client_request_id, created_by,
    metadata
  ) values (
    p_project_id, 'script', v_version, v_text, v_digest, p_idempotency_key, null,
    jsonb_build_object('generated_by','trusted_worker','synthetic_or_provider','unspecified')
  ) returning * into v_artifact;

  update public.creator_projects set current_stage='SCRIPT_REVIEW',updated_at=now()
  where id=p_project_id returning * into v_project;

  insert into public.creator_audit_events(
    project_id, owner_id, actor_kind, event_code, artifact_id, idempotency_key, details
  ) values (
    p_project_id, v_project.owner_id, 'worker', 'SCRIPT_READY', v_artifact.id, p_idempotency_key,
    jsonb_build_object('artifact_sha256',v_digest,'artifact_version',v_version,'next_stage','SCRIPT_REVIEW')
  );

  return jsonb_build_object('project',to_jsonb(v_project),'artifact',to_jsonb(v_artifact),'replayed',false);
end;
$$;

revoke all on function creator_private.creator_record_script_draft_impl(uuid,text,text,uuid) from public, anon, authenticated;
grant execute on function creator_private.creator_record_script_draft_impl(uuid,text,text,uuid) to service_role;

create or replace function public.creator_record_script_draft(
  p_project_id uuid, p_inline_text text, p_sha256 text, p_idempotency_key uuid
) returns jsonb
language sql
security invoker
set search_path = ''
as $$ select creator_private.creator_record_script_draft_impl(p_project_id,p_inline_text,p_sha256,p_idempotency_key) $$;

revoke all on function public.creator_record_script_draft(uuid,text,text,uuid) from public, anon, authenticated;
grant execute on function public.creator_record_script_draft(uuid,text,text,uuid) to service_role;
