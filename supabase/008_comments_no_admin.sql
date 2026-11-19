-- Comments are visible only to the person who posted the look and the person who wrote the comment.
-- Admins no longer see other people's comments.
drop policy if exists "comments private" on public.comments;
create policy "comments private" on public.comments for select to authenticated
  using (author_id = auth.uid()
         or exists (select 1 from public.posts p where p.id = post_id and p.author_id = auth.uid()));
