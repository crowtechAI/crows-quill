-- 6 pieces per month, production weeks start on Mondays and are created automatically.
update public.studio_settings set monthly_capacity = 6, updated_at = now() where id;

create unique index if not exists slots_slot_date_key on public.slots (slot_date);

create or replace function public.ensure_weekly_slots(p_weeks integer default 16)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  first_monday date := (current_date + ((8 - extract(isodow from current_date)::int) % 7 + case when extract(isodow from current_date)::int = 1 then 7 else 0 end))::date;
  n integer;
begin
  with ins as (
    insert into slots (slot_date, label, capacity, booked_count, status)
    select d::date, 'Production week', 1, 0, 'open'
    from generate_series(first_monday, first_monday + (p_weeks * 7), interval '7 days') d
    on conflict (slot_date) do nothing
    returning 1
  )
  select count(*) into n from ins;
  return n;
end;
$$;

revoke all on function public.ensure_weekly_slots(integer) from public, anon, authenticated;

select public.ensure_weekly_slots(16);

create extension if not exists pg_cron;
select cron.schedule('ensure-weekly-slots', '0 3 * * *', $$select public.ensure_weekly_slots(16)$$);

-- One-off tidy: close the old non-Monday dates (existing bookings keep their slot).
update public.slots set status = 'closed'
where extract(isodow from slot_date) <> 1 and status in ('open','full') and slot_date >= current_date;
