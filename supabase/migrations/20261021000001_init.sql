-- RoomScan — initial schema
-- Organizations (branches / companies / individuals), users, jobs, scans, photos,
-- time tracking, subscriptions & scan credits, invites. Row-level security throughout.

create extension if not exists "pgcrypto";

-- ---------------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------------
create type org_type as enum ('company', 'individual');
create type member_role as enum ('owner', 'admin', 'member');
create type job_status as enum ('new', 'scheduled', 'measured', 'designing', 'quoted', 'won', 'lost', 'archived');
create type subscription_status as enum ('active', 'grace', 'expired', 'revoked');

-- ---------------------------------------------------------------------------
-- Organizations & members
-- ---------------------------------------------------------------------------
create table organizations (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  type          org_type not null default 'individual',
  owner_id      uuid not null references auth.users(id) on delete restrict,
  free_scans    int  not null default 3,            -- free tier allowance
  created_at    timestamptz not null default now()
);

create table profiles (
  id            uuid primary key references auth.users(id) on delete cascade,
  org_id        uuid not null references organizations(id) on delete cascade,
  role          member_role not null default 'member',
  full_name     text,
  email         text,
  phone         text,
  avatar_path   text,
  is_active     boolean not null default true,
  created_at    timestamptz not null default now()
);
create index profiles_org_idx on profiles(org_id);

-- Invite codes let an owner/admin add staff. The new user signs up with the code.
create table org_invites (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references organizations(id) on delete cascade,
  code          text not null unique default upper(substr(encode(gen_random_bytes(6),'hex'),1,8)),
  role          member_role not null default 'member',
  email         text,                               -- optional restriction
  created_by    uuid not null references auth.users(id),
  expires_at    timestamptz not null default now() + interval '14 days',
  used_by       uuid references auth.users(id),
  used_at       timestamptz,
  created_at    timestamptz not null default now()
);
create index org_invites_org_idx on org_invites(org_id);

-- ---------------------------------------------------------------------------
-- Jobs
-- ---------------------------------------------------------------------------
create table jobs (
  id              uuid primary key default gen_random_uuid(),
  org_id          uuid not null references organizations(id) on delete cascade,
  created_by      uuid not null references auth.users(id),
  assigned_to     uuid references auth.users(id),
  title           text not null,
  status          job_status not null default 'new',
  customer_name   text,
  customer_phone  text,
  customer_email  text,
  address_line1   text,
  address_line2   text,
  city            text,
  state           text,
  postal_code     text,
  country         text default 'US',
  latitude        double precision,
  longitude       double precision,
  scheduled_at    timestamptz,                      -- appointment / calendar
  estimate_amount numeric(12,2),
  estimate_currency text not null default 'USD',
  notes           text,
  floor_layout    jsonb,                            -- [{scan_id, x, y, rotation}] room placements on the combined plan
  local_id        text,                             -- client-side id for offline sync
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  deleted_at      timestamptz
);
create index jobs_org_status_idx on jobs(org_id, status);
create index jobs_org_updated_idx on jobs(org_id, updated_at desc);
create unique index jobs_org_local_idx on jobs(org_id, local_id) where local_id is not null;

-- ---------------------------------------------------------------------------
-- Scans (RoomPlan output)
-- ---------------------------------------------------------------------------
create table scans (
  id              uuid primary key default gen_random_uuid(),
  job_id          uuid not null references jobs(id) on delete cascade,
  org_id          uuid not null references organizations(id) on delete cascade,
  created_by      uuid not null references auth.users(id),
  name            text not null default 'Room',
  usdz_path       text,                             -- storage: scans/{org}/{job}/{scan}.usdz
  json_path       text,                             -- storage: scans/{org}/{job}/{scan}.json (CapturedRoom)
  thumbnail_path  text,
  room_count      int  not null default 1,
  floor_area_m2   numeric(10,3),
  summary         jsonb not null default '{}'::jsonb, -- walls/doors/windows/objects counts, bbox etc.
  captured_at     timestamptz not null default now(),
  local_id        text,
  created_at      timestamptz not null default now()
);
create index scans_job_idx on scans(job_id);
create index scans_org_idx on scans(org_id, created_at desc);
create unique index scans_org_local_idx on scans(org_id, local_id) where local_id is not null;

-- ---------------------------------------------------------------------------
-- Photos
-- ---------------------------------------------------------------------------
create table photos (
  id              uuid primary key default gen_random_uuid(),
  job_id          uuid not null references jobs(id) on delete cascade,
  org_id          uuid not null references organizations(id) on delete cascade,
  created_by      uuid not null references auth.users(id),
  storage_path    text not null,                    -- photos/{org}/{job}/{photo}.jpg
  caption         text,
  width           int,
  height          int,
  taken_at        timestamptz,
  local_id        text,
  created_at      timestamptz not null default now()
);
create index photos_job_idx on photos(job_id);
create unique index photos_org_local_idx on photos(org_id, local_id) where local_id is not null;

-- ---------------------------------------------------------------------------
-- Time tracking (timer per job)
-- ---------------------------------------------------------------------------
create table time_entries (
  id              uuid primary key default gen_random_uuid(),
  job_id          uuid not null references jobs(id) on delete cascade,
  org_id          uuid not null references organizations(id) on delete cascade,
  user_id         uuid not null references auth.users(id),
  started_at      timestamptz not null default now(),
  ended_at        timestamptz,
  note            text,
  local_id        text,
  created_at      timestamptz not null default now()
);
create index time_entries_job_idx on time_entries(job_id);
create unique index time_entries_org_local_idx on time_entries(org_id, local_id) where local_id is not null;

-- ---------------------------------------------------------------------------
-- Subscriptions (Apple In-App Purchase, verified server-side)
-- ---------------------------------------------------------------------------
create table subscriptions (
  id                        uuid primary key default gen_random_uuid(),
  org_id                    uuid not null references organizations(id) on delete cascade,
  platform                  text not null default 'apple',
  product_id                text not null,
  original_transaction_id   text not null,
  status                    subscription_status not null default 'active',
  expires_at                timestamptz,
  environment               text,                  -- Sandbox / Production
  raw                       jsonb,
  updated_at                timestamptz not null default now(),
  created_at                timestamptz not null default now(),
  unique (platform, original_transaction_id)
);
create index subscriptions_org_idx on subscriptions(org_id);

-- One-off scan credit packs (optional, for consumable purchases)
create table scan_credits (
  id              uuid primary key default gen_random_uuid(),
  org_id          uuid not null references organizations(id) on delete cascade,
  amount          int not null,                     -- positive = granted, negative = consumed
  reason          text,
  transaction_id  text unique,
  created_at      timestamptz not null default now()
);
create index scan_credits_org_idx on scan_credits(org_id);

-- ---------------------------------------------------------------------------
-- Helper functions
-- ---------------------------------------------------------------------------
create or replace function current_org_id() returns uuid
language sql stable security definer set search_path = public as $$
  select org_id from profiles where id = auth.uid()
$$;

create or replace function current_role_in_org() returns member_role
language sql stable security definer set search_path = public as $$
  select role from profiles where id = auth.uid()
$$;

create or replace function is_org_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select role in ('owner','admin') from profiles where id = auth.uid()), false)
$$;

create or replace function org_has_active_subscription(p_org uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from subscriptions
    where org_id = p_org
      and status in ('active','grace')
      and (expires_at is null or expires_at > now())
  )
$$;

-- Scans used vs. allowance. Returns remaining free+credit scans (null = unlimited).
create or replace function scans_remaining(p_org uuid) returns int
language plpgsql stable security definer set search_path = public as $$
declare
  v_free int; v_used int; v_credits int;
begin
  if org_has_active_subscription(p_org) then return null; end if;
  select free_scans into v_free from organizations where id = p_org;
  select count(*) into v_used from scans where org_id = p_org;
  select coalesce(sum(amount),0) into v_credits from scan_credits where org_id = p_org;
  return greatest(v_free + v_credits - v_used, 0);
end $$;

create or replace function can_create_scan(p_org uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(scans_remaining(p_org), 1) > 0
$$;

-- Convenience RPC for the app: entitlement summary
create or replace function my_entitlement() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'org_id', current_org_id(),
    'subscribed', org_has_active_subscription(current_org_id()),
    'scans_remaining', scans_remaining(current_org_id()),
    'scans_used', (select count(*) from scans where org_id = current_org_id())
  )
$$;

-- ---------------------------------------------------------------------------
-- Triggers
-- ---------------------------------------------------------------------------
-- New auth user → profile (+ org). Signup metadata:
--   org_name   : create a new company org and make the user its owner
--   invite_code: join an existing org via invite
--   (neither)  : individual org
create or replace function handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_org uuid; v_role member_role := 'owner'; v_inv org_invites%rowtype;
  v_name text := coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email,'@',1));
begin
  if new.raw_user_meta_data ? 'invite_code' then
    select * into v_inv from org_invites
     where code = upper(new.raw_user_meta_data->>'invite_code')
       and used_at is null and expires_at > now()
       and (email is null or lower(email) = lower(new.email));
    if v_inv.id is null then
      raise exception 'Invalid or expired invite code';
    end if;
    v_org := v_inv.org_id; v_role := v_inv.role;
    update org_invites set used_by = new.id, used_at = now() where id = v_inv.id;
  elsif coalesce(new.raw_user_meta_data->>'org_name','') <> '' then
    insert into organizations(name, type, owner_id)
      values (new.raw_user_meta_data->>'org_name', 'company', new.id) returning id into v_org;
  else
    insert into organizations(name, type, owner_id)
      values (v_name, 'individual', new.id) returning id into v_org;
  end if;

  insert into profiles(id, org_id, role, full_name, email)
    values (new.id, v_org, v_role, v_name, new.email);
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();

-- Enforce scan allowance
create or replace function enforce_scan_allowance() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not can_create_scan(new.org_id) then
    raise exception 'SCAN_LIMIT_REACHED' using errcode = 'P0001';
  end if;
  return new;
end $$;

create trigger scans_enforce_allowance
  before insert on scans
  for each row execute function enforce_scan_allowance();

-- updated_at
create or replace function touch_updated_at() returns trigger
language plpgsql as $$
begin new.updated_at = now(); return new; end $$;

create trigger jobs_touch before update on jobs
  for each row execute function touch_updated_at();

-- ---------------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------------
alter table organizations enable row level security;
alter table profiles      enable row level security;
alter table org_invites   enable row level security;
alter table jobs          enable row level security;
alter table scans         enable row level security;
alter table photos        enable row level security;
alter table time_entries  enable row level security;
alter table subscriptions enable row level security;
alter table scan_credits  enable row level security;

-- organizations
create policy org_select on organizations for select using (id = current_org_id());
create policy org_update on organizations for update using (id = current_org_id() and is_org_admin());

-- profiles
create policy profiles_select on profiles for select using (org_id = current_org_id());
create policy profiles_update_self on profiles for update using (id = auth.uid());
create policy profiles_admin_update on profiles for update using (org_id = current_org_id() and is_org_admin());

-- invites (admins only)
create policy invites_select on org_invites for select using (org_id = current_org_id() and is_org_admin());
create policy invites_insert on org_invites for insert with check (org_id = current_org_id() and is_org_admin() and created_by = auth.uid());
create policy invites_delete on org_invites for delete using (org_id = current_org_id() and is_org_admin());

-- jobs: everyone in org can read/write; delete is soft (deleted_at) via update
create policy jobs_select on jobs for select using (org_id = current_org_id());
create policy jobs_insert on jobs for insert with check (org_id = current_org_id() and created_by = auth.uid());
create policy jobs_update on jobs for update using (org_id = current_org_id());
create policy jobs_delete on jobs for delete using (org_id = current_org_id() and is_org_admin());

-- scans / photos / time entries
create policy scans_select on scans for select using (org_id = current_org_id());
create policy scans_insert on scans for insert with check (org_id = current_org_id() and created_by = auth.uid());
create policy scans_update on scans for update using (org_id = current_org_id());
create policy scans_delete on scans for delete using (org_id = current_org_id());

create policy photos_select on photos for select using (org_id = current_org_id());
create policy photos_insert on photos for insert with check (org_id = current_org_id() and created_by = auth.uid());
create policy photos_update on photos for update using (org_id = current_org_id());
create policy photos_delete on photos for delete using (org_id = current_org_id());

create policy time_select on time_entries for select using (org_id = current_org_id());
create policy time_insert on time_entries for insert with check (org_id = current_org_id() and user_id = auth.uid());
create policy time_update on time_entries for update using (org_id = current_org_id() and user_id = auth.uid());
create policy time_delete on time_entries for delete using (org_id = current_org_id() and user_id = auth.uid());

-- subscriptions & credits: read-only for members; written by edge function (service role)
create policy subs_select on subscriptions for select using (org_id = current_org_id());
create policy credits_select on scan_credits for select using (org_id = current_org_id());

-- ---------------------------------------------------------------------------
-- Storage buckets (private). Object path convention: {org_id}/{job_id}/{file}
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('scans',  'scans',  false, 209715200, null),                                   -- 200 MB (usdz/json)
  ('photos', 'photos', false,  26214400, array['image/jpeg','image/png','image/heic']) -- 25 MB
on conflict (id) do nothing;

create policy storage_org_read on storage.objects for select
  using (bucket_id in ('scans','photos') and (storage.foldername(name))[1] = current_org_id()::text);
create policy storage_org_write on storage.objects for insert
  with check (bucket_id in ('scans','photos') and (storage.foldername(name))[1] = current_org_id()::text);
create policy storage_org_update on storage.objects for update
  using (bucket_id in ('scans','photos') and (storage.foldername(name))[1] = current_org_id()::text);
create policy storage_org_delete on storage.objects for delete
  using (bucket_id in ('scans','photos') and (storage.foldername(name))[1] = current_org_id()::text);

-- ---------------------------------------------------------------------------
-- Grants (defaults are fine for authenticated via RLS; expose RPCs)
-- ---------------------------------------------------------------------------
grant execute on function my_entitlement() to authenticated;
grant execute on function scans_remaining(uuid) to authenticated;
grant execute on function can_create_scan(uuid) to authenticated;
