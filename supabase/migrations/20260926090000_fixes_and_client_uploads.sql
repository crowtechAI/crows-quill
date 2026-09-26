-- Fixes: RLS scoped to the studio owner, slot race condition, RPC names that
-- actually match the front-end, spam/rate-limit guards, FK indexes, webhook
-- idempotency, and client-side file/text uploads.

-- ============================================================
-- 1. Studio admin scoping (replaces "any authenticated user")
-- ============================================================
create table if not exists studio_admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  email text,
  created_at timestamptz not null default now()
);
alter table studio_admins enable row level security;
-- no policies granted here on purpose: only service_role / SECURITY DEFINER
-- functions touch this table, never anon/authenticated directly.

-- First person to ever sign up (via the admin "create studio account" flow)
-- becomes the sole studio admin. Anyone who signs up afterwards still gets
-- an account, but RLS below will grant them nothing.
create or replace function public.handle_new_studio_user()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from studio_admins) then
    insert into studio_admins (user_id, email) values (new.id, new.email);
  end if;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created_studio_admin on auth.users;
create trigger on_auth_user_created_studio_admin
  after insert on auth.users
  for each row execute function public.handle_new_studio_user();

create or replace function public.is_studio_admin()
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from studio_admins where user_id = auth.uid());
$$;

-- Re-scope every "studio full access" policy from any authenticated user to
-- the actual studio admin only.
drop policy if exists "studio full access clients" on clients;
create policy "studio full access clients" on clients for all
  using (is_studio_admin()) with check (is_studio_admin());

drop policy if exists "studio full access commissions" on commissions;
create policy "studio full access commissions" on commissions for all
  using (is_studio_admin()) with check (is_studio_admin());

drop policy if exists "studio full access quotes" on quotes;
create policy "studio full access quotes" on quotes for all
  using (is_studio_admin()) with check (is_studio_admin());

drop policy if exists "studio full access contracts" on contracts;
create policy "studio full access contracts" on contracts for all
  using (is_studio_admin()) with check (is_studio_admin());

drop policy if exists "studio full access commission_files" on commission_files;
create policy "studio full access commission_files" on commission_files for all
  using (is_studio_admin()) with check (is_studio_admin());

drop policy if exists "studio update slots" on slots;
create policy "studio update slots" on slots for update
  using (is_studio_admin());

drop policy if exists "studio read commission-files" on storage.objects;
create policy "studio read commission-files" on storage.objects for select
  using (bucket_id = 'commission-files' and is_studio_admin());
drop policy if exists "studio write commission-files" on storage.objects;
create policy "studio write commission-files" on storage.objects for insert
  with check (bucket_id = 'commission-files' and is_studio_admin());
drop policy if exists "studio update commission-files" on storage.objects;
create policy "studio update commission-files" on storage.objects for update
  using (bucket_id = 'commission-files' and is_studio_admin());
drop policy if exists "studio delete commission-files" on storage.objects;
create policy "studio delete commission-files" on storage.objects for delete
  using (bucket_id = 'commission-files' and is_studio_admin());

-- ============================================================
-- 2. Client reference uploads: files + pasted text notes
-- ============================================================
create table if not exists commission_notes (
  id uuid primary key default gen_random_uuid(),
  commission_id uuid not null references commissions(id) on delete cascade,
  note text not null check (char_length(note) between 1 and 5000),
  created_by text not null default 'client' check (created_by in ('client','artist')),
  created_at timestamptz not null default now()
);
alter table commission_notes enable row level security;
create policy "studio full access commission_notes" on commission_notes for all
  using (is_studio_admin()) with check (is_studio_admin());

-- A client may upload into a commission's own folder in storage as long as
-- that commission is still live (not cancelled/declined/delivered). The
-- commission_id itself — a random UUID only ever shown to that client —
-- is the access token here, same trust model the RPCs already use.
create or replace function public.is_uploadable_commission(p_path text)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from commissions c
    where c.id::text = split_part(p_path, '/', 1)
      and c.status not in ('cancelled', 'declined', 'delivered')
  );
$$;

drop policy if exists "client upload commission-files" on storage.objects;
create policy "client upload commission-files" on storage.objects for insert
  with check (bucket_id = 'commission-files' and public.is_uploadable_commission(name));

create or replace function add_client_file(p_commission_id uuid, p_file_path text, p_file_type text default 'reference')
returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_status text;
begin
  if p_file_type not in ('reference', 'sketch', 'other') then
    raise exception 'Invalid file type for a client upload';
  end if;
  select status into v_status from commissions where id = p_commission_id;
  if v_status is null or v_status in ('cancelled', 'declined', 'delivered') then
    raise exception 'This commission can no longer accept uploads';
  end if;
  insert into commission_files (commission_id, file_path, file_type, uploaded_by)
  values (p_commission_id, p_file_path, p_file_type, 'client')
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function add_client_note(p_commission_id uuid, p_note text)
returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_status text; v_note text := trim(p_note);
begin
  if char_length(v_note) = 0 then
    raise exception 'Note is empty';
  end if;
  if char_length(v_note) > 5000 then
    raise exception 'Note is too long (5000 characters max)';
  end if;
  select status into v_status from commissions where id = p_commission_id;
  if v_status is null or v_status in ('cancelled', 'declined', 'delivered') then
    raise exception 'This commission can no longer accept notes';
  end if;
  insert into commission_notes (commission_id, note, created_by)
  values (p_commission_id, v_note, 'client')
  returning id into v_id;
  return v_id;
end;
$$;

grant execute on function add_client_file to anon, authenticated;
grant execute on function add_client_note to anon, authenticated;

-- ============================================================
-- 3. Replace the RPCs with ones matching the front-end's actual
--    calls, fixing the slot-capacity race condition and adding
--    a honeypot + basic rate limit against spam enquiries.
-- ============================================================
drop function if exists submit_enquiry(text, text, text, uuid, text, text[], text);
drop function if exists respond_to_quote(uuid, text);
drop function if exists sign_contract(uuid, text, text);

create or replace function create_commission_and_quote(
  p_slot_id uuid, p_author_name text, p_author_email text, p_book_title text,
  p_commission_type_id text, p_brief text, p_extra_ids text[], p_hp text default ''
) returns table (commission_id uuid, quote_id uuid, total numeric, deposit numeric, is_estimate boolean, items jsonb)
language plpgsql security definer set search_path = public as $$
declare
  v_client_id uuid;
  v_commission_id uuid;
  v_quote_id uuid;
  v_base numeric;
  v_is_estimate boolean;
  v_type_label text;
  v_fixed numeric := 0;
  v_pct numeric := 0;
  v_sub numeric;
  v_total numeric;
  v_deposit numeric;
  v_items jsonb := '[]'::jsonb;
  v_extra record;
  v_capacity int;
  v_booked int;
  v_recent int;
begin
  -- Honeypot: bots that fill the hidden field get a plausible-looking fake
  -- success with nothing written to the database.
  if p_hp is not null and length(trim(p_hp)) > 0 then
    return query select gen_random_uuid(), gen_random_uuid(), 0::numeric, 0::numeric, false, '[]'::jsonb;
    return;
  end if;

  if p_author_email is null or position('@' in p_author_email) = 0 then
    raise exception 'A valid email address is required';
  end if;

  select count(*) into v_recent from clients
    where email = p_author_email and created_at > now() - interval '24 hours';
  if v_recent >= 5 then
    raise exception 'Too many enquiries from this email today — please contact the studio directly.';
  end if;

  select base_price, is_estimate, label into v_base, v_is_estimate, v_type_label
    from commission_types where id = p_commission_type_id;
  if v_base is null then raise exception 'Unknown commission type'; end if;

  if p_slot_id is not null then
    select capacity, booked_count into v_capacity, v_booked
      from slots where id = p_slot_id for update;
    if v_capacity is null then raise exception 'Slot not found'; end if;
    if v_booked >= v_capacity then
      raise exception 'That slot just filled up — please choose another.';
    end if;
  end if;

  v_items := v_items || jsonb_build_object('label', v_type_label, 'amount', v_base);
  for v_extra in select * from extras where id = any(coalesce(p_extra_ids, '{}')) loop
    if v_extra.is_percentage then
      v_pct := v_pct + v_extra.percentage;
      v_items := v_items || jsonb_build_object('label', v_extra.label, 'amount',
        round(v_base * v_extra.percentage / 100));
    else
      v_fixed := v_fixed + v_extra.price;
      v_items := v_items || jsonb_build_object('label', v_extra.label, 'amount', v_extra.price);
    end if;
  end loop;

  v_sub := v_base + v_fixed;
  v_total := round(v_sub * (1 + v_pct / 100));
  v_deposit := round(v_total * 0.5);

  insert into clients (name, email, book_title) values (p_author_name, p_author_email, p_book_title)
    returning id into v_client_id;

  insert into commissions (client_id, slot_id, commission_type, extra_ids, brief, status, total_price, deposit_amount)
    values (v_client_id, p_slot_id, p_commission_type_id, coalesce(p_extra_ids, '{}'), p_brief, 'quoted', v_total, v_deposit)
    returning id into v_commission_id;

  if p_slot_id is not null then
    update slots set booked_count = booked_count + 1 where id = p_slot_id;
    update slots set status = 'full' where id = p_slot_id and booked_count >= capacity;
  end if;

  insert into quotes (commission_id, total, deposit, is_estimate)
    values (v_commission_id, v_total, v_deposit, v_is_estimate)
    returning id into v_quote_id;

  return query select v_commission_id, v_quote_id, v_total, v_deposit, v_is_estimate, v_items;
end;
$$;

create or replace function decline_quote(p_quote_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare v_commission_id uuid; v_slot_id uuid;
begin
  update quotes set response = 'declined', responded_at = now()
    where id = p_quote_id and response = 'pending'
    returning commission_id into v_commission_id;
  if v_commission_id is null then raise exception 'Quote not found or already answered'; end if;

  update commissions set status = 'declined', updated_at = now()
    where id = v_commission_id
    returning slot_id into v_slot_id;

  if v_slot_id is not null then
    update slots set booked_count = greatest(booked_count - 1, 0), status = 'open' where id = v_slot_id;
  end if;
end;
$$;

create or replace function accept_quote_and_sign(p_quote_id uuid, p_signer_name text)
returns uuid
language plpgsql security definer set search_path = public as $$
declare v_commission_id uuid; v_total numeric; v_deposit numeric; v_id uuid;
  v_signer text := trim(p_signer_name);
begin
  if char_length(v_signer) < 2 then
    raise exception 'A signature name is required';
  end if;

  select commission_id, total, deposit into v_commission_id, v_total, v_deposit
    from quotes where id = p_quote_id and response = 'pending';
  if v_commission_id is null then
    raise exception 'This quote is not awaiting a response';
  end if;

  update quotes set response = 'accepted', responded_at = now() where id = p_quote_id;
  update commissions set status = 'accepted', updated_at = now() where id = v_commission_id;

  insert into contracts (commission_id, contract_text, signature_name)
    values (
      v_commission_id,
      format('Commission agreement — total £%s, 50%% deposit of £%s due to confirm; balance due before high-resolution delivery.', v_total, v_deposit),
      v_signer
    )
    returning id into v_id;

  update commissions set status = 'in_progress', updated_at = now() where id = v_commission_id;
  return v_id;
end;
$$;

grant execute on function create_commission_and_quote to anon, authenticated;
grant execute on function decline_quote to anon, authenticated;
grant execute on function accept_quote_and_sign to anon, authenticated;

-- ============================================================
-- 4. Foreign-key indexes
-- ============================================================
create index if not exists idx_commissions_client_id on commissions(client_id);
create index if not exists idx_commissions_slot_id on commissions(slot_id);
create index if not exists idx_commissions_commission_type on commissions(commission_type);
create index if not exists idx_quotes_commission_id on quotes(commission_id);
create index if not exists idx_contracts_commission_id on contracts(commission_id);
create index if not exists idx_commission_files_commission_id on commission_files(commission_id);
create index if not exists idx_commission_notes_commission_id on commission_notes(commission_id);

-- ============================================================
-- 5. Stripe webhook idempotency
-- ============================================================
create table if not exists stripe_events (
  id text primary key,
  processed_at timestamptz not null default now()
);
alter table stripe_events enable row level security;
-- No policies: only the service-role key (used by the webhook function,
-- which bypasses RLS) ever touches this table.
