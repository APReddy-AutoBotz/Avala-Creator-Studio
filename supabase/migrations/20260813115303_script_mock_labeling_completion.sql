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
  v_raw_text text;
  v_text text;
  v_digest text;
  v_version integer;
  v_label constant text := '[SYNTHETIC MOCK DRAFT]';
begin
  if p_idempotency_key is null then raise exception 'IDEMPOTENCY_KEY_REQUIRED'; end if;
  if p_inline_text is null or char_length(btrim(p_inline_text)) not between 1 and 100000 then raise exception 'ARTIFACT_TEXT_INVALID'; end if;
  v_raw_text := btrim(p_inline_text);
  v_text := case
    when left(v_raw_text, char_length(v_label)) = v_label then v_raw_text
    else v_label || E'\n' || v_raw_text
  end;
  if char_length(v_text) > 100000 then raise exception 'ARTIFACT_TEXT_INVALID'; end if;
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
      or v_artifact.metadata->>'provider' is distinct from 'mock'
      or v_artifact.metadata->>'generation_mode' is distinct from 'synthetic_mock'
    then raise exception 'WORKER_COMPLETION_EVIDENCE_INVALID'; end if;
    return jsonb_build_object('project',to_jsonb(v_project),'artifact',to_jsonb(v_artifact),'replayed',true);
  end if;

  if v_project.current_stage <> 'SCRIPT_GENERATING' then raise exception 'STAGE_CONFLICT'; end if;

  select coalesce(max(version_number),0)+1 into v_version
  from public.creator_artifacts where project_id = p_project_id and kind = 'script';

  insert into public.creator_artifacts(
    project_id, kind, version_number, inline_text, sha256, client_request_id, created_by, metadata
  ) values (
    p_project_id, 'script', v_version, v_text, v_digest, p_idempotency_key, null,
    jsonb_build_object(
      'generated_by','trusted_worker',
      'provider','mock',
      'generation_mode','synthetic_mock',
      'visible_label',v_label
    )
  ) returning * into v_artifact;

  update public.creator_projects set current_stage='SCRIPT_REVIEW',updated_at=now()
  where id=p_project_id returning * into v_project;

  insert into public.creator_audit_events(
    project_id, owner_id, actor_kind, event_code, artifact_id, idempotency_key, details
  ) values (
    p_project_id, v_project.owner_id, 'worker', 'SCRIPT_READY', v_artifact.id, p_idempotency_key,
    jsonb_build_object(
      'artifact_sha256',v_digest,
      'artifact_version',v_version,
      'next_stage','SCRIPT_REVIEW',
      'provider','mock',
      'generation_mode','synthetic_mock'
    )
  );

  return jsonb_build_object('project',to_jsonb(v_project),'artifact',to_jsonb(v_artifact),'replayed',false);
end;
$$;
