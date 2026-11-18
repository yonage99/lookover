-- Remove Supabase's broad default table privileges, then re-grant only what the app needs.
revoke all on all tables in schema public from anon, authenticated;
alter default privileges in schema public revoke all on tables from anon, authenticated;
revoke execute on all functions in schema public from anon, authenticated, public;
alter default privileges in schema public revoke execute on functions from anon, authenticated, public;

grant select on public.profiles, public.stylists, public.posts, public.ratings, public.comments to anon, authenticated;
grant update (name, photo_url, keywords, fav_color, board, stickers, submissions) on public.profiles to authenticated;
grant select, insert, update, delete on public.color_profiles to authenticated;
grant insert (id, name, title, line, services, specialties, turnaround) on public.stylists to authenticated;
grant update (name, title, line, services, specialties, turnaround) on public.stylists to authenticated;
grant select on public.requests to authenticated;
grant insert (stylist_id, client_id, kind, question, keep, swap, aesthetic, photo_url, color_profile) on public.requests to authenticated;
grant update (feedback, status, client_stars, post_id) on public.requests to authenticated;
grant insert (author_id, kind, caption, aesthetic, photo_url, request_id) on public.posts to authenticated;
grant delete on public.posts to authenticated;
grant insert (post_id, user_id, score) on public.ratings to authenticated;
grant update (score) on public.ratings to authenticated;
grant insert (post_id, author_id, text) on public.comments to authenticated;
grant delete on public.comments to authenticated;
grant select on public.applications to authenticated;
grant insert (stylist_id, experience, link, note, portfolio) on public.applications to authenticated;
grant execute on function public.review_application(uuid, boolean) to authenticated;
grant execute on function public.is_admin() to anon, authenticated;

-- Let internal triggers (rating refresh) update stylist stats; block users from editing them.
create or replace function public.stylist_before_write() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if pg_trigger_depth() > 1 or public.is_admin() then return new; end if;
  if tg_op = 'INSERT' then new.verified := false; new.rating := 0; new.reviews := 0;
  else new.verified := old.verified; new.rating := old.rating; new.reviews := old.reviews; end if;
  return new;
end $$;
