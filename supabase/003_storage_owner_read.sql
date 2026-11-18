drop policy if exists "photos owner list" on storage.objects;
create policy "photos owner list" on storage.objects for select to authenticated
  using (bucket_id = 'photos' and (storage.foldername(name))[1] = auth.uid()::text);
