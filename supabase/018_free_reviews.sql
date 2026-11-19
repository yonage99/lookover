-- Stylists may review for free (price $0). Among free reviews, only the first
-- from each person to that stylist counts toward the stylist's score.
-- Paid and membership reviews still count.

alter table public.stylists drop constraint if exists stylists_price_check;
alter table public.stylists add constraint stylists_price_check check (price is null or price between 0 and 5000);

create or replace function public.request_before_insert() returns trigger
language plpgsql security definer set search_path = public as $$
declare s public.stylists; first_time boolean;
begin
  select * into s from public.stylists where id = new.stylist_id;
  if s.id is null or not s.verified then raise exception 'This stylist isn’t taking requests right now.'; end if;
  if not (new.kind = any (s.services)) then raise exception 'This stylist does not review %', new.kind; end if;
  if new.stylist_id = new.client_id then raise exception 'You cannot review your own look'; end if;
  new.status := 'pending'; new.feedback := null; new.client_stars := null; new.created_at := now();
  first_time := not exists (select 1 from public.requests r where r.stylist_id = s.id and r.client_id = new.client_id);
  if first_time and (s.first_free or s.price = 0) then
    new.amount := 0; new.price_reason := 'first_free';      -- counts toward the score
  elsif public.membership_has_room(new.client_id, s.id) then
    new.amount := 0; new.price_reason := 'membership';
  elsif s.price is null then
    raise exception 'This stylist hasn’t set a price yet.';
  elsif s.price = 0 then
    new.amount := 0; new.price_reason := 'free';            -- free, not counted
  else
    new.amount := s.price; new.price_reason := 'standard';
  end if;
  return new;
end $$;
