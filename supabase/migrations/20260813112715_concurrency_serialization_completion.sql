create or replace function creator_private.creator_create_project_impl(p_title text, p_client_request_id uuid)
returns public.creator_projects
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_project public.creator_projects;
  v_title text;
begin
  if v_actor is null then raise exception 'UNAUTHORIZED'; end if;
  if p_title is null or char_length(btrim(p_title)) not between 1 and 160 then raise exception 'PROJECT_TITLE_INVALID'; end if;
  if p_client_request_id is null then raise exception 'CLIENT_REQUEST_ID_REQUIRED'; end if;
  v_title := btrim(p_title);

  insert into public.creator_projects(owner_id, title, client_request_id)
  values (v_actor, v_title, p_client_request_id)
  on conflict (owner_id, client_request_id) do nothing
  returning * into v_project;

  if found then
    insert into public.creator_audit_events(project_id, owner_id, actor_id, actor_kind, event_code, details)
    values (v_project.id, v_actor, v_actor, 'human', 'PROJECT_CREATED', jsonb_build_object('title', v_title));
    return v_project;
  end if;

  select * into v_project from public.creator_projects
  where owner_id = v_actor and client_request_id = p_client_request_id;
  if not found then raise exception 'PROJECT_CREATE_REPLAY_LOST'; end if;
  if v_project.title <> v_title then raise exception 'IDEMPOTENCY_KEY_REUSED'; end if;
  return v_project;
end;
$$;

create or replace function creator_private.creator_invalidate_profile_dependents(
  p_profile_id uuid, p_reason text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_kind text;
  v_projects uuid[];
  v_artifacts integer := 0;
  v_reviews integer := 0;
  v_jobs integer := 0;
  v_projects_updated integer := 0;
begin
  select profile_kind into v_kind from public.creator_consent_profiles where id=p_profile_id;
  if v_kind is null then raise exception 'PROFILE_NOT_FOUND'; end if;

  select array_agg(distinct project_id) into v_projects
  from (
    select project_id from public.creator_artifacts where identity_profile_id=p_profile_id
    union
    select project_id from public.creator_jobs where identity_profile_id=p_profile_id
  ) affected;

  if coalesce(array_length(v_projects,1),0)=0 then
    return jsonb_build_object('projects',0,'artifacts',0,'reviews',0,'jobs',0);
  end if;

  perform p.id
  from public.creator_projects p
  where p.id = any(v_projects)
  order by p.id
  for update;

  if v_kind='voice' then
    update public.creator_artifacts
      set stale_at=coalesce(stale_at,now())
      where project_id=any(v_projects) and kind in ('voice','avatar','edit','final') and stale_at is null;
    get diagnostics v_artifacts=row_count;

    update public.creator_reviews r
      set invalidated_at=coalesce(r.invalidated_at,now()), invalidation_reason=p_reason
      where r.project_id=any(v_projects) and r.invalidated_at is null
        and exists(select 1 from public.creator_artifacts a where a.id=r.artifact_id and a.kind in ('voice','avatar','edit','final'));
    get diagnostics v_reviews=row_count;

    update public.creator_jobs
      set status='cancelled', error_code=p_reason, updated_at=now()
      where project_id=any(v_projects) and job_type in ('voice','avatar','edit','final') and status in ('queued','leased','running');
    get diagnostics v_jobs=row_count;

    update public.creator_projects set
      current_stage=case when current_stage in (
        'VOICE_GENERATING','VOICE_REVIEW','VOICE_APPROVED','AVATAR_GENERATING','AVATAR_REVIEW','AVATAR_APPROVED',
        'EDIT_GENERATING','EDIT_REVIEW','EDIT_APPROVED','FINAL_RENDERING','FINAL_REVIEW','FINAL_APPROVED'
      ) then 'SCRIPT_APPROVED' else current_stage end,
      updated_at=now()
      where id=any(v_projects);
    get diagnostics v_projects_updated=row_count;
  else
    update public.creator_artifacts
      set stale_at=coalesce(stale_at,now())
      where project_id=any(v_projects) and kind in ('avatar','edit','final') and stale_at is null;
    get diagnostics v_artifacts=row_count;

    update public.creator_reviews r
      set invalidated_at=coalesce(r.invalidated_at,now()), invalidation_reason=p_reason
      where r.project_id=any(v_projects) and r.invalidated_at is null
        and exists(select 1 from public.creator_artifacts a where a.id=r.artifact_id and a.kind in ('avatar','edit','final'));
    get diagnostics v_reviews=row_count;

    update public.creator_jobs
      set status='cancelled', error_code=p_reason, updated_at=now()
      where project_id=any(v_projects) and job_type in ('avatar','edit','final') and status in ('queued','leased','running');
    get diagnostics v_jobs=row_count;

    update public.creator_projects set
      current_stage=case when current_stage in (
        'AVATAR_GENERATING','AVATAR_REVIEW','AVATAR_APPROVED','EDIT_GENERATING','EDIT_REVIEW','EDIT_APPROVED',
        'FINAL_RENDERING','FINAL_REVIEW','FINAL_APPROVED'
      ) then 'VOICE_APPROVED' else current_stage end,
      updated_at=now()
      where id=any(v_projects);
    get diagnostics v_projects_updated=row_count;
  end if;

  return jsonb_build_object(
    'projects',v_projects_updated,'artifacts',v_artifacts,'reviews',v_reviews,'jobs',v_jobs
  );
end;
$$;
