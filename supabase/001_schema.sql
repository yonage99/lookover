-- Lookover schema: profiles, stylists, requests, community posts, verification.
create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  name text not null default 'New member' check (char_length(name) between 1 and 40),
  photo_url text,
  keywords text[] not null default '{}',
  fav_color text not null default '#8c1238' check (fav_color ~ '^#[0-9a-fA-F]{6}$'),
  board jsonb not null default '[]',
  stickers jsonb not null default '[]',
  submissions int not null default 0,
  is_admin boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists public.color_profiles (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  data jsonb not null,
  updated_at timestamptz not null default now()
);

create table if not exists public.stylists (
  id uuid primary key references public.profiles(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 60),
  title text not null default '',
  line text not null default '' check (char_length(line) <= 120),
  services text[] not null default '{outfit}',
  specialties text[] not null default '{}',
  turnaround text not null default '48h',
  verified boolean not null default false,
  rating numeric(3,2) not null default 0,
  reviews int not null default 0,
  created_at timestamptz not null default now()
);

create table if not exists public.requests (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references public.profiles(id) on delete cascade,
  stylist_id uuid not null references public.stylists(id) on delete cascade,
  kind text not null check (kind in ('outfit','makeup','skin','nails','hair')),
  question text not null check (char_length(question) between 1 and 600),
  keep text not null default '',
  swap text not null default '',
  aesthetic text not null default '',
  photo_url text,
  color_profile jsonb,
  status text not null default 'pending' check (status in ('pending','done')),
  amount int not null default 0,
  feedback jsonb,
  client_stars int check (client_stars between 1 and 5),
  post_id uuid,
  created_at timestamptz not null default now()
);

create table if not exists public.posts (
  id uuid primary key default gen_random_uuid(),
  author_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null check (kind in ('outfit','makeup','skin','nails','hair')),
  caption text not null default '' check (char_length(caption) <= 600),
  aesthetic text not null default '',
  photo_url text,
  request_id uuid references public.requests(id) on delete set null,
  created_at timestamptz not null default now()
);

create table if not exists public.ratings (
  post_id uuid not null references public.posts(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  score int not null check (score between 1 and 10),
  created_at timestamptz not null default now(),
  primary key (post_id, user_id)
);

create table if not exists public.comments (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.posts(id) on delete cascade,
  author_id uuid not null references public.profiles(id) on delete cascade,
  text text not null check (char_length(text) between 1 and 300),
  is_pro boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists public.applications (
  id uuid primary key default gen_random_uuid(),
  stylist_id uuid not null references public.stylists(id) on delete cascade,
  experience text not null,
  link text not null default '',
  note text not null default '',
  portfolio text[] not null default '{}',
  status text not null default 'pending' check (status in ('pending','approved','declined')),
  created_at timestamptz not null default now()
);

create index if not exists requests_client_idx on public.requests(client_id, created_at desc);
create index if not exists requests_stylist_idx on public.requests(stylist_id, status, created_at);
create index if not exists posts_created_idx on public.posts(created_at desc);
create index if not exists comments_post_idx on public.comments(post_id, created_at);

-- ---------- helper + triggers ----------
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as
$$ select coalesce((select is_admin from public.profiles where id = auth.uid()), false) $$;

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, name)
  values (new.id, coalesce(nullif(left(trim(new.raw_user_meta_data->>'name'), 40), ''), 'New member'))
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- Price and status are set by the server, never by the client.
create or replace function public.request_before_insert() returns trigger
language plpgsql security definer set search_path = public as $$
declare s public.stylists;
begin
  select * into s from public.stylists where id = new.stylist_id;
  if s.id is null then raise exception 'Stylist not found'; end if;
  if not (new.kind = any (s.services)) then raise exception 'This stylist does not review %', new.kind; end if;
  if new.stylist_id = new.client_id then raise exception 'You cannot review your own look'; end if;
  new.amount := case when not s.verified then 0 when s.rating >= 4.8 and s.reviews >= 50 then 15 else 10 end;
  new.status := 'pending'; new.feedback := null; new.client_stars := null; new.created_at := now();
  return new;
end $$;
drop trigger if exists requests_bi on public.requests;
create trigger requests_bi before insert on public.requests for each row execute function public.request_before_insert();

-- Who may change what on a request after it is created.
create or replace function public.request_before_update() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return new; end if;
  if auth.uid() = old.stylist_id and auth.uid() <> old.client_id then
    new.client_stars := old.client_stars; new.post_id := old.post_id;
    if new.feedback is not null then new.status := 'done'; end if;
  elsif auth.uid() = old.client_id then
    new.feedback := old.feedback; new.status := old.status;
    if old.status <> 'done' then new.client_stars := old.client_stars; end if;
    if old.client_stars is not null then new.client_stars := old.client_stars; end if;
  end if;
  return new;
end $$;
drop trigger if exists requests_bu on public.requests;
create trigger requests_bu before update on public.requests for each row execute function public.request_before_update();

-- Client stars feed the stylist's rating.
create or replace function public.refresh_stylist_rating() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.client_stars is distinct from old.client_stars then
    update public.stylists s set
      rating = coalesce((select round(avg(client_stars)::numeric, 2) from public.requests where stylist_id = s.id and client_stars is not null), 0),
      reviews = (select count(*) from public.requests where stylist_id = s.id and client_stars is not null)
    where s.id = new.stylist_id;
  end if;
  return new;
end $$;
drop trigger if exists requests_au on public.requests;
create trigger requests_au after update on public.requests for each row execute function public.refresh_stylist_rating();

create or replace function public.comment_before_insert() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.is_pro := exists (select 1 from public.stylists where id = new.author_id);
  new.created_at := now();
  return new;
end $$;
drop trigger if exists comments_bi on public.comments;
create trigger comments_bi before insert on public.comments for each row execute function public.comment_before_insert();

create or replace function public.stylist_before_write() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.is_admin() then return new; end if;
  if tg_op = 'INSERT' then
    new.verified := false; new.rating := 0; new.reviews := 0;
  else
    new.verified := old.verified; new.rating := old.rating; new.reviews := old.reviews;
  end if;
  return new;
end $$;
drop trigger if exists stylists_bw on public.stylists;
create trigger stylists_bw before insert or update on public.stylists for each row execute function public.stylist_before_write();

create or replace function public.application_before_insert() returns trigger
language plpgsql security definer set search_path = public as $$
begin new.status := 'pending'; new.created_at := now(); return new; end $$;
drop trigger if exists applications_bi on public.applications;
create trigger applications_bi before insert on public.applications for each row execute function public.application_before_insert();

create or replace function public.review_application(app_id uuid, approve boolean) returns void
language plpgsql security definer set search_path = public as $$
declare a public.applications;
begin
  if not public.is_admin() then raise exception 'Only admins can review applications'; end if;
  update public.applications set status = case when approve then 'approved' else 'declined' end where id = app_id returning * into a;
  if approve and a.id is not null then update public.stylists set verified = true where id = a.stylist_id; end if;
end $$;

-- ---------- Row level security ----------
alter table public.profiles enable row level security;
alter table public.color_profiles enable row level security;
alter table public.stylists enable row level security;
alter table public.requests enable row level security;
alter table public.posts enable row level security;
alter table public.ratings enable row level security;
alter table public.comments enable row level security;
alter table public.applications enable row level security;

drop policy if exists "profiles readable" on public.profiles;
create policy "profiles readable" on public.profiles for select using (true);
drop policy if exists "profiles self update" on public.profiles;
create policy "profiles self update" on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

drop policy if exists "colors own" on public.color_profiles;
create policy "colors own" on public.color_profiles for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists "stylists readable" on public.stylists;
create policy "stylists readable" on public.stylists for select using (true);
drop policy if exists "stylists self insert" on public.stylists;
create policy "stylists self insert" on public.stylists for insert to authenticated with check (id = auth.uid());
drop policy if exists "stylists self update" on public.stylists;
create policy "stylists self update" on public.stylists for update to authenticated using (id = auth.uid() or public.is_admin()) with check (id = auth.uid() or public.is_admin());

drop policy if exists "requests parties read" on public.requests;
create policy "requests parties read" on public.requests for select to authenticated using (client_id = auth.uid() or stylist_id = auth.uid());
drop policy if exists "requests client insert" on public.requests;
create policy "requests client insert" on public.requests for insert to authenticated with check (client_id = auth.uid());
drop policy if exists "requests parties update" on public.requests;
create policy "requests parties update" on public.requests for update to authenticated using (client_id = auth.uid() or stylist_id = auth.uid()) with check (client_id = auth.uid() or stylist_id = auth.uid());

drop policy if exists "posts readable" on public.posts;
create policy "posts readable" on public.posts for select using (true);
drop policy if exists "posts own insert" on public.posts;
create policy "posts own insert" on public.posts for insert to authenticated with check (author_id = auth.uid());
drop policy if exists "posts own delete" on public.posts;
create policy "posts own delete" on public.posts for delete to authenticated using (author_id = auth.uid() or public.is_admin());

drop policy if exists "ratings readable" on public.ratings;
create policy "ratings readable" on public.ratings for select using (true);
drop policy if exists "ratings own write" on public.ratings;
create policy "ratings own write" on public.ratings for insert to authenticated
  with check (user_id = auth.uid() and not exists (select 1 from public.posts p where p.id = post_id and p.author_id = auth.uid()));
drop policy if exists "ratings own update" on public.ratings;
create policy "ratings own update" on public.ratings for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists "comments readable" on public.comments;
create policy "comments readable" on public.comments for select using (true);
drop policy if exists "comments own insert" on public.comments;
create policy "comments own insert" on public.comments for insert to authenticated with check (author_id = auth.uid());
drop policy if exists "comments own delete" on public.comments;
create policy "comments own delete" on public.comments for delete to authenticated using (author_id = auth.uid() or public.is_admin());

drop policy if exists "applications own or admin read" on public.applications;
create policy "applications own or admin read" on public.applications for select to authenticated using (stylist_id = auth.uid() or public.is_admin());
drop policy if exists "applications own insert" on public.applications;
create policy "applications own insert" on public.applications for insert to authenticated
  with check (stylist_id = auth.uid() and not exists (select 1 from public.applications x where x.stylist_id = auth.uid() and x.status = 'pending'));

-- ---------- Grants (auto-grant is off, so be explicit) ----------
grant usage on schema public to anon, authenticated;
grant select on public.profiles, public.stylists, public.posts, public.ratings, public.comments to anon, authenticated;
grant update (name, photo_url, keywords, fav_color, board, stickers, submissions) on public.profiles to authenticated;
grant select, insert, update, delete on public.color_profiles to authenticated;
grant insert (id, name, title, line, services, specialties, turnaround) on public.stylists to authenticated;
grant update (name, title, line, services, specialties, turnaround, verified) on public.stylists to authenticated;
grant select on public.requests to authenticated;
grant insert (stylist_id, client_id, kind, question, keep, swap, aesthetic, photo_url, color_profile) on public.requests to authenticated;
grant update (feedback, status, client_stars, post_id) on public.requests to authenticated;
grant insert (author_id, kind, caption, aesthetic, photo_url, request_id) on public.posts to authenticated;
grant delete on public.posts to authenticated;
grant insert, update (score) on public.ratings to authenticated;
grant insert (post_id, user_id, score) on public.ratings to authenticated;
grant insert (post_id, author_id, text) on public.comments to authenticated;
grant delete on public.comments to authenticated;
grant select on public.applications to authenticated;
grant insert (stylist_id, experience, link, note, portfolio) on public.applications to authenticated;
grant execute on function public.review_application(uuid, boolean) to authenticated;
grant execute on function public.is_admin() to authenticated;

-- ---------- Photo storage ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('photos', 'photos', true, 5242880, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set public = true, file_size_limit = 5242880, allowed_mime_types = array['image/jpeg','image/png','image/webp'];

drop policy if exists "photos owner upload" on storage.objects;
create policy "photos owner upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'photos' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "photos owner delete" on storage.objects;
create policy "photos owner delete" on storage.objects for delete to authenticated
  using (bucket_id = 'photos' and (storage.foldername(name))[1] = auth.uid()::text);
