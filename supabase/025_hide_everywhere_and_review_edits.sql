-- 1. Hiding an upload removes it from the whole app: the stylist, the
--    community and the sender. Only admins still see it (in Hidden).
drop policy if exists "requests parties read" on public.requests;
create policy "requests parties read" on public.requests for select to authenticated
  using ((((client_id = auth.uid() or stylist_id = auth.uid()) and admin_state <> 'hidden')
          or public.is_admin())
         and public.visible_to_viewer(client_id) and public.visible_to_viewer(stylist_id));

drop policy if exists "posts readable" on public.posts;
create policy "posts readable" on public.posts for select
  using ((status = 'approved' or (author_id = auth.uid() and review_state <> 'hidden') or public.is_admin())
         and public.visible_to_viewer(author_id));

-- 2. Stylists can edit a review after sending it. The edit goes live right
--    away, is marked as edited, and waits in admin until it is reviewed.
alter table public.requests
  add column if not exists feedback_edited_at timestamptz,
  add column if not exists previous_feedback jsonb,
  add column if not exists feedback_edit_reviewed boolean not null default true;

create or replace function public.request_before_update()
 returns trigger language plpgsql security definer set search_path to 'public' as $function$
begin
  if auth.uid() is null or pg_trigger_depth() > 1 then return new; end if;
  if auth.uid() = old.stylist_id and auth.uid() <> old.client_id then
    new.client_stars := old.client_stars; new.post_id := old.post_id; new.share_when_done := old.share_when_done;
    if new.feedback is not null then new.status := 'done'; end if;
    if old.feedback is not null and new.feedback is distinct from old.feedback then
      if new.feedback is null then new.feedback := old.feedback; new.status := old.status;
      else
        new.previous_feedback := old.feedback; new.feedback_edited_at := now(); new.feedback_edit_reviewed := false;
      end if;
    end if;
  elsif auth.uid() = old.client_id then
    new.feedback := old.feedback; new.status := old.status;
    if old.status <> 'done' then new.client_stars := old.client_stars; end if;
    if old.client_stars is not null then new.client_stars := old.client_stars; end if;
  end if;
  return new;
end $function$;

-- Contact check covers every written part of a review, including each category.
create or replace function public.request_contact_guard()
 returns trigger language plpgsql security definer set search_path to 'public' as $function$
declare t text;
begin
  if tg_op = 'INSERT' then
    if public.has_contact_info(new.question) or public.has_contact_info(new.keep)
       or public.has_contact_info(new.swap) or public.has_contact_info(new.aesthetic) then
      raise exception 'Please keep contact details, links and handles out of your request. Everything happens here on Lookover.'; end if;
  elsif new.feedback is distinct from old.feedback and new.feedback is not null then
    for t in select v from jsonb_path_query(new.feedback - 'products', 'strict $.**') j(x), lateral (select x #>> '{}' v) s
             where jsonb_typeof(x) = 'string' loop
      if public.has_contact_info(t) then
        raise exception 'Reviews can’t include contact details, handles or other apps. Product links go in the product link boxes.'; end if;
    end loop;
  end if;
  return new;
end $function$;

create or replace function public.mark_review_edit_checked(rid uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Only admins can review edits'; end if;
  update public.requests set feedback_edit_reviewed = true where id = rid;
end $$;
revoke execute on function public.mark_review_edit_checked(uuid) from public, anon;
grant execute on function public.mark_review_edit_checked(uuid) to authenticated;
