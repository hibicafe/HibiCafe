-- Fund snapshots are calculated inside Postgres so reconciliation never depends
-- on potentially stale browser-side order, refund, or expense caches.
create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated;

create or replace function private.save_fund_balance_snapshot_db(
  p_business_date date,
  p_notes text default null,
  p_snapshot_type text default 'reconciliation'
)
returns table (
  id uuid,
  business_date date,
  snapshot_at timestamptz,
  cash_balance numeric,
  gcash_balance numeric,
  bank_balance numeric,
  snapshot_type text
)
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_anchor public.fund_balance_snapshots%rowtype;
  v_cash_sales numeric := 0;
  v_gcash_sales numeric := 0;
  v_grab_sales numeric := 0;
  v_cash_refunds numeric := 0;
  v_gcash_refunds numeric := 0;
  v_grab_refunds numeric := 0;
  v_cash_movements numeric := 0;
  v_daily_expenses numeric := 0;
  v_cash_opex numeric := 0;
  v_gcash_opex numeric := 0;
  v_bank_opex numeric := 0;
  v_cash numeric := 0;
  v_gcash numeric := 0;
  v_bank numeric := 0;
  v_actor text;
  v_id uuid;
  v_at timestamptz;
begin
  if auth.uid() is null then
    raise exception 'Authentication is required.';
  end if;
  if p_business_date is null then
    raise exception 'Business date is required.';
  end if;

  if p_snapshot_type = 'reconciliation' then
    if not public.hibi_has_permission('reports') then
      raise exception 'You do not have permission to save a reconciliation snapshot.';
    end if;
    if not exists (
      select 1 from public.eod_reconciliations e
      where e.business_date = p_business_date
        and e.locked = true
        and e.reconciled_at is not null
    ) then
      raise exception 'A locked EOD reconciliation is required before saving this snapshot.';
    end if;
  elsif p_snapshot_type = 'manual' then
    if not public.hibi_is_superuser() then
      raise exception 'Only a superuser can save a manual snapshot.';
    end if;
  else
    raise exception 'Unsupported snapshot type.';
  end if;

  select s.* into v_anchor
  from public.fund_balance_snapshots s
  where s.snapshot_type <> 'voided'
  order by s.snapshot_at desc
  limit 1;

  if not found then
    raise exception 'No valid fund snapshot exists to use as a starting balance.';
  end if;

  select coalesce(sum(
    case
      when o.payment_method = 'Cash' then coalesce(o.total,0)
      when o.payment_method = 'Cash + GCash' then coalesce(o.cash_amount,0)
      else 0
    end
  ),0),
  coalesce(sum(
    case
      when o.payment_method = 'GCash' then coalesce(o.total,0)
      when o.payment_method = 'Cash + GCash' then coalesce(o.gcash_amount,0)
      else 0
    end
  ),0),
  coalesce(sum(case when o.source = 'GrabFood' then coalesce(o.total,0) else 0 end),0)
  into v_cash_sales,v_gcash_sales,v_grab_sales
  from public.pos_orders o
  where o.created_at > v_anchor.snapshot_at
    and o.status <> 'Cancelled'
    and (coalesce(o.source,'Walk-in') <> 'Online' or o.payment_status = 'Paid');

  -- Cancelled orders are already excluded from sales. Their cancellation
  -- refunds must not be deducted again; only refunds against non-cancelled,
  -- paid orders are applied here.
  select
    coalesce(sum(case
      when coalesce(r.cash_amount,0)+coalesce(r.gcash_amount,0)+coalesce(r.grab_amount,0) > 0 then coalesce(r.cash_amount,0)
      when o.payment_method = 'Cash' then r.amount
      when o.payment_method = 'Cash + GCash' then least(coalesce(r.amount,0),coalesce(o.cash_amount,0))
      else 0 end),0),
    coalesce(sum(case
      when coalesce(r.cash_amount,0)+coalesce(r.gcash_amount,0)+coalesce(r.grab_amount,0) > 0 then coalesce(r.gcash_amount,0)
      when o.payment_method = 'GCash' then r.amount
      when o.payment_method = 'Cash + GCash' then least(coalesce(r.amount,0),coalesce(o.gcash_amount,0))
      else 0 end),0),
    coalesce(sum(case
      when coalesce(r.cash_amount,0)+coalesce(r.gcash_amount,0)+coalesce(r.grab_amount,0) > 0 then coalesce(r.grab_amount,0)
      when o.source = 'GrabFood' then r.amount
      else 0 end),0)
  into v_cash_refunds,v_gcash_refunds,v_grab_refunds
  from public.pos_refunds r
  join public.pos_orders o on o.id = r.order_id
  where r.created_at > v_anchor.snapshot_at
    and r.voided_at is null
    and o.status <> 'Cancelled'
    and (coalesce(o.source,'Walk-in') <> 'Online' or o.payment_status = 'Paid');

  select coalesce(sum(case when m.movement_type='In' then m.amount else -m.amount end),0)
  into v_cash_movements
  from public.cash_movements m
  where m.created_at > v_anchor.snapshot_at
    and m.status = 'Active'
    and m.voided_at is null;

  select coalesce(sum(d.amount),0) into v_daily_expenses
  from public.daily_expenses d
  where d.created_at > v_anchor.snapshot_at
    and d.status = 'Active'
    and d.voided_at is null;

  select
    coalesce(sum(case when e.payment_method='Cash' then e.amount else 0 end),0),
    coalesce(sum(case when e.payment_method='GCash' then e.amount else 0 end),0),
    coalesce(sum(case when e.payment_method='Bank Transfer' then e.amount else 0 end),0)
  into v_cash_opex,v_gcash_opex,v_bank_opex
  from public.owner_expenses e
  where e.created_at > v_anchor.snapshot_at
    and e.status = 'Active'
    and e.voided_at is null;

  v_cash := coalesce(v_anchor.cash_balance,0) + v_cash_sales - v_cash_refunds
            + v_cash_movements - v_daily_expenses - v_cash_opex;
  v_gcash := coalesce(v_anchor.gcash_balance,0) + v_gcash_sales - v_gcash_refunds - v_gcash_opex;
  v_bank := coalesce(v_anchor.bank_balance,0)
            + (v_grab_sales - v_grab_refunds) * 0.75 - v_bank_opex;

  select coalesce(nullif(p.display_name,''),p.username,'Staff')
  into v_actor
  from public.user_profiles p
  where p.auth_user_id = auth.uid()
  limit 1;

  insert into public.fund_balance_snapshots (
    business_date,snapshot_at,cash_balance,gcash_balance,bank_balance,
    snapshot_type,notes,created_by,created_by_name
  ) values (
    p_business_date,now(),round(v_cash,2),round(v_gcash,2),round(v_bank,2),
    p_snapshot_type,p_notes,auth.uid(),coalesce(v_actor,'Staff')
  )
  returning fund_balance_snapshots.id,fund_balance_snapshots.snapshot_at
  into v_id,v_at;

  return query
  select v_id,p_business_date,v_at,round(v_cash,2),round(v_gcash,2),round(v_bank,2),p_snapshot_type;
end;
$function$;

revoke all on function private.save_fund_balance_snapshot_db(date,text,text) from public;
revoke all on function private.save_fund_balance_snapshot_db(date,text,text) from anon;
grant execute on function private.save_fund_balance_snapshot_db(date,text,text) to authenticated;


-- Expose only a SECURITY INVOKER wrapper through the Data API. The internal
-- SECURITY DEFINER routine remains in the non-exposed private schema and
-- performs explicit authentication and Hibi permission checks.
create or replace function public.save_fund_balance_snapshot_db(
  p_business_date date,
  p_notes text default null,
  p_snapshot_type text default 'reconciliation'
)
returns table (
  id uuid,
  business_date date,
  snapshot_at timestamptz,
  cash_balance numeric,
  gcash_balance numeric,
  bank_balance numeric,
  snapshot_type text
)
language sql
security invoker
set search_path = ''
as $wrapper$
  select * from private.save_fund_balance_snapshot_db(
    p_business_date,p_notes,p_snapshot_type
  );
$wrapper$;

revoke all on function public.save_fund_balance_snapshot_db(date,text,text) from public;
revoke all on function public.save_fund_balance_snapshot_db(date,text,text) from anon;
grant execute on function public.save_fund_balance_snapshot_db(date,text,text) to authenticated;
