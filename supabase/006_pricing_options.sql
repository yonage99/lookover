-- Stylist pricing options: first review free, monthly memberships, and a free list for friends.

alter table public.stylists
  add column if not exists first_free boolean not null default false,
  add column if not exists plan_price int check (plan_price is null or plan_price between 5 and 500),
  add column if not exists plan_submissions int check (plan_submissions is null or plan_submissions between 1 and 100);

alter table public.requests add column if not exists price_reason text not null default 'standard';

create table if not exists public.memberships (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references public.profiles(id) on delete cascade,
  stylist_id uuid not null references public.stylists(id) on delete cascade,
  price int not null,
  submissions int not null,
  status text not null default 'active' check (status in ('active','canceled')),
  started_at timestamptz not null default now(),
  canceled_at timestamptz,
  ends_at timestamptz
);
create unique index if not exists memberships_one_active on public.memberships(client_id, stylist_id) where status = 'active';

create table if not exists public.free_clients (
  stylist_id uuid not null references public.stylists(id) on delete cascade,
  client_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (stylist_id, client_id),
  check (stylist_id <> client_id)
);

alter table public.memberships enable row level security;
alter table public.free_clients enable row level security;

drop policy if exists "memberships parties read" on public.memberships;
create policy "memberships parties read" on public.memberships for select to authenticated
  using (client_id = auth.uid() or stylist_id = auth.uid() or public.is_admin());

drop policy if exists "free list read" on public.free_clients;
create policy "free list read" on public.free_clients for select to authenticated
  using (stylist_id = auth.uid() or client_id = auth.uid());
drop policy if exists "free list stylist add" on public.free_clients;
create policy "free list stylist add" on public.free_clients for insert to authenticated
  with check (stylist_id = auth.uid());
drop policy if exists "free list stylist remove" on public.free_clients;
create policy "free list stylist remove" on public.free_clients for delete to authenticated
  using (stylist_id = auth.uid());

grant select on public.memberships to authenticated;
grant select, delete on public.free_clients to authenticated;
grant insert (stylist_id, client_id) on public.free_clients to authenticated;
grant update (first_free, plan_price, plan_submissions) on public.stylists to authenticated;

-- Start of the current 30-day membership period.
create or replace function public.membership_period_start(m public.memberships) returns timestamptz
language sql stable as $$
  select m.started_at + floor(extract(epoch from (now() - m.started_at)) / (30*86400)) * interval '30 days'
$$;

-- An active membership (or a canceled one still inside its paid period) with looks left this period.
create or replace function public.membership_has_room(client uuid, sty uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.memberships m
    where m.client_id = client and m.stylist_id = sty
      and (m.status = 'active' or (m.ends_at is not null and m.ends_at > now()))
      and (select count(*) from public.requests r
            where r.client_id = client and r.stylist_id = sty and r.price_reason = 'membership'
              and r.created_at >= public.membership_period_start(m)) < m.submissions)
$$;

create or replace function public.request_before_insert() returns trigger
language plpgsql security definer set search_path = public as $$
declare s public.stylists;
begin
  select * into s from public.stylists where id = new.stylist_id;
  if s.id is null then raise exception 'Stylist not found'; end if;
  if not (new.kind = any (s.services)) then raise exception 'This stylist does not review %', new.kind; end if;
  if new.stylist_id = new.client_id then raise exception 'You cannot review your own look'; end if;
  new.status := 'pending'; new.feedback := null; new.client_stars := null; new.created_at := now();
  if not s.verified then
    new.amount := 0; new.price_reason := 'community';
  elsif exists (select 1 from public.free_clients f where f.stylist_id = s.id and f.client_id = new.client_id) then
    new.amount := 0; new.price_reason := 'friend';
  elsif s.first_free and not exists (select 1 from public.requests r where r.stylist_id = s.id and r.client_id = new.client_id) then
    new.amount := 0; new.price_reason := 'first_free';
  elsif public.membership_has_room(new.client_id, s.id) then
    new.amount := 0; new.price_reason := 'membership';
  else
    new.amount := case when s.rating >= 4.8 and s.reviews >= 50 then 15 else 10 end; new.price_reason := 'standard';
  end if;
  return new;
end $$;

create or replace function public.join_membership(sty uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare s public.stylists; mid uuid;
begin
  if auth.uid() is null then raise exception 'Please log in first'; end if;
  select * into s from public.stylists where id = sty;
  if s.id is null or not s.verified or s.plan_price is null or s.plan_submissions is null then
    raise exception 'This stylist does not offer a membership right now'; end if;
  if sty = auth.uid() then raise exception 'You cannot join your own membership'; end if;
  if exists (select 1 from public.memberships where client_id = auth.uid() and stylist_id = sty and status = 'active') then
    raise exception 'You already have a membership with this stylist'; end if;
  insert into public.memberships (client_id, stylist_id, price, submissions)
  values (auth.uid(), sty, s.plan_price, s.plan_submissions) returning id into mid;
  return mid;
end $$;

create or replace function public.cancel_membership(mid uuid) returns void
language plpgsql security definer set search_path = public as $$
declare m public.memberships;
begin
  select * into m from public.memberships where id = mid and client_id = auth.uid() and status = 'active';
  if m.id is null then raise exception 'Membership not found'; end if;
  update public.memberships set status = 'canceled', canceled_at = now(),
    ends_at = public.membership_period_start(m) + interval '30 days' where id = mid;
end $$;

create or replace function public.membership_usage(mid uuid) returns table (used int, period_start timestamptz, period_end timestamptz)
language sql stable security definer set search_path = public as $$
  select (select count(*)::int from public.requests r where r.client_id = m.client_id and r.stylist_id = m.stylist_id
            and r.price_reason = 'membership' and r.created_at >= public.membership_period_start(m)),
         public.membership_period_start(m), public.membership_period_start(m) + interval '30 days'
  from public.memberships m where m.id = mid and (m.client_id = auth.uid() or m.stylist_id = auth.uid())
$$;

revoke execute on function public.join_membership(uuid), public.cancel_membership(uuid), public.membership_usage(uuid),
  public.membership_has_room(uuid, uuid), public.membership_period_start(public.memberships) from public, anon;
grant execute on function public.join_membership(uuid), public.cancel_membership(uuid), public.membership_usage(uuid) to authenticated;
