-- Sticker packs unlock with looks sent for review. The count is kept by the
-- server, so it only goes up when someone really sends a look.
revoke update (submissions) on public.profiles from authenticated;

create or replace function public.count_submission() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update public.profiles set submissions = submissions + 1 where id = new.client_id;
  return new;
end $$;
drop trigger if exists requests_count_submission on public.requests;
create trigger requests_count_submission after insert on public.requests for each row execute function public.count_submission();

-- Nobody loses stickers they already have.
update public.profiles p set submissions = greatest(p.submissions, (select count(*) from public.requests r where r.client_id = p.id));
