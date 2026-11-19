-- Inspiration gallery: real photos admins choose, shown in "Add to your
-- collage". Everyone sees the ones that are on; only admins can change them.
create table if not exists public.inspirations (
  id uuid primary key default gen_random_uuid(),
  title text not null default '' check (char_length(title) <= 60),
  category text not null default 'outfit' check (category in ('outfit','makeup','nails','hair','other')),
  photo_url text not null,
  sort int not null default 0,
  active boolean not null default true,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists inspirations_sort_idx on public.inspirations(sort, created_at desc);
alter table public.inspirations enable row level security;
revoke all on public.inspirations from public, anon, authenticated;
grant select on public.inspirations to anon, authenticated;
grant insert (title, category, photo_url, sort, active), update (title, category, sort, active), delete on public.inspirations to authenticated;

drop policy if exists "inspirations read" on public.inspirations;
create policy "inspirations read" on public.inspirations for select using (active or public.is_admin());
drop policy if exists "inspirations admin insert" on public.inspirations;
create policy "inspirations admin insert" on public.inspirations for insert to authenticated with check (public.is_admin());
drop policy if exists "inspirations admin update" on public.inspirations;
create policy "inspirations admin update" on public.inspirations for update to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists "inspirations admin delete" on public.inspirations;
create policy "inspirations admin delete" on public.inspirations for delete to authenticated using (public.is_admin());

create or replace function public.inspiration_defaults() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.created_by := auth.uid(); new.created_at := now();
  if new.photo_url !~ '^https://stehllepbcppfkqmayfg\.supabase\.co/storage/v1/object/public/photos/' then
    raise exception 'Upload the photo to Lookover first'; end if;
  return new;
end $$;
drop trigger if exists inspirations_bi on public.inspirations;
create trigger inspirations_bi before insert on public.inspirations for each row execute function public.inspiration_defaults();

-- History: added, edited, hidden, shown, deleted by whom
create or replace function public.log_inspiration() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return coalesce(new, old); end if;
  if tg_op = 'INSERT' then
    perform public.log_action('added', 'inspiration', new.id, null, coalesce(nullif(new.title, ''), 'Untitled') || ' · ' || new.category);
  elsif tg_op = 'DELETE' then
    perform public.log_action('deleted', 'inspiration', old.id, null, coalesce(nullif(old.title, ''), 'Untitled') || ' · ' || old.category);
  elsif new.active is distinct from old.active then
    perform public.log_action(case when new.active then 'shown' else 'hidden' end, 'inspiration', new.id, null, coalesce(nullif(new.title, ''), 'Untitled'));
  elsif new.title is distinct from old.title or new.category is distinct from old.category then
    perform public.log_action('edited', 'inspiration', new.id, null,
      coalesce(nullif(old.title, ''), 'Untitled') || ' · ' || old.category || ' → ' || coalesce(nullif(new.title, ''), 'Untitled') || ' · ' || new.category);
  end if;
  return coalesce(new, old);
end $$;
drop trigger if exists inspirations_log on public.inspirations;
create trigger inspirations_log after insert or update or delete on public.inspirations for each row execute function public.log_inspiration();
