-- Soft delete sets deleted_at via UPDATE ... RETURNING; the returned row must still satisfy the SELECT policy.
alter policy jobs_select on jobs using (org_id = current_org_id());
