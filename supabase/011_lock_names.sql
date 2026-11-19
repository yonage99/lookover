-- Names are permanent once set. An account still on the default "New member"
-- placeholder can set its name once. A stylist's name always matches the
-- account name. Changes can still be made directly in the database.

create or replace function public.profile_lock_name() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and new.name is distinct from old.name and old.name <> 'New member' then
    raise exception 'Your name can''t be changed once it''s set.';
  end if;
  return new;
end $$;
drop trigger if exists profiles_lock_name on public.profiles;
create trigger profiles_lock_name before update on public.profiles for each row execute function public.profile_lock_name();

-- Keep stylist names in sync with the account name.
create or replace function public.stylist_before_write() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null then
    new.name := coalesce((select name from public.profiles where id = new.id), new.name);
  end if;
  if pg_trigger_depth() > 1 or public.is_admin() then return new; end if;
  if tg_op = 'INSERT' then new.verified := false; new.rating := 0; new.reviews := 0;
  else new.verified := old.verified; new.rating := old.rating; new.reviews := old.reviews; end if;
  return new;
end $$;

create or replace function public.sync_stylist_name() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.name is distinct from old.name then update public.stylists set name = new.name where id = new.id; end if;
  return new;
end $$;
drop trigger if exists profiles_sync_stylist_name on public.profiles;
create trigger profiles_sync_stylist_name after update on public.profiles for each row execute function public.sync_stylist_name();

-- Bring existing stylist names in line with account names.
update public.stylists s set name = p.name from public.profiles p where p.id = s.id and s.name <> p.name;
