-- Upserts from the app also write the key column.
grant update (user_id) on public.photo_reviews to authenticated;
grant update (stylist_id) on public.bio_reviews to authenticated;

-- An automatic share must never block the stylist's review.
create or replace function public.share_when_reviewed() returns trigger
language plpgsql security definer set search_path = public as $$
declare pid uuid;
begin
  if new.status = 'done' and old.status <> 'done' and new.share_when_done and new.post_id is null then
    begin
      insert into public.posts (author_id, kind, caption, aesthetic, request_id)
      values (new.client_id, new.kind, new.question, new.aesthetic, new.id) returning id into pid;
      update public.requests set post_id = pid where id = new.id;
    exception when others then
      null; -- e.g. caption failed the contact check; the client can share it later
    end;
  end if;
  return new;
end $$;

-- No contact details in requests or in stylists' written feedback (product links are allowed).
create or replace function public.request_contact_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    if public.has_contact_info(new.question) or public.has_contact_info(new.keep)
       or public.has_contact_info(new.swap) or public.has_contact_info(new.aesthetic) then
      raise exception 'Please keep contact details, links and handles out of your request. Everything happens here on Lookover.'; end if;
  elsif new.feedback is distinct from old.feedback and new.feedback is not null then
    if public.has_contact_info(new.feedback->>'notes') or public.has_contact_info(new.feedback->>'tryInstead')
       or public.has_contact_info(new.feedback->>'am') or public.has_contact_info(new.feedback->>'pm') then
      raise exception 'Reviews can’t include contact details, handles or other apps. Product links go in the product link boxes.'; end if;
  end if;
  return new;
end $$;
drop trigger if exists requests_contact_guard on public.requests;
create trigger requests_contact_guard before insert or update on public.requests for each row execute function public.request_contact_guard();
