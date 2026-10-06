-- Studio alerts (email on new enquiry / signed contract / client message / client file)
-- and a cookie-less visitor counter. (Testimonials live in 20261001100000_testimonials.sql.)
-- NOTE: __NOTIFY_SECRET__ is substituted when applying (never commit the real value).
-- Must match the NOTIFY_SECRET function secret used by the notify-studio edge function.

create extension if not exists pg_net;

-- Column the payment-link / Stripe webhook functions write to (was missing on the live DB)
alter table public.commissions add column if not exists stripe_checkout_session_id text;

-- ============ 1. Alerts to the studio ============
create or replace function public.notify_studio(p_kind text, p_commission_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform net.http_post(
    url := 'https://btdhzzpaicairpgudkwq.supabase.co/functions/v1/notify-studio',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-notify-secret', '__NOTIFY_SECRET__'),
    body := jsonb_build_object('kind', p_kind, 'commission_id', p_commission_id)
  );
exception when others then
  -- an alert failure must never block a client's submission
  raise warning 'notify_studio failed: %', sqlerrm;
end $$;
revoke all on function public.notify_studio(text, uuid) from public, anon, authenticated;

create or replace function public.trg_notify_commission() returns trigger
language plpgsql security definer set search_path = public as $$
begin perform public.notify_studio('enquiry', new.id); return new; end $$;
drop trigger if exists notify_new_commission on public.commissions;
create trigger notify_new_commission after insert on public.commissions
  for each row execute function public.trg_notify_commission();

create or replace function public.trg_notify_contract() returns trigger
language plpgsql security definer set search_path = public as $$
begin perform public.notify_studio('contract_signed', new.commission_id); return new; end $$;
drop trigger if exists notify_contract_signed on public.contracts;
create trigger notify_contract_signed after insert on public.contracts
  for each row execute function public.trg_notify_contract();

create or replace function public.trg_notify_note() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(new.created_by, '') not in ('artist', 'studio') then
    perform public.notify_studio('client_note', new.commission_id);
  end if;
  return new;
end $$;
drop trigger if exists notify_client_note on public.commission_notes;
create trigger notify_client_note after insert on public.commission_notes
  for each row execute function public.trg_notify_note();

create or replace function public.trg_notify_file() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(new.uploaded_by, '') = 'client' then
    perform public.notify_studio('client_file', new.commission_id);
  end if;
  return new;
end $$;
drop trigger if exists notify_client_file on public.commission_files;
create trigger notify_client_file after insert on public.commission_files
  for each row execute function public.trg_notify_file();

-- ============ 2. Cookie-less visitor counter ============
create table if not exists public.page_views (
  day date not null default current_date,
  path text not null,
  visits integer not null default 0,
  primary key (day, path)
);
alter table public.page_views enable row level security;
drop policy if exists "authenticated read page views" on public.page_views;
create policy "authenticated read page views" on public.page_views
  for select using (auth.role() = 'authenticated');

create or replace function public.track_view(p_path text) returns void
language plpgsql security definer set search_path = public as $$
declare v_path text := left(coalesce(p_path, '/'), 100);
begin
  if left(v_path, 1) <> '/' then return; end if;
  v_path := split_part(split_part(v_path, '?', 1), '#', 1);
  insert into page_views (day, path, visits) values (current_date, v_path, 1)
  on conflict (day, path) do update set visits = page_views.visits + 1;
end $$;
revoke all on function public.track_view(text) from public;
grant execute on function public.track_view(text) to anon, authenticated;
