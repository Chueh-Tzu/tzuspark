-- TzuSpark only. Run this on an empty TzuSpark project, never on the imMBA database.

create schema if not exists private;

create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  email text not null default '',
  display_name text not null default '',
  role text not null default 'visitor' check (role in ('visitor', 'pending', 'rejected', 'admin', 'super_admin')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.site_content (
  key text primary key,
  value_zh text not null default '',
  value_en text not null default '',
  updated_at timestamptz not null default now(),
  updated_by uuid references public.profiles (id)
);

create table if not exists public.news (
  id uuid primary key default gen_random_uuid(),
  title_zh text not null,
  title_en text not null,
  body_zh text not null,
  body_en text not null,
  published boolean not null default true,
  created_by uuid references public.profiles (id),
  created_at timestamptz not null default now()
);

create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  kind text not null check (kind in ('message', 'question', 'quote', 'product_info')),
  name text not null default '',
  email text not null default '',
  topic text not null default '',
  body text not null,
  status text not null default 'new' check (status in ('new', 'read', 'replied')),
  reply text not null default '',
  created_at timestamptz not null default now()
);

create table if not exists public.product_details (
  id uuid primary key default gen_random_uuid(),
  flavor text not null unique,
  detail_zh text not null,
  detail_en text not null,
  updated_at timestamptz not null default now()
);

create table if not exists public.site_events (
  id uuid primary key default gen_random_uuid(),
  visitor_id text not null,
  session_id text not null,
  event_type text not null check (event_type in ('pageview', 'click', 'duration')),
  path text,
  label text,
  href text,
  duration_seconds integer,
  created_at timestamptz not null default now(),
  constraint site_events_duration_check check (duration_seconds is null or (duration_seconds >= 0 and duration_seconds <= 7200)),
  constraint site_events_visitor_len_check check (char_length(visitor_id) between 8 and 80 and char_length(session_id) between 8 and 80)
);

create index if not exists news_created_at_idx on public.news (created_at desc);
create index if not exists messages_user_idx on public.messages (user_id, created_at desc);
create index if not exists site_events_created_idx on public.site_events (created_at desc);

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

alter table public.profiles enable row level security;
alter table public.site_content enable row level security;
alter table public.news enable row level security;
alter table public.messages enable row level security;
alter table public.product_details enable row level security;
alter table public.site_events enable row level security;

create or replace function private.tz_role()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select role from public.profiles where id = (select auth.uid())
$$;

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

create or replace function private.protect_last_super_admin()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.role = 'super_admin' and new.role <> 'super_admin' then
    if (select count(*) from public.profiles where role = 'super_admin' and id <> old.id) = 0 then
      raise exception 'At least one super admin is required';
    end if;
  end if;
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function private.handle_new_user();

drop trigger if exists profiles_protect_super_admin on public.profiles;
create trigger profiles_protect_super_admin
  before update on public.profiles
  for each row execute function private.protect_last_super_admin();

revoke all on function private.tz_role() from public, anon;
revoke all on function private.handle_new_user() from public, anon, authenticated;
revoke all on function private.protect_last_super_admin() from public, anon, authenticated;
grant execute on function private.tz_role() to authenticated;

drop policy if exists "members record their own login" on public.login_logs;
create policy "members record their own login" on public.login_logs
  for insert to authenticated
  with check (user_id = (select auth.uid()));

drop policy if exists "staff reads login logs" on public.login_logs;
create policy "staff reads login logs" on public.login_logs
  for select to authenticated
  using ((select private.tz_role()) in ('admin', 'super_admin'));

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

grant select on public.site_content to anon, authenticated;
grant select on public.news to anon, authenticated;
grant insert on public.site_events to anon, authenticated;
grant select on public.site_events to authenticated;
grant select, update on public.profiles to authenticated;
grant insert, update, delete on public.news to authenticated;
grant insert, update, delete on public.site_content to authenticated;
grant select, insert, update on public.messages to authenticated;
grant select, insert, update, delete on public.product_details to authenticated;

drop policy if exists "public reads site content" on public.site_content;
create policy "public reads site content" on public.site_content
  for select to anon, authenticated using (true);

drop policy if exists "super admin writes site content" on public.site_content;
create policy "super admin writes site content" on public.site_content
  for all to authenticated
  using ((select private.tz_role()) in ('admin', 'super_admin'))
  with check ((select private.tz_role()) in ('admin', 'super_admin'));

drop policy if exists "public reads published news" on public.news;
create policy "public reads published news" on public.news
  for select to anon, authenticated using (published = true);

drop policy if exists "staff reads all news" on public.news;
create policy "staff reads all news" on public.news
  for select to authenticated
  using ((select private.tz_role()) in ('admin', 'super_admin'));

drop policy if exists "staff creates news" on public.news;
create policy "staff creates news" on public.news
  for insert to authenticated
  with check (
    (select private.tz_role()) in ('admin', 'super_admin')
    and created_by = (select auth.uid())
  );

drop policy if exists "super admin updates news" on public.news;
create policy "super admin updates news" on public.news
  for update to authenticated
  using ((select private.tz_role()) = 'super_admin')
  with check ((select private.tz_role()) = 'super_admin');

drop policy if exists "super admin deletes news" on public.news;
create policy "super admin deletes news" on public.news
  for delete to authenticated
  using ((select private.tz_role()) = 'super_admin');

drop policy if exists "read own profile" on public.profiles;
create policy "read own profile" on public.profiles
  for select to authenticated
  using (id = (select auth.uid()));

drop policy if exists "super admin reads profiles" on public.profiles;
create policy "super admin reads profiles" on public.profiles
  for select to authenticated
  using ((select private.tz_role()) in ('admin', 'super_admin'));

drop policy if exists "admin reads profiles" on public.profiles;

drop policy if exists "super admin updates profiles" on public.profiles;
create policy "super admin updates profiles" on public.profiles
  for update to authenticated
  using ((select private.tz_role()) = 'super_admin')
  with check ((select private.tz_role()) = 'super_admin' and role in ('visitor', 'pending', 'rejected', 'admin', 'super_admin'));

drop policy if exists "admin updates other accounts" on public.profiles;
create policy "admin updates other accounts" on public.profiles
  for update to authenticated
  using ((select private.tz_role()) = 'admin' and role <> 'super_admin')
  with check ((select private.tz_role()) = 'admin' and role in ('visitor', 'pending', 'rejected', 'admin'));

drop policy if exists "members insert own messages" on public.messages;
create policy "members insert own messages" on public.messages
  for insert to authenticated
  with check (user_id = (select auth.uid()));

drop policy if exists "members read own messages" on public.messages;
create policy "members read own messages" on public.messages
  for select to authenticated
  using (user_id = (select auth.uid()));

drop policy if exists "super admin reads messages" on public.messages;
create policy "super admin reads messages" on public.messages
  for select to authenticated
  using ((select private.tz_role()) in ('admin', 'super_admin'));

drop policy if exists "super admin replies to messages" on public.messages;
create policy "super admin replies to messages" on public.messages
  for update to authenticated
  using ((select private.tz_role()) in ('admin', 'super_admin'))
  with check ((select private.tz_role()) in ('admin', 'super_admin'));

drop policy if exists "members read product details" on public.product_details;
create policy "members read product details" on public.product_details
  for select to authenticated using (true);

drop policy if exists "super admin writes product details" on public.product_details;
create policy "super admin writes product details" on public.product_details
  for all to authenticated
  using ((select private.tz_role()) = 'super_admin')
  with check ((select private.tz_role()) = 'super_admin');

drop policy if exists "anyone records a page view" on public.site_events;
create policy "anyone records a page view" on public.site_events
  for insert to anon, authenticated
  with check (
    event_type in ('pageview', 'click', 'duration')
    and char_length(visitor_id) between 8 and 80
    and char_length(session_id) between 8 and 80
    and (duration_seconds is null or (duration_seconds >= 0 and duration_seconds <= 7200))
  );

drop policy if exists "staff reads analytics" on public.site_events;
create policy "staff reads analytics" on public.site_events
  for select to authenticated
  using ((select private.tz_role()) in ('admin', 'super_admin'));

insert into public.site_content (key, value_zh, value_en) values
  ('hero_slogan', E'今天創新。\n明天連結。', E'Innovating Today.\nConnecting Tomorrow.'),
  ('hero_lede', '致力於提供高品質的產品與專業服務，陪你走得更遠。', 'Dedicated to providing high-quality products and professional services, helping you achieve greater success.'),
  ('about_p1', 'TzuSpark 從一個個人想法開始：一款有真正風味、沒有人工色素的氣泡汽水。這條產品線從那一點火花，長成四款氣泡罐，也長成一條可以幫夥伴做出自己罐子的小型生產路徑。', 'TzuSpark started as a personal idea: a soda with a real snap of flavor and no artificial color. The line grew from that spark into four sparkling cans, and into a small production path for partners who want a can of their own.'),
  ('about_p2', '每罐上的袋鼠只有一個原因：把快樂留在眼前。', 'The kangaroo on every can is there for one reason. Keep the joy in view.'),
  ('contact_intro', '跟我們說一個口味、一個合作，或一個問題。每一則我們都會看。', 'Tell us about a flavor, a partnership, or a question. We read every note.')
on conflict (key) do nothing;

insert into public.product_details (flavor, detail_zh, detail_en) values
  ('Ginger Ale', '薑味更明亮，帶檸檬皮。建議冰飲。成分是氣泡水、蔗糖、天然香料與檸檬酸，沒有人工色素。', 'A brighter ginger snap with lemon peel. Best served cold. Carbonated water, cane sugar, natural flavors, and citric acid. No artificial colors.'),
  ('Cranberry Ginger Ale', '蔓越莓的酸與薑的暖。適合想要更酸的氣泡口感。沒有人工色素。', 'Tart cranberry with warm ginger, for a sharper sparkling sip. No artificial colors.'),
  ('Lime', '乾淨的萊姆香氣，氣泡較清爽。適合餐後或單獨冰飲。', 'Clean lime aroma and a lighter sparkle. Suited to an after-meal glass or on its own over ice.'),
  ('Black Cherry', '熟成黑櫻桃，口感較圓。同樣只有氣泡水、蔗糖、天然香料與檸檬酸。', 'Ripe black cherry with a rounder finish. The same four ingredients: carbonated water, cane sugar, natural flavors, and citric acid.')
on conflict (flavor) do nothing;

do $$
begin
  alter publication supabase_realtime add table public.news;
exception when duplicate_object then null;
end $$;

do $$
begin
  alter publication supabase_realtime add table public.site_content;
exception when duplicate_object then null;
end $$;

do $$
begin
  alter publication supabase_realtime add table public.messages;
exception when duplicate_object then null;
end $$;

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
