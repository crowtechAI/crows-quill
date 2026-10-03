-- Monthly intake: one shared start date per month (first Monday), matching the 5-week batching schedule.
create or replace function public.ensure_monthly_slots(p_months integer default 8)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare n integer;
begin
  with months as (
    select (date_trunc('month', current_date) + (g || ' month')::interval)::date as m
    from generate_series(0, p_months) g
  ),
  firsts as (
    select (m + ((8 - extract(isodow from m)::int) % 7))::date as d from months
  ),
  ins as (
    insert into slots (slot_date, label, capacity, booked_count, status)
    select d, 'Monthly start', 1, 0, 'open'
    from firsts
    where d >= current_date + 7
    on conflict (slot_date) do nothing
    returning 1
  )
  select count(*) into n from ins;
  return n;
end;
$$;
revoke all on function public.ensure_monthly_slots(integer) from public, anon, authenticated;

select cron.schedule('ensure-monthly-slots', '0 3 * * *', $$select public.ensure_monthly_slots(8)$$);
drop function if exists public.ensure_weekly_slots(integer);

update public.slots s set status = 'closed'
where s.slot_date >= current_date and s.status in ('open','full')
  and not exists (select 1 from public.commissions c where c.slot_id = s.id)
  and s.slot_date <> (date_trunc('month', s.slot_date)::date + ((8 - extract(isodow from date_trunc('month', s.slot_date))::int) % 7));
