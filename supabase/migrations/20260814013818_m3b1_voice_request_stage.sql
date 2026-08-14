create or replace function creator_private.creator_request_voice_job_b1_impl(
  p_project_id uuid,p_script_artifact_id uuid,p_script_sha256 text,p_profile_id uuid,
  p_provider_id text,p_voice_manifest_sha256 text,p_generation_mode text,p_max_cost_microunits bigint,
  p_human_triggered boolean,p_idempotency_key uuid
) returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  v_actor uuid:=auth.uid();
  v_result jsonb;
  v_project public.creator_projects;
  v_job_id uuid;
begin
  if v_actor is null then raise exception 'UNAUTHORIZED'; end if;
  v_result:=creator_private.creator_request_voice_job_impl(
    p_project_id,p_script_artifact_id,p_script_sha256,p_profile_id,p_provider_id,
    p_voice_manifest_sha256,p_generation_mode,p_max_cost_microunits,p_human_triggered,p_idempotency_key
  );
  if coalesce((v_result->>'accepted')::boolean,false) and p_provider_id='mock' then
    v_job_id:=(v_result->'job'->>'id')::uuid;
    select * into v_project from public.creator_projects
      where id=p_project_id and owner_id=v_actor for update;
    if not found then raise exception 'PROJECT_NOT_FOUND'; end if;
    if v_project.current_stage='SCRIPT_APPROVED' then
      update public.creator_projects set current_stage='VOICE_GENERATING',updated_at=now()
      where id=p_project_id returning * into v_project;
      insert into public.creator_audit_events(project_id,owner_id,actor_id,actor_kind,event_code,profile_id,details)
      values(p_project_id,v_actor,v_actor,'human','START_VOICE',p_profile_id,
             jsonb_build_object('job_id',v_job_id,'generation_mode','synthetic_mock','provider_id','mock'));
    elsif v_project.current_stage not in ('VOICE_GENERATING','VOICE_REVIEW','VOICE_APPROVED') then
      raise exception 'STAGE_CONFLICT';
    end if;
    return v_result || jsonb_build_object('project',to_jsonb(v_project));
  end if;
  return v_result;
end;
$$;
revoke all on function creator_private.creator_request_voice_job_b1_impl(uuid,uuid,text,uuid,text,text,text,bigint,boolean,uuid)
  from public,anon,authenticated;

create or replace function public.creator_request_voice_job(
  p_project_id uuid,p_script_artifact_id uuid,p_script_sha256 text,p_profile_id uuid,
  p_provider_id text,p_voice_manifest_sha256 text,p_generation_mode text,p_max_cost_microunits bigint,
  p_human_triggered boolean,p_idempotency_key uuid
) returns jsonb language sql set search_path=''
as $$select creator_private.creator_request_voice_job_b1_impl(
  p_project_id,p_script_artifact_id,p_script_sha256,p_profile_id,p_provider_id,
  p_voice_manifest_sha256,p_generation_mode,p_max_cost_microunits,p_human_triggered,p_idempotency_key
)$$;
