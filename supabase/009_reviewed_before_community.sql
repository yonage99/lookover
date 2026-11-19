-- A look can only be posted to the community after a stylist has reviewed it.
-- The client can choose to share it automatically when the review comes back,
-- or share it later. Each request can be posted once. The post shows the
-- stylist's score and who reviewed it.

alter table public.posts
  add column if not exists stylist_id uuid references public.stylists(id) on delete set null,
  add column if not exists stylist_score int;
create unique index if not exists posts_one_per_request on public.posts(request_id) where request_id is not null;

alter table public.requests add column if not exists share_when_done boolean not null default false;
grant insert (share_when_done) on public.requests to authenticated;
grant update (share_when_done) on public.requests to authenticated;

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
  new.stylist_id := r.stylist_id; new.stylist_score := nullif(r.feedback->>'score', '')::int; new.created_at := now();
  return new;
end $$;
drop trigger if exists posts_bi on public.posts;
create trigger posts_bi before insert on public.posts for each row execute function public.post_before_insert();

-- Let internal triggers set post_id; keep the per-role rules for direct updates.
create or replace function public.request_before_update() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or pg_trigger_depth() > 1 then return new; end if;
  if auth.uid() = old.stylist_id and auth.uid() <> old.client_id then
    new.client_stars := old.client_stars; new.post_id := old.post_id; new.share_when_done := old.share_when_done;
    if new.feedback is not null then new.status := 'done'; end if;
  elsif auth.uid() = old.client_id then
    new.feedback := old.feedback; new.status := old.status;
    if old.status <> 'done' then new.client_stars := old.client_stars; end if;
    if old.client_stars is not null then new.client_stars := old.client_stars; end if;
  end if;
  return new;
end $$;

-- When a review comes back and the client asked to share it, post it.
create or replace function public.share_when_reviewed() returns trigger
language plpgsql security definer set search_path = public as $$
declare pid uuid;
begin
  if new.status = 'done' and old.status <> 'done' and new.share_when_done and new.post_id is null then
    insert into public.posts (author_id, kind, caption, aesthetic, request_id)
    values (new.client_id, new.kind, new.question, new.aesthetic, new.id) returning id into pid;
    update public.requests set post_id = pid where id = new.id;
  end if;
  return new;
end $$;
drop trigger if exists requests_share on public.requests;
create trigger requests_share after update on public.requests for each row execute function public.share_when_reviewed();
