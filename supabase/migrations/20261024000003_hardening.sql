-- Security hardening
-- 1. Nobody but the service role may touch billing/ownership columns.
revoke update on organizations from authenticated, anon;
grant  update (name, branding) on organizations to authenticated;

-- 2. A user may edit their own profile but never their role or organization.
create or replace function protect_profile_columns() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (new.role <> old.role or new.org_id <> old.org_id) and not is_org_admin() then
    raise exception 'Not allowed to change role or organization';
  end if;
  if new.org_id <> old.org_id then
    raise exception 'Profiles cannot move between organizations';
  end if;
  -- only owners may promote to owner / demote an owner
  if (new.role = 'owner' or old.role = 'owner') and new.role <> old.role and current_role_in_org() <> 'owner' then
    raise exception 'Only the owner can transfer ownership';
  end if;
  return new;
end $$;
create trigger profiles_protect before update on profiles
  for each row execute function protect_profile_columns();

-- 3. Rows can never be re-homed to another organization through an update.
create or replace function protect_org_column() returns trigger
language plpgsql as $$
begin
  if new.org_id <> old.org_id then raise exception 'org_id is immutable'; end if;
  return new;
end $$;
create trigger jobs_protect_org   before update on jobs         for each row execute function protect_org_column();
create trigger scans_protect_org  before update on scans        for each row execute function protect_org_column();
create trigger photos_protect_org before update on photos       for each row execute function protect_org_column();
create trigger time_protect_org   before update on time_entries for each row execute function protect_org_column();

-- 4. Only org members with a job may attach scans/photos to it (job must belong to the same org).
create or replace function check_job_org() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from jobs where id = new.job_id and org_id = new.org_id and deleted_at is null) then
    raise exception 'Job does not belong to this organization';
  end if;
  return new;
end $$;
create trigger scans_check_job  before insert on scans  for each row execute function check_job_org();
create trigger photos_check_job before insert on photos for each row execute function check_job_org();

-- 5. Functions: no execution for anonymous / public; only signed-in users.
revoke execute on all functions in schema public from public, anon;
grant execute on function my_entitlement()        to authenticated;
grant execute on function scans_remaining(uuid)   to authenticated;
grant execute on function can_create_scan(uuid)   to authenticated;
grant execute on function current_org_id()        to authenticated;
grant execute on function current_role_in_org()   to authenticated;
grant execute on function is_org_admin()          to authenticated;
grant execute on function org_has_active_subscription(uuid) to authenticated;
alter default privileges in schema public revoke execute on functions from public;

-- 6. Lock search_path on the remaining trigger function.
alter function touch_updated_at() set search_path = public;

-- 7. Soft-deleted jobs are invisible to the API (hard delete stays admin-only).
drop policy jobs_select on jobs;
create policy jobs_select on jobs for select using (org_id = current_org_id() and deleted_at is null);

-- 8. Invites: a user may read the invite they redeemed (nothing else).
create policy invites_select_redeemed on org_invites for select using (used_by = auth.uid());

-- 9. Helpful indexes
create index if not exists jobs_org_scheduled_idx on jobs(org_id, scheduled_at) where scheduled_at is not null and deleted_at is null;
create index if not exists photos_org_idx on photos(org_id, created_at desc);
