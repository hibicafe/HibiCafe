-- Fix inventory movement balance updates and unconfigured product availability.
-- The old ON CONFLICT insert supplied a negative EXCLUDED quantity. PostgreSQL
-- checked inventory_balances.quantity_on_hand >= 0 before applying the conflict
-- update, so valid deductions against an existing positive balance failed.
-- Locking the inventory item serializes balance mutations for that item.

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

  select active into item_active
  from public.inventory_items
  where id=new.item_id
  for update;

  if not found or not item_active then
    raise exception 'Inventory item is missing or archived';
  end if;

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
  from public.inventory_balances
  where item_id=new.item_id
  for update;
  balance_exists := found;
  current_qty := coalesce(current_qty,0);
  next_qty := current_qty + new.quantity_delta;

  if next_qty < 0 then
    raise exception 'Insufficient stock for %; available: %',
      (select name from public.inventory_items where id=new.item_id),
      current_qty;
  end if;

  if balance_exists then
    update public.inventory_balances
    set quantity_on_hand=next_qty,updated_at=now()
    where item_id=new.item_id;
  else
    insert into public.inventory_balances(item_id,quantity_on_hand,updated_at)
    values(new.item_id,next_qty,now());
  end if;

  if new.movement_type='stock_in' and new.purchase_unit_price is not null then
    update public.inventory_items
    set purchase_price=new.purchase_unit_price,purchase_price_updated_at=now(),updated_at=now()
    where id=new.item_id;
  end if;

  return new;
end;
$function$;

create or replace function public.hibi_inventory_variant_availability(
  p_product_id text,
  p_size text,
  p_addon_ids text[] default '{}'::text[],
  p_qty integer default 1
)
returns table(is_available boolean, unavailable_ingredients text[])
language plpgsql
stable
security definer
set search_path=pg_catalog,public
as $function$
begin
  if p_qty is null or p_qty not between 1 and 10000 then
    raise exception 'Invalid item quantity';
  end if;

  -- Products and add-ons without recipe lines are not inventory-tracked.
  if not exists (
    select 1
    from public.inventory_recipe_lines rl
    where (rl.recipe_type='product'
      and rl.product_id=p_product_id
      and rl.product_size=coalesce(p_size,'Regular'))
       or (rl.recipe_type='addon'
      and rl.addon_id=any(coalesce(p_addon_ids,'{}'::text[])))
  ) then
    return query select true,'{}'::text[];
    return;
  end if;

  return query
  with required as (
    select rl.item_id,rl.optional
    from public.inventory_recipe_lines rl
    where rl.recipe_type='product'
      and rl.product_id=p_product_id
      and rl.product_size=coalesce(p_size,'Regular')
    union all
    select rl.item_id,rl.optional
    from public.inventory_recipe_lines rl
    where rl.recipe_type='addon'
      and rl.addon_id=any(coalesce(p_addon_ids,'{}'::text[]))
  ),
  shortages as (
    select distinct i.name
    from required r
    join public.inventory_items i on i.id=r.item_id
    left join public.inventory_balances b on b.item_id=i.id
    where not r.optional
      and coalesce(b.quantity_on_hand,0) < (
        select sum(rl.quantity_per_unit)*p_qty
        from public.inventory_recipe_lines rl
        where rl.item_id=r.item_id
          and (
            (rl.recipe_type='product'
              and rl.product_id=p_product_id
              and rl.product_size=coalesce(p_size,'Regular'))
            or (rl.recipe_type='addon'
              and rl.addon_id=any(coalesce(p_addon_ids,'{}'::text[])))
          )
      )
  )
  select not exists(select 1 from shortages),
         coalesce((select array_agg(name order by name) from shortages),'{}'::text[]);
end;
$function$;
