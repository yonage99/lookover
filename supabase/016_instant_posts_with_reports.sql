-- Shared looks go live immediately. Protection comes from caption checks,
-- automatic flags, member reports, auto-hiding after 3 reports, and a daily limit.

-- Anything waiting today goes live.
update public.posts set status = 'approved' where status = 'pending';
alter table public.posts alter column status set default 'approved';

create table if not exists public.post_flags (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.posts(id) on delete cascade,
  reporter_id uuid references public.profiles(id) on delete set null,
  reason text not null check (reason in ('not_a_look','contact','inappropriate','spam','other','auto')),
  detail text not null default '' check (char_length(detail) <= 300),
  created_at timestamptz not null default now()
);
create unique index if not exists post_flags_once on public.post_flags(post_id, reporter_id) where reporter_id is not null;
alter table public.post_flags enable row level security;
drop policy if exists "post flags report" on public.post_flags;
create policy "post flags report" on public.post_flags for insert to authenticated
  with check (reporter_id = auth.uid() and reason <> 'auto' and public.is_approved(auth.uid())
              and exists (select 1 from public.posts p where p.id = post_id and p.author_id <> auth.uid()));
drop policy if exists "post flags read" on public.post_flags;
create policy "post flags read" on public.post_flags for select to authenticated using (public.is_admin() or reporter_id = auth.uid());
drop policy if exists "post flags dismiss" on public.post_flags;
create policy "post flags dismiss" on public.post_flags for delete to authenticated using (public.is_admin());
grant select, delete on public.post_flags to authenticated;
grant insert (post_id, reporter_id, reason, detail) on public.post_flags to authenticated;

create or replace function public.post_before_insert() returns trigger
language plpgsql security definer set search_path = public as $$
declare r public.requests;
begin
  select * into r from public.requests where id = new.request_id;
  if r.id is null or r.client_id <> new.author_id then
    raise exception 'Send your look to a stylist first. You can share it once it has been reviewed.'; end if;
  if r.status <> 'done' then raise exception 'You can share this look once your stylist has reviewed it.'; end if;
  if (select count(*) from public.posts where author_id = new.author_id and created_at > now() - interval '24 hours') >= 10 then
    raise exception 'You can share up to 10 looks a day. Try again tomorrow.'; end if;
  new.kind := r.kind; new.photo_url := r.photo_url; new.aesthetic := coalesce(nullif(new.aesthetic, ''), r.aesthetic);
  new.caption := coalesce(nullif(new.caption, ''), r.question);
  if public.has_contact_info(new.caption) or public.has_contact_info(new.aesthetic) then
    raise exception 'Captions can’t include contact details, links or handles.'; end if;
  new.stylist_id := r.stylist_id; new.stylist_score := nullif(r.feedback->>'score', '')::int; new.created_at := now();
  new.status := 'approved';
  return new;
end $$;

create or replace function public.flag_suspicious_post() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.looks_like_evasion(new.caption) or public.looks_like_evasion(new.aesthetic) then
    insert into public.post_flags (post_id, reporter_id, reason, detail)
    values (new.id, null, 'auto', 'Caption may be trying to share contact details or advertise');
  end if;
  return new;
end $$;
drop trigger if exists posts_auto_flag on public.posts;
create trigger posts_auto_flag after insert on public.posts for each row execute function public.flag_suspicious_post();

-- Three different people reporting a look hides it until an admin decides.
create or replace function public.hide_after_reports() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (select count(distinct reporter_id) from public.post_flags where post_id = new.post_id and reporter_id is not null) >= 3 then
    update public.posts set status = 'pending' where id = new.post_id and status = 'approved';
  end if;
  return new;
end $$;
drop trigger if exists post_flags_hide on public.post_flags;
create trigger post_flags_hide after insert on public.post_flags for each row execute function public.hide_after_reports();

-- Keep = clear the reports and show the look; Remove = take it down.
create or replace function public.moderate_post(pid uuid, approve boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Only admins can moderate looks'; end if;
  update public.posts set status = case when approve then 'approved' else 'rejected' end where id = pid;
  if approve then delete from public.post_flags where post_id = pid; end if;
end $$;
