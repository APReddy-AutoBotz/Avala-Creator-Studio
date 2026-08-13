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
  v_attestation public.creator_rights_attestations;
begin
  if v_actor is null then raise exception 'UNAUTHORIZED'; end if;
  if p_client_request_id is null then raise exception 'CLIENT_REQUEST_ID_REQUIRED'; end if;

  select statement_sha256 into v_statement_sha256
  from creator_private.rights_statements
  where statement_version = p_statement_version and active = true;
  if v_statement_sha256 is null then raise exception 'RIGHTS_STATEMENT_INVALID'; end if;

  select a.* into v_artifact
  from public.creator_artifacts a
  join public.creator_projects p on p.id = a.project_id
  where a.id = p_artifact_id and a.project_id = p_project_id and a.kind = 'content'
    and a.stale_at is null and p.owner_id = v_actor;
  if not found then raise exception 'ARTIFACT_BINDING_INVALID'; end if;

  insert into public.creator_rights_attestations(
    project_id, artifact_id, attested_by, statement_version, statement_sha256,
    artifact_sha256, client_request_id
  ) values (
    p_project_id, p_artifact_id, v_actor, p_statement_version, v_statement_sha256,
    v_artifact.sha256, p_client_request_id
  )
  on conflict (attested_by, client_request_id) do nothing
  returning * into v_attestation;

  if found then
    insert into public.creator_audit_events(project_id, owner_id, actor_id, actor_kind, event_code, artifact_id, details)
    values (p_project_id, v_actor, v_actor, 'human', 'RIGHTS_ATTESTED', p_artifact_id,
            jsonb_build_object('statement_version', p_statement_version, 'statement_sha256', v_statement_sha256,
                               'artifact_sha256', v_artifact.sha256));
    return;
  end if;

  select * into v_attestation from public.creator_rights_attestations
  where attested_by = v_actor and client_request_id = p_client_request_id;
  if not found then raise exception 'RIGHTS_ATTESTATION_REPLAY_LOST'; end if;
  if v_attestation.project_id <> p_project_id
    or v_attestation.artifact_id <> p_artifact_id
    or v_attestation.statement_version <> p_statement_version
    or v_attestation.statement_sha256 <> v_statement_sha256
    or v_attestation.artifact_sha256 <> v_artifact.sha256
  then raise exception 'IDEMPOTENCY_KEY_REUSED'; end if;
end;
$$;
