-- One request can cover several categories (e.g. outfit + hair). kind stays as
-- the first category so older code and posts keep working.

alter table public.requests add column if not exists kinds text[] not null default '{}';
alter table public.posts add column if not exists kinds text[] not null default '{}';
update public.requests set kinds = array[kind] where cardinality(kinds) = 0;
update public.posts set kinds = array[kind] where cardinality(kinds) = 0;
grant insert (kinds) on public.requests to authenticated;

create or replace function public.request_before_insert() returns trigger
language plpgsql security definer set search_path = public as $$
declare s public.stylists; first_time boolean;
begin
  if cardinality(new.kinds) = 0 then new.kinds := array[new.kind]; end if;
  select array_agg(k order by array_position(array['outfit','makeup','nails','hair'], k)) into new.kinds from (select distinct unnest(new.kinds) k) x;
  if cardinality(new.kinds) > 4 or exists (select 1 from unnest(new.kinds) k where k not in ('outfit','makeup','nails','hair')) then
    raise exception 'Choose what you want reviewed: outfit, makeup, nails or hair.'; end if;
  new.kind := (select k from unnest(new.kinds) k order by array_position(array['outfit','makeup','nails','hair'], k) limit 1);
  select * into s from public.stylists where id = new.stylist_id;
  if s.id is null or not s.verified then raise exception 'This stylist isn’t taking requests right now.'; end if;
  if not (new.kinds <@ s.services) then raise exception 'This stylist doesn’t review everything you picked.'; end if;
  if new.stylist_id = new.client_id then raise exception 'You cannot review your own look'; end if;
  new.status := 'pending'; new.feedback := null; new.client_stars := null; new.created_at := now();
  first_time := not exists (select 1 from public.requests r where r.stylist_id = s.id and r.client_id = new.client_id);
  if first_time and (s.first_free or s.price = 0) then
    new.amount := 0; new.price_reason := 'first_free';
  elsif public.membership_has_room(new.client_id, s.id) then
    new.amount := 0; new.price_reason := 'membership';
  elsif s.price is null then
    raise exception 'This stylist hasn’t set a price yet.';
  elsif s.price = 0 then
    new.amount := 0; new.price_reason := 'free';
  else
    new.amount := s.price; new.price_reason := 'standard';
  end if;
  return new;
end $$;

-- The photo guard ran before this and rejected kind = 'skin'; kinds are now checked above.
create or replace function public.request_photos_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare u text;
begin
  if cardinality(new.photo_urls) = 0 and new.photo_url is not null then new.photo_urls := array[new.photo_url]; end if;
  foreach u in array new.photo_urls loop
    if u !~ ('^https://[a-z0-9]+\.supabase\.co/storage/v1/object/public/photos/' || new.client_id::text || '/') then
      raise exception 'Photos must be uploaded through Lookover.'; end if;
  end loop;
  new.photo_url := new.photo_urls[1];
  return new;
end $$;

create or replace function public.post_copy_photos() returns trigger
language plpgsql security definer set search_path = public as $$
declare r public.requests;
begin
  select * into r from public.requests where id = new.request_id;
  new.photo_urls := coalesce(r.photo_urls, '{}'); new.photo_url := new.photo_urls[1];
  new.kinds := coalesce(nullif(r.kinds, '{}'), array[r.kind]);
  return new;
end $$;
