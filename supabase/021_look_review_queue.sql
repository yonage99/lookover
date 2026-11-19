-- Admin review queue for live looks. Looks are live right away; review_state
-- tracks whether an admin has checked them: pending -> checked, or hidden.

alter table public.posts add column if not exists review_state text not null default 'pending'
  check (review_state in ('pending','checked','hidden'));
alter table public.posts add column if not exists reviewed_at timestamptz;
update public.posts set review_state = 'hidden' where status = 'rejected';
create index if not exists posts_review_state_idx on public.posts(review_state, created_at desc);

-- New looks always start unchecked.
create or replace function public.post_review_default() returns trigger
language plpgsql as $$ begin new.review_state := 'pending'; new.reviewed_at := null; return new; end $$;
drop trigger if exists posts_review_default on public.posts;
create trigger posts_review_default before insert on public.posts for each row execute function public.post_review_default();

-- When reports auto-hide a look, put it back in the queue.
create or replace function public.hide_after_reports() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (select count(distinct reporter_id) from public.post_flags where post_id = new.post_id and reporter_id is not null) >= 3 then
    update public.posts set status = 'pending', review_state = 'pending' where id = new.post_id and status = 'approved';
  end if;
  return new;
end $$;

create or replace function public.moderate_look(pid uuid, action text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Only admins can review looks'; end if;
  if action = 'approve' then
    update public.posts set status = 'approved', review_state = 'checked', reviewed_at = now() where id = pid;
    delete from public.post_flags where post_id = pid;
  elsif action = 'hide' then
    update public.posts set status = 'rejected', review_state = 'hidden', reviewed_at = now() where id = pid;
  elsif action = 'restore' then
    update public.posts set status = 'approved', review_state = 'checked', reviewed_at = now() where id = pid;
    delete from public.post_flags where post_id = pid;
  elsif action = 'delete' then
    if (select review_state from public.posts where id = pid) <> 'hidden' then
      raise exception 'Hide this look first. Only hidden looks can be deleted.'; end if;
    update public.requests set post_id = null where post_id = pid;
    delete from public.posts where id = pid;
  else
    raise exception 'Unknown action';
  end if;
end $$;
revoke execute on function public.moderate_look(uuid, text) from public, anon;
grant execute on function public.moderate_look(uuid, text) to authenticated;

-- Keep the older Keep/Remove action consistent with the queue.
create or replace function public.moderate_post(pid uuid, approve boolean) returns void
language plpgsql security definer set search_path = public as $$
begin perform public.moderate_look(pid, case when approve then 'approve' else 'hide' end); end $$;

-- New accounts default to the logo's pink.
alter table public.profiles alter column fav_color set default '#C2185B';
