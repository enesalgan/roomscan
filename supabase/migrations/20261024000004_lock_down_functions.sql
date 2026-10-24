-- Trigger functions and org-parameterised helpers are internal: not callable through the API.
revoke execute on function handle_new_user()            from authenticated, anon, public;
revoke execute on function enforce_scan_allowance()     from authenticated, anon, public;
revoke execute on function check_job_org()              from authenticated, anon, public;
revoke execute on function protect_profile_columns()    from authenticated, anon, public;
revoke execute on function protect_org_column()         from authenticated, anon, public;
revoke execute on function touch_updated_at()           from authenticated, anon, public;
revoke execute on function scans_remaining(uuid)        from authenticated, anon, public;
revoke execute on function can_create_scan(uuid)        from authenticated, anon, public;
revoke execute on function org_has_active_subscription(uuid) from authenticated, anon, public;
-- Callers only ever see their own org through these (used by RLS and my_entitlement):
grant execute on function current_org_id()      to authenticated;
grant execute on function current_role_in_org() to authenticated;
grant execute on function is_org_admin()        to authenticated;
grant execute on function my_entitlement()      to authenticated;
