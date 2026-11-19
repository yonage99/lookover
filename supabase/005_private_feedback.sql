-- Keep community feedback unbiased.
-- Comments: only the post's author, the commenter, and admins can read them.
-- Ratings: each person can read only their own rating. Everyone sees just the
-- median score and the number of ratings, through post_scores().

drop policy if exists "comments readable" on public.comments;
drop policy if exists "comments private" on public.comments;
create policy "comments private" on public.comments for select to authenticated
  using (author_id = auth.uid()
         or exists (select 1 from public.posts p where p.id = post_id and p.author_id = auth.uid())
         or public.is_admin());
revoke select on public.comments from anon;

drop policy if exists "ratings readable" on public.ratings;
drop policy if exists "ratings own read" on public.ratings;
create policy "ratings own read" on public.ratings for select to authenticated
  using (user_id = auth.uid());
revoke select on public.ratings from anon;

create or replace function public.post_scores(ids uuid[])
returns table (post_id uuid, median numeric, ratings int)
language sql stable security definer set search_path = public as $$
  select r.post_id,
         round((percentile_cont(0.5) within group (order by r.score))::numeric, 1),
         count(*)::int
  from public.ratings r
  where r.post_id = any (ids)
  group by r.post_id
$$;
revoke execute on function public.post_scores(uuid[]) from public;
grant execute on function public.post_scores(uuid[]) to anon, authenticated;

-- Logged-out visitors must still be able to run the feed query. With no policy for
-- the anon role, row level security returns zero comments and ratings to them.
grant select on public.comments, public.ratings to anon;
