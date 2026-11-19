-- Sticker progress follows the same rule as stylist scores: paid reviews,
-- memberships and the first free review with each stylist count. Extra free
-- reviews from the same person to the same stylist don't.
create or replace function public.count_submission() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.rating_counts(new.price_reason) then
    update public.profiles set submissions = submissions + 1 where id = new.client_id;
  end if;
  return new;
end $$;

-- Recount everyone with the new rule.
update public.profiles p set submissions =
  (select count(*) from public.requests r where r.client_id = p.id and public.rating_counts(r.price_reason));
