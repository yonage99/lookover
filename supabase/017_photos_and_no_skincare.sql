-- Up to 3 photos per request (and on the shared post), and skincare paused.

alter table public.requests add column if not exists photo_urls text[] not null default '{}'
  check (cardinality(photo_urls) <= 3);
alter table public.posts add column if not exists photo_urls text[] not null default '{}';
update public.requests set photo_urls = array[photo_url] where photo_url is not null and cardinality(photo_urls) = 0;
update public.posts set photo_urls = array[photo_url] where photo_url is not null and cardinality(photo_urls) = 0;
grant insert (photo_urls) on public.requests to authenticated;

-- Photos must be Lookover uploads from the sender's own folder.
create or replace function public.request_photos_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare u text;
begin
  if cardinality(new.photo_urls) = 0 and new.photo_url is not null then new.photo_urls := array[new.photo_url]; end if;
  foreach u in array new.photo_urls loop
    if u !~ ('^https://[a-z0-9]+\.supabase\.co/storage/v1/object/public/photos/' || new.client_id::text || '/') then
      raise exception 'Photos must be uploaded through Lookover.'; end if;
  end loop;
  new.photo_url := new.photo_urls[1];
  if new.kind = 'skin' then raise exception 'Skincare reviews aren’t available right now.'; end if;
  return new;
end $$;
drop trigger if exists requests_photos_guard on public.requests;
create trigger requests_photos_guard before insert on public.requests for each row execute function public.request_photos_guard();

-- Shared posts carry all the request's photos.
create or replace function public.post_copy_photos() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.photo_urls := coalesce((select photo_urls from public.requests where id = new.request_id), '{}');
  new.photo_url := new.photo_urls[1];
  return new;
end $$;
drop trigger if exists posts_copy_photos on public.posts;
create trigger posts_copy_photos before insert on public.posts for each row execute function public.post_copy_photos();

-- Skincare paused: remove it from stylists' services.
update public.stylists set services = array_remove(services, 'skin') where 'skin' = any(services);
update public.stylists set services = array['outfit'] where cardinality(services) = 0;
create or replace function public.stylist_no_skin() returns trigger
language plpgsql as $$ begin new.services := array_remove(new.services, 'skin'); return new; end $$;
drop trigger if exists stylists_no_skin on public.stylists;
create trigger stylists_no_skin before insert or update on public.stylists for each row execute function public.stylist_no_skin();
