-- Profession per user, company branding per organization, logo bucket
alter table profiles      add column if not exists profession text;
alter table organizations add column if not exists branding jsonb;

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
    insert into organizations(name, type, owner_id, branding)
      values (new.raw_user_meta_data->>'org_name', 'company', new.id,
              jsonb_build_object('company_name', new.raw_user_meta_data->>'org_name', 'watermark', true))
      returning id into v_org;
  else
    insert into organizations(name, type, owner_id)
      values (v_name, 'individual', new.id) returning id into v_org;
  end if;

  insert into profiles(id, org_id, role, full_name, email, profession)
    values (new.id, v_org, v_role, v_name, new.email, new.raw_user_meta_data->>'profession');
  return new;
end $$;

-- logos: branding/{org}/logo.png
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('branding','branding', false, 5242880, array['image/png','image/jpeg'])
  on conflict (id) do nothing;
create policy branding_read   on storage.objects for select using (bucket_id = 'branding' and (storage.foldername(name))[1] = current_org_id()::text);
create policy branding_write  on storage.objects for insert with check (bucket_id = 'branding' and (storage.foldername(name))[1] = current_org_id()::text and is_org_admin());
create policy branding_update on storage.objects for update using (bucket_id = 'branding' and (storage.foldername(name))[1] = current_org_id()::text and is_org_admin());
create policy branding_delete on storage.objects for delete using (bucket_id = 'branding' and (storage.foldername(name))[1] = current_org_id()::text and is_org_admin());
