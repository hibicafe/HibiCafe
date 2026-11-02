CREATE OR REPLACE FUNCTION public.create_hibi_pos_order(p_source text, p_grab_code text, p_order_date date, p_order_time time without time zone, p_created_at timestamp with time zone, p_subtotal numeric, p_discount_type text, p_discount_amount numeric, p_total numeric, p_payment_method text, p_amount_received numeric, p_cash_amount numeric, p_gcash_amount numeric, p_change_given numeric, p_gcash_ref text, p_status text, p_cashier text, p_items jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
    v_order_id uuid;
    v_order_number integer;
    v_order jsonb;
begin
    -- One atomic transaction: if any item fails, the entire order rolls back.
    v_order_number := nextval('public.hibi_order_number_seq');

    insert into public.pos_orders(
        order_number, order_date, order_time, created_at,
        source, grab_code, subtotal, discount_type, discount_amount,
        total, payment_method, amount_received, cash_amount,
        gcash_amount, change_given, gcash_ref, status, cashier
    )
    values(
        v_order_number, p_order_date, p_order_time, p_created_at,
        coalesce(p_source,'Walk-in'), p_grab_code, coalesce(p_subtotal,0),
        p_discount_type, coalesce(p_discount_amount,0), coalesce(p_total,0),
        p_payment_method, p_amount_received, p_cash_amount, p_gcash_amount,
        coalesce(p_change_given,0), p_gcash_ref,
        coalesce(p_status,'Completed'), p_cashier
    )
    returning id into v_order_id;

    insert into public.pos_order_items(
        order_id, product_id, name, category, size, is_drink,
        qty, unit_price, line_total, addons
    )
    select
        v_order_id,
        item->>'productId',
        coalesce(item->>'name','Unknown'),
        item->>'category',
        item->>'size',
        coalesce((item->>'isDrink')::boolean,false),
        coalesce((item->>'qty')::integer,1),
        coalesce((item->>'unitPrice')::numeric,0),
        coalesce((item->>'lineTotal')::numeric,0),
        coalesce(item->'addons','[]'::jsonb)
    from jsonb_array_elements(coalesce(p_items,'[]'::jsonb)) item;

    select to_jsonb(o) || jsonb_build_object(
        'items', coalesce((
            select jsonb_agg(to_jsonb(i) order by i.id)
            from public.pos_order_items i
            where i.order_id = o.id
        ), '[]'::jsonb)
    )
    into v_order
    from public.pos_orders o
    where o.id = v_order_id;

    return v_order;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_fund_balance_snapshot_for_date(p_business_date date)
 RETURNS TABLE(id uuid, business_date date, snapshot_at timestamp with time zone, cash_balance numeric, gcash_balance numeric, bank_balance numeric, snapshot_type text, notes text, created_by_name text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select s.id, s.business_date, s.snapshot_at, s.cash_balance, s.gcash_balance,
         s.bank_balance, s.snapshot_type, s.notes, s.created_by_name
  from public.fund_balance_snapshots s
  where s.business_date = p_business_date
    and s.snapshot_type = 'reconciliation'
    and auth.uid() is not null
    and public.hibi_has_permission('reports')
  order by s.snapshot_at desc
  limit 1;
$function$
;

CREATE OR REPLACE FUNCTION public.get_latest_fund_balance_snapshot()
 RETURNS TABLE(id uuid, business_date date, snapshot_at timestamp with time zone, cash_balance numeric, gcash_balance numeric, bank_balance numeric, snapshot_type text, notes text, created_by_name text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  select s.id, s.business_date, s.snapshot_at, s.cash_balance, s.gcash_balance,
         s.bank_balance, s.snapshot_type, s.notes, s.created_by_name
  from public.fund_balance_snapshots s
  order by s.snapshot_at desc
  limit 1;
$function$
;

CREATE OR REPLACE FUNCTION public.get_login_email(p_username text)
 RETURNS text
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select u.email
  from public.user_profiles p
  join auth.users u on u.id = p.auth_user_id
  where lower(p.username)=lower(trim(p_username))
    and p.active=true
  limit 1;
$function$
;

CREATE OR REPLACE FUNCTION public.get_next_hibi_order_number()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
declare
    next_num integer;
begin
    next_num := nextval('public.hibi_order_number_seq');
    return next_num;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.guard_hibi_shift_reopen()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF OLD.status = 'Closed' AND NEW.status = 'Open' AND
    current_setting('hibi.reopen_shift_authorized', true) IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'Use the superuser Reopen Shift action to reopen a closed shift.';
  END IF;
  RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.hibi_actor()
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$ SELECT coalesce(nullif(display_name,''),username) FROM user_profiles WHERE auth_user_id=auth.uid() $function$
;

CREATE OR REPLACE FUNCTION public.hibi_audit_row()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_new jsonb; v_old jsonb;
BEGIN
 v_new:=CASE WHEN TG_OP='DELETE' THEN NULL ELSE to_jsonb(NEW) END;
 v_old:=CASE WHEN TG_OP='INSERT' THEN NULL ELSE to_jsonb(OLD) END;
 INSERT INTO audit_logs(auth_user_id,username,action,entity_type,entity_id,reason,details)
 VALUES(auth.uid(),hibi_actor(),'db.'||lower(TG_OP),TG_TABLE_NAME,
 coalesce(v_new->>'id',v_old->>'id',v_new->>'business_date',v_new->>'key',v_new->>'product_id'),
 coalesce(nullif(current_setting('hibi.reason',true),''),v_new->>'void_reason',v_new->>'variance_reason',v_new->>'reason',''),
 jsonb_build_object('before',v_old,'after',v_new));
 RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;
END $function$
;

CREATE OR REPLACE FUNCTION public.hibi_backup()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  result jsonb;
BEGIN
  IF NOT public.hibi_is_superuser() THEN
    RAISE EXCEPTION 'Superuser required';
  END IF;

  SELECT jsonb_build_object(
    'format', 'hibi-application-backup-v2',
    'created_at', now(),
    'tables', jsonb_build_object(
      'user_profiles', coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM public.user_profiles t), '[]'::jsonb),
      'app_data', coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM public.app_data t), '[]'::jsonb),
      'hibi_fee_rates', coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM public.hibi_fee_rates t), '[]'::jsonb),
      'cash_shifts', coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM public.cash_shifts t), '[]'::jsonb),
      'pos_orders', coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM public.pos_orders t), '[]'::jsonb),
      'pos_order_items', coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM public.pos_order_items t), '[]'::jsonb),
      'pos_refunds', coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM public.pos_refunds t), '[]'::jsonb),
      'daily_expenses', coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM public.daily_expenses t), '[]'::jsonb),
      'owner_expenses', coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM public.owner_expenses t), '[]'::jsonb),
      'cash_movements', coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM public.cash_movements t), '[]'::jsonb),
      'eod_reconciliations', coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM public.eod_reconciliations t), '[]'::jsonb),
      'product_availability', coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM public.product_availability t), '[]'::jsonb),
      'online_product_availability', coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM public.online_product_availability t), '[]'::jsonb),
      'online_order_details', coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM public.online_order_details t), '[]'::jsonb),
      'fund_transactions', coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM public.fund_transactions t), '[]'::jsonb),
      'fund_balance_snapshots', coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM public.fund_balance_snapshots t), '[]'::jsonb),
      'monthly_report_settings', coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM public.monthly_report_settings t), '[]'::jsonb),
      'monthly_report_log', coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM public.monthly_report_log t), '[]'::jsonb),
      'hibi_order_refs', coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM public.hibi_order_refs t), '[]'::jsonb),
      'hibi_requests', coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM public.hibi_requests t), '[]'::jsonb),
      'audit_logs', coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM public.audit_logs t), '[]'::jsonb)
    ),
    'sequences', jsonb_build_object(
      'hibi_order_number_seq', (SELECT last_value FROM public.hibi_order_number_seq)
    )
  ) INTO result;

  RETURN result;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.hibi_business_day()
 RETURNS date
 LANGUAGE sql
 STABLE
AS $function$
  select case
    when (now() at time zone 'Asia/Manila')::time < time '03:00'
      then (now() at time zone 'Asia/Manila')::date - 1
    else (now() at time zone 'Asia/Manila')::date
  end;
$function$
;

CREATE OR REPLACE FUNCTION public.hibi_check_day(p_date date)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
 IF NOT hibi_is_active_user() THEN RAISE EXCEPTION 'Active login required'; END IF;
 IF p_date IS NULL OR p_date>hibi_business_day() THEN RAISE EXCEPTION 'Invalid business date'; END IF;
 IF NOT hibi_is_superuser() AND p_date<>hibi_business_day() THEN RAISE EXCEPTION 'Staff cannot change previous dates'; END IF;
 PERFORM pg_advisory_xact_lock(714021, p_date-date '2000-01-01');
 IF EXISTS(SELECT 1 FROM eod_reconciliations WHERE business_date=p_date AND locked) THEN
  RAISE EXCEPTION 'Unlock the reconciled day before making changes'; END IF;
END $function$
;

CREATE OR REPLACE FUNCTION public.hibi_create_online_order(p_payload jsonb, p_details jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_order_id uuid;
  v_order_number integer;
  v_order jsonb;
  v_item jsonb;
  v_subtotal numeric;
  v_total numeric;
  v_sum numeric := 0;
  v_qty integer;
  v_unit numeric;
  v_line numeric;
begin
  if jsonb_typeof(p_payload->'p_items') is distinct from 'array'
     or jsonb_array_length(coalesce(p_payload->'p_items','[]'::jsonb)) = 0 then
    raise exception 'Order requires items';
  end if;
  if p_payload->>'p_source' <> 'Online' then raise exception 'Invalid order source'; end if;
  if p_payload->>'p_service_type' not in ('Dine In','Take Out') then raise exception 'Invalid service type'; end if;
  if p_payload->>'p_payment_method' not in ('Cash','GCash') then raise exception 'Invalid payment method'; end if;
  if p_details->>'payment_provider' not in ('Cash','GCash QR','BPI QR') then raise exception 'Invalid payment provider'; end if;
  if (p_payload->>'p_payment_method'='GCash') is distinct from (p_details->>'payment_provider' in ('GCash QR','BPI QR')) then
    raise exception 'Payment provider mismatch';
  end if;
  if length(btrim(coalesce(p_details->>'customer_name',''))) not between 1 and 100
     or length(btrim(coalesce(p_details->>'customer_phone',''))) > 30
     or length(coalesce(p_details->>'tracking_token_hash','')) <> 64 then
    raise exception 'Invalid customer details';
  end if;

  v_subtotal := (p_payload->>'p_subtotal')::numeric;
  v_total := (p_payload->>'p_total')::numeric;
  if v_subtotal is null or v_total is null or v_subtotal < 0 or v_subtotal > 9999999999.99
     or v_total < 0 or v_total > 9999999999.99 or round(v_subtotal,2) <> round(v_total,2) then
    raise exception 'Invalid online order total';
  end if;
  for v_item in select * from jsonb_array_elements(p_payload->'p_items') loop
    v_qty := (v_item->>'qty')::integer;
    v_unit := (v_item->>'unitPrice')::numeric;
    v_line := (v_item->>'lineTotal')::numeric;
    if v_qty is null or v_qty not between 1 and 20 or v_unit is null or v_unit < 0
       or v_line is null or round(v_line,2) <> round(v_qty*v_unit,2) then
      raise exception 'Invalid online order item';
    end if;
    v_sum := v_sum + v_line;
  end loop;
  if round(v_sum,2) <> round(v_total,2) then raise exception 'Online order item total mismatch'; end if;

  v_order_number := nextval('public.hibi_order_number_seq');
  insert into public.pos_orders(
    order_number, order_date, order_time, created_at, source, subtotal,
    discount_type, discount_amount, total, payment_method, amount_received,
    cash_amount, gcash_amount, change_given, gcash_ref, status, cashier,
    payment_status, service_type, grab_fee_rate
  ) values (
    v_order_number, (p_payload->>'p_order_date')::date,
    (p_payload->>'p_order_time')::time, (p_payload->>'p_created_at')::timestamptz,
    'Online', v_subtotal, null, 0, v_total, p_payload->>'p_payment_method',
    null, null, null, 0, nullif(p_details->>'payment_reference',''),
    'New', 'Online Customer', 'Pending', p_payload->>'p_service_type',
    coalesce((select rate from public.hibi_fee_rates where effective_date <= (p_payload->>'p_order_date')::date order by effective_date desc limit 1),0.25)
  ) returning id into v_order_id;

  insert into public.pos_order_items(order_id,product_id,name,category,size,is_drink,qty,unit_price,line_total,addons)
  select v_order_id, item->>'productId', coalesce(item->>'name','Unknown'), item->>'category',
         item->>'size', coalesce((item->>'isDrink')::boolean,false),
         (item->>'qty')::integer, (item->>'unitPrice')::numeric,
         (item->>'lineTotal')::numeric, coalesce(item->'addons','[]'::jsonb)
  from jsonb_array_elements(p_payload->'p_items') item;

  insert into public.online_order_details(order_id,customer_name,customer_phone,customer_note,payment_provider,payment_reference,tracking_token_hash,pickup_time)
  values(v_order_id,btrim(p_details->>'customer_name'),nullif(btrim(p_details->>'customer_phone'),''),nullif(btrim(p_details->>'customer_note'),''),p_details->>'payment_provider',nullif(btrim(p_details->>'payment_reference'),''),p_details->>'tracking_token_hash',nullif(p_details->>'pickup_time','')::time);

  select to_jsonb(o)||jsonb_build_object('items',coalesce((select jsonb_agg(to_jsonb(i) order by i.id) from public.pos_order_items i where i.order_id=o.id),'[]'::jsonb))
    into v_order from public.pos_orders o where o.id=v_order_id;
  return v_order;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.hibi_create_order_v2(p_request_id uuid, p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
 v_existing hibi_requests%ROWTYPE;
 v_order jsonb;
 v_date date;
 v_item jsonb;
 v_total numeric;
 v_sub numeric;
 v_discount numeric;
 v_sum numeric := 0;
 v_method text;
 v_service_type text;
BEGIN
 IF NOT hibi_is_active_user() THEN RAISE EXCEPTION 'Active login required'; END IF;
 IF p_request_id IS NULL THEN RAISE EXCEPTION 'Submission reference is required'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(p_request_id::text,0));
 SELECT * INTO v_existing FROM hibi_requests WHERE id=p_request_id;
 IF FOUND THEN
  IF v_existing.actor<>auth.uid() OR v_existing.kind<>'order' OR v_existing.payload<>p_payload THEN RAISE EXCEPTION 'Submission reference mismatch'; END IF;
  RETURN v_existing.result;
 END IF;
 IF NOT hibi_has_permission(CASE WHEN p_payload->>'p_source'='GrabFood' THEN 'grab' ELSE 'pos' END) THEN RAISE EXCEPTION 'Order permission required'; END IF;
 v_date:=(p_payload->>'p_order_date')::date;
 PERFORM hibi_check_day(v_date);
 IF v_date=hibi_business_day() AND NOT EXISTS(SELECT 1 FROM cash_shifts WHERE business_date=v_date AND status='Open') THEN RAISE EXCEPTION 'Open a shift first'; END IF;
 IF coalesce(p_payload->>'p_source','') NOT IN ('Walk-in','GrabFood') THEN RAISE EXCEPTION 'Invalid channel'; END IF;

 v_service_type:=nullif(btrim(p_payload->>'p_service_type'),'');
 IF p_payload->>'p_source'='GrabFood' THEN
  IF v_service_type IS NOT NULL AND v_service_type<>'Take Out' THEN RAISE EXCEPTION 'GrabFood orders must be Take Out'; END IF;
  v_service_type:='Take Out';
 ELSIF v_service_type IS NOT NULL AND v_service_type NOT IN ('Dine In','Take Out') THEN
  RAISE EXCEPTION 'Invalid service type';
 END IF;

 v_total:=(p_payload->>'p_total')::numeric;
 v_sub:=(p_payload->>'p_subtotal')::numeric;
 v_discount:=(p_payload->>'p_discount_amount')::numeric;
 IF v_total IS NULL OR v_sub IS NULL OR v_discount IS NULL OR v_total NOT BETWEEN 0 AND 9999999999.99 OR v_sub NOT BETWEEN 0 AND 9999999999.99 OR v_discount NOT BETWEEN 0 AND 9999999999.99 OR v_discount>v_sub OR round(v_total,2)<>round(v_sub-v_discount,2) THEN RAISE EXCEPTION 'Invalid order totals'; END IF;
 IF jsonb_typeof(p_payload->'p_items') IS DISTINCT FROM 'array' OR jsonb_array_length(p_payload->'p_items')=0 THEN RAISE EXCEPTION 'Order requires items'; END IF;
 FOR v_item IN SELECT * FROM jsonb_array_elements(p_payload->'p_items') LOOP
  IF (v_item->>'qty')::numeric IS NULL OR (v_item->>'qty')::numeric NOT BETWEEN 1 AND 10000 OR (v_item->>'qty')::numeric<>trunc((v_item->>'qty')::numeric) OR
   (v_item->>'unitPrice')::numeric IS NULL OR (v_item->>'unitPrice')::numeric NOT BETWEEN 0 AND 9999999999.99 OR (v_item->>'lineTotal')::numeric IS NULL OR
   round((v_item->>'lineTotal')::numeric,2)<>round((v_item->>'qty')::numeric*(v_item->>'unitPrice')::numeric,2) THEN RAISE EXCEPTION 'Invalid item quantity or price'; END IF;
  v_sum:=v_sum+(v_item->>'lineTotal')::numeric;
 END LOOP;
 -- Loyalty rewards are already reduced in item lines; ordinary discounts are order-level.
 IF round(v_sum,2)<round(v_total,2) OR round(v_sum,2)>round(v_sub,2) THEN RAISE EXCEPTION 'Item totals do not match order'; END IF;
 v_method:=p_payload->>'p_payment_method';
 IF v_method IS NULL OR v_method NOT IN ('Cash','GCash','Cash + GCash','GrabFood') THEN RAISE EXCEPTION 'Invalid payment method'; END IF;
 IF (p_payload->>'p_source'='GrabFood') IS DISTINCT FROM (v_method='GrabFood') THEN RAISE EXCEPTION 'Payment does not match channel'; END IF;
 IF v_method='Cash + GCash' AND (coalesce((p_payload->>'p_cash_amount')::numeric,-1)<0 OR coalesce((p_payload->>'p_gcash_amount')::numeric,-1)<0 OR round((p_payload->>'p_cash_amount')::numeric+(p_payload->>'p_gcash_amount')::numeric,2)<>round(v_total,2)) THEN RAISE EXCEPTION 'Split payments do not match total'; END IF;
 IF v_method IN ('Cash','Cash + GCash') AND (coalesce((p_payload->>'p_amount_received')::numeric,-1)<v_total OR round((p_payload->>'p_amount_received')::numeric-v_total,2)<>round(coalesce((p_payload->>'p_change_given')::numeric,-1),2)) THEN RAISE EXCEPTION 'Invalid tender or change'; END IF;
 IF v_method='GrabFood' AND nullif(btrim(p_payload->>'p_grab_code'),'') IS NULL THEN RAISE EXCEPTION 'Grab reference required'; END IF;

 v_order:=create_hibi_pos_order(p_payload->>'p_source',p_payload->>'p_grab_code',v_date,
  (now() AT TIME ZONE 'Asia/Manila')::time,now(),v_sub,p_payload->>'p_discount_type',v_discount,v_total,v_method,
  (p_payload->>'p_amount_received')::numeric,(p_payload->>'p_cash_amount')::numeric,(p_payload->>'p_gcash_amount')::numeric,
  (p_payload->>'p_change_given')::numeric,p_payload->>'p_gcash_ref','Preparing',hibi_actor(),p_payload->'p_items');
 UPDATE pos_orders
 SET created_by=auth.uid(),
     service_type=v_service_type,
     grab_fee_rate=coalesce((SELECT rate FROM hibi_fee_rates WHERE effective_date<=v_date ORDER BY effective_date DESC LIMIT 1),0.25)
 WHERE id=(v_order->>'id')::uuid;
 SELECT to_jsonb(o)||jsonb_build_object('items',v_order->'items') INTO v_order FROM pos_orders o WHERE id=(v_order->>'id')::uuid;
 INSERT INTO hibi_requests(id,actor,kind,payload,result) VALUES(p_request_id,auth.uid(),'order',p_payload,v_order);
 RETURN v_order;
END
$function$
;

CREATE OR REPLACE FUNCTION public.hibi_day_money(p_date date, p_start timestamp with time zone DEFAULT NULL::timestamp with time zone, p_end timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
 WITH o AS (SELECT * FROM pos_orders WHERE order_date=p_date AND payment_status<>'LegacyCancelled' AND status NOT IN ('Cancelled','LegacyCancelled')
 AND (p_start IS NULL OR created_at>=p_start) AND (p_end IS NULL OR created_at<=p_end)),
 r AS (SELECT r.* FROM pos_refunds r
 WHERE business_date=p_date AND kind='Refund' AND (to_jsonb(r)->>'voided_at') IS NULL
 AND EXISTS (SELECT 1 FROM pos_orders original WHERE original.id=r.order_id
   AND original.status NOT IN ('Cancelled','LegacyCancelled') AND original.payment_status<>'LegacyCancelled') AND (p_start IS NULL OR created_at>=p_start) AND (p_end IS NULL OR created_at<=p_end)),
 e AS (SELECT * FROM daily_expenses WHERE business_date=p_date AND status<>'Voided' AND (p_start IS NULL OR created_at>=p_start) AND (p_end IS NULL OR created_at<=p_end)),
 c AS (SELECT * FROM cash_movements WHERE business_date=p_date AND status<>'Voided' AND (p_start IS NULL OR created_at>=p_start) AND (p_end IS NULL OR created_at<=p_end))
 SELECT jsonb_build_object(
 'cash',coalesce((SELECT sum(CASE payment_method WHEN 'Cash' THEN total WHEN 'Cash + GCash' THEN cash_amount ELSE 0 END) FROM o),0)-coalesce((SELECT sum(cash_amount) FROM r),0),
 'gcash',coalesce((SELECT sum(CASE payment_method WHEN 'GCash' THEN total WHEN 'Cash + GCash' THEN gcash_amount ELSE 0 END) FROM o),0)-coalesce((SELECT sum(gcash_amount) FROM r),0),
 'grab',coalesce((SELECT sum(CASE payment_method WHEN 'GrabFood' THEN total ELSE 0 END) FROM o),0)-coalesce((SELECT sum(grab_amount) FROM r),0),
 'expenses',coalesce((SELECT sum(amount) FROM e),0),'in',coalesce((SELECT sum(amount) FROM c WHERE movement_type='In'),0),'out',coalesce((SELECT sum(amount) FROM c WHERE movement_type='Out'),0),
 'transactions',(SELECT count(*) FROM o),'cups',coalesce((SELECT sum(i.qty) FROM pos_order_items i JOIN o ON o.id=i.order_id WHERE i.is_drink AND o.status<>'Cancelled'),0))
 $function$
;

CREATE OR REPLACE FUNCTION public.hibi_financial_guard_v2()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE d date; oldj jsonb; newj jsonb; m jsonb; opening numeric; expected numeric;
BEGIN
 newj:=to_jsonb(NEW); d:=(newj->>'business_date')::date;
 IF TG_OP='UPDATE' THEN oldj:=to_jsonb(OLD); END IF;
 IF NOT hibi_is_active_user() THEN RAISE EXCEPTION 'Active login required'; END IF;
 -- Serialize all drawer activity and reconciliation for the day.
 PERFORM pg_advisory_xact_lock(714021,d-date '2000-01-01');
 IF TG_OP='UPDATE' AND (oldj->>'business_date') IS DISTINCT FROM (newj->>'business_date') THEN RAISE EXCEPTION 'Business date cannot change'; END IF;
 IF TG_TABLE_NAME='eod_reconciliations' THEN
  IF TG_OP='UPDATE' AND OLD.locked THEN
   IF NOT hibi_is_superuser() OR NEW.locked OR (newj-'locked'-'unlocked_at'-'unlocked_by'-'updated_at'-'updated_by') IS DISTINCT FROM (oldj-'locked'-'unlocked_at'-'unlocked_by'-'updated_at'-'updated_by') THEN RAISE EXCEPTION 'Unlock the day before editing it'; END IF;
   RETURN NEW;
  END IF;
  PERFORM hibi_check_day(d);
  IF EXISTS(SELECT 1 FROM cash_shifts WHERE business_date=d AND status='Open') THEN RAISE EXCEPTION 'Close the open shift first'; END IF;
  IF NEW.actual IS NULL OR NEW.actual NOT BETWEEN 0 AND 9999999999.99 THEN RAISE EXCEPTION 'Actual cash counted is required'; END IF;
  SELECT opening_cash INTO opening FROM cash_shifts WHERE business_date=d ORDER BY shift_number LIMIT 1;
  IF opening IS NULL THEN SELECT actual INTO opening FROM eod_reconciliations WHERE business_date=d-1; END IF;
  opening:=coalesce(opening,0);
  IF NEW.opening IS DISTINCT FROM opening THEN RAISE EXCEPTION 'Opening must equal the first shift opening or previous actual cash'; END IF;
  m:=hibi_day_money(d); expected:=NEW.opening+(m->>'cash')::numeric+(m->>'in')::numeric-(m->>'out')::numeric-(m->>'expenses')::numeric;
  IF abs(coalesce(NEW.expected,-999999)-expected)>.005 THEN RAISE EXCEPTION 'Drawer activity changed. Refresh before reconciling'; END IF;
  NEW.expected:=expected; NEW.variance:=NEW.actual-expected;
  NEW.total_cash_sales:=(m->>'cash')::numeric; NEW.total_gcash_sales:=(m->>'gcash')::numeric;
  NEW.total_expenses:=(m->>'expenses')::numeric; NEW.cash_in:=(m->>'in')::numeric; NEW.cash_out:=(m->>'out')::numeric;
  IF abs(NEW.variance)>=.005 AND nullif(btrim(NEW.variance_reason),'') IS NULL THEN RAISE EXCEPTION 'Variance reason required'; END IF;
  NEW.locked:=true; NEW.reconciled_by:=hibi_actor(); NEW.reconciled_at:=now(); RETURN NEW;
 END IF;
 PERFORM hibi_check_day(d);
 IF TG_TABLE_NAME='cash_shifts' THEN
  IF TG_OP='UPDATE' AND (newj-'status'-'closed_at'-'closed_by'-'expected_cash'-'actual_cash_counted'-'variance'-'variance_reason'-'cash_sales'-'gcash_sales'-'grab_sales'-'cash_in'-'cash_out'-'expenses'-'transaction_count'-'cups_sold'-'updated_at') IS DISTINCT FROM (oldj-'status'-'closed_at'-'closed_by'-'expected_cash'-'actual_cash_counted'-'variance'-'variance_reason'-'cash_sales'-'gcash_sales'-'grab_sales'-'cash_in'-'cash_out'-'expenses'-'transaction_count'-'cups_sold'-'updated_at') THEN RAISE EXCEPTION 'Shift opening details cannot be rewritten'; END IF;
  IF TG_OP='INSERT' THEN IF NEW.opening_cash NOT BETWEEN 0 AND 9999999999.99 THEN RAISE EXCEPTION 'Invalid opening cash'; END IF; NEW.opened_by:=hibi_actor(); NEW.opened_at:=now(); RETURN NEW; END IF;
  IF OLD.status='Closed' AND NEW.status<>'Open' THEN RAISE EXCEPTION 'Reopen a closed shift before making changes'; END IF;
  IF NEW.status='Closed' AND OLD.status='Open' THEN
   IF NEW.actual_cash_counted IS NULL OR NEW.actual_cash_counted NOT BETWEEN 0 AND 9999999999.99 THEN RAISE EXCEPTION 'Enter a valid actual cash count'; END IF;
   NEW.closed_at:=now(); NEW.closed_by:=hibi_actor(); m:=hibi_day_money(d,NEW.opened_at,NEW.closed_at);
   expected:=NEW.opening_cash+(m->>'cash')::numeric+(m->>'in')::numeric-(m->>'out')::numeric-(m->>'expenses')::numeric;
   IF abs(coalesce(NEW.expected_cash,-999999)-expected)>.005 THEN RAISE EXCEPTION 'Drawer activity changed. Refresh before closing'; END IF;
   NEW.expected_cash:=expected; NEW.variance:=NEW.actual_cash_counted-expected;
   NEW.cash_sales:=(m->>'cash')::numeric; NEW.gcash_sales:=(m->>'gcash')::numeric; NEW.grab_sales:=(m->>'grab')::numeric;
   NEW.cash_in:=(m->>'in')::numeric;NEW.cash_out:=(m->>'out')::numeric;NEW.expenses:=(m->>'expenses')::numeric;
   NEW.transaction_count:=(m->>'transactions')::integer;NEW.cups_sold:=(m->>'cups')::integer;
  END IF;
  RETURN NEW;
 END IF;
 IF d=hibi_business_day() AND TG_TABLE_NAME<>'owner_expenses' AND NOT EXISTS(SELECT 1 FROM cash_shifts WHERE business_date=d AND status='Open') THEN RAISE EXCEPTION 'Open a shift first'; END IF;
 IF TG_OP='INSERT' THEN
  IF NEW.status<>'Active' OR NEW.amount NOT BETWEEN .01 AND 9999999999.99 THEN RAISE EXCEPTION 'Enter a positive amount for an active record'; END IF;
  IF TG_TABLE_NAME='owner_expenses' THEN NEW.entered_by:=hibi_actor(); ELSE NEW.cashier:=hibi_actor(); END IF;
  NEW.created_at:=now(); NEW.created_by:=auth.uid(); RETURN NEW; END IF;
 IF (newj-'status'-'voided_at'-'voided_by'-'void_reason') IS DISTINCT FROM (oldj-'status'-'voided_at'-'voided_by'-'void_reason') THEN RAISE EXCEPTION 'Void and re-enter a financial record instead of rewriting it'; END IF;
 IF OLD.status='Voided' OR NEW.status<>'Voided' OR nullif(btrim(NEW.void_reason),'') IS NULL THEN RAISE EXCEPTION 'A valid void reason is required'; END IF;
 NEW.voided_at:=now(); NEW.voided_by:=hibi_actor(); RETURN NEW;
END $function$
;

CREATE OR REPLACE FUNCTION public.hibi_has_permission(p_permission text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
  select exists (
    select 1
    from public.user_profiles p
    where p.auth_user_id = auth.uid()
      and coalesce(p.active, true) = true
      and (
        p.role = 'superuser'
        or coalesce((to_jsonb(p.permissions) ->> p_permission)::boolean, false)
      )
  );
$function$
;

CREATE OR REPLACE FUNCTION public.hibi_is_active_user()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
  select exists (
    select 1
    from public.user_profiles p
    where p.auth_user_id = auth.uid()
      and coalesce(p.active, true) = true
  );
$function$
;

CREATE OR REPLACE FUNCTION public.hibi_is_superuser()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
  select exists (
    select 1
    from public.user_profiles p
    where p.auth_user_id = auth.uid()
      and coalesce(p.active, true) = true
      and p.role = 'superuser'
  );
$function$
;

CREATE OR REPLACE FUNCTION public.hibi_order_status(p_id uuid, p_status text, p_reason text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE o pos_orders%ROWTYPE;
BEGIN
 IF NOT hibi_has_permission('orders') THEN RAISE EXCEPTION 'Order permission required'; END IF;
 SELECT * INTO o FROM pos_orders WHERE id=p_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Order not found'; END IF;
 PERFORM hibi_check_day(o.order_date);
 SELECT * INTO o FROM pos_orders WHERE id=p_id FOR UPDATE;
 IF p_status=o.status THEN RETURN to_jsonb(o); END IF;
 IF p_status NOT IN ('Preparing','Completed') OR o.status='Cancelled' THEN RAISE EXCEPTION 'Use the cancellation/refund action'; END IF;
 IF p_status='Preparing' AND NOT hibi_is_superuser() THEN RAISE EXCEPTION 'Only a superuser may reopen preparation'; END IF;
 PERFORM set_config('hibi.reason',coalesce(p_reason,''),true);
 UPDATE pos_orders SET status=p_status,completed_at=CASE WHEN p_status='Completed' THEN now() ELSE NULL END WHERE id=p_id RETURNING * INTO o;
 RETURN to_jsonb(o);
END $function$
;

CREATE OR REPLACE FUNCTION public.hibi_protect_eod_update()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
begin
  if public.hibi_is_superuser() then return new; end if;
  if old.business_date is distinct from new.business_date then
    raise exception 'Business date cannot be changed';
  end if;
  if old.locked then
    raise exception 'Reconciled day is locked';
  end if;
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.hibi_protect_financial_update()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
begin
  if public.hibi_is_superuser() then return new; end if;

  if tg_table_name='daily_expenses' then
    if old.status='Voided' then raise exception 'Voided expense records are immutable'; end if;
    if new.id is distinct from old.id
       or new.business_date is distinct from old.business_date
       or new.entry_time is distinct from old.entry_time
       or new.created_at is distinct from old.created_at
       or new.amount is distinct from old.amount
       or new.note is distinct from old.note
       or new.cashier is distinct from old.cashier then
      raise exception 'Staff cannot rewrite expense financial fields';
    end if;
  elsif tg_table_name='cash_movements' then
    if old.status='Voided' then raise exception 'Voided cash movement records are immutable'; end if;
    if new.id is distinct from old.id
       or new.business_date is distinct from old.business_date
       or new.entry_time is distinct from old.entry_time
       or new.created_at is distinct from old.created_at
       or new.movement_type is distinct from old.movement_type
       or new.amount is distinct from old.amount
       or new.reason is distinct from old.reason
       or new.cashier is distinct from old.cashier then
      raise exception 'Staff cannot rewrite cash movement financial fields';
    end if;
  end if;

  if new.status='Voided' and coalesce(nullif(new.void_reason,''),'')='' then
    raise exception 'Void reason is required';
  end if;
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.hibi_protect_profile()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
 IF hibi_is_superuser() THEN RETURN NEW; END IF;
 IF TG_OP<>'UPDATE' OR OLD.auth_user_id<>auth.uid() OR
 (to_jsonb(NEW)-'display_name'-'updated_at') IS DISTINCT FROM (to_jsonb(OLD)-'display_name'-'updated_at') THEN
 RAISE EXCEPTION 'Only a superuser may change roles, account status or permissions'; END IF;
 RETURN NEW;
END $function$
;

CREATE OR REPLACE FUNCTION public.hibi_protect_shift_update()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
begin
  if old.status='Closed' and not public.hibi_is_superuser() then
    raise exception 'Closed shifts are immutable';
  end if;

  if not public.hibi_is_superuser() then
    if new.id is distinct from old.id
       or new.business_date is distinct from old.business_date
       or new.shift_number is distinct from old.shift_number
       or new.shift_name is distinct from old.shift_name
       or new.opened_at is distinct from old.opened_at
       or new.opened_by is distinct from old.opened_by
       or new.opening_cash is distinct from old.opening_cash then
      raise exception 'Staff cannot rewrite shift opening details';
    end if;
  end if;

  if old.status='Open' and new.status='Closed' then
    if new.closed_at is null or coalesce(new.closed_by,'')='' then
      raise exception 'Closed shift requires closed time and user';
    end if;
    if new.expected_cash is null or new.actual_cash_counted is null or new.variance is null then
      raise exception 'Closed shift requires expected, actual and variance amounts';
    end if;
    if abs(new.variance) >= 0.005 and coalesce(nullif(new.variance_reason,''),'')='' then
      raise exception 'Variance reason is required';
    end if;
  elsif new.status is distinct from old.status and not public.hibi_is_superuser() then
    raise exception 'Invalid shift status transition';
  end if;

  new.updated_at := now();
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.hibi_refund(p_request_id uuid, p_order_id uuid, p_cash numeric, p_gcash numeric, p_grab numeric, p_kind text, p_prepared boolean, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE o pos_orders%ROWTYPE; v_date date:=hibi_business_day(); v_sum numeric; v_prev numeric;
  r pos_refunds%ROWTYPE; v_req hibi_requests%ROWTYPE;
  v_payload jsonb:=jsonb_build_object('order',p_order_id,'cash',p_cash,'gcash',p_gcash,'grab',p_grab,'kind',p_kind,'prepared',p_prepared,'reason',p_reason);
BEGIN
  IF NOT hibi_has_permission('orders') THEN RAISE EXCEPTION 'Order permission required for refunds and cancellations'; END IF;
  IF p_request_id IS NULL THEN RAISE EXCEPTION 'Submission reference required'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(p_request_id::text,0));
  SELECT * INTO v_req FROM hibi_requests WHERE id=p_request_id;
  IF FOUND THEN
    IF v_req.actor<>auth.uid() OR v_req.kind<>'refund' OR v_req.payload<>v_payload THEN RAISE EXCEPTION 'Submission reference mismatch'; END IF;
    RETURN v_req.result;
  END IF;
  PERFORM hibi_check_day(v_date);
  IF NOT EXISTS(SELECT 1 FROM cash_shifts WHERE business_date=v_date AND status='Open') THEN RAISE EXCEPTION 'Open a shift before returning money'; END IF;
  SELECT * INTO o FROM pos_orders WHERE id=p_order_id FOR UPDATE;
  IF NOT FOUND OR o.payment_status='LegacyCancelled' THEN RAISE EXCEPTION 'Order is unavailable for refund'; END IF;
  IF NOT hibi_is_superuser() AND o.order_date<>v_date THEN RAISE EXCEPTION 'Cashiers may refund or cancel current-day orders only'; END IF;
  IF p_prepared IS NULL OR p_kind NOT IN ('Refund','Cancellation') OR nullif(btrim(p_reason),'') IS NULL THEN RAISE EXCEPTION 'Kind, preparation state and reason required'; END IF;
  IF p_cash IS NULL OR p_gcash IS NULL OR p_grab IS NULL OR p_cash NOT BETWEEN 0 AND 9999999999.99 OR p_gcash NOT BETWEEN 0 AND 9999999999.99 OR p_grab NOT BETWEEN 0 AND 9999999999.99 OR round(p_cash,2)<>p_cash OR round(p_gcash,2)<>p_gcash OR round(p_grab,2)<>p_grab THEN RAISE EXCEPTION 'Invalid refund amounts'; END IF;
  v_sum:=p_cash+p_gcash+p_grab;
  SELECT coalesce(sum(amount),0) INTO v_prev FROM pos_refunds WHERE order_id=p_order_id AND voided_at IS NULL;
  IF (v_sum=0 AND NOT (p_kind='Cancellation' AND o.total=0)) OR v_sum+v_prev>o.total THEN RAISE EXCEPTION 'Refund exceeds remaining paid amount'; END IF;
  IF (o.source='GrabFood' AND p_cash+p_gcash<>0) OR (o.source<>'GrabFood' AND p_grab<>0) THEN RAISE EXCEPTION 'Refund method must match channel'; END IF;
  IF p_cash+coalesce((SELECT sum(cash_amount) FROM pos_refunds WHERE order_id=p_order_id AND voided_at IS NULL),0)>(CASE o.payment_method WHEN 'Cash' THEN o.total WHEN 'Cash + GCash' THEN o.cash_amount ELSE 0 END) OR
     p_gcash+coalesce((SELECT sum(gcash_amount) FROM pos_refunds WHERE order_id=p_order_id AND voided_at IS NULL),0)>(CASE o.payment_method WHEN 'GCash' THEN o.total WHEN 'Cash + GCash' THEN o.gcash_amount ELSE 0 END) THEN RAISE EXCEPTION 'Refund exceeds amount originally paid by that method'; END IF;
  IF p_kind='Cancellation' AND (o.status NOT IN ('New','Preparing') OR o.order_date<>v_date OR v_sum+v_prev<>o.total) THEN RAISE EXCEPTION 'Cancellation requires the full remaining payment of a current-day preparing order'; END IF;
  PERFORM set_config('hibi.reason',p_reason,true);
  INSERT INTO pos_refunds(order_id,business_date,amount,cash_amount,gcash_amount,grab_amount,kind,prepared,reason,approved_by,approved_by_name)
  VALUES(p_order_id,v_date,v_sum,p_cash,p_gcash,p_grab,p_kind,p_prepared,p_reason,auth.uid(),hibi_actor()) RETURNING * INTO r;
  UPDATE pos_orders SET payment_status=CASE WHEN v_sum+v_prev=total THEN 'Refunded' ELSE 'PartiallyRefunded' END,status=CASE WHEN p_kind='Cancellation' THEN 'Cancelled' ELSE status END WHERE id=p_order_id;
  INSERT INTO hibi_requests(id,actor,kind,payload,result) VALUES(p_request_id,auth.uid(),'refund',v_payload,to_jsonb(r));
  RETURN to_jsonb(r);
END $function$
;

CREATE OR REPLACE FUNCTION public.hibi_resolve_request(p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE r hibi_requests%ROWTYPE;
BEGIN
 IF NOT hibi_is_active_user() THEN RAISE EXCEPTION 'Active login required'; END IF;
 IF p_request_id IS NULL THEN RAISE EXCEPTION 'Request reference required'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(p_request_id::text,0));
 SELECT * INTO r FROM hibi_requests WHERE id=p_request_id;
 IF FOUND THEN
  IF r.actor<>auth.uid() THEN RAISE EXCEPTION 'This request belongs to another user'; END IF;
  RETURN jsonb_build_object('state',CASE WHEN r.kind='abandoned' THEN 'not_saved' ELSE 'saved' END,'kind',r.kind,'result',r.result);
 END IF;
 INSERT INTO hibi_requests(id,actor,kind,payload,result) VALUES(p_request_id,auth.uid(),'abandoned','{}','{}');
 RETURN jsonb_build_object('state','not_saved');
END $function$
;

CREATE OR REPLACE FUNCTION public.hibi_set_fee(p_date date, p_rate numeric)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
 IF NOT hibi_is_superuser() THEN RAISE EXCEPTION 'Superuser required'; END IF;
 IF p_date<hibi_business_day() OR p_date IS NULL OR p_rate IS NULL OR p_rate NOT BETWEEN 0 AND 1 THEN RAISE EXCEPTION 'Use today or a future date and a rate between 0 and 100 percent'; END IF;
 INSERT INTO hibi_fee_rates VALUES(p_date,p_rate) ON CONFLICT(effective_date) DO UPDATE SET rate=excluded.rate;
END $function$
;

CREATE OR REPLACE FUNCTION public.hibi_snapshot(p_start date, p_end date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE result jsonb; v_sales boolean; v_fin boolean;
BEGIN
 IF NOT hibi_is_active_user() THEN RAISE EXCEPTION 'Active login required'; END IF;
 v_sales:=hibi_has_permission('orders') OR hibi_has_permission('reports') OR hibi_has_permission('dashboard');
 v_fin:=hibi_has_permission('expenses') OR hibi_has_permission('reports') OR hibi_has_permission('dashboard');
 IF p_start IS NULL OR p_end IS NULL OR p_end<p_start OR p_start<date '1900-01-01' THEN RAISE EXCEPTION 'Choose a valid date range from 1900 onward'; END IF;
 SELECT jsonb_build_object(
 'orders',coalesce((SELECT jsonb_agg(to_jsonb(o)||jsonb_build_object('pos_order_items',coalesce((SELECT jsonb_agg(to_jsonb(i)) FROM pos_order_items i WHERE i.order_id=o.id),'[]'::jsonb))) FROM pos_orders o WHERE v_sales AND order_date BETWEEN p_start AND p_end),'[]'::jsonb),
 'refunds',coalesce((SELECT jsonb_agg(to_jsonb(r)||jsonb_build_object('order',to_jsonb(o)||jsonb_build_object('pos_order_items',coalesce((SELECT jsonb_agg(to_jsonb(i)) FROM pos_order_items i WHERE i.order_id=o.id),'[]'::jsonb)))) FROM pos_refunds r JOIN pos_orders o ON o.id=r.order_id WHERE v_sales AND r.business_date BETWEEN p_start AND p_end),'[]'::jsonb),
 'expenses',coalesce((SELECT jsonb_agg(to_jsonb(e)) FROM daily_expenses e WHERE v_fin AND business_date BETWEEN p_start AND p_end),'[]'::jsonb),
 'ownerExpenses',CASE WHEN hibi_is_superuser() THEN coalesce((SELECT jsonb_agg(to_jsonb(e)) FROM owner_expenses e WHERE business_date BETWEEN p_start AND p_end),'[]'::jsonb) ELSE '[]'::jsonb END,
 'cashMovements',coalesce((SELECT jsonb_agg(to_jsonb(e)) FROM cash_movements e WHERE v_fin AND business_date BETWEEN p_start AND p_end),'[]'::jsonb),
 'eod',coalesce((SELECT jsonb_agg(CASE WHEN v_fin THEN to_jsonb(e) ELSE jsonb_build_object('business_date',e.business_date,'locked',e.locked) END) FROM eod_reconciliations e WHERE business_date BETWEEN p_start-1 AND p_end),'[]'::jsonb),
 'shifts',coalesce((SELECT jsonb_agg(CASE WHEN v_fin THEN to_jsonb(e) ELSE jsonb_build_object('id',e.id,'business_date',e.business_date,'shift_number',e.shift_number,'shift_name',e.shift_name,'status',e.status,'opened_at',e.opened_at,'opened_by',e.opened_by) END) FROM cash_shifts e WHERE business_date BETWEEN p_start-1 AND p_end),'[]'::jsonb),
 'fees',coalesce((SELECT jsonb_agg(to_jsonb(f) ORDER BY effective_date) FROM hibi_fee_rates f),'[]'::jsonb),
 'nextOrderNumber',(SELECT coalesce(max(order_number),0)+1 FROM pos_orders)
 ) INTO result;
 RETURN result;
END $function$
;

CREATE OR REPLACE FUNCTION public.hibi_validate_shift_insert()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  v_expected_number integer;
  v_prior_actual numeric(12,2);
  v_prev_eod_actual numeric(12,2);
  v_locked boolean;
begin
  if new.business_date <> public.hibi_business_day() and not public.hibi_is_superuser() then
    raise exception 'Staff can only open a shift for the current Hibi business day';
  end if;

  select coalesce(max(s.shift_number),0)+1
    into v_expected_number
  from public.cash_shifts s
  where s.business_date=new.business_date;

  if new.shift_number <> v_expected_number then
    raise exception 'Next shift number must be %', v_expected_number;
  end if;

  select coalesce(r.locked,false)
    into v_locked
  from public.eod_reconciliations r
  where r.business_date=new.business_date;

  if coalesce(v_locked,false) then
    raise exception 'This business day is already reconciled and locked';
  end if;

  select s.actual_cash_counted
    into v_prior_actual
  from public.cash_shifts s
  where s.business_date=new.business_date
    and s.status='Closed'
    and s.actual_cash_counted is not null
  order by s.shift_number desc
  limit 1;

  if v_prior_actual is not null then
    if abs(coalesce(new.opening_cash,0)-v_prior_actual) >= 0.005 then
      raise exception 'Opening cash must equal the previous shift actual cash counted (%)', v_prior_actual;
    end if;
  else
    select r.actual
      into v_prev_eod_actual
    from public.eod_reconciliations r
    where r.business_date=new.business_date - 1;

    if v_prev_eod_actual is not null
       and abs(coalesce(new.opening_cash,0)-v_prev_eod_actual) >= 0.005 then
      raise exception 'Opening cash must equal the previous business day actual cash counted (%)', v_prev_eod_actual;
    end if;
  end if;

  new.status := 'Open';
  new.closed_at := null;
  new.closed_by := null;
  new.expected_cash := null;
  new.actual_cash_counted := null;
  new.variance := null;
  new.variance_reason := null;
  new.updated_at := now();
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.hibi_void_refund(p_request_id uuid, p_refund_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE r pos_refunds%ROWTYPE; v_req hibi_requests%ROWTYPE; v_payload jsonb:=jsonb_build_object('refund',p_refund_id,'reason',p_reason);
BEGIN
  IF NOT hibi_is_superuser() THEN RAISE EXCEPTION 'Only a superuser may correct a refund'; END IF;
  IF p_request_id IS NULL OR p_refund_id IS NULL OR nullif(btrim(p_reason),'') IS NULL THEN RAISE EXCEPTION 'Refund, reference and reason required'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(p_request_id::text,0));
  SELECT * INTO v_req FROM hibi_requests WHERE id=p_request_id;
  IF FOUND THEN
    IF v_req.actor<>auth.uid() OR v_req.kind<>'refund_void' OR v_req.payload<>v_payload THEN RAISE EXCEPTION 'Submission reference mismatch'; END IF;
    RETURN v_req.result;
  END IF;
  SELECT * INTO r FROM pos_refunds WHERE id=p_refund_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Refund not found'; END IF;
  IF r.voided_at IS NOT NULL THEN RAISE EXCEPTION 'Refund is already voided'; END IF;
  PERFORM hibi_check_day(r.business_date);
  PERFORM set_config('hibi.reason',p_reason,true);
  UPDATE pos_refunds SET voided_at=now(),voided_by=auth.uid(),void_reason=p_reason WHERE id=p_refund_id RETURNING * INTO r;
  UPDATE pos_orders o SET payment_status=CASE WHEN coalesce((SELECT sum(amount) FROM pos_refunds x WHERE x.order_id=o.id AND x.voided_at IS NULL),0)=0 THEN 'Paid' ELSE 'PartiallyRefunded' END,
    status=CASE WHEN r.kind='Cancellation' THEN 'Preparing' ELSE o.status END
    WHERE o.id=r.order_id;
  INSERT INTO hibi_requests(id,actor,kind,payload,result) VALUES(p_request_id,auth.uid(),'refund_void',v_payload,to_jsonb(r));
  RETURN to_jsonb(r);
END $function$
;

CREATE OR REPLACE FUNCTION public.is_superuser()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (
    select 1
    from public.user_profiles
    where auth_user_id = auth.uid()
      and role = 'superuser'
      and active = true
  );
$function$
;

CREATE OR REPLACE FUNCTION public.reopen_hibi_shift(p_shift_id text, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_shift public.cash_shifts%ROWTYPE;
  v_profile public.user_profiles%ROWTYPE;
  v_before jsonb;
BEGIN
  SELECT * INTO v_profile FROM public.user_profiles
    WHERE auth_user_id = auth.uid() AND role = 'superuser' AND active IS DISTINCT FROM false LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'Only an active superuser can reopen a shift.'; END IF;
  IF nullif(btrim(p_reason), '') IS NULL THEN RAISE EXCEPTION 'A reopening reason is required.'; END IF;
  -- Serialize against shift creation/closing and reconciliation while checking dependencies.
  LOCK TABLE public.cash_shifts IN SHARE ROW EXCLUSIVE MODE;
  LOCK TABLE public.eod_reconciliations IN SHARE ROW EXCLUSIVE MODE;
  SELECT * INTO v_shift FROM public.cash_shifts WHERE id::text = p_shift_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Shift not found.'; END IF;
  IF v_shift.status <> 'Closed' THEN RAISE EXCEPTION 'This shift is no longer closed. Refresh and try again.'; END IF;
  IF EXISTS (SELECT 1 FROM public.eod_reconciliations WHERE business_date = v_shift.business_date AND locked) THEN
    RAISE EXCEPTION 'Unlock this reconciled day in Reports before reopening its shift.';
  END IF;
  IF EXISTS (SELECT 1 FROM public.cash_shifts WHERE status = 'Open') THEN
    RAISE EXCEPTION 'Another shift is open. Close it before reopening a shift.';
  END IF;
  IF EXISTS (SELECT 1 FROM public.cash_shifts WHERE id <> v_shift.id AND
    (business_date > v_shift.business_date OR
      (business_date = v_shift.business_date AND shift_number > v_shift.shift_number) OR opened_at > v_shift.opened_at)) THEN
    RAISE EXCEPTION 'A later shift has already started. Only the latest shift can be reopened.';
  END IF;
  IF EXISTS (SELECT 1 FROM public.eod_reconciliations WHERE business_date > v_shift.business_date AND locked) THEN
    RAISE EXCEPTION 'A later day is reconciled. Resolve that reconciliation before reopening this shift.';
  END IF;
  v_before := to_jsonb(v_shift);
  PERFORM set_config('hibi.reopen_shift_authorized', 'true', true);
  UPDATE public.cash_shifts SET status = 'Open', closed_at = NULL, closed_by = NULL,
    expected_cash = NULL, actual_cash_counted = NULL, variance = NULL, variance_reason = NULL,
    updated_at = now()
    WHERE id = v_shift.id RETURNING * INTO v_shift;
  INSERT INTO public.audit_logs (auth_user_id, username, action, entity_type, entity_id, reason, details)
    VALUES (auth.uid(), v_profile.username, 'reopen_shift', 'cash_shift', v_shift.id,
      btrim(p_reason), jsonb_build_object('before', v_before, 'after', to_jsonb(v_shift),
      'reopenedBy', coalesce(v_profile.display_name, v_profile.username), 'reopenedAt', now()));
  PERFORM set_config('hibi.reopen_shift_authorized', 'false', true);
  RETURN to_jsonb(v_shift);
END;
$function$
;

CREATE OR REPLACE FUNCTION public.sync_online_product_availability()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
DECLARE
  v_business_date date;
BEGIN
  IF tg_op = 'DELETE' THEN
    DELETE FROM public.online_product_availability
    WHERE product_id = old.product_id;
    RETURN old;
  END IF;

  v_business_date := coalesce(new.business_date, public.hibi_business_day());

  INSERT INTO public.online_product_availability
    (product_id, status, business_date, updated_at)
  VALUES
    (new.product_id,
     CASE WHEN new.status = 'SoldOut' THEN 'SoldOut' ELSE 'Available' END,
     v_business_date,
     coalesce(new.updated_at, now()))
  ON CONFLICT (product_id) DO UPDATE
    SET status = excluded.status,
        business_date = excluded.business_date,
        updated_at = excluded.updated_at;

  RETURN new;
END;
$function$
;
