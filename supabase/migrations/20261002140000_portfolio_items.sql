-- Homepage portfolio cards, managed from the admin area.
create table if not exists public.portfolio_items (
  id uuid primary key default gen_random_uuid(),
  section text not null default 'gallery' check (section in ('gallery','commissions')),
  label text not null,
  image_url text not null,
  image_position text not null default 'center',
  alt_text text not null default '',
  client_name text,
  link_url text,
  sort_order integer not null default 0,
  published boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.portfolio_items enable row level security;

drop policy if exists "portfolio public read" on public.portfolio_items;
create policy "portfolio public read" on public.portfolio_items
  for select to anon, authenticated using (published = true);

drop policy if exists "portfolio admin all" on public.portfolio_items;
create policy "portfolio admin all" on public.portfolio_items
  for all to authenticated using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');

-- Public image bucket for uploads from the admin page.
insert into storage.buckets (id, name, public) values ('portfolio', 'portfolio', true)
on conflict (id) do nothing;

drop policy if exists "portfolio images admin write" on storage.objects;
create policy "portfolio images admin write" on storage.objects
  for all to authenticated using (bucket_id = 'portfolio') with check (bucket_id = 'portfolio');

insert into public.portfolio_items (section, label, image_url, image_position, alt_text, sort_order)
select * from (values
 ('gallery','Character Portrait','/images/gallery/portrait-new.jpg?v=wm1','center 30%','Portrait of a dark-haired elf with amber eyes glancing over a shadowed shoulder',10),
 ('gallery','Character Portrait','/images/gallery/portrait-2.jpg?v=wm1','center 35%','Painted profile portrait of a dark-haired elf with a golden eye, looking up and away against a stormy sky',20),
 ('gallery','Character Portrait','/images/gallery/portrait-3.jpg?v=wm1','center 50%','Painted close-up portrait of a figure in a deep green hood, one pale eye catching the light from the shadows',30),
 ('commissions','Romantasy Duo','/images/gallery/romantasy-couple.jpg?v=wm1','center 22%','Painted romantasy scene: a braided heroine holds a knife to a smirking elf''s throat in a dim, candlelit room',10),
 ('commissions','Illustrated Scene','/images/gallery/illustrated-scene.jpg?v=wm1','center','Painted winter market scene: a stallholder hands a silver-haired elf in a star-pinned coat a piece of fudge under lantern light',20)
) v(section,label,image_url,image_position,alt_text,sort_order)
where not exists (select 1 from public.portfolio_items);
