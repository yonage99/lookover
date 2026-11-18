-- Admins can revoke a stylist's verification. The stylist goes back to free reviews and may re-apply.
alter table public.applications drop constraint if exists applications_status_check;
alter table public.applications add constraint applications_status_check check (status in ('pending','approved','declined','revoked'));

create or replace function public.revoke_verification(target uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Only admins can revoke verification'; end if;
  update public.stylists set verified = false where id = target;
  if not found then raise exception 'Stylist not found'; end if;
  update public.applications set status = 'revoked'
   where id = (select id from public.applications where stylist_id = target and status = 'approved' order by created_at desc limit 1);
end $$;
revoke execute on function public.revoke_verification(uuid) from public, anon;
grant execute on function public.revoke_verification(uuid) to authenticated;
