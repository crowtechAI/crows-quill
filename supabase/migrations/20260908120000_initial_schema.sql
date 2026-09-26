-- The Crow's Quill: core schema
create extension if not exists "pgcrypto";

create table if not exists commission_types (
  id text primary key,
  label text not null,
  base_price numeric not null,
  is_estimate boolean not null default false,
  sort_order int not null default 0
);

create table if not exists extras (
  id text primary key,
  label text not null,
  price numeric,
  is_percentage boolean not null default false,
  percentage numeric
);

create table if not exists slots (
  id uuid primary key default gen_random_uuid(),
  slot_date date not null,
  capacity int not null default 1,
  booked_count int not null default 0,
  status text not null default 'open' check (status in ('open','full','closed'))
);

create table if not exists clients (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  email text not null,
  book_title text,
  created_at timestamptz not null default now()
);

create table if not exists commissions (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references clients(id) on delete cascade,
  slot_id uuid references slots(id),
  commission_type text not null references commission_types(id),
  extra_ids text[] not null default '{}',
  brief text,
  status text not null default 'enquiry'
    check (status in ('enquiry','quoted','accepted','declined','in_progress','delivered','cancelled')),
  total_price numeric,
  deposit_amount numeric,
  deposit_paid boolean not null default false,
  balance_paid boolean not null default false,
  deposit_link_sent_at timestamptz,
  stripe_checkout_session_id text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists quotes (
  id uuid primary key default gen_random_uuid(),
  commission_id uuid not null references commissions(id) on delete cascade,
  total numeric not null,
  deposit numeric not null,
  is_estimate boolean not null default false,
  response text not null default 'pending' check (response in ('pending','accepted','declined')),
  sent_at timestamptz not null default now(),
  responded_at timestamptz
);

create table if not exists contracts (
  id uuid primary key default gen_random_uuid(),
  commission_id uuid not null references commissions(id) on delete cascade,
  contract_text text not null,
  signature_name text not null,
  signed_at timestamptz not null default now()
);

create table if not exists commission_files (
  id uuid primary key default gen_random_uuid(),
  commission_id uuid not null references commissions(id) on delete cascade,
  file_path text not null,
  file_type text not null default 'other',
  uploaded_by text not null default 'artist',
  uploaded_at timestamptz not null default now()
);

-- RLS: public catalog tables are readable by anyone (anon).
-- Everything client-specific is locked down; the public site only ever
-- touches it through the SECURITY DEFINER RPCs below. Studio (authenticated)
-- users get full read/write, since only the artist signs in.
alter table commission_types enable row level security;
alter table extras enable row level security;
alter table slots enable row level security;
alter table clients enable row level security;
alter table commissions enable row level security;
alter table quotes enable row level security;
alter table contracts enable row level security;
alter table commission_files enable row level security;

create policy "public read commission_types" on commission_types for select using (true);
create policy "public read extras" on extras for select using (true);
create policy "public read open slots" on slots for select using (true);

create policy "studio full access clients" on clients for all
  using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy "studio full access commissions" on commissions for all
  using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy "studio full access quotes" on quotes for all
  using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy "studio full access contracts" on contracts for all
  using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy "studio full access commission_files" on commission_files for all
  using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy "studio update slots" on slots for update
  using (auth.role() = 'authenticated');
