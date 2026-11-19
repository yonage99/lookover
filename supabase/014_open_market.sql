-- Open market + approvals.
-- 1. New accounts must be approved by an admin before they can take part.
-- 2. Stylists must be verified to be listed or receive requests.
-- 3. Each stylist sets their own price per review. No tiers.
-- 4. No free reviews except an optional free first review per person.
--    The free list for friends is switched off.

-- ---------- Member approval ----------
alter table public.profiles add column if not exists member_status text not null default 'pending'
  check (member_status in ('pending','approved','rejected'));
update public.profiles set member_status = 'approved' where member_status = 'pending' and created_at < now();

create or replace function public.is_approved(uid uuid) returns boolean
language sql stable security definer set search_path = public as
$$ select coalesce((select member_status = 'approved' from public.profiles where id = uid), false) $$;
grant execute on function public.is_approved(uuid) to anon, authenticated;

-- Pending or rejected accounts are visible only to themselves and admins.
drop policy if exists "profiles readable" on public.profiles;
create policy "profiles readable" on public.profiles for select
  using (public.visible_to_viewer(id) and (member_status = 'approved' or id = auth.uid() or public.is_admin()));

create or replace function public.moderate_member(uid uuid, approve boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Only admins can approve accounts'; end if;
  update public.profiles set member_status = case when approve then 'approved' else 'rejected' end where id = uid;
end $$;
revoke execute on function public.moderate_member(uuid, boolean) from public, anon;
grant execute on function public.moderate_member(uuid, boolean) to authenticated;

-- Taking part requires an approved account.
drop policy if exists "requests client insert" on public.requests;
create policy "requests client insert" on public.requests for insert to authenticated
  with check (client_id = auth.uid() and public.is_approved(auth.uid()));
drop policy if exists "posts own insert" on public.posts;
create policy "posts own insert" on public.posts for insert to authenticated
  with check (author_id = auth.uid() and public.is_approved(auth.uid()));
drop policy if exists "comments own insert" on public.comments;
create policy "comments own insert" on public.comments for insert to authenticated
  with check (author_id = auth.uid() and public.is_approved(auth.uid()));
drop policy if exists "ratings own write" on public.ratings;
create policy "ratings own write" on public.ratings for insert to authenticated
  with check (user_id = auth.uid() and public.is_approved(auth.uid())
              and not exists (select 1 from public.posts p where p.id = post_id and p.author_id = auth.uid()));
drop policy if exists "stylists self insert" on public.stylists;
create policy "stylists self insert" on public.stylists for insert to authenticated
  with check (id = auth.uid() and public.is_approved(auth.uid()));

-- ---------- Stylist prices, verification required to be listed ----------
alter table public.stylists add column if not exists price int check (price is null or price between 1 and 5000);
update public.stylists set price = 10 where verified and price is null;
grant insert (price, first_free), update (price) on public.stylists to authenticated;

drop policy if exists "stylists readable" on public.stylists;
create policy "stylists readable" on public.stylists for select
  using (public.visible_to_viewer(id) and (verified or id = auth.uid() or public.is_admin()));

create or replace function public.request_before_insert() returns trigger
language plpgsql security definer set search_path = public as $$
declare s public.stylists;
begin
  select * into s from public.stylists where id = new.stylist_id;
  if s.id is null or not s.verified then raise exception 'This stylist isn’t taking requests right now.'; end if;
  if not (new.kind = any (s.services)) then raise exception 'This stylist does not review %', new.kind; end if;
  if new.stylist_id = new.client_id then raise exception 'You cannot review your own look'; end if;
  new.status := 'pending'; new.feedback := null; new.client_stars := null; new.created_at := now();
  if s.first_free and not exists (select 1 from public.requests r where r.stylist_id = s.id and r.client_id = new.client_id) then
    new.amount := 0; new.price_reason := 'first_free';
  elsif public.membership_has_room(new.client_id, s.id) then
    new.amount := 0; new.price_reason := 'membership';
  elsif s.price is null then
    raise exception 'This stylist hasn’t set a price yet.';
  else
    new.amount := s.price; new.price_reason := 'standard';
  end if;
  return new;
end $$;

-- ---------- Free list switched off ----------
drop policy if exists "free list stylist add" on public.free_clients;
revoke insert on public.free_clients from authenticated;
