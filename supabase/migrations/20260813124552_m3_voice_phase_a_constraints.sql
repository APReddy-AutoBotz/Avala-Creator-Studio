alter table public.creator_jobs add constraint creator_jobs_voice_samples_required_check
  check (job_type <> 'voice' or (voice_sample_ids is not null and cardinality(voice_sample_ids) > 0));

alter table public.creator_jobs add constraint creator_jobs_provider_approval_state_check
  check (provider_approval_state is null or provider_approval_state in ('research_only','approved_for_test','approved_for_runtime','disabled'));
