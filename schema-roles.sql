alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles add constraint profiles_role_check
  check (role in ('visitor', 'pending', 'rejected', 'admin', 'super_admin'));

create or replace function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  assigned text;
begin
  if not exists (select 1 from public.profiles where role = 'super_admin') then
    assigned := 'super_admin';
  else
    assigned := 'pending';
  end if;
  insert into public.profiles (id, email, display_name, role)
  values (
    new.id,
    coalesce(new.email, ''),
    coalesce(new.raw_user_meta_data ->> 'display_name', split_part(coalesce(new.email, ''), '@', 1)),
    assigned
  );
  return new;
end;
$$;

drop policy if exists "super admin updates profiles" on public.profiles;
create policy "super admin updates profiles" on public.profiles
  for update to authenticated
  using ((select private.tz_role()) = 'super_admin')
  with check ((select private.tz_role()) = 'super_admin' and role in ('visitor', 'pending', 'rejected', 'admin', 'super_admin'));

create table if not exists public.login_logs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references public.profiles (id) on delete cascade,
  email text not null default '',
  display_name text not null default '',
  role text not null default '',
  created_at timestamptz not null default now()
);

create index if not exists login_logs_created_idx on public.login_logs (created_at desc);
alter table public.login_logs enable row level security;
grant insert, select on public.login_logs to authenticated;

drop policy if exists "members record their own login" on public.login_logs;
create policy "members record their own login" on public.login_logs
  for insert to authenticated
  with check (user_id = (select auth.uid()));

drop policy if exists "staff reads login logs" on public.login_logs;
create policy "staff reads login logs" on public.login_logs
  for select to authenticated
  using ((select private.tz_role()) in ('admin', 'super_admin'));
