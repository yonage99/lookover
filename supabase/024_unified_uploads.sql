-- One admin queue for uploads. A request (photo sent to a stylist) and its
-- shared community post are the same upload: one decision covers both.

-- Carry over decisions already made on shared looks.
update public.requests r set admin_state = p.review_state
from public.posts p where p.request_id = r.id and p.review_state <> 'pending' and r.admin_state = 'pending';

create or replace function public.moderate_upload(rid uuid, action text) returns void
language plpgsql security definer set search_path = public as $$
declare r public.requests;
begin
  if not public.is_admin() then raise exception 'Only admins can review uploads'; end if;
  select * into r from public.requests where id = rid;
  if r.id is null then raise exception 'Upload not found'; end if;
  if action in ('approve','restore') then
    update public.requests set admin_state = 'checked' where id = rid;
    update public.posts set status = 'approved', review_state = 'checked', reviewed_at = now() where request_id = rid;
    delete from public.post_flags where post_id in (select id from public.posts where request_id = rid);
  elsif action = 'hide' then
    update public.requests set admin_state = 'hidden' where id = rid;
    update public.posts set status = 'rejected', review_state = 'hidden', reviewed_at = now() where request_id = rid;
  elsif action = 'delete' then
    if r.admin_state <> 'hidden' then raise exception 'Hide this upload first. Only hidden uploads can be deleted.'; end if;
    delete from public.posts where request_id = rid;
    delete from public.requests where id = rid;
  else
    raise exception 'Unknown action';
  end if;
end $$;
revoke execute on function public.moderate_upload(uuid, text) from public, anon;
grant execute on function public.moderate_upload(uuid, text) to authenticated;

-- Sharing an upload or getting reported puts it back in the queue.
create or replace function public.post_review_default() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.review_state := 'pending'; new.reviewed_at := null;
  update public.requests set admin_state = 'pending' where id = new.request_id and admin_state = 'checked';
  return new;
end $$;

create or replace function public.hide_after_reports() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update public.requests set admin_state = 'pending'
   where id = (select request_id from public.posts where id = new.post_id) and admin_state = 'checked';
  if (select count(distinct reporter_id) from public.post_flags where post_id = new.post_id and reporter_id is not null) >= 3 then
    update public.posts set status = 'pending', review_state = 'pending' where id = new.post_id and status = 'approved';
  end if;
  return new;
end $$;
