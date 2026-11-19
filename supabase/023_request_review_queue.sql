-- Admins can see every request (private ones too) and review them:
-- pending -> checked, or hidden (removed from the stylist's feed and the
-- community). Only hidden requests can be deleted.

alter table public.requests add column if not exists admin_state text not null default 'pending'
  check (admin_state in ('pending','checked','hidden'));
create index if not exists requests_admin_state_idx on public.requests(admin_state, created_at desc);

-- Admins can read all requests; stylists stop seeing hidden ones.
drop policy if exists "requests parties read" on public.requests;
create policy "requests parties read" on public.requests for select to authenticated
  using (((client_id = auth.uid())
          or (stylist_id = auth.uid() and admin_state <> 'hidden')
          or public.is_admin())
         and public.visible_to_viewer(client_id) and public.visible_to_viewer(stylist_id));

-- New requests always start unchecked (runs after the main insert rules).
create or replace function public.request_admin_default() returns trigger
language plpgsql as $$ begin new.admin_state := 'pending'; return new; end $$;
drop trigger if exists requests_zz_admin_default on public.requests;
create trigger requests_zz_admin_default before insert on public.requests for each row execute function public.request_admin_default();

-- Users can't change admin_state themselves (it is not in their update grant).

create or replace function public.moderate_request(rid uuid, action text) returns void
language plpgsql security definer set search_path = public as $$
declare r public.requests;
begin
  if not public.is_admin() then raise exception 'Only admins can review requests'; end if;
  select * into r from public.requests where id = rid;
  if r.id is null then raise exception 'Request not found'; end if;
  if action = 'approve' then
    update public.requests set admin_state = 'checked' where id = rid;
  elsif action = 'hide' then
    update public.requests set admin_state = 'hidden' where id = rid;
    update public.posts set status = 'rejected', review_state = 'hidden', reviewed_at = now() where request_id = rid;
  elsif action = 'restore' then
    update public.requests set admin_state = 'checked' where id = rid;
  elsif action = 'delete' then
    if r.admin_state <> 'hidden' then raise exception 'Hide this request first. Only hidden requests can be deleted.'; end if;
    delete from public.posts where request_id = rid;
    delete from public.requests where id = rid;
  else
    raise exception 'Unknown action';
  end if;
end $$;
revoke execute on function public.moderate_request(uuid, text) from public, anon;
grant execute on function public.moderate_request(uuid, text) to authenticated;
