-- Return recipe ingredients whenever a deducted order is cancelled.
-- The return ledger makes cancellation retries idempotent. Orders cancelled
-- before Preparing have no deductions and therefore create no stock movement.
create table if not exists public.inventory_order_return_runs (
  order_id uuid primary key references public.pos_orders(id) on delete restrict,
  returned_at timestamptz not null default now()
);
alter table public.inventory_order_return_runs enable row level security;

create or replace function public.hibi_inventory_restore_order(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path=pg_catalog,public
as $function$
declare
  v_deduction record;
  v_order public.pos_orders%rowtype;
begin
  select * into v_order from public.pos_orders where id=p_order_id for update;
  if not found or v_order.status<>'Cancelled' then return; end if;
  if exists(select 1 from public.inventory_order_return_runs where order_id=p_order_id) then return; end if;
  if not exists(select 1 from public.inventory_order_deductions where order_id=p_order_id) then return; end if;

  insert into public.inventory_order_return_runs(order_id) values(p_order_id);
  perform set_config('hibi.inventory_deduction','on',true);

  for v_deduction in
    select d.item_id,d.quantity
    from public.inventory_order_deductions d
    where d.order_id=p_order_id
    order by d.item_id,d.id
  loop
    insert into public.inventory_movements(
      item_id,movement_type,quantity_delta,reason,reference,created_by,created_by_name
    )
    values(
      v_deduction.item_id,'adjustment',v_deduction.quantity,
      'Cancelled order ingredient return',
      'Order '||coalesce(v_order.order_code,v_order.order_number::text),
      v_order.created_by,
      'System · cancelled order '||coalesce(v_order.order_code,v_order.order_number::text)
    );
  end loop;
end;
$function$;

create or replace function public.hibi_inventory_deduct_on_status_change()
returns trigger
language plpgsql
security definer
set search_path=pg_catalog,public
as $function$
begin
  if new.status='Preparing' and old.status is distinct from new.status then
    perform public.hibi_apply_order_inventory(new.id);
  elsif new.status='Cancelled' and old.status is distinct from new.status then
    perform public.hibi_inventory_restore_order(new.id);
  end if;
  return new;
end;
$function$;

-- Stock-in movements update quantity only. Purchase cost is tracked separately
-- as OPEX, so inventory delivery entry must not change the item's purchase cost.
create or replace function public.hibi_inventory_apply_movement()
returns trigger
language plpgsql
security definer
set search_path=pg_catalog,public
as $function$
declare
  item_active boolean;
  current_qty numeric(14,3);
  next_qty numeric(14,3);
  balance_exists boolean := false;
  is_system_deduction boolean := current_setting('hibi.inventory_deduction',true)='on';
begin
  if not is_system_deduction and (auth.uid() is null or not public.hibi_is_active_user()) then
    raise exception 'Active authenticated user required';
  end if;

  select active into item_active from public.inventory_items where id=new.item_id for update;
  if not found or not item_active then raise exception 'Inventory item is missing or archived'; end if;

  if new.movement_type in ('adjustment','waste') and length(btrim(coalesce(new.reason,'')))=0 then
    raise exception 'A reason is required for adjustments and waste';
  end if;
  if new.movement_type in ('opening','stock_in') and new.quantity_delta<=0 then
    raise exception 'Opening stock and deliveries must increase stock';
  end if;
  if new.movement_type in ('waste','sale') and new.quantity_delta>=0 then
    raise exception 'Waste and sales must decrease stock';
  end if;
  if new.movement_type='sale' and not is_system_deduction then
    raise exception 'Sale deductions are system-managed';
  end if;

  select quantity_on_hand into current_qty
  from public.inventory_balances where item_id=new.item_id for update;
  balance_exists := found;
  current_qty := coalesce(current_qty,0);
  next_qty := current_qty + new.quantity_delta;
  if next_qty<0 then
    raise exception 'Insufficient stock for %; available: %',
      (select name from public.inventory_items where id=new.item_id),current_qty;
  end if;

  if balance_exists then
    update public.inventory_balances set quantity_on_hand=next_qty,updated_at=now()
    where item_id=new.item_id;
  else
    insert into public.inventory_balances(item_id,quantity_on_hand,updated_at)
    values(new.item_id,next_qty,now());
  end if;

  -- Delivery cost is intentionally excluded from inventory movements.
  if new.movement_type='stock_in' then
    new.purchase_unit_price := null;
    new.purchase_total_cost := null;
    new.cost_per_consumption_unit := null;
  end if;
  return new;
end;
$function$;

revoke all on function public.hibi_inventory_restore_order(uuid) from public, anon, authenticated;
