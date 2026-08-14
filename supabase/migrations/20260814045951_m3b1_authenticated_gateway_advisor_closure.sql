alter function public.creator_request_voice_job(uuid,uuid,text,uuid,text,text,text,bigint,boolean,uuid) security invoker;
alter function public.creator_request_voice_revision(uuid,uuid,text,text,uuid) security invoker;
grant execute on function creator_private.creator_request_voice_job_b1_impl(uuid,uuid,text,uuid,text,text,text,bigint,boolean,uuid) to authenticated;
grant execute on function creator_private.creator_request_voice_revision_impl(uuid,uuid,text,text,uuid) to authenticated;
revoke execute on function public.creator_request_voice_job(uuid,uuid,text,uuid,text,text,text,bigint,boolean,uuid) from service_role;
revoke execute on function public.creator_request_voice_revision(uuid,uuid,text,text,uuid) from service_role;
