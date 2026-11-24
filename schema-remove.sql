create or replace function public.remove_account(target uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_role text;
  super_count integer;
begin
  if (select private.tz_role()) not in ('admin', 'super_admin') then
    raise exception 'not allowed';
  end if;
  if target = (select auth.uid()) then
    raise exception 'cannot remove the account you are using';
  end if;
  select role into target_role from public.profiles where id = target;
  if target_role = 'super_admin' and (select private.tz_role()) is distinct from 'super_admin' then
    raise exception 'cannot change a super admin';
  end if;
  select count(*) into super_count from public.profiles where role = 'super_admin';
  if target_role = 'super_admin' and super_count <= 1 then
    raise exception 'cannot remove the last super admin';
  end if;
  delete from auth.users where id = target;
end;
$$;

revoke all on function public.remove_account(uuid) from public, anon;
grant execute on function public.remove_account(uuid) to authenticated;
