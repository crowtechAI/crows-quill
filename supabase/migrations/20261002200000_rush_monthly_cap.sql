-- Rush is limited to monthly_rush_cap pieces per start month (default 1), finishing ~14 days after the start date.
alter table public.studio_settings add column if not exists monthly_rush_cap integer not null default 1;
-- get_slot_availability gains rush_cap / rush_committed / rush_remaining; create_commission_and_quote rejects a rush
-- quote once the month's rush places are taken. (Applied via the Supabase MCP as migration "rush_monthly_cap".)
