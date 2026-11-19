-- Account gender (man or woman). Clients are matched only with stylists of
-- the same gender. People set it once; after that only an admin can change it.
alter table public.profiles add column if not exists gender text check (gender in ('man','woman'));
grant select (gender) on public.profiles to anon, authenticated;
grant update (gender) on public.profiles to authenticated;

create or replace function public.profile_lock_gender() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.gender is distinct from old.gender and old.gender is not null
     and auth.uid() is not null and not public.is_admin() then
    raise exception 'Your account type is set. Contact the Lookover team to change it.';
  end if;
  return new;
end $$;
drop trigger if exists profiles_lock_gender on public.profiles;
create trigger profiles_lock_gender before update on public.profiles for each row execute function public.profile_lock_gender();

create or replace function public.set_gender(uid uuid, g text) returns void
language plpgsql security definer set search_path = public as $$
declare old_g text;
begin
  if not public.is_admin() then raise exception 'Only admins can change this'; end if;
  if g not in ('man','woman') then raise exception 'Choose man or woman'; end if;
  select gender into old_g from public.profiles where id = uid;
  update public.profiles set gender = g where id = uid;
  perform public.log_action('edited', 'account', uid, uid, 'Account type: ' || coalesce(old_g, 'not set') || ' → ' || g);
end $$;
revoke execute on function public.set_gender(uuid, text) from public, anon;
grant execute on function public.set_gender(uuid, text) to authenticated;

-- Same-gender matching for every new request. Ghost and demo test accounts are exempt.
create or replace function public.request_gender_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare cg text; sg text;
begin
  if public.is_ghost(new.client_id) or public.is_ghost(new.stylist_id) then return new; end if;
  select gender into cg from public.profiles where id = new.client_id;
  select gender into sg from public.profiles where id = new.stylist_id;
  if cg is null then raise exception 'Choose man or woman on your profile before sending a look.'; end if;
  if sg is null or sg <> cg then raise exception 'This stylist only works with % clients.', case sg when 'man' then 'male' else 'female' end; end if;
  return new;
end $$;
drop trigger if exists requests_gender_guard on public.requests;
create trigger requests_gender_guard before insert on public.requests for each row execute function public.request_gender_guard();

-- Memberships follow the same rule.
create or replace function public.membership_gender_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.is_ghost(new.client_id) or public.is_ghost(new.stylist_id) then return new; end if;
  if (select gender from public.profiles where id = new.client_id) is distinct from (select gender from public.profiles where id = new.stylist_id)
     or (select gender from public.profiles where id = new.client_id) is null then
    raise exception 'Memberships are only with stylists who work with your account type.'; end if;
  return new;
end $$;
drop trigger if exists memberships_gender_guard on public.memberships;
create trigger memberships_gender_guard before insert on public.memberships for each row execute function public.membership_gender_guard();

-- Inspiration photos can be for men, women or everyone.
alter table public.inspirations add column if not exists audience text not null default 'all' check (audience in ('all','man','woman'));
grant insert (audience), update (audience) on public.inspirations to authenticated;
