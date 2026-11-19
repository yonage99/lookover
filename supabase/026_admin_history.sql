-- History of who did what: every admin decision (approved by, hidden by,
-- deleted by...) and every edit (edited by). Only admins can read it.
-- Deleted items keep a short description here so they can be traced later.

create table if not exists public.admin_log (
  id bigint generated always as identity primary key,
  actor_id uuid references public.profiles(id) on delete set null,
  actor_name text,
  action text not null,          -- approved, declined, hidden, restored, deleted, verified, revoked, edited, edit_checked, flag_dismissed
  kind text not null,            -- account, profile_photo, bio, upload, look, comment, review, verification
  target_id uuid,
  subject_id uuid,               -- whose content or account it was
  subject_name text,
  detail text,
  created_at timestamptz not null default now()
);
create index if not exists admin_log_target_idx on public.admin_log(target_id, created_at desc);
create index if not exists admin_log_created_idx on public.admin_log(created_at desc);
alter table public.admin_log enable row level security;
revoke all on public.admin_log from public, anon, authenticated;
grant select on public.admin_log to authenticated;
drop policy if exists "admin log admins read" on public.admin_log;
create policy "admin log admins read" on public.admin_log for select to authenticated using (public.is_admin());

create or replace function public.log_action(p_action text, p_kind text, p_target uuid, p_subject uuid, p_detail text)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into public.admin_log (actor_id, actor_name, action, kind, target_id, subject_id, subject_name, detail)
  values (auth.uid(), (select name from public.profiles where id = auth.uid()), p_action, p_kind, p_target,
          p_subject, (select name from public.profiles where id = p_subject), left(p_detail, 300));
end $$;
revoke execute on function public.log_action(text, text, uuid, uuid, text) from public, anon, authenticated;

-- Accounts
create or replace function public.moderate_member(uid uuid, approve boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Only admins can approve accounts'; end if;
  update public.profiles set member_status = case when approve then 'approved' else 'rejected' end where id = uid;
  perform public.log_action(case when approve then 'approved' else 'declined' end, 'account', uid, uid, null);
end $$;

-- Profile photos
create or replace function public.moderate_photo(uid uuid, approve boolean) returns void
language plpgsql security definer set search_path = public as $$
declare pr public.photo_reviews;
begin
  if not public.is_admin() then raise exception 'Only admins can approve photos'; end if;
  select * into pr from public.photo_reviews where user_id = uid;
  if pr.user_id is null then raise exception 'Nothing to review'; end if;
  if approve then
    update public.profiles set photo_url = pr.url where id = uid;
    delete from public.photo_reviews where user_id = uid;
  else
    update public.photo_reviews set status = 'rejected' where user_id = uid;
  end if;
  perform public.log_action(case when approve then 'approved' else 'declined' end, 'profile_photo', uid, uid, pr.url);
end $$;

-- Stylist bios
create or replace function public.moderate_bio(sid uuid, approve boolean) returns void
language plpgsql security definer set search_path = public as $$
declare br public.bio_reviews;
begin
  if not public.is_admin() then raise exception 'Only admins can approve bios'; end if;
  select * into br from public.bio_reviews where stylist_id = sid;
  if br.stylist_id is null then raise exception 'Nothing to review'; end if;
  if approve then
    update public.stylists set bio = br.text where id = sid;
    delete from public.bio_reviews where stylist_id = sid;
  else
    update public.bio_reviews set status = 'rejected' where stylist_id = sid;
  end if;
  perform public.log_action(case when approve then 'approved' else 'declined' end, 'bio', sid, sid, br.text);
end $$;

-- Verification
create or replace function public.review_application(app_id uuid, approve boolean) returns void
language plpgsql security definer set search_path = public as $$
declare a public.applications;
begin
  if not public.is_admin() then raise exception 'Only admins can review applications'; end if;
  update public.applications set status = case when approve then 'approved' else 'declined' end where id = app_id returning * into a;
  if approve and a.id is not null then update public.stylists set verified = true where id = a.stylist_id; end if;
  if a.id is not null then
    perform public.log_action(case when approve then 'verified' else 'declined' end, 'verification', a.stylist_id, a.stylist_id, null);
  end if;
end $$;

create or replace function public.revoke_verification(target uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Only admins can revoke verification'; end if;
  update public.stylists set verified = false where id = target;
  if not found then raise exception 'Stylist not found'; end if;
  update public.applications set status = 'revoked'
   where id = (select id from public.applications where stylist_id = target and status = 'approved' order by created_at desc limit 1);
  perform public.log_action('revoked', 'verification', target, target, null);
end $$;

-- Uploads (a request and its shared look)
create or replace function public.moderate_upload(rid uuid, action text) returns void
language plpgsql security definer set search_path = public as $$
declare r public.requests; d text;
begin
  if not public.is_admin() then raise exception 'Only admins can review uploads'; end if;
  perform set_config('lookover.logged', '1', true);  -- this action is logged once below
  select * into r from public.requests where id = rid;
  if r.id is null then raise exception 'Upload not found'; end if;
  d := coalesce((select name from public.profiles where id = r.client_id), '?') || ' → '
       || coalesce((select name from public.profiles where id = r.stylist_id), '?') || ': “' || coalesce(r.question, '') || '”';
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
  perform public.log_action(case action when 'approve' then 'approved' when 'restore' then 'restored'
                              when 'hide' then 'hidden' else 'deleted' end, 'upload', rid, r.client_id, d);
end $$;

-- Looks posted without a request (older posts)
create or replace function public.moderate_look(pid uuid, action text) returns void
language plpgsql security definer set search_path = public as $$
declare p public.posts;
begin
  if not public.is_admin() then raise exception 'Only admins can review looks'; end if;
  perform set_config('lookover.logged', '1', true);
  select * into p from public.posts where id = pid;
  if action in ('approve','restore') then
    update public.posts set status = 'approved', review_state = 'checked', reviewed_at = now() where id = pid;
    delete from public.post_flags where post_id = pid;
  elsif action = 'hide' then
    update public.posts set status = 'rejected', review_state = 'hidden', reviewed_at = now() where id = pid;
  elsif action = 'delete' then
    if p.review_state <> 'hidden' then raise exception 'Hide this look first. Only hidden looks can be deleted.'; end if;
    update public.requests set post_id = null where post_id = pid;
    delete from public.posts where id = pid;
  else
    raise exception 'Unknown action';
  end if;
  perform public.log_action(case action when 'approve' then 'approved' when 'restore' then 'restored'
                              when 'hide' then 'hidden' else 'deleted' end, 'look', pid, p.author_id, '“' || coalesce(p.caption, '') || '”');
end $$;

-- Edits checked
create or replace function public.mark_comment_reviewed(cid uuid) returns void
language plpgsql security definer set search_path = public as $$
declare c public.comments;
begin
  if not public.is_admin() then raise exception 'Only admins can review comments'; end if;
  update public.comments set edit_reviewed = true where id = cid returning * into c;
  if c.id is not null then perform public.log_action('edit_checked', 'comment', cid, c.author_id, '“' || c.text || '”'); end if;
end $$;

create or replace function public.mark_review_edit_checked(rid uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r public.requests;
begin
  if not public.is_admin() then raise exception 'Only admins can review edits'; end if;
  update public.requests set feedback_edit_reviewed = true where id = rid returning * into r;
  if r.id is not null then perform public.log_action('edit_checked', 'review', rid, r.stylist_id, '“' || coalesce(r.feedback->>'notes', '') || '”'); end if;
end $$;

-- Edits by members (comments and stylist reviews)
create or replace function public.log_comment_edit() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.text is distinct from old.text and auth.uid() is not null then
    perform public.log_action('edited', 'comment', new.id, new.author_id, '“' || old.text || '” → “' || new.text || '”');
  end if;
  return new;
end $$;
drop trigger if exists comments_log_edit on public.comments;
create trigger comments_log_edit after update on public.comments for each row execute function public.log_comment_edit();

create or replace function public.log_review_edit() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.feedback_edited_at is distinct from old.feedback_edited_at and new.feedback_edited_at is not null then
    perform public.log_action('edited', 'review', new.id, new.stylist_id,
      '“' || coalesce(old.feedback->>'notes', '') || '” → “' || coalesce(new.feedback->>'notes', '') || '”');
  end if;
  return new;
end $$;
drop trigger if exists requests_log_review_edit on public.requests;
create trigger requests_log_review_edit after update on public.requests for each row execute function public.log_review_edit();

-- Deletes done directly by admins (comments, flags)
create or replace function public.log_admin_delete() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or not public.is_admin() or pg_trigger_depth() > 1
     or coalesce(current_setting('lookover.logged', true), '') = '1' then return old; end if;
  if tg_table_name = 'comments' then
    perform public.log_action('deleted', 'comment', old.id, old.author_id, '“' || old.text || '”');
  elsif tg_table_name = 'posts' and old.author_id <> auth.uid() then
    perform public.log_action('deleted', 'look', old.id, old.author_id, '“' || coalesce(old.caption, '') || '”');
  elsif tg_table_name = 'comment_flags' then
    perform public.log_action('flag_dismissed', 'comment', old.comment_id, (select author_id from public.comments where id = old.comment_id), old.reason);
  elsif tg_table_name = 'post_flags' then
    perform public.log_action('flag_dismissed', 'look', old.post_id, (select author_id from public.posts where id = old.post_id), old.reason);
  end if;
  return old;
end $$;
drop trigger if exists comments_log_delete on public.comments;
create trigger comments_log_delete after delete on public.comments for each row execute function public.log_admin_delete();
drop trigger if exists posts_log_delete on public.posts;
create trigger posts_log_delete after delete on public.posts for each row execute function public.log_admin_delete();
drop trigger if exists comment_flags_log_delete on public.comment_flags;
create trigger comment_flags_log_delete after delete on public.comment_flags for each row execute function public.log_admin_delete();
drop trigger if exists post_flags_log_delete on public.post_flags;
create trigger post_flags_log_delete after delete on public.post_flags for each row execute function public.log_admin_delete();
