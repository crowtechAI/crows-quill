-- 1. Fix page_views RLS: was "any authenticated user", same class of bug fixed
--    elsewhere. Scope to the studio admin specifically.
drop policy if exists "authenticated read page views" on public.page_views;
create policy "studio read page views" on public.page_views
  for select using (is_studio_admin());

-- 2. Referrer tracking, privacy-safe: only the referring *hostname* is ever
--    stored (e.g. "instagram.com", "google", "direct") — never a full URL,
--    never anything from the same site, never anything that could identify
--    a person. This lets the studio see which channel actually drives
--    traffic without tracking individuals.
alter table public.page_views add column if not exists referrer text not null default 'direct';

-- Primary key grows to include referrer so the same day/path can have
-- multiple referrer buckets.
alter table public.page_views drop constraint if exists page_views_pkey;
alter table public.page_views add primary key (day, path, referrer);

create or replace function public.track_view(p_path text, p_referrer text default 'direct')
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_path text := left(coalesce(p_path, '/'), 100);
  v_ref text := left(lower(coalesce(nullif(trim(p_referrer), ''), 'direct')), 60);
begin
  if left(v_path, 1) <> '/' then return; end if;
  v_path := split_part(split_part(v_path, '?', 1), '#', 1);
  -- Only allow a bare hostname-looking value or the literal 'direct' — defence
  -- in depth in case the client-side bucketing is ever bypassed.
  if v_ref <> 'direct' and v_ref !~ '^[a-z0-9.-]+$' then
    v_ref := 'direct';
  end if;
  insert into page_views (day, path, referrer, visits) values (current_date, v_path, v_ref, 1)
  on conflict (day, path, referrer) do update set visits = page_views.visits + 1;
end $$;
revoke all on function public.track_view(text, text) from public;
grant execute on function public.track_view(text, text) to anon, authenticated;
