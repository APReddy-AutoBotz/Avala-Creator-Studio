create index creator_upload_intents_sample_idx
  on public.creator_upload_intents(sample_id)
  where sample_id is not null;
