create table if not exists public.change_logs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references public.profiles (id) on delete set null,
  email text not null default '',
  display_name text not null default '',
  role text not null default '',
  action text not null check (action in ('insert', 'update', 'delete')),
  item_zh text not null default '',
  item_en text not null default '',
  created_at timestamptz not null default now()
);

create index if not exists change_logs_created_idx on public.change_logs (created_at desc);
alter table public.change_logs enable row level security;
grant insert, select on public.change_logs to authenticated;

drop policy if exists "staff records office changes" on public.change_logs;
create policy "staff records office changes" on public.change_logs
  for insert to authenticated
  with check (
    user_id = (select auth.uid())
    and role = (select private.tz_role())
    and (select private.tz_role()) in ('admin', 'super_admin')
    and email = (select email from public.profiles where id = (select auth.uid()))
    and display_name = (select display_name from public.profiles where id = (select auth.uid()))
  );

drop policy if exists "staff reads office changes" on public.change_logs;
create policy "staff reads office changes" on public.change_logs
  for select to authenticated
  using ((select private.tz_role()) in ('admin', 'super_admin'));
