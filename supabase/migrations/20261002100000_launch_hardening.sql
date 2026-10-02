-- Launch hardening: Stripe webhook table, deposit-gated "in progress",
-- stricter client file/note RPCs. (Applied to the live project 2026-10-02.)

create table if not exists public.stripe_events (
  id text primary key,
  processed_at timestamptz not null default now()
);
alter table public.stripe_events enable row level security;

-- Signing no longer starts work; the deposit does.
do $mig$
declare
  d text;
  f text;
begin
  foreach f in array array['public.accept_quote_and_sign(uuid,text)', 'public.sign_contract(uuid,text,text)'] loop
    d := pg_get_functiondef(f::regprocedure);
    if position($a$set status = 'in_progress', updated_at = now()$a$ in d) > 0 then
      execute replace(d, $a$set status = 'in_progress', updated_at = now()$a$, $b$set status = 'accepted', updated_at = now()$b$);
    end if;
  end loop;
end
$mig$;

create or replace function public.start_work_on_deposit()
returns trigger language plpgsql security definer set search_path = public as $fn$
begin
  if new.deposit_paid and not coalesce(old.deposit_paid, false)
     and old.status = 'accepted' and new.status = 'accepted' then
    new.status := 'in_progress';
  end if;
  return new;
end
$fn$;

drop trigger if exists commissions_start_work_on_deposit on public.commissions;
create trigger commissions_start_work_on_deposit
  before update of deposit_paid on public.commissions
  for each row execute function public.start_work_on_deposit();

-- Client file records: path must be <commission_id>/<filename>, object must exist, capped at 50.
create or replace function public.add_client_file(p_commission_id uuid, p_file_path text, p_file_type text default 'reference')
returns uuid language plpgsql security definer set search_path to 'public' as $fn$
declare v_id uuid; v_status text; v_name text;
begin
  if p_file_type not in ('reference', 'sketch', 'other') then
    raise exception 'Invalid file type for a client upload';
  end if;
  if p_file_path is null or length(p_file_path) > 400
     or position('/' in p_file_path) = 0
     or split_part(p_file_path, '/', 1) <> p_commission_id::text then
    raise exception 'Invalid file path';
  end if;
  v_name := substr(p_file_path, position('/' in p_file_path) + 1);
  if v_name = '' or v_name in ('.', '..')
     or position('/' in v_name) > 0 or position(E'\\' in v_name) > 0
     or v_name ~ '[[:cntrl:]]' then
    raise exception 'Invalid file path';
  end if;
  select c.status into v_status from commissions c where c.id = p_commission_id;
  if v_status is null or v_status in ('cancelled', 'declined', 'delivered') then
    raise exception 'This commission can no longer accept uploads';
  end if;
  if not exists (select 1 from storage.objects o where o.bucket_id = 'commission-files' and o.name = p_file_path) then
    raise exception 'Uploaded file not found';
  end if;
  if (select count(*) from commission_files f where f.commission_id = p_commission_id and f.uploaded_by = 'client') >= 50 then
    raise exception 'Upload limit reached for this commission';
  end if;
  insert into commission_files (commission_id, file_path, file_type, uploaded_by)
  values (p_commission_id, p_file_path, p_file_type, 'client')
  returning id into v_id;
  return v_id;
end;
$fn$;

-- Client notes: cap at 100 per commission.
create or replace function public.add_client_note(p_commission_id uuid, p_note text)
returns uuid language plpgsql security definer set search_path to 'public' as $fn$
declare v_id uuid; v_status text; v_note text := trim(p_note);
begin
  if v_note is null or char_length(v_note) = 0 then raise exception 'Note is empty'; end if;
  if char_length(v_note) > 5000 then raise exception 'Note is too long (5000 characters max)'; end if;
  select c.status into v_status from commissions c where c.id = p_commission_id;
  if v_status is null or v_status in ('cancelled', 'declined', 'delivered') then
    raise exception 'This commission can no longer accept notes';
  end if;
  if (select count(*) from commission_notes n where n.commission_id = p_commission_id and n.created_by = 'client') >= 100 then
    raise exception 'Note limit reached for this commission - please email the studio';
  end if;
  insert into commission_notes (commission_id, note, created_by)
  values (p_commission_id, v_note, 'client')
  returning id into v_id;
  return v_id;
end;
$fn$;
