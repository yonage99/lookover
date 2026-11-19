-- Ghost accounts: private test accounts. A ghost can use every feature, but its
-- activity is visible only to ghost accounts and never affects real users:
-- not in the feed, roster, search or people list for others; its ratings are left
-- out of medians and stylist scores; its comments are invisible to real posters;
-- real stylists never see its requests, and real clients cannot send to a ghost.
-- Ghost status is set only directly in the database (no app control).

alter table public.profiles add column if not exists is_ghost boolean not null default false;

create or replace function public.is_ghost(uid uuid) returns boolean
language sql stable security definer set search_path = public as
$$ select coalesce((select is_ghost from public.profiles where id = uid), false) $$;
create or replace function public.viewer_is_ghost() returns boolean
language sql stable security definer set search_path = public as
$$ select public.is_ghost(auth.uid()) $$;
-- visible(x): real content is visible as before; ghost content only to ghosts.
create or replace function public.visible_to_viewer(owner uuid) returns boolean
language sql stable security definer set search_path = public as
$$ select owner = auth.uid() or not public.is_ghost(owner) or public.viewer_is_ghost() $$;
grant execute on function public.is_ghost(uuid), public.viewer_is_ghost(), public.visible_to_viewer(uuid) to anon, authenticated;

drop policy if exists "profiles readable" on public.profiles;
create policy "profiles readable" on public.profiles for select using (public.visible_to_viewer(id));

drop policy if exists "stylists readable" on public.stylists;
create policy "stylists readable" on public.stylists for select using (public.visible_to_viewer(id));

drop policy if exists "posts readable" on public.posts;
create policy "posts readable" on public.posts for select using (public.visible_to_viewer(author_id));

drop policy if exists "comments private" on public.comments;
create policy "comments private" on public.comments for select to authenticated
  using ((author_id = auth.uid()
          or exists (select 1 from public.posts p where p.id = post_id and p.author_id = auth.uid()))
         and public.visible_to_viewer(author_id));

drop policy if exists "requests parties read" on public.requests;
create policy "requests parties read" on public.requests for select to authenticated
  using ((client_id = auth.uid() or stylist_id = auth.uid())
         and public.visible_to_viewer(client_id) and public.visible_to_viewer(stylist_id));

drop policy if exists "memberships parties read" on public.memberships;
create policy "memberships parties read" on public.memberships for select to authenticated
  using ((client_id = auth.uid() or stylist_id = auth.uid() or public.is_admin())
         and public.visible_to_viewer(client_id) and public.visible_to_viewer(stylist_id));

drop policy if exists "free list read" on public.free_clients;
create policy "free list read" on public.free_clients for select to authenticated
  using ((stylist_id = auth.uid() or client_id = auth.uid())
         and public.visible_to_viewer(client_id) and public.visible_to_viewer(stylist_id));

drop policy if exists "applications own or admin read" on public.applications;
create policy "applications own or admin read" on public.applications for select to authenticated
  using ((stylist_id = auth.uid() or public.is_admin()) and public.visible_to_viewer(stylist_id));

-- Median score ignores ghost ratings.
create or replace function public.post_scores(ids uuid[])
returns table (post_id uuid, median numeric, ratings int)
language sql stable security definer set search_path = public as $$
  select r.post_id, round((percentile_cont(0.5) within group (order by r.score))::numeric, 1), count(*)::int
  from public.ratings r
  where r.post_id = any (ids) and not public.is_ghost(r.user_id)
  group by r.post_id
$$;

-- Stylist scores ignore ghost clients.
create or replace function public.refresh_stylist_rating() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.client_stars is distinct from old.client_stars then
    update public.stylists s set
      rating = coalesce((select round(avg(client_stars)::numeric, 2) from public.requests
                          where stylist_id = s.id and client_stars is not null and public.rating_counts(price_reason)
                            and not public.is_ghost(client_id)), 0),
      reviews = (select count(*) from public.requests
                  where stylist_id = s.id and client_stars is not null and public.rating_counts(price_reason)
                    and not public.is_ghost(client_id))
    where s.id = new.stylist_id;
  end if;
  return new;
end $$;

-- Real clients cannot send requests to a ghost stylist.
create or replace function public.block_requests_to_ghosts() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.is_ghost(new.stylist_id) and not public.is_ghost(new.client_id) then
    raise exception 'Stylist not found'; end if;
  return new;
end $$;
drop trigger if exists requests_ghost_guard on public.requests;
create trigger requests_ghost_guard before insert on public.requests for each row execute function public.block_requests_to_ghosts();
