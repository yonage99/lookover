-- Authors can edit their comments. Edits go live right away, are marked as
-- edited, and wait in the admin Comments tab until an admin marks them reviewed.

alter table public.comments
  add column if not exists edited_at timestamptz,
  add column if not exists previous_text text,
  add column if not exists edit_reviewed boolean not null default true;

drop policy if exists "comments own edit" on public.comments;
create policy "comments own edit" on public.comments for update to authenticated
  using (author_id = auth.uid()) with check (author_id = auth.uid());
grant update (text) on public.comments to authenticated;

create or replace function public.comment_before_update() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.is_admin() and new.text = old.text then return new; end if;  -- admin marking reviewed
  if new.text is distinct from old.text then
    if public.has_contact_info(new.text) then
      raise exception 'Comments can’t include contact details, links or handles.'; end if;
    new.previous_text := old.text; new.edited_at := now(); new.edit_reviewed := false;
  end if;
  new.post_id := old.post_id; new.author_id := old.author_id; new.is_pro := old.is_pro; new.created_at := old.created_at;
  return new;
end $$;
drop trigger if exists comments_bu on public.comments;
create trigger comments_bu before update on public.comments for each row execute function public.comment_before_update();

-- Edits that look like dodging the filter get flagged too.
create or replace function public.flag_suspicious_comment_edit() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.text is distinct from old.text and public.looks_like_evasion(new.text) then
    insert into public.comment_flags (comment_id, reporter_id, reason, detail)
    values (new.id, null, 'auto', 'Edited comment may be sharing contact details or moving off Lookover');
  end if;
  return new;
end $$;
drop trigger if exists comments_auto_flag_edit on public.comments;
create trigger comments_auto_flag_edit after update on public.comments for each row execute function public.flag_suspicious_comment_edit();

create or replace function public.mark_comment_reviewed(cid uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Only admins can review comments'; end if;
  update public.comments set edit_reviewed = true where id = cid;
end $$;
revoke execute on function public.mark_comment_reviewed(uuid) from public, anon;
grant execute on function public.mark_comment_reviewed(uuid) to authenticated;
