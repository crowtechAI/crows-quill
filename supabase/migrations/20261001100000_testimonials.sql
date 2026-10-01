-- Testimonials: studio sends a one-time link to a paid-up client, the client
-- rates and writes a testimonial, and published ones feed the homepage.
-- The public never gets table access; they only call the SECURITY DEFINER
-- functions below, and the secret token in the link is the key for one row.

create table if not exists testimonials (
  id uuid primary key default gen_random_uuid(),
  commission_id uuid not null unique references commissions(id) on delete cascade,
  token uuid not null unique default gen_random_uuid(),
  status text not null default 'requested'
    check (status in ('requested','published','hidden')),
  rating int check (rating between 1 and 5),
  body text check (body is null or char_length(body) between 10 and 1500),
  display_name text check (display_name is null or char_length(display_name) between 1 and 80),
  display_title text check (display_title is null or char_length(display_title) <= 120),
  requested_at timestamptz not null default now(),
  emailed_at timestamptz,
  submitted_at timestamptz,
  updated_at timestamptz not null default now()
);

alter table testimonials enable row level security;

-- Match whatever access model the database uses: if the stricter
-- is_studio_admin() helper exists use it, otherwise fall back to "signed-in
-- user" like the other studio tables (only the artist signs in).
drop policy if exists "studio full access testimonials" on testimonials;
do $$
begin
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'public' and p.proname = 'is_studio_admin') then
    execute 'create policy "studio full access testimonials" on testimonials for all
             using (public.is_studio_admin()) with check (public.is_studio_admin())';
  else
    execute 'create policy "studio full access testimonials" on testimonials for all
             using (auth.role() = ''authenticated'') with check (auth.role() = ''authenticated'')';
  end if;
end $$;

create or replace function public.get_testimonial_request(p_token uuid)
returns table (client_name text, book_title text, already_submitted boolean)
language sql stable security definer set search_path = public as $$
  select c.name, c.book_title, (t.submitted_at is not null)
  from testimonials t
  join commissions co on co.id = t.commission_id
  join clients c on c.id = co.client_id
  where t.token = p_token;
$$;

create or replace function public.submit_testimonial(
  p_token uuid, p_rating int, p_body text, p_display_name text, p_display_title text default null
)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
  v_submitted timestamptz;
begin
  if p_rating is null or p_rating < 1 or p_rating > 5 then
    raise exception 'Please choose a rating from 1 to 5.';
  end if;
  if p_body is null or char_length(trim(p_body)) < 10 then
    raise exception 'Please write at least a sentence or two.';
  end if;
  if char_length(p_body) > 1500 then
    raise exception 'That is a little long - please keep it under 1500 characters.';
  end if;
  if p_display_name is null or char_length(trim(p_display_name)) < 1 then
    raise exception 'Please add the name you would like shown.';
  end if;

  select id, submitted_at into v_id, v_submitted
  from testimonials where token = p_token for update;

  if v_id is null then raise exception 'This testimonial link is not valid.'; end if;
  if v_submitted is not null then raise exception 'A testimonial has already been submitted with this link.'; end if;

  update testimonials set
    rating = p_rating,
    body = trim(p_body),
    display_name = left(trim(p_display_name), 80),
    display_title = nullif(left(trim(coalesce(p_display_title, '')), 120), ''),
    status = 'published',
    submitted_at = now(),
    updated_at = now()
  where id = v_id;
end;
$$;

create or replace function public.get_public_testimonials(p_limit int default 9)
returns table (rating int, body text, display_name text, display_title text, submitted_at timestamptz)
language sql stable security definer set search_path = public as $$
  select t.rating, t.body, t.display_name, t.display_title, t.submitted_at
  from testimonials t
  where t.status = 'published' and t.submitted_at is not null
  order by t.submitted_at desc
  limit least(greatest(p_limit, 1), 24);
$$;

grant execute on function public.get_testimonial_request(uuid) to anon, authenticated;
grant execute on function public.submit_testimonial(uuid, int, text, text, text) to anon, authenticated;
grant execute on function public.get_public_testimonials(int) to anon, authenticated;

-- make PostgREST pick up the new table/functions immediately
notify pgrst, 'reload schema';
