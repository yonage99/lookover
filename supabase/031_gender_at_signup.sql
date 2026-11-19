-- Gender is chosen at sign-up. It can be changed until an admin approves the
-- account; after approval only an admin can change it.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, name, gender)
  values (new.id, coalesce(nullif(left(trim(new.raw_user_meta_data->>'name'), 40), ''), 'New member'),
          case when new.raw_user_meta_data->>'gender' in ('man','woman') then new.raw_user_meta_data->>'gender' end)
  on conflict (id) do nothing;
  return new;
end $$;

create or replace function public.profile_lock_gender() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.gender is distinct from old.gender and old.gender is not null and old.member_status = 'approved'
     and auth.uid() is not null and not public.is_admin() then
    raise exception 'Your account type was approved and can’t be changed. Contact the Lookover team if it’s wrong.';
  end if;
  return new;
end $$;

-- Approving an account confirms its type: it needs one first.
create or replace function public.moderate_member(uid uuid, approve boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Only admins can approve accounts'; end if;
  if approve and (select gender from public.profiles where id = uid) is null then
    raise exception 'This account hasn’t chosen man or woman yet. Set it on their profile first.'; end if;
  update public.profiles set member_status = case when approve then 'approved' else 'rejected' end where id = uid;
  perform public.log_action(case when approve then 'approved' else 'declined' end, 'account', uid, uid,
    'As ' || coalesce((select gender from public.profiles where id = uid), 'not set'));
end $$;
