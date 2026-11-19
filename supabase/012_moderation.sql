-- Moderation: admin approval for community looks, profile photos and stylist bios,
-- plus an automatic block on contact details (emails, phones, links, handles,
-- off-platform apps) in bios, taglines, captions and comments.

create or replace function public.has_contact_info(t text) returns boolean
language sql immutable as $$
  select t is not null and (
       t ~* '[a-z0-9._%+-]+\s*(@|\(at\)|\[at\])\s*[a-z0-9.-]+\s*(\.|\(dot\)|\[dot\]|dot)\s*[a-z]{2,}'   -- email
    or t ~ '\+?[0-9]([ ().-]*[0-9]){6,}'                                                            -- phone-like
    or t ~* '(https?://|www\.)'                                                                       -- links
    or t ~* '\m[a-z0-9-]+\.(com|net|org|io|co|me|app|shop|store|link|ly|gg|info|biz)\M'              -- domains
    or t ~* '(^|\s)@[a-z0-9._]{2,}'                                                                   -- @handles
    or t ~* '\m(instagram|insta|ig|tiktok|snapchat|snap|whatsapp|whats app|telegram|signal|facebook|fb|venmo|cash ?app|cashapp|paypal|zelle|linktree|onlyfans|discord)\M'
    or t ~* '\m(dm me|text me|call me|email me|e-mail me|message me|contact me|reach me|hit me up|find me on)\M'
  )
$$;
grant execute on function public.has_contact_info(text) to anon, authenticated;

-- ---------- Stylist bios ----------
alter table public.stylists add column if not exists bio text not null default '';
create table if not exists public.bio_reviews (
  stylist_id uuid primary key references public.stylists(id) on delete cascade,
  text text not null check (char_length(text) between 1 and 400),
  status text not null default 'pending' check (status in ('pending','rejected')),
  created_at timestamptz not null default now()
);
alter table public.bio_reviews enable row level security;
drop policy if exists "bio own or admin read" on public.bio_reviews;
create policy "bio own or admin read" on public.bio_reviews for select to authenticated using (stylist_id = auth.uid() or public.is_admin());
drop policy if exists "bio own write" on public.bio_reviews;
create policy "bio own write" on public.bio_reviews for insert to authenticated with check (stylist_id = auth.uid());
drop policy if exists "bio own update" on public.bio_reviews;
create policy "bio own update" on public.bio_reviews for update to authenticated using (stylist_id = auth.uid()) with check (stylist_id = auth.uid());
drop policy if exists "bio own delete" on public.bio_reviews;
create policy "bio own delete" on public.bio_reviews for delete to authenticated using (stylist_id = auth.uid());
grant select, delete on public.bio_reviews to authenticated;
grant insert (stylist_id, text), update (text) on public.bio_reviews to authenticated;

create or replace function public.bio_review_before_write() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.text := trim(new.text);
  if public.has_contact_info(new.text) then
    raise exception 'Bios can’t include contact details, links, handles or other apps. Keep it about your style and experience.'; end if;
  if tg_op = 'INSERT' or new.text is distinct from old.text then new.status := 'pending'; new.created_at := now(); end if;
  return new;
end $$;
drop trigger if exists bio_reviews_bw on public.bio_reviews;
create trigger bio_reviews_bw before insert or update on public.bio_reviews for each row execute function public.bio_review_before_write();

-- ---------- Profile photos ----------
create table if not exists public.photo_reviews (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  url text not null,
  status text not null default 'pending' check (status in ('pending','rejected')),
  created_at timestamptz not null default now()
);
alter table public.photo_reviews enable row level security;
drop policy if exists "photo own or admin read" on public.photo_reviews;
create policy "photo own or admin read" on public.photo_reviews for select to authenticated using (user_id = auth.uid() or public.is_admin());
drop policy if exists "photo own write" on public.photo_reviews;
create policy "photo own write" on public.photo_reviews for insert to authenticated with check (user_id = auth.uid());
drop policy if exists "photo own update" on public.photo_reviews;
create policy "photo own update" on public.photo_reviews for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
grant select on public.photo_reviews to authenticated;
grant insert (user_id, url), update (url) on public.photo_reviews to authenticated;

create or replace function public.photo_review_before_write() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.url !~ ('^https://[a-z0-9]+\.supabase\.co/storage/v1/object/public/photos/' || new.user_id::text || '/') then
    raise exception 'Upload your photo through Lookover.'; end if;
  if tg_op = 'INSERT' or new.url is distinct from old.url then new.status := 'pending'; new.created_at := now(); end if;
  return new;
end $$;
drop trigger if exists photo_reviews_bw on public.photo_reviews;
create trigger photo_reviews_bw before insert or update on public.photo_reviews for each row execute function public.photo_review_before_write();

-- Users can no longer set their public photo directly.
revoke update (photo_url) on public.profiles from authenticated;

-- ---------- Community looks ----------
alter table public.posts add column if not exists status text not null default 'approved' check (status in ('pending','approved','rejected'));
alter table public.posts alter column status set default 'pending';

create or replace function public.post_before_insert() returns trigger
language plpgsql security definer set search_path = public as $$
declare r public.requests;
begin
  select * into r from public.requests where id = new.request_id;
  if r.id is null or r.client_id <> new.author_id then
    raise exception 'Send your look to a stylist first. You can share it once it has been reviewed.'; end if;
  if r.status <> 'done' then raise exception 'You can share this look once your stylist has reviewed it.'; end if;
  new.kind := r.kind; new.photo_url := r.photo_url; new.aesthetic := coalesce(nullif(new.aesthetic, ''), r.aesthetic);
  new.caption := coalesce(nullif(new.caption, ''), r.question);
  if public.has_contact_info(new.caption) or public.has_contact_info(new.aesthetic) then
    raise exception 'Captions can’t include contact details, links or handles.'; end if;
  new.stylist_id := r.stylist_id; new.stylist_score := nullif(r.feedback->>'score', '')::int; new.created_at := now();
  new.status := 'pending';
  return new;
end $$;

drop policy if exists "posts readable" on public.posts;
create policy "posts readable" on public.posts for select
  using ((status = 'approved' or author_id = auth.uid() or public.is_admin()) and public.visible_to_viewer(author_id));

-- ---------- Contact info in taglines and comments ----------
create or replace function public.stylist_before_write() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null then
    new.name := coalesce((select name from public.profiles where id = new.id), new.name);
    if public.has_contact_info(new.line) then
      raise exception 'Your tagline can’t include contact details, links, handles or other apps.'; end if;
  end if;
  if pg_trigger_depth() > 1 or public.is_admin() then return new; end if;
  if tg_op = 'INSERT' then new.verified := false; new.rating := 0; new.reviews := 0; new.bio := '';
  else new.verified := old.verified; new.rating := old.rating; new.reviews := old.reviews; new.bio := old.bio; end if;
  return new;
end $$;

create or replace function public.comment_before_insert() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.has_contact_info(new.text) then
    raise exception 'Comments can’t include contact details, links or handles.'; end if;
  new.is_pro := exists (select 1 from public.stylists where id = new.author_id);
  new.created_at := now();
  return new;
end $$;

-- ---------- Admin decisions ----------
create or replace function public.moderate_post(pid uuid, approve boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Only admins can approve looks'; end if;
  update public.posts set status = case when approve then 'approved' else 'rejected' end where id = pid;
end $$;

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
end $$;

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
end $$;

revoke execute on function public.moderate_post(uuid, boolean), public.moderate_photo(uuid, boolean), public.moderate_bio(uuid, boolean) from public, anon;
grant execute on function public.moderate_post(uuid, boolean), public.moderate_photo(uuid, boolean), public.moderate_bio(uuid, boolean) to authenticated;
