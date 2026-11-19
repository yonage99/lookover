-- Comment moderation: admins can read and delete any comment; people can report
-- comments; comments that look like an attempt to get around the contact filter
-- are flagged for admins automatically.

drop policy if exists "comments private" on public.comments;
create policy "comments private" on public.comments for select to authenticated
  using (((author_id = auth.uid()
           or exists (select 1 from public.posts p where p.id = post_id and p.author_id = auth.uid()))
          or public.is_admin())
         and public.visible_to_viewer(author_id));
-- (Deleting: "comments own delete" already allows the author or any admin.)

create table if not exists public.comment_flags (
  id uuid primary key default gen_random_uuid(),
  comment_id uuid not null references public.comments(id) on delete cascade,
  reporter_id uuid references public.profiles(id) on delete set null,
  reason text not null check (reason in ('contact','harassment','spam','other','auto')),
  detail text not null default '' check (char_length(detail) <= 300),
  created_at timestamptz not null default now()
);
create unique index if not exists comment_flags_once on public.comment_flags(comment_id, reporter_id) where reporter_id is not null;
alter table public.comment_flags enable row level security;

drop policy if exists "flags report" on public.comment_flags;
create policy "flags report" on public.comment_flags for insert to authenticated
  with check (reporter_id = auth.uid() and reason <> 'auto'
              and exists (select 1 from public.comments c where c.id = comment_id and c.author_id <> auth.uid()));
drop policy if exists "flags admin read" on public.comment_flags;
create policy "flags admin read" on public.comment_flags for select to authenticated
  using (public.is_admin() or reporter_id = auth.uid());
drop policy if exists "flags admin dismiss" on public.comment_flags;
create policy "flags admin dismiss" on public.comment_flags for delete to authenticated using (public.is_admin());
grant select, delete on public.comment_flags to authenticated;
grant insert (comment_id, reporter_id, reason, detail) on public.comment_flags to authenticated;

-- Looks like someone is trying to move a conversation off Lookover without
-- triggering the hard block (which already rejects clear contact details).
create or replace function public.looks_like_evasion(t text) returns boolean
language sql immutable as $$
  select t is not null and (
       t ~* '\m(the gram|my gram|on gram|my handle|my page|my profile on|my socials|socials|link in (my )?bio|in my bio|my number|my digits|my cell|my email|g ?mail|hotmail|yahoo|outlook|dot com|add me|follow me|look me up|search me|off (the )?app|outside (the )?app|off lookover|outside lookover|direct(ly)? (message|book)|book (with )?me directly|pay me directly|private message|pm me)\M'
    or (select count(*) from regexp_matches(lower(t), '\m(zero|one|two|three|four|five|six|seven|eight|nine|oh)\M', 'g')) >= 5
    or t ~* '[0-9][^0-9a-z]{1,3}[0-9][^0-9a-z]{1,3}[0-9][^0-9a-z]{1,3}[0-9]'
  )
$$;

create or replace function public.flag_suspicious_comment() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.looks_like_evasion(new.text) then
    insert into public.comment_flags (comment_id, reporter_id, reason, detail)
    values (new.id, null, 'auto', 'Possible attempt to share contact details or move off Lookover');
  end if;
  return new;
end $$;
drop trigger if exists comments_auto_flag on public.comments;
create trigger comments_auto_flag after insert on public.comments for each row execute function public.flag_suspicious_comment();
