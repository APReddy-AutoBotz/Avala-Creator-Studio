create index if not exists voice_completion_claims_artifact_idx
  on creator_private.voice_completion_claims(artifact_id);
create index if not exists creator_media_deletions_project_idx
  on public.creator_media_deletions(project_id);
create index if not exists creator_media_deletions_artifact_idx
  on public.creator_media_deletions(artifact_id);
