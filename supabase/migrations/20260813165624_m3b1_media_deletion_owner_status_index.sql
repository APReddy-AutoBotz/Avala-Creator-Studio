create index creator_media_deletions_owner_status_idx
  on public.creator_media_deletions(owner_id,status,requested_at);
