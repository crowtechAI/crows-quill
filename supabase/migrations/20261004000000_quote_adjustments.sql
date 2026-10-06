-- Studio can confirm / adjust a quote after reviewing the brief, with a reason the client can see.
alter table public.quotes
  add column if not exists original_total numeric,
  add column if not exists adjustment_reason text,
  add column if not exists adjusted_at timestamptz;

-- Client portal: the latest adjustment for a commission (same reference + email check as get_commission_status)
create or replace function public.get_quote_adjustment(p_commission_id uuid, p_email text)
returns table (original_total numeric, new_total numeric, deposit_amount numeric, reason text, adjusted_at timestamptz, line_items jsonb)
language sql stable security definer set search_path = public as $$
  select q.original_total, q.total, co.deposit_amount, q.adjustment_reason, q.adjusted_at, q.line_items
  from quotes q
  join commissions co on co.id = q.commission_id
  join clients cl on cl.id = co.client_id
  where co.id = p_commission_id
    and lower(cl.email) = lower(trim(p_email))
    and q.adjusted_at is not null
  order by q.adjusted_at desc
  limit 1;
$$;
revoke all on function public.get_quote_adjustment(uuid, text) from public;
grant execute on function public.get_quote_adjustment(uuid, text) to anon, authenticated;
notify pgrst, 'reload schema';
