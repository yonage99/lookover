-- Only ratings on paid reviews (standard or membership) or a free first review
-- count toward a stylist's public score. Friend (free list) and community
-- reviews can still be rated, and both sides can see those ratings, but they
-- are left out of the score so they cannot be used to inflate it.

create or replace function public.rating_counts(reason text) returns boolean
language sql immutable as $$ select reason in ('standard','membership','first_free') $$;

create or replace function public.refresh_stylist_rating() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.client_stars is distinct from old.client_stars then
    update public.stylists s set
      rating = coalesce((select round(avg(client_stars)::numeric, 2) from public.requests
                          where stylist_id = s.id and client_stars is not null and public.rating_counts(price_reason)), 0),
      reviews = (select count(*) from public.requests
                  where stylist_id = s.id and client_stars is not null and public.rating_counts(price_reason))
    where s.id = new.stylist_id;
  end if;
  return new;
end $$;

-- Recalculate every stylist's score under the new rule.
update public.stylists s set
  rating = coalesce((select round(avg(client_stars)::numeric, 2) from public.requests
                      where stylist_id = s.id and client_stars is not null and public.rating_counts(price_reason)), 0),
  reviews = (select count(*) from public.requests
              where stylist_id = s.id and client_stars is not null and public.rating_counts(price_reason));
