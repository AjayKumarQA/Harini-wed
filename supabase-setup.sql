-- Harini's Wedding Planner: database setup for Supabase
-- Run this whole file once in Supabase: SQL Editor > New query > paste > Run.

-- ---------------------------------------------------------------
-- 1. People (one row per person who signs up)
-- ---------------------------------------------------------------
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  display_name text,
  approved boolean not null default false,
  is_admin boolean not null default false,
  created_at timestamptz not null default now()
);

-- The first person to sign up becomes the admin and is approved automatically.
-- Everyone after that waits until an admin approves them.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  first_user boolean;
begin
  select not exists (select 1 from public.profiles) into first_user;
  insert into public.profiles (id, email, display_name, approved, is_admin)
  values (
    new.id,
    new.email,
    coalesce(nullif(new.raw_user_meta_data->>'display_name', ''), split_part(new.email, '@', 1)),
    first_user,
    first_user
  );
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Helper checks used by the security rules below
create or replace function public.is_approved()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select approved from public.profiles where id = auth.uid()), false);
$$;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select approved and is_admin from public.profiles where id = auth.uid()), false);
$$;

-- ---------------------------------------------------------------
-- 2. Planner data
--    pages = Engagement, Reception, Wedding (and any you add)
--    items = tasks, expenses, guests, events and photos on a page
-- ---------------------------------------------------------------
create table if not exists public.pages (
  id text primary key,
  name text not null,
  date date,
  total_budget numeric not null default 0,
  palette jsonb not null default '[]'::jsonb,
  position integer not null default 0,
  updated_at timestamptz not null default now(),
  updated_by uuid
);

create table if not exists public.items (
  id text primary key,
  page_id text not null references public.pages(id) on delete cascade,
  kind text not null check (kind in ('task', 'expense', 'guest', 'event', 'photo')),
  data jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  updated_by uuid
);

create index if not exists items_page_idx on public.items (page_id);

-- Record who changed a row and when
create or replace function public.touch_row()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  new.updated_by = auth.uid();
  return new;
end;
$$;

drop trigger if exists touch_pages on public.pages;
create trigger touch_pages before insert or update on public.pages
  for each row execute function public.touch_row();

drop trigger if exists touch_items on public.items;
create trigger touch_items before insert or update on public.items
  for each row execute function public.touch_row();

-- ---------------------------------------------------------------
-- 3. Security rules: only approved people can read or change anything
-- ---------------------------------------------------------------
alter table public.profiles enable row level security;
alter table public.pages enable row level security;
alter table public.items enable row level security;

drop policy if exists "see own profile or all if admin" on public.profiles;
create policy "see own profile or all if admin" on public.profiles
  for select to authenticated
  using (id = auth.uid() or public.is_admin());

drop policy if exists "admins approve people" on public.profiles;
create policy "admins approve people" on public.profiles
  for update to authenticated
  using (public.is_admin())
  with check (public.is_admin());

drop policy if exists "approved people use pages" on public.pages;
create policy "approved people use pages" on public.pages
  for all to authenticated
  using (public.is_approved())
  with check (public.is_approved());

drop policy if exists "approved people use items" on public.items;
create policy "approved people use items" on public.items
  for all to authenticated
  using (public.is_approved())
  with check (public.is_approved());

-- ---------------------------------------------------------------
-- 4. Photo storage (private bucket, approved people only)
-- ---------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('photos', 'photos', false, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

drop policy if exists "approved people read photos" on storage.objects;
create policy "approved people read photos" on storage.objects
  for select to authenticated
  using (bucket_id = 'photos' and public.is_approved());

drop policy if exists "approved people add photos" on storage.objects;
create policy "approved people add photos" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'photos' and public.is_approved());

drop policy if exists "approved people remove photos" on storage.objects;
create policy "approved people remove photos" on storage.objects
  for delete to authenticated
  using (bucket_id = 'photos' and public.is_approved());

-- ---------------------------------------------------------------
-- 5. Live updates so everyone sees changes without refreshing
-- ---------------------------------------------------------------
do $$
begin
  begin alter publication supabase_realtime add table public.pages; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.items; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.profiles; exception when duplicate_object then null; end;
end $$;

-- ---------------------------------------------------------------
-- 6. Activity log: who added, changed or removed what (safe to run again)
-- ---------------------------------------------------------------
create table if not exists public.activity (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  actor uuid, actor_name text, page_id text, page_name text,
  kind text not null, action text not null, summary text
);
create index if not exists activity_at_idx on public.activity (at desc);
alter table public.activity enable row level security;
drop policy if exists "approved people read activity" on public.activity;
create policy "approved people read activity" on public.activity
  for select to authenticated using (public.is_approved());

create or replace function public.log_change()
returns trigger language plpgsql security definer set search_path = public as $$
declare r record; k text; act text; summ text; pname text; pid text; who text;
begin
  if TG_OP = 'DELETE' then r := old; else r := new; end if;
  if TG_TABLE_NAME = 'pages' then
    k := 'page'; pid := r.id; pname := r.name; summ := r.name;
    if TG_OP = 'INSERT' then act := 'added';
    elsif TG_OP = 'DELETE' then act := 'removed';
    else
      if (old.name, old.date, old.total_budget, old.palette) is not distinct from (new.name, new.date, new.total_budget, new.palette) then return null; end if;
      act := 'changed';
    end if;
  else
    k := r.kind; pid := r.page_id;
    select name into pname from public.pages where id = pid;
    if pname is null and TG_OP = 'DELETE' then return null; end if; -- the whole page was removed
    summ := coalesce(r.data->>'text', r.data->>'name', nullif(r.data->>'cap', ''), 'photo');
    if TG_OP = 'INSERT' then act := 'added';
    elsif TG_OP = 'DELETE' then act := 'removed';
    else
      if (old.data - 'ord') = (new.data - 'ord') and old.page_id = new.page_id then return null; end if;
      act := 'changed';
      if k = 'task' and (old.data->>'done') is distinct from (new.data->>'done') then
        act := case when (new.data->>'done') = 'true' then 'completed' else 'reopened' end;
      elsif k = 'expense' and (old.data->>'paid') is distinct from (new.data->>'paid') then act := 'updated the payment for';
      elsif k = 'guest' and (old.data->>'rsvp') is distinct from (new.data->>'rsvp') then act := 'changed the reply for';
      end if;
    end if;
  end if;
  select coalesce(nullif(display_name, ''), email) into who from public.profiles where id = auth.uid();
  insert into public.activity (actor, actor_name, page_id, page_name, kind, action, summary)
  values (auth.uid(), coalesce(who, 'Admin (database)'), pid, pname, k, act, left(summ, 120));
  return null;
end;
$$;

drop trigger if exists log_pages on public.pages;
create trigger log_pages after insert or update or delete on public.pages
  for each row execute function public.log_change();
drop trigger if exists log_items on public.items;
create trigger log_items after insert or update or delete on public.items
  for each row execute function public.log_change();
