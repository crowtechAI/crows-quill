-- USD pricing (converted from the GBP price list at ~1.32, rounded to nearest $5),
-- full extras list (NSFW, alternate expression, merch licence), quote function fixes,
-- and full Art Commission Agreement snapshot stored at signing.
-- Applied to the live project via the Supabase MCP on 2026-10-01.

-- 1) Extras: display + grouping metadata
alter table extras
  add column if not exists sort_order int not null default 0,
  add column if not exists is_from boolean not null default false,
  add column if not exists display_price text,
  add column if not exists option_group text;

-- 2) Commission types: USD
update commission_types set base_price = v.p
from (values
  ('portrait1',100),('half1',125),('full1',165),
  ('portrait2',160),('half2',205),('full2',255),
  ('scenebasic1',230),('scenedetail1',295),('scenebasic2',295),('scenedetail2',365)
) as v(id,p)
where commission_types.id = v.id;

-- 3) Extras: complete price list
insert into extras (id,label,price,is_percentage,percentage,is_from,display_price,option_group,sort_order) values
  ('pet','Small pet / familiar',35,false,null,true,'From +$35',null,1),
  ('creature','Large animal / creature',55,false,null,true,'From +$55',null,2),
  ('expression','Alternate expression',20,false,null,true,'+$20–$35',null,3),
  ('additional','Additional character',80,false,null,true,'From +$80',null,4),
  ('nsfw1','NSFW art — 1 character',35,false,null,true,'From +$35','nsfw',5),
  ('nsfw2','NSFW art — 2 characters',55,false,null,true,'From +$55','nsfw',6),
  ('merch','Commercial merchandise licence',null,true,50,false,'+50%',null,7),
  ('rush','Rush commission',null,true,30,true,'+25–40%',null,8)
on conflict (id) do update set
  label=excluded.label, price=excluded.price, is_percentage=excluded.is_percentage,
  percentage=excluded.percentage, is_from=excluded.is_from, display_price=excluded.display_price,
  option_group=excluded.option_group, sort_order=excluded.sort_order;

-- 4) create_commission_and_quote: percentage extras apply to the original quote (base + fixed extras);
--    line items always add up to the total; "from" extras flag the quote as an estimate;
--    exclusive options (NSFW 1 vs 2 characters) enforced server-side.
create or replace function public.create_commission_and_quote(
  p_slot_id uuid, p_author_name text, p_author_email text, p_book_title text,
  p_commission_type_id text, p_brief text, p_extra_ids text[], p_hp text default ''::text)
returns table(commission_id uuid, quote_id uuid, total numeric, deposit numeric, is_estimate boolean, items jsonb)
language plpgsql security definer set search_path to 'public'
as $function$
#variable_conflict use_column
declare
  v_client_id uuid; v_commission_id uuid; v_quote_id uuid;
  v_base numeric; v_is_estimate boolean; v_type_label text;
  v_fixed numeric := 0; v_pct_sum numeric := 0; v_pct_amt numeric;
  v_sub numeric; v_total numeric; v_deposit numeric;
  v_items jsonb := '[]'::jsonb; v_extra record; v_any_from boolean := false;
  v_capacity int; v_booked int; v_slot_status text; v_recent int; v_dupe int;
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
    select s.capacity, s.booked_count, s.status into v_capacity, v_booked, v_slot_status
      from slots s where s.id = p_slot_id for update;
    if v_capacity is null then raise exception 'Slot not found'; end if;
    if v_slot_status <> 'open' or v_booked >= v_capacity then
      raise exception 'That slot just filled up — please choose another.';
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
$function$;

-- 5) accept_quote_and_sign: stores the full agreement text the client agreed to.
--    Estimated completion = slot week start + 14 days (same rule as the booking page).
create or replace function public.accept_quote_and_sign(p_quote_id uuid, p_signer_name text)
returns uuid
language plpgsql security definer set search_path to 'public'
as $function$
declare
  v_commission_id uuid; v_total numeric; v_deposit numeric; v_id uuid;
  v_signer text := trim(p_signer_name);
  v_type text; v_extras jsonb; v_slot date; v_client text; v_email text; v_book text;
  v_est text; v_licence text; v_text text;
begin
  if char_length(v_signer) < 2 then
    raise exception 'A signature name is required';
  end if;

  select q.commission_id, q.total into v_commission_id, v_total
    from quotes q where q.id = p_quote_id and q.response = 'pending';
  if v_commission_id is null then
    raise exception 'This quote is not awaiting a response';
  end if;

  select co.deposit_amount, ct.label, co.extras, s.slot_date, cl.name, cl.email, cl.book_title
    into v_deposit, v_type, v_extras, v_slot, v_client, v_email, v_book
    from commissions co
    left join commission_types ct on ct.id = co.commission_type
    left join slots s on s.id = co.slot_id
    left join clients cl on cl.id = co.client_id
    where co.id = v_commission_id;

  update quotes set response = 'accepted', responded_at = now() where id = p_quote_id;

  v_est := case when v_slot is null then 'to be confirmed by the Artist'
                else 'around ' || to_char(v_slot + 14, 'DD Mon YYYY') end;
  v_licence := 'Author Promotional Licence' ||
    case when v_extras ? 'merch' then ' + Commercial Merchandise Licence' else '' end;

  v_text :=
    'ART COMMISSION AGREEMENT (v2026-10-01)' || E'\n\n' ||
    'Between The Crow''s Quill (the Artist, contact@crowsquill.art) and ' || coalesce(v_client,'the Client') ||
    ' (' || coalesce(v_email,'') || ')' || case when v_book is not null then ', for ' || v_book else '' end || '.' || E'\n\n' ||
    'THE COMMISSION' || E'\n' ||
    'The Artist will create the artwork described in the commission brief submitted through the website and any later changes agreed by both parties in writing. The brief and supplied references form part of this agreement. All characters depicted must be fictional adults aged 18 or over.' || E'\n' ||
    'Commission type: ' || coalesce(v_type,'') || E'\n' ||
    'Agreed price: $' || v_total || ' USD (50% booking payment of $' || v_deposit || ')' || E'\n' ||
    'Licence: ' || v_licence || E'\n\n' ||
    'FINAL FILES' || E'\n' ||
    'The Client will receive the agreed finished digital artwork in the appropriate high-resolution format, plus any additional versions specifically agreed. Working files, layered files, sketches and source files are not included unless separately agreed.' || E'\n\n' ||
    'PAYMENT' || E'\n' ||
    'A 50% booking payment is due before work begins. The remaining 50% is due before the final high-resolution artwork is delivered. Payment plans may be agreed for larger commissions. If the Client requests work outside the agreed brief, the Artist will confirm any additional cost before carrying out that work. The Client''s usage licence begins once the commission has been paid for in full.' || E'\n\n' ||
    'PROCESS & REVISIONS' || E'\n' ||
    'The Artist will provide a sketch for approval before completing the final artwork. The commission includes two rounds of changes at sketch stage and minor corrections at final stage. One revision round means one consolidated set of requested changes. Once the sketch has been approved, major changes to the pose, composition, clothing, characters, setting or other agreed elements may incur an additional fee. Changes required because the Artist has not followed the agreed brief do not count as revisions.' || E'\n\n' ||
    'TIMESCALE' || E'\n' ||
    'Estimated completion: ' || v_est || '. The Client agrees to provide required information, references and feedback within a reasonable time. If required information or feedback is delayed, the completion date may also move. Any fixed deadline must be agreed before the commission begins.' || E'\n\n' ||
    'CANCELLATION' || E'\n' ||
    'Either party may cancel the commission before completion. If the Client cancels after work has begun, the Artist may retain payment reasonably reflecting the work already completed and any reasonable loss resulting from the cancellation. Any remaining amount will be refunded where applicable. If the Artist is unable to complete the commission, the Client will be refunded for any part of the commission paid for but not supplied. Cancelled or unfinished artwork may not be used by the Client unless separate written permission is given. Either party may end an active commission where the other engages in abusive, threatening or seriously inappropriate behaviour toward the other.' || E'\n\n' ||
    'COPYRIGHT' || E'\n' ||
    'Copyright in the finished artwork remains with the Artist. The Client retains all rights they hold in their characters, books, series, world, text and other underlying intellectual property. Commissioning the artwork does not transfer ownership of either party''s underlying intellectual property to the other. The Artist will not sell, license or otherwise commercially exploit commissioned artwork depicting the Client''s original characters without the Client''s permission.' || E'\n\n' ||
    'USAGE LICENCE' || E'\n' ||
    'Author Promotional Licence (included): the Client may use the finished artwork to promote the relevant book, characters or series, including social media, websites, newsletters, paid advertising, retailer graphics, character reveals, launch and preorder graphics, events and displays, banners, and free bookmarks, postcards, art cards, preorder gifts, reader swag and other promotional material given away free. The Client may crop, resize and add text where reasonably required for promotional use.' || E'\n' ||
    'Commercial Merchandise Licence (only if selected in the quote; flat fee of 50% of the original artwork cost): permits reproduction of the finished artwork on products offered for sale. Copyright remains with the Artist and the Client may not sell, transfer or license the artwork itself to another person or business.' || E'\n' ||
    'Publishing use (covers, dust jackets, endpapers, interior illustrations, special-edition components) is quoted separately and agreed in writing before completion.' || E'\n\n' ||
    'ARTIST PORTFOLIO & PROMOTION' || E'\n' ||
    'The Artist may display the finished artwork on their website, portfolio and social media to promote their work. Where an embargo or reveal date has been agreed in the brief, the Artist will not publicly share the artwork before that date. If no embargo has been agreed, the Artist may share the finished artwork after delivery to the Client.' || E'\n\n' ||
    'AI & ALTERATION' || E'\n' ||
    'The Client may not use the artwork to train generative AI systems or upload the artwork to generative AI services for the purpose of creating replacement or derivative artwork. The Client may not repaint, redraw, retouch, recolour or otherwise alter the artwork without the Artist''s written permission.' || E'\n\n' ||
    'CREDIT' || E'\n' ||
    'Where credit is reasonably practical, the Artist''s preferred credit is "Art by The Crow''s Quill". Credit is appreciated when the artwork itself is being showcased, but is not required on every advertisement, promotional graphic or physical item on which the artwork appears.' || E'\n\n' ||
    'Signed electronically by ' || v_signer || ' on ' || to_char(now() at time zone 'utc', 'DD Mon YYYY HH24:MI') || ' UTC.';

  insert into contracts (commission_id, contract_text, signature_name, agreed, signed_at)
    values (v_commission_id, v_text, v_signer, true, now())
    returning id into v_id;

  update commissions set status = 'in_progress', updated_at = now() where id = v_commission_id;
  return v_id;
end;
$function$;
