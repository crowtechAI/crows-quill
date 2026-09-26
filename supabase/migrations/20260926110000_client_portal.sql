-- Client/author portal: lets an author check their commission's status and
-- add follow-up notes/files without ever getting read access to the
-- commissions table itself (which stays locked to the studio admin). The
-- commission_id + the email used at enquiry time acts as the access token,
-- matching the trust model the existing add_client_file/add_client_note
-- RPCs already use.

create or replace function public.get_commission_status(p_commission_id uuid, p_email text)
returns table (
  status text,
  commission_type text,
  book_title text,
  total_price numeric,
  deposit_amount numeric,
  deposit_paid boolean,
  balance_paid boolean,
  slot_date date,
  created_at timestamptz,
  notes jsonb,
  files jsonb
)
language plpgsql security definer set search_path = public as $$
declare
  v_client_id uuid;
begin
  select c.id into v_client_id
  from commissions co
  join clients c on c.id = co.client_id
  where co.id = p_commission_id and lower(c.email) = lower(trim(p_email));

  if v_client_id is null then
    raise exception 'No commission found for that reference and email.';
  end if;

  return query
  select
    co.status,
    co.commission_type,
    c.book_title,
    co.total_price,
    co.deposit_amount,
    co.deposit_paid,
    co.balance_paid,
    s.slot_date,
    co.created_at,
    coalesce((
      select jsonb_agg(jsonb_build_object('note', n.note, 'created_by', n.created_by, 'created_at', n.created_at) order by n.created_at)
      from commission_notes n where n.commission_id = co.id
    ), '[]'::jsonb),
    coalesce((
      select jsonb_agg(jsonb_build_object('file_type', f.file_type, 'uploaded_by', f.uploaded_by, 'uploaded_at', f.uploaded_at) order by f.uploaded_at)
      from commission_files f where f.commission_id = co.id
    ), '[]'::jsonb)
  from commissions co
  join clients c on c.id = co.client_id
  left join slots s on s.id = co.slot_id
  where co.id = p_commission_id;
end;
$$;

grant execute on function public.get_commission_status to anon, authenticated;
