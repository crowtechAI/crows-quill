-- submit_enquiry: creates client + commission + quote, reserves the slot.
-- SECURITY DEFINER so the public (anon) site can write these rows despite
-- RLS locking the base tables to authenticated-only.
create or replace function submit_enquiry(
  p_name text, p_email text, p_book_title text, p_slot_id uuid,
  p_commission_type text, p_extra_ids text[], p_brief text
) returns table (commission_id uuid, quote_id uuid, total numeric, deposit numeric, is_estimate boolean)
language plpgsql security definer set search_path = public as $$
declare
  v_client_id uuid;
  v_commission_id uuid;
  v_quote_id uuid;
  v_base numeric;
  v_is_estimate boolean;
  v_extras_total numeric := 0;
  v_total numeric;
  v_deposit numeric;
  v_extra record;
begin
  select base_price, is_estimate into v_base, v_is_estimate
  from commission_types where id = p_commission_type;
  if v_base is null then raise exception 'Unknown commission type'; end if;

  for v_extra in select * from extras where id = any(p_extra_ids) loop
    v_extras_total := v_extras_total + case when v_extra.is_percentage
      then round(v_base * v_extra.percentage / 100) else v_extra.price end;
  end loop;
  v_total := v_base + v_extras_total;
  v_deposit := round(v_total * 0.5);

  insert into clients (name, email, book_title) values (p_name, p_email, p_book_title)
  returning id into v_client_id;

  insert into commissions (client_id, slot_id, commission_type, extra_ids, brief, status, total_price, deposit_amount)
  values (v_client_id, p_slot_id, p_commission_type, coalesce(p_extra_ids, '{}'), p_brief, 'quoted', v_total, v_deposit)
  returning id into v_commission_id;

  if p_slot_id is not null then
    update slots set booked_count = booked_count + 1 where id = p_slot_id;
    update slots set status = 'full' where id = p_slot_id and booked_count >= capacity;
  end if;

  insert into quotes (commission_id, total, deposit, is_estimate)
  values (v_commission_id, v_total, v_deposit, v_is_estimate)
  returning id into v_quote_id;

  return query select v_commission_id, v_quote_id, v_total, v_deposit, v_is_estimate;
end; $$;

-- respond_to_quote: accept/decline; releases the slot on decline.
create or replace function respond_to_quote(p_quote_id uuid, p_response text)
returns void language plpgsql security definer set search_path = public as $$
declare v_commission_id uuid; v_slot_id uuid;
begin
  if p_response not in ('accepted','declined') then raise exception 'Invalid response'; end if;
  update quotes set response = p_response, responded_at = now() where id = p_quote_id
    returning commission_id into v_commission_id;
  if v_commission_id is null then raise exception 'Quote not found'; end if;

  update commissions set status = p_response, updated_at = now()
    where id = v_commission_id
    returning slot_id into v_slot_id;

  if p_response = 'declined' and v_slot_id is not null then
    update slots set booked_count = greatest(booked_count - 1, 0), status = 'open' where id = v_slot_id;
  end if;
end; $$;

-- sign_contract: only allowed once a quote has been accepted.
create or replace function sign_contract(p_commission_id uuid, p_contract_text text, p_signature_name text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_status text; v_id uuid;
begin
  select status into v_status from commissions where id = p_commission_id;
  if v_status is distinct from 'accepted' then
    raise exception 'Commission has not been accepted yet';
  end if;
  insert into contracts (commission_id, contract_text, signature_name)
  values (p_commission_id, p_contract_text, p_signature_name)
  returning id into v_id;
  update commissions set status = 'in_progress', updated_at = now() where id = p_commission_id;
  return v_id;
end; $$;

grant execute on function submit_enquiry to anon, authenticated;
grant execute on function respond_to_quote to anon, authenticated;
grant execute on function sign_contract to anon, authenticated;
