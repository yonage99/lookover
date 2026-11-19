-- Demo accounts: ghost accounts that admins can see and use. Their activity
-- never counts toward real scores or medians. The name "Demo" is reserved.

alter table public.profiles add column if not exists is_demo boolean not null default false;

create or replace function public.is_demo(uid uuid) returns boolean
language sql stable security definer set search_path = public as
$$ select coalesce((select is_demo from public.profiles where id = uid), false) $$;
grant execute on function public.is_demo(uuid) to anon, authenticated;

-- Ghost content stays visible only to ghosts, except demo accounts, which admins can also see.
create or replace function public.visible_to_viewer(owner uuid) returns boolean
language sql stable security definer set search_path = public as
$$ select owner = auth.uid() or not public.is_ghost(owner) or public.viewer_is_ghost()
          or (public.is_demo(owner) and public.is_admin()) $$;

-- Real clients still can't reach ghost stylists, but admins can send to the Demo stylist.
create or replace function public.block_requests_to_ghosts() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.is_ghost(new.stylist_id) and not public.is_ghost(new.client_id)
     and not (public.is_demo(new.stylist_id) and public.is_admin()) then
    raise exception 'Stylist not found'; end if;
  return new;
end $$;

-- Reserve names starting with "Demo" for demo accounts.
create or replace function public.reserve_demo_name() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.name ~* '^\s*demo' and not new.is_demo then
    raise exception 'That name is reserved. Please choose another name.'; end if;
  return new;
end $$;
drop trigger if exists profiles_reserve_demo on public.profiles;
create trigger profiles_reserve_demo before insert or update of name on public.profiles for each row execute function public.reserve_demo_name();
