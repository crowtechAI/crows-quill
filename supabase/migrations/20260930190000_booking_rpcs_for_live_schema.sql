-- Booking RPCs aligned with the LIVE database schema (commissions.extras jsonb,
-- quotes.line_items, no quotes.deposit/is_estimate). Purely additive: nothing is
-- dropped and no existing RLS policy is changed.
--
-- NOTE: 20260926090000_fixes_and_client_uploads.sql / 20260926110000_client_portal.sql
-- were written against a different column layout and were never applied to the
-- live project; this file supersedes the function parts of them.

-- Client notes -------------------------------------------------------------
create table if not exists commission_notes (
  id uuid primary key default gen_random_uuid(),
  commission_id uuid not null references commissions(id) on delete cascade,
  note text not null check (char_length(note) between 1 and 5000),
  created_by text not null default 'client' check (created_by in ('client','artist')),
  created_at timestamptz not null default now()
);
create index if not exists idx_commission_notes_commission_id on commission_notes(commission_id);
alter table commission_notes enable row level security;
drop policy if exists "authenticated full access commission_notes" on commission_notes;
create policy "authenticated full access commission_notes" on commission_notes for all
  using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');

-- Client uploads into <commission_id>/... while the commission is still live --
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

-- create_commission_and_quote ---------------------------------------------
create or replace function public.create_commission_and_quote(
  p_slot_id uuid, p_author_name text, p_author_email text, p_book_title text,
  p_commission_type_id text, p_brief text, p_extra_ids text[], p_hp text default ''
) returns table (commission_id uuid, quote_id uuid, total numeric, deposit numeric, is_estimate boolean, items jsonb)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
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
  v_slot_status text;
  v_recent int;
begin
  -- Honeypot: bots filling the hidden field get a fake success, nothing is written.
  if p_hp is not null and length(trim(p_hp)) > 0 then
    return query select gen_random_uuid(), gen_random_uuid(), 0::numeric, 0::numeric, false, '[]'::jsonb;
    return;
  end if;

  if p_author_email is null or position('@' in p_author_email) = 0 then
    raise exception 'A valid email address is required';
  end if;

  select count(*) into v_recent from clients cl
    where cl.email = p_author_email and cl.created_at > now() - interval '24 hours';
  if v_recent >= 5 then
    raise exception 'Too many enquiries from this email today — please contact the studio directly.';
  end if;

  select ct.base_price, ct.is_estimate, ct.label into v_base, v_is_estimate, v_type_label
    from commission_types ct where ct.id = p_commission_type_id;
  if v_base is null then raise exception 'Unknown commission type'; end if;

  if p_slot_id is not null then
    select s.capacity, s.booked_count, s.status into v_capacity, v_booked, v_slot_status
      from slots s where s.id = p_slot_id for update;
    if v_capacity is null then raise exception 'Slot not found'; end if;
    if v_slot_status <> 'open' or v_booked >= v_capacity then
      raise exception 'That slot just filled up — please choose another.';
    end if;
  end if;

  v_items := v_items || jsonb_build_object('label', v_type_label, 'amount', v_base);
  for v_extra in select e.* from extras e where e.id = any(coalesce(p_extra_ids, '{}')) loop
    if v_extra.is_percentage then
      v_pct := v_pct + v_extra.percentage;
      v_items := v_items || jsonb_build_object('label', v_extra.label, 'amount',
        round(v_base * v_extra.percentage / 100));
    else
      v_fixed := v_fixed + v_extra.price;
      v_items := v_items || jsonb_build_object('label', v_extra.label, 'amount', v_extra.price);
    end if;
  end loop;

  -- Same formula as the public booking page's live estimate.
  v_sub := v_base + v_fixed;
  v_total := round(v_sub * (1 + v_pct / 100));
  v_deposit := round(v_total * 0.5);

  insert into clients (name, email, book_title)
    values (p_author_name, p_author_email, p_book_title)
    returning id into v_client_id;

  insert into commissions (client_id, slot_id, commission_type, extras, brief, status,
                           base_price, extras_total, total_price, is_estimate, deposit_amount)
    values (v_client_id, p_slot_id, p_commission_type_id, to_jsonb(coalesce(p_extra_ids, '{}')), p_brief, 'quoted',
            v_base, v_total - v_base, v_total, v_is_estimate, v_deposit)
    returning id into v_commission_id;

  if p_slot_id is not null then
    update slots set booked_count = booked_count + 1,
           status = case when booked_count + 1 >= capacity then 'full' else status end
     where id = p_slot_id;
  end if;

  insert into quotes (commission_id, line_items, total, response)
    values (v_commission_id, v_items, v_total, 'pending')
    returning id into v_quote_id;

  return query select v_commission_id, v_quote_id, v_total, v_deposit, v_is_estimate, v_items;
end;
$$;

-- decline_quote -------------------------------------------------------------
create or replace function public.decline_quote(p_quote_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare v_commission_id uuid; v_slot_id uuid;
begin
  update quotes set response = 'declined', responded_at = now()
    where id = p_quote_id and response = 'pending'
    returning quotes.commission_id into v_commission_id;
  if v_commission_id is null then raise exception 'Quote not found or already answered'; end if;

  update commissions set status = 'declined', updated_at = now()
    where id = v_commission_id
    returning slot_id into v_slot_id;

  if v_slot_id is not null then
    update slots set booked_count = greatest(booked_count - 1, 0),
           status = case when status = 'full' then 'open' else status end
     where id = v_slot_id;
  end if;
end;
$$;

-- accept_quote_and_sign -----------------------------------------------------
create or replace function public.accept_quote_and_sign(p_quote_id uuid, p_signer_name text)
returns uuid
language plpgsql security definer set search_path = public as $$
declare v_commission_id uuid; v_total numeric; v_deposit numeric; v_id uuid;
  v_signer text := trim(p_signer_name);
begin
  if char_length(v_signer) < 2 then
    raise exception 'A signature name is required';
  end if;

  select q.commission_id, q.total into v_commission_id, v_total
    from quotes q where q.id = p_quote_id and q.response = 'pending';
  if v_commission_id is null then
    raise exception 'This quote is not awaiting a response';
  end if;
  select co.deposit_amount into v_deposit from commissions co where co.id = v_commission_id;

  update quotes set response = 'accepted', responded_at = now() where id = p_quote_id;

  insert into contracts (commission_id, contract_text, signature_name, agreed, signed_at)
    values (
      v_commission_id,
      format('Commission agreement — total $%s, 50%% deposit of $%s due to confirm; balance due before high-resolution delivery.', v_total, v_deposit),
      v_signer, true, now()
    )
    returning id into v_id;

  update commissions set status = 'in_progress', updated_at = now() where id = v_commission_id;
  return v_id;
end;
$$;

-- add_client_file / add_client_note ----------------------------------------
create or replace function public.add_client_file(p_commission_id uuid, p_file_path text, p_file_type text default 'reference')
returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_status text;
begin
  if p_file_type not in ('reference', 'sketch', 'other') then
    raise exception 'Invalid file type for a client upload';
  end if;
  select c.status into v_status from commissions c where c.id = p_commission_id;
  if v_status is null or v_status in ('cancelled', 'declined', 'delivered') then
    raise exception 'This commission can no longer accept uploads';
  end if;
  insert into commission_files (commission_id, file_path, file_type, uploaded_by)
  values (p_commission_id, p_file_path, p_file_type, 'client')
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.add_client_note(p_commission_id uuid, p_note text)
returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_status text; v_note text := trim(p_note);
begin
  if char_length(v_note) = 0 then raise exception 'Note is empty'; end if;
  if char_length(v_note) > 5000 then raise exception 'Note is too long (5000 characters max)'; end if;
  select c.status into v_status from commissions c where c.id = p_commission_id;
  if v_status is null or v_status in ('cancelled', 'declined', 'delivered') then
    raise exception 'This commission can no longer accept notes';
  end if;
  insert into commission_notes (commission_id, note, created_by)
  values (p_commission_id, v_note, 'client')
  returning id into v_id;
  return v_id;
end;
$$;

-- get_commission_status (client portal: site/track.html) --------------------
create or replace function public.get_commission_status(p_commission_id uuid, p_email text)
returns table (
  status text, commission_type text, book_title text, total_price numeric,
  deposit_amount numeric, deposit_paid boolean, balance_paid boolean,
  slot_date date, created_at timestamptz, notes jsonb, files jsonb
)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare v_client_id uuid;
begin
  select c.id into v_client_id
  from commissions co join clients c on c.id = co.client_id
  where co.id = p_commission_id and lower(c.email) = lower(trim(p_email));

  if v_client_id is null then
    raise exception 'No commission found for that reference and email.';
  end if;

  return query
  select co.status, co.commission_type, c.book_title, co.total_price, co.deposit_amount,
    co.deposit_paid, co.balance_paid, s.slot_date, co.created_at,
    coalesce((select jsonb_agg(jsonb_build_object('note', n.note, 'created_by', n.created_by, 'created_at', n.created_at) order by n.created_at)
              from commission_notes n where n.commission_id = co.id), '[]'::jsonb),
    coalesce((select jsonb_agg(jsonb_build_object('file_type', f.file_type, 'uploaded_by', f.uploaded_by, 'uploaded_at', f.created_at) order by f.created_at)
              from commission_files f where f.commission_id = co.id), '[]'::jsonb)
  from commissions co
  join clients c on c.id = co.client_id
  left join slots s on s.id = co.slot_id
  where co.id = p_commission_id;
end;
$$;

grant execute on function public.create_commission_and_quote(uuid, text, text, text, text, text, text[], text) to anon, authenticated;
grant execute on function public.decline_quote(uuid) to anon, authenticated;
grant execute on function public.accept_quote_and_sign(uuid, text) to anon, authenticated;
grant execute on function public.add_client_file(uuid, text, text) to anon, authenticated;
grant execute on function public.add_client_note(uuid, text) to anon, authenticated;
grant execute on function public.get_commission_status(uuid, text) to anon, authenticated;

-- make PostgREST pick up the new functions immediately
notify pgrst, 'reload schema';
