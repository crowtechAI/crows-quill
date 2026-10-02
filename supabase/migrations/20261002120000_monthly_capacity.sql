-- Monthly capacity model.
-- One number (studio_settings.monthly_capacity) controls how many commissions
-- the studio takes per calendar month. A commission counts toward its slot's
-- month once its deposit is paid, or while an unpaid quote/agreement is still
-- inside the hold window. When a month reaches the cap, all of its dates drop
-- off the public picker and clients roll to the next month with room.
--
-- To scale from 4 to 6:  update studio_settings set monthly_capacity = 6;
-- Optional second dial (min. notice before a client's deadline, in weeks):
--                        update studio_settings set lead_time_weeks = 8;

create table if not exists public.studio_settings (
  id boolean primary key default true check (id),            -- single-row table
  monthly_capacity int not null default 4 check (monthly_capacity between 1 and 50),
  lead_time_weeks  int not null default 6 check (lead_time_weeks between 0 and 26),
  hold_hours       int not null default 72 check (hold_hours between 1 and 720),
  updated_at timestamptz not null default now()
);
insert into public.studio_settings (id) values (true) on conflict do nothing;
alter table public.studio_settings enable row level security;
drop policy if exists "public can view studio settings" on public.studio_settings;
create policy "public can view studio settings" on public.studio_settings for select using (true);
drop policy if exists "studio full access settings" on public.studio_settings;
create policy "studio full access settings" on public.studio_settings for all
  using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');

-- The admin calendar writes 'closed'; the original check only allowed 'blocked'.
do $mig$
declare c text;
begin
  for c in select conname from pg_constraint
           where conrelid = 'public.slots'::regclass and contype = 'c'
             and pg_get_constraintdef(oid) ilike '%status%' loop
    execute format('alter table public.slots drop constraint %I', c);
  end loop;
  alter table public.slots add constraint slots_status_check
    check (status in ('open', 'full', 'blocked', 'closed'));
end
$mig$;

-- Single definition of "this commission uses up a place in its month".
create or replace function public.commission_holds_capacity(
  p_status text, p_deposit_paid boolean, p_created timestamptz, p_updated timestamptz, p_hold_hours int)
returns boolean language sql stable set search_path = public as $fn$
  select p_status not in ('enquiry', 'declined', 'cancelled')
    and (coalesce(p_deposit_paid, false)
         or (p_status in ('quoted', 'accepted')
             and greatest(p_created, p_updated) > now() - make_interval(hours => p_hold_hours)))
$fn$;

create or replace function public.get_slot_availability(p_from date default null, p_to date default null)
returns table(slot_id uuid, slot_date date, status text, monthly_capacity int,
              committed int, remaining int, bookable boolean)
language sql stable security definer set search_path = public as $fn$
  with cfg as (select st.monthly_capacity as cap, st.hold_hours as hh from studio_settings st where st.id),
  used as (
    select date_trunc('month', s.slot_date::timestamp)::date as m, count(*)::int as n
    from commissions c
    join slots s on s.id = c.slot_id
    cross join cfg
    where commission_holds_capacity(c.status, c.deposit_paid, c.created_at, c.updated_at, cfg.hh)
    group by 1
  )
  select s.id, s.slot_date, s.status, cfg.cap,
         coalesce(u.n, 0),
         greatest(cfg.cap - coalesce(u.n, 0), 0),
         (s.status = 'open' and cfg.cap - coalesce(u.n, 0) > 0)
  from slots s
  cross join cfg
  left join used u on u.m = date_trunc('month', s.slot_date::timestamp)::date
  where (p_from is null or s.slot_date >= p_from)
    and (p_to is null or s.slot_date <= p_to)
  order by s.slot_date
$fn$;
grant execute on function public.get_slot_availability(date, date) to anon, authenticated;

-- Booking RPC: identical pricing/validation to before; only the slot gate
-- changed (month cap instead of per-date capacity, no booked_count writes).
create or replace function public.create_commission_and_quote(
  p_slot_id uuid, p_author_name text, p_author_email text, p_book_title text,
  p_commission_type_id text, p_brief text, p_extra_ids text[], p_hp text default ''::text)
returns table(commission_id uuid, quote_id uuid, total numeric, deposit numeric, is_estimate boolean, items jsonb)
language plpgsql security definer set search_path to 'public' as $fn$
#variable_conflict use_column
declare
  v_client_id uuid; v_commission_id uuid; v_quote_id uuid;
  v_base numeric; v_is_estimate boolean; v_type_label text;
  v_fixed numeric := 0; v_pct_sum numeric := 0; v_pct_amt numeric;
  v_sub numeric; v_total numeric; v_deposit numeric;
  v_items jsonb := '[]'::jsonb; v_extra record; v_any_from boolean := false;
  v_slot_date date; v_slot_status text; v_cap int; v_hold int; v_used int;
  v_recent int; v_dupe int;
begin
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

  select count(*) - count(distinct e.option_group) into v_dupe
    from extras e where e.id = any(coalesce(p_extra_ids, '{}')) and e.option_group is not null;
  if v_dupe > 0 then
    raise exception 'Please choose only one option from each exclusive group (e.g. NSFW for 1 or 2 characters).';
  end if;

  if p_slot_id is not null then
    select s.slot_date, s.status into v_slot_date, v_slot_status from slots s where s.id = p_slot_id;
    if v_slot_date is null then raise exception 'Slot not found'; end if;
    -- Serialise bookings per calendar month so two clients can't both take the last place.
    perform pg_advisory_xact_lock(hashtext('slot-month:' || to_char(v_slot_date, 'YYYY-MM')));
    select st.monthly_capacity, st.hold_hours into v_cap, v_hold from studio_settings st where st.id;
    select count(*) into v_used
      from commissions c join slots s on s.id = c.slot_id
      where date_trunc('month', s.slot_date::timestamp) = date_trunc('month', v_slot_date::timestamp)
        and commission_holds_capacity(c.status, c.deposit_paid, c.created_at, c.updated_at, v_hold);
    if v_slot_status <> 'open' or v_used >= v_cap then
      raise exception 'That month just filled up — please choose another date.';
    end if;
  end if;

  v_items := v_items || jsonb_build_object('label', v_type_label, 'amount', v_base);

  for v_extra in select e.* from extras e
      where e.id = any(coalesce(p_extra_ids, '{}')) and not e.is_percentage order by e.sort_order loop
    v_fixed := v_fixed + v_extra.price;
    if v_extra.is_from then v_any_from := true; end if;
    v_items := v_items || jsonb_build_object('label', v_extra.label, 'amount', v_extra.price);
  end loop;

  v_sub := v_base + v_fixed;

  for v_extra in select e.* from extras e
      where e.id = any(coalesce(p_extra_ids, '{}')) and e.is_percentage order by e.sort_order loop
    v_pct_amt := round(v_sub * v_extra.percentage / 100);
    v_pct_sum := v_pct_sum + v_pct_amt;
    if v_extra.is_from then v_any_from := true; end if;
    v_items := v_items || jsonb_build_object('label',
      v_extra.label || ' (' || trim_scale(v_extra.percentage)::text || '%)', 'amount', v_pct_amt);
  end loop;

  v_total := v_sub + v_pct_sum;
  v_deposit := round(v_total * 0.5);
  v_is_estimate := v_is_estimate or v_any_from;

  insert into clients (name, email, book_title)
    values (p_author_name, p_author_email, p_book_title)
    returning id into v_client_id;

  insert into commissions (client_id, slot_id, commission_type, extras, brief, status,
                           base_price, extras_total, total_price, is_estimate, deposit_amount)
    values (v_client_id, p_slot_id, p_commission_type_id, to_jsonb(coalesce(p_extra_ids, '{}')), p_brief, 'quoted',
            v_base, v_total - v_base, v_total, v_is_estimate, v_deposit)
    returning id into v_commission_id;

  insert into quotes (commission_id, line_items, total, response)
    values (v_commission_id, v_items, v_total, 'pending')
    returning id into v_quote_id;

  return query select v_commission_id, v_quote_id, v_total, v_deposit, v_is_estimate, v_items;
end;
$fn$;

-- slots.label was NOT NULL with no default, so the admin calendar's "Mark open"
-- insert (which sends no label) failed. Fill it automatically instead.
alter table public.slots alter column label drop not null;
create or replace function public.slots_default_label() returns trigger
language plpgsql set search_path = public as $fn$
begin
  if new.label is null or btrim(new.label) = '' then
    new.label := to_char(new.slot_date, 'FMDD Mon YYYY');
  end if;
  return new;
end
$fn$;
drop trigger if exists slots_default_label on public.slots;
create trigger slots_default_label before insert on public.slots
  for each row execute function public.slots_default_label();
