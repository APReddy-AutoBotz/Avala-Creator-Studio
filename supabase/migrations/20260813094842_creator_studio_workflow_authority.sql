create or replace function creator_private.creator_create_project_impl(p_title text,p_client_request_id uuid)
returns public.creator_projects language plpgsql security definer set search_path=''
as $$
declare v_actor uuid:=auth.uid(); v_project public.creator_projects; begin
 if v_actor is null then raise exception 'UNAUTHORIZED'; end if;
 if p_title is null or char_length(btrim(p_title)) not between 1 and 160 then raise exception 'PROJECT_TITLE_INVALID'; end if;
 if p_client_request_id is null then raise exception 'CLIENT_REQUEST_ID_REQUIRED'; end if;
 select * into v_project from public.creator_projects where owner_id=v_actor and client_request_id=p_client_request_id;
 if found then return v_project; end if;
 insert into public.creator_projects(owner_id,title,client_request_id) values(v_actor,btrim(p_title),p_client_request_id) returning * into v_project;
 insert into public.creator_audit_events(project_id,owner_id,actor_id,actor_kind,event_code) values(v_project.id,v_actor,v_actor,'human','PROJECT_CREATED');
 return v_project;
end $$;

create or replace function creator_private.creator_create_artifact_version_impl(p_project_id uuid,p_kind text,p_inline_text text,p_sha256 text,p_client_request_id uuid)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_actor uuid:=auth.uid(); v_project public.creator_projects; v_artifact public.creator_artifacts; v_version integer; begin
 if v_actor is null then raise exception 'UNAUTHORIZED'; end if;
 if p_kind not in ('content','script') then raise exception 'ARTIFACT_KIND_NOT_ENABLED'; end if;
 if p_inline_text is null or char_length(btrim(p_inline_text)) not between 1 and 100000 then raise exception 'ARTIFACT_TEXT_INVALID'; end if;
 if p_sha256 is null or p_sha256 !~ '^[a-f0-9]{64}$' then raise exception 'SHA256_INVALID'; end if;
 if p_client_request_id is null then raise exception 'CLIENT_REQUEST_ID_REQUIRED'; end if;
 select * into v_project from public.creator_projects where id=p_project_id and owner_id=v_actor for update;
 if not found then raise exception 'PROJECT_NOT_FOUND'; end if;
 select * into v_artifact from public.creator_artifacts where project_id=p_project_id and client_request_id=p_client_request_id;
 if found then return jsonb_build_object('project',to_jsonb(v_project),'artifact',to_jsonb(v_artifact),'replayed',true); end if;
 if p_kind='content' and v_project.current_stage<>'CONTENT_REVIEW' then raise exception 'STAGE_CONFLICT'; end if;
 if p_kind='script' and v_project.current_stage<>'SCRIPT_REVIEW' then raise exception 'STAGE_CONFLICT'; end if;
 select coalesce(max(version_number),0)+1 into v_version from public.creator_artifacts where project_id=p_project_id and kind=p_kind;
 insert into public.creator_artifacts(project_id,kind,version_number,inline_text,sha256,client_request_id,created_by)
 values(p_project_id,p_kind,v_version,btrim(p_inline_text),p_sha256,p_client_request_id,v_actor) returning * into v_artifact;
 if v_version>1 then
   update public.creator_reviews r set invalidated_at=now(),invalidation_reason='NEW_VERSION_CREATED'
   where r.project_id=p_project_id and r.invalidated_at is null and r.artifact_id in(select a.id from public.creator_artifacts a where a.project_id=p_project_id and a.kind=p_kind and a.id<>v_artifact.id);
 end if;
 insert into public.creator_audit_events(project_id,owner_id,actor_id,actor_kind,event_code,artifact_id) values(p_project_id,v_actor,v_actor,'human','ARTIFACT_VERSION_CREATED',v_artifact.id);
 return jsonb_build_object('project',to_jsonb(v_project),'artifact',to_jsonb(v_artifact),'replayed',false);
end $$;

create or replace function creator_private.creator_attest_rights_impl(p_project_id uuid,p_artifact_id uuid,p_statement_version text,p_client_request_id uuid)
returns void language plpgsql security definer set search_path=''
as $$
declare v_actor uuid:=auth.uid(); v_artifact public.creator_artifacts; begin
 if v_actor is null then raise exception 'UNAUTHORIZED'; end if;
 if p_statement_version is null or char_length(btrim(p_statement_version)) not between 1 and 64 then raise exception 'RIGHTS_STATEMENT_INVALID'; end if;
 if p_client_request_id is null then raise exception 'CLIENT_REQUEST_ID_REQUIRED'; end if;
 if exists(select 1 from public.creator_rights_attestations where attested_by=v_actor and client_request_id=p_client_request_id) then return; end if;
 select a.* into v_artifact from public.creator_artifacts a join public.creator_projects p on p.id=a.project_id
 where a.id=p_artifact_id and a.project_id=p_project_id and a.kind='content' and a.stale_at is null and p.owner_id=v_actor;
 if not found then raise exception 'ARTIFACT_BINDING_INVALID'; end if;
 insert into public.creator_rights_attestations(project_id,artifact_id,attested_by,statement_version,artifact_sha256,client_request_id)
 values(p_project_id,p_artifact_id,v_actor,btrim(p_statement_version),v_artifact.sha256,p_client_request_id);
 insert into public.creator_audit_events(project_id,owner_id,actor_id,actor_kind,event_code,artifact_id) values(p_project_id,v_actor,v_actor,'human','RIGHTS_ATTESTED',p_artifact_id);
end $$;

create or replace function creator_private.creator_transition_project_impl(p_project_id uuid,p_expected_stage text,p_event text,p_artifact_id uuid,p_artifact_sha256 text,p_idempotency_key uuid,p_notes text default null)
returns public.creator_projects language plpgsql security definer set search_path=''
as $$
declare v_actor uuid:=auth.uid(); v_project public.creator_projects; v_artifact public.creator_artifacts; v_next_stage text; v_expected_kind text; begin
 if v_actor is null then raise exception 'UNAUTHORIZED'; end if; if p_idempotency_key is null then raise exception 'IDEMPOTENCY_KEY_REQUIRED'; end if;
 select * into v_project from public.creator_projects where id=p_project_id and owner_id=v_actor for update; if not found then raise exception 'PROJECT_NOT_FOUND'; end if;
 if exists(select 1 from public.creator_audit_events where project_id=p_project_id and idempotency_key=p_idempotency_key) then return v_project; end if;
 if v_project.current_stage<>p_expected_stage then raise exception 'STAGE_CONFLICT'; end if;
 select t.next_stage,t.expected_kind into v_next_stage,v_expected_kind from (values
 ('CONTENT_REVIEW','APPROVE_CONTENT','CONTENT_APPROVED','content'),('CONTENT_APPROVED','START_SCRIPT','SCRIPT_GENERATING',null),
 ('SCRIPT_REVIEW','APPROVE_SCRIPT','SCRIPT_APPROVED','script'),('SCRIPT_APPROVED','START_VOICE','VOICE_GENERATING',null),
 ('VOICE_REVIEW','APPROVE_VOICE','VOICE_APPROVED','voice'),('VOICE_APPROVED','START_AVATAR','AVATAR_GENERATING',null),
 ('AVATAR_REVIEW','APPROVE_AVATAR','AVATAR_APPROVED','avatar'),('AVATAR_APPROVED','START_EDIT','EDIT_GENERATING',null),
 ('EDIT_REVIEW','APPROVE_EDIT','EDIT_APPROVED','edit'),('EDIT_APPROVED','START_FINAL','FINAL_RENDERING',null),
 ('FINAL_REVIEW','APPROVE_FINAL','FINAL_APPROVED','final')) as t(current_stage,event_code,next_stage,expected_kind)
 where t.current_stage=p_expected_stage and t.event_code=p_event;
 if v_next_stage is null then raise exception 'INVALID_WORKFLOW_TRANSITION'; end if;
 if v_expected_kind is not null then
   if p_artifact_id is null or p_artifact_sha256 is null then raise exception 'APPROVAL_BINDING_REQUIRED'; end if;
   select * into v_artifact from public.creator_artifacts where id=p_artifact_id and project_id=p_project_id and kind=v_expected_kind and sha256=p_artifact_sha256 and stale_at is null;
   if not found then raise exception 'ARTIFACT_BINDING_INVALID'; end if;
   if v_artifact.version_number<>(select max(version_number) from public.creator_artifacts where project_id=p_project_id and kind=v_expected_kind and stale_at is null) then raise exception 'LATEST_ARTIFACT_REQUIRED'; end if;
   if p_event='APPROVE_CONTENT' and not exists(select 1 from public.creator_rights_attestations where project_id=p_project_id and artifact_id=p_artifact_id and attested_by=v_actor and artifact_sha256=p_artifact_sha256) then raise exception 'RIGHTS_ATTESTATION_REQUIRED'; end if;
   insert into public.creator_reviews(project_id,artifact_id,reviewer_id,decision,artifact_version,artifact_sha256,notes)
   values(p_project_id,p_artifact_id,v_actor,'approved',v_artifact.version_number,p_artifact_sha256,p_notes);
 end if;
 update public.creator_projects set current_stage=v_next_stage,updated_at=now() where id=p_project_id returning * into v_project;
 insert into public.creator_audit_events(project_id,owner_id,actor_id,actor_kind,event_code,artifact_id,idempotency_key) values(p_project_id,v_actor,v_actor,'human',p_event,p_artifact_id,p_idempotency_key);
 return v_project;
end $$;

create or replace function creator_private.creator_request_revision_impl(p_project_id uuid,p_target_kind text,p_reason text,p_idempotency_key uuid)
returns public.creator_projects language plpgsql security definer set search_path=''
as $$
declare v_actor uuid:=auth.uid(); v_project public.creator_projects; v_boundary integer; begin
 if v_actor is null then raise exception 'UNAUTHORIZED'; end if; if p_target_kind not in ('content','script','voice','avatar','edit','final') then raise exception 'REVISION_TARGET_INVALID'; end if;
 if p_reason is null or char_length(btrim(p_reason)) not between 1 and 4000 then raise exception 'REVISION_REASON_INVALID'; end if; if p_idempotency_key is null then raise exception 'IDEMPOTENCY_KEY_REQUIRED'; end if;
 select * into v_project from public.creator_projects where id=p_project_id and owner_id=v_actor for update; if not found then raise exception 'PROJECT_NOT_FOUND'; end if;
 if exists(select 1 from public.creator_audit_events where project_id=p_project_id and idempotency_key=p_idempotency_key) then return v_project; end if;
 v_boundary:=array_position(array['content','script','voice','avatar','edit','final'],p_target_kind);
 update public.creator_artifacts set stale_at=coalesce(stale_at,now()) where project_id=p_project_id and array_position(array['content','script','voice','avatar','edit','final'],kind)>v_boundary;
 update public.creator_reviews set invalidated_at=coalesce(invalidated_at,now()),invalidation_reason='UPSTREAM_REVISED' where project_id=p_project_id and invalidated_at is null and artifact_id in(select id from public.creator_artifacts where project_id=p_project_id and stale_at is not null);
 update public.creator_jobs set status='cancelled',error_code='UPSTREAM_REVISED',updated_at=now() where project_id=p_project_id and status in ('queued','leased','running');
 update public.creator_projects set current_stage=case p_target_kind when 'content' then 'CONTENT_REVIEW' when 'script' then 'SCRIPT_REVIEW' when 'voice' then 'VOICE_REVIEW' when 'avatar' then 'AVATAR_REVIEW' when 'edit' then 'EDIT_REVIEW' else 'FINAL_REVIEW' end,updated_at=now() where id=p_project_id returning * into v_project;
 insert into public.creator_audit_events(project_id,owner_id,actor_id,actor_kind,event_code,idempotency_key,details) values(p_project_id,v_actor,v_actor,'human','REVISION_REQUESTED',p_idempotency_key,jsonb_build_object('target_kind',p_target_kind,'reason',btrim(p_reason)));
 return v_project;
end $$;

revoke all on function creator_private.creator_create_project_impl(text,uuid),creator_private.creator_create_artifact_version_impl(uuid,text,text,text,uuid),creator_private.creator_attest_rights_impl(uuid,uuid,text,uuid),creator_private.creator_transition_project_impl(uuid,text,text,uuid,text,uuid,text),creator_private.creator_request_revision_impl(uuid,text,text,uuid) from public,anon;
grant execute on function creator_private.creator_create_project_impl(text,uuid),creator_private.creator_create_artifact_version_impl(uuid,text,text,text,uuid),creator_private.creator_attest_rights_impl(uuid,uuid,text,uuid),creator_private.creator_transition_project_impl(uuid,text,text,uuid,text,uuid,text),creator_private.creator_request_revision_impl(uuid,text,text,uuid) to authenticated;

create or replace function public.creator_create_project(p_title text,p_client_request_id uuid) returns public.creator_projects language sql security invoker set search_path='' as $$select creator_private.creator_create_project_impl(p_title,p_client_request_id)$$;
create or replace function public.creator_create_artifact_version(p_project_id uuid,p_kind text,p_inline_text text,p_sha256 text,p_client_request_id uuid) returns jsonb language sql security invoker set search_path='' as $$select creator_private.creator_create_artifact_version_impl(p_project_id,p_kind,p_inline_text,p_sha256,p_client_request_id)$$;
create or replace function public.creator_attest_rights(p_project_id uuid,p_artifact_id uuid,p_statement_version text,p_client_request_id uuid) returns void language sql security invoker set search_path='' as $$select creator_private.creator_attest_rights_impl(p_project_id,p_artifact_id,p_statement_version,p_client_request_id)$$;
create or replace function public.creator_transition_project(p_project_id uuid,p_expected_stage text,p_event text,p_artifact_id uuid,p_artifact_sha256 text,p_idempotency_key uuid,p_notes text default null) returns public.creator_projects language sql security invoker set search_path='' as $$select creator_private.creator_transition_project_impl(p_project_id,p_expected_stage,p_event,p_artifact_id,p_artifact_sha256,p_idempotency_key,p_notes)$$;
create or replace function public.creator_request_revision(p_project_id uuid,p_target_kind text,p_reason text,p_idempotency_key uuid) returns public.creator_projects language sql security invoker set search_path='' as $$select creator_private.creator_request_revision_impl(p_project_id,p_target_kind,p_reason,p_idempotency_key)$$;
revoke all on function public.creator_create_project(text,uuid),public.creator_create_artifact_version(uuid,text,text,text,uuid),public.creator_attest_rights(uuid,uuid,text,uuid),public.creator_transition_project(uuid,text,text,uuid,text,uuid,text),public.creator_request_revision(uuid,text,text,uuid) from public,anon;
grant execute on function public.creator_create_project(text,uuid),public.creator_create_artifact_version(uuid,text,text,text,uuid),public.creator_attest_rights(uuid,uuid,text,uuid),public.creator_transition_project(uuid,text,text,uuid,text,uuid,text),public.creator_request_revision(uuid,text,text,uuid) to authenticated;
