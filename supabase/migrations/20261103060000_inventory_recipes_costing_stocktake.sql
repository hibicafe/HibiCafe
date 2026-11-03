-- Hibi Cafe inventory recipes, costing, stock counts and automatic usage.
-- No historical orders are backfilled. Deductions begin only for orders entering Preparing after this migration.

alter table public.inventory_items
  add column if not exists purchase_price numeric(14,4),
  add column if not exists purchase_price_updated_at timestamptz;

-- minimum_stock is now expressed in purchase units. Preserve the same threshold
-- by converting existing consumption-unit thresholds to their purchase-unit equivalent.
update public.inventory_items
set minimum_stock = round(minimum_stock / nullif(purchase_conversion_to_base,0), 3)
where purchase_conversion_to_base is not null and purchase_conversion_to_base > 0;

alter table public.inventory_movements
  add column if not exists purchase_unit_price numeric(14,4),
  add column if not exists purchase_total_cost numeric(14,2),
  add column if not exists cost_per_consumption_unit numeric(14,6);

alter table public.inventory_movements
  drop constraint if exists inventory_movements_movement_type_check,
  add constraint inventory_movements_movement_type_check
    check (movement_type in ('opening','stock_in','adjustment','waste','sale'));

alter table public.inventory_movements alter column created_by drop not null;

create table if not exists public.inventory_recipe_lines (
  id uuid primary key default gen_random_uuid(),
  recipe_type text not null check (recipe_type in ('product','addon')),
  product_id text,
  product_size text,
  addon_id text,
  item_id uuid not null references public.inventory_items(id),
  quantity_per_unit numeric(14,4) not null check (quantity_per_unit > 0),
  optional boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid references auth.users(id),
  constraint inventory_recipe_scope_check check (
    (recipe_type='product' and product_id is not null and product_size is not null and addon_id is null)
    or (recipe_type='addon' and addon_id is not null and product_id is null and product_size is null)
  )
);
create unique index if not exists inventory_recipe_product_line_uidx
  on public.inventory_recipe_lines(product_id,product_size,item_id) where recipe_type='product';
create unique index if not exists inventory_recipe_addon_line_uidx
  on public.inventory_recipe_lines(addon_id,item_id) where recipe_type='addon';
create index if not exists inventory_recipe_lookup_idx
  on public.inventory_recipe_lines(recipe_type,product_id,product_size,addon_id);

create table if not exists public.inventory_stock_counts (
  id uuid primary key default gen_random_uuid(),
  item_id uuid not null references public.inventory_items(id),
  system_quantity numeric(14,3) not null,
  actual_quantity numeric(14,3) not null check (actual_quantity >= 0),
  variance numeric(14,3) not null,
  purchase_unit text not null,
  reason text not null check (length(btrim(reason)) >= 2),
  counted_by uuid references auth.users(id),
  counted_by_name text not null,
  counted_at timestamptz not null default now()
);
create index if not exists inventory_stock_counts_item_date_idx
  on public.inventory_stock_counts(item_id,counted_at desc);

create table if not exists public.inventory_order_deductions (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.pos_orders(id),
  order_item_id uuid not null references public.pos_order_items(id),
  item_id uuid not null references public.inventory_items(id),
  movement_id uuid not null references public.inventory_movements(id),
  quantity numeric(14,3) not null check (quantity > 0),
  unit_cost numeric(14,6),
  total_cost numeric(14,4),
  created_at timestamptz not null default now(),
  unique(order_item_id,item_id)
);
create index if not exists inventory_order_deductions_order_idx
  on public.inventory_order_deductions(order_id);

alter table public.inventory_recipe_lines enable row level security;
alter table public.inventory_stock_counts enable row level security;
alter table public.inventory_order_deductions enable row level security;
grant select on public.inventory_recipe_lines,public.inventory_stock_counts,public.inventory_order_deductions to authenticated;
grant insert,update,delete on public.inventory_recipe_lines to authenticated;
grant insert on public.inventory_stock_counts to authenticated;
grant select on public.inventory_order_deductions to authenticated;

drop policy if exists inventory_recipe_read on public.inventory_recipe_lines;
create policy inventory_recipe_read on public.inventory_recipe_lines for select to authenticated using (public.hibi_is_active_user());
drop policy if exists inventory_recipe_manage on public.inventory_recipe_lines;
create policy inventory_recipe_manage on public.inventory_recipe_lines for all to authenticated
using (public.hibi_is_superuser()) with check (public.hibi_is_superuser());
drop policy if exists inventory_stock_count_read on public.inventory_stock_counts;
create policy inventory_stock_count_read on public.inventory_stock_counts for select to authenticated using (public.hibi_is_active_user());
drop policy if exists inventory_stock_count_insert on public.inventory_stock_counts;
create policy inventory_stock_count_insert on public.inventory_stock_counts for insert to authenticated
with check (public.hibi_is_active_user() and (counted_by is null or counted_by=auth.uid()));
drop policy if exists inventory_order_deductions_read on public.inventory_order_deductions;
create policy inventory_order_deductions_read on public.inventory_order_deductions for select to authenticated using (public.hibi_is_active_user());

-- Replace movement trigger to permit trusted order deductions while keeping staff validation.
create or replace function public.hibi_inventory_apply_movement()
returns trigger language plpgsql security definer
set search_path=pg_catalog,public
as $$
declare
  item_active boolean;
  next_qty numeric(14,3);
  is_system_deduction boolean := current_setting('hibi.inventory_deduction',true)='on';
begin
  if not is_system_deduction and (auth.uid() is null or not public.hibi_is_active_user()) then
    raise exception 'Active authenticated user required';
  end if;
  select active into item_active from public.inventory_items where id=new.item_id for update;
  if not found or not item_active then raise exception 'Inventory item is missing or archived'; end if;
  if new.movement_type in ('adjustment','waste') and length(btrim(coalesce(new.reason,'')))=0 then raise exception 'A reason is required for adjustments and waste'; end if;
  if new.movement_type in ('opening','stock_in') and new.quantity_delta<=0 then raise exception 'Opening stock and deliveries must increase stock'; end if;
  if new.movement_type in ('waste','sale') and new.quantity_delta>=0 then raise exception 'Waste and sales must decrease stock'; end if;
  insert into public.inventory_balances(item_id,quantity_on_hand,updated_at)
  values(new.item_id,new.quantity_delta,now())
  on conflict(item_id) do update set quantity_on_hand=public.inventory_balances.quantity_on_hand+excluded.quantity_on_hand,updated_at=now()
  returning quantity_on_hand into next_qty;
  if next_qty<0 then raise exception 'Insufficient stock for %; available: %', (select name from public.inventory_items where id=new.item_id), next_qty-new.quantity_delta; end if;
  return new;
end;
$$;

-- Idempotent, transactional deduction. An order either deducts all required ingredients
-- or the order/status change rolls back. Optional recipe lines are skipped if insufficient.
create or replace function public.hibi_apply_order_inventory(p_order_id uuid)
returns void language plpgsql security definer
set search_path=pg_catalog,public
as $$
declare
  v_order public.pos_orders%rowtype;
  v_need record;
  v_available numeric(14,3);
  v_movement_id uuid;
  v_unit_cost numeric(14,6);
  v_total numeric(14,4);
begin
  select * into v_order from public.pos_orders where id=p_order_id for update;
  if not found or v_order.status<>'Preparing' then return; end if;
  if exists(select 1 from public.inventory_order_deductions where order_id=p_order_id) then return; end if;

  perform set_config('hibi.inventory_deduction','on',true);

  for v_need in
    select order_item_id,item_id,sum(required_qty) as required_qty,bool_and(optional) as optional
    from (
      select oi.id as order_item_id,rl.item_id,(oi.qty*rl.quantity_per_unit)::numeric as required_qty,rl.optional
      from public.pos_order_items oi
      join public.inventory_recipe_lines rl on rl.recipe_type='product'
        and rl.product_id=oi.product_id and rl.product_size=coalesce(oi.size,'Regular')
      where oi.order_id=p_order_id
      union all
      select oi.id as order_item_id,rl.item_id,(oi.qty*rl.quantity_per_unit)::numeric as required_qty,rl.optional
      from public.pos_order_items oi
      cross join lateral jsonb_array_elements(coalesce(oi.addons,'[]'::jsonb)) addon
      join public.inventory_recipe_lines rl on rl.recipe_type='addon' and rl.addon_id=addon->>'id'
      where oi.order_id=p_order_id
    ) recipe_need
    group by order_item_id,item_id
    order by item_id,order_item_id
  loop
    select coalesce(quantity_on_hand,0) into v_available
      from public.inventory_balances where item_id=v_need.item_id for update;
    v_available:=coalesce(v_available,0);
    if v_available<v_need.required_qty and v_need.optional then continue; end if;
    if v_available<v_need.required_qty then
      raise exception 'Insufficient inventory for %: need %, available %',
        (select name from public.inventory_items where id=v_need.item_id),v_need.required_qty,v_available;
    end if;
    select case when purchase_conversion_to_base>0 and purchase_price is not null
      then purchase_price/purchase_conversion_to_base else null end
      into v_unit_cost from public.inventory_items where id=v_need.item_id;
    v_total:=case when v_unit_cost is null then null else round(v_unit_cost*v_need.required_qty,4) end;
    insert into public.inventory_movements(item_id,movement_type,quantity_delta,reason,reference,created_by,created_by_name)
    values(v_need.item_id,'sale',-v_need.required_qty,'Recipe usage','Order '||coalesce(v_order.order_code,v_order.order_number::text),v_order.created_by,'System · order '||coalesce(v_order.order_code,v_order.order_number::text))
    returning id into v_movement_id;
    insert into public.inventory_order_deductions(order_id,order_item_id,item_id,movement_id,quantity,unit_cost,total_cost)
    values(p_order_id,v_need.order_item_id,v_need.item_id,v_movement_id,v_need.required_qty,v_unit_cost,v_total);
  end loop;
end;
$$;

create or replace function public.hibi_inventory_deduct_on_order_item()
returns trigger language plpgsql security definer
set search_path=pg_catalog,public
as $$
begin
  perform public.hibi_apply_order_inventory(new.order_id);
  return null;
end;
$$;
drop trigger if exists inventory_deduct_after_order_items on public.pos_order_items;
create constraint trigger inventory_deduct_after_order_items
after insert on public.pos_order_items
deferrable initially deferred
for each row execute function public.hibi_inventory_deduct_on_order_item();

create or replace function public.hibi_inventory_deduct_on_status_change()
returns trigger language plpgsql security definer
set search_path=pg_catalog,public
as $$
begin
  if new.status='Preparing' and old.status is distinct from new.status then
    perform public.hibi_apply_order_inventory(new.id);
  end if;
  return new;
end;
$$;
drop trigger if exists inventory_deduct_after_status_change on public.pos_orders;
create trigger inventory_deduct_after_status_change
after update of status on public.pos_orders
for each row execute function public.hibi_inventory_deduct_on_status_change();

-- Shared availability check for POS and online ordering. Unconfigured variants remain unaffected.
create or replace function public.hibi_inventory_variant_availability(
  p_product_id text,p_size text,p_addon_ids text[] default '{}'::text[]
)
returns table(is_available boolean, unavailable_ingredients text[])
language sql stable security definer
set search_path=pg_catalog,public
as $$
  with required as (
    select rl.item_id,rl.optional
    from public.inventory_recipe_lines rl
    where rl.recipe_type='product' and rl.product_id=p_product_id and rl.product_size=coalesce(p_size,'Regular')
    union all
    select rl.item_id,rl.optional
    from public.inventory_recipe_lines rl
    where rl.recipe_type='addon' and rl.addon_id=any(coalesce(p_addon_ids,'{}'::text[]))
  ), shortages as (
    select distinct i.name
    from required r join public.inventory_items i on i.id=r.item_id
    left join public.inventory_balances b on b.item_id=i.id
    where not r.optional and coalesce(b.quantity_on_hand,0) < (
      select sum(rl.quantity_per_unit)
      from public.inventory_recipe_lines rl
      where rl.item_id=r.item_id and (
        (rl.recipe_type='product' and rl.product_id=p_product_id and rl.product_size=coalesce(p_size,'Regular'))
        or (rl.recipe_type='addon' and rl.addon_id=any(coalesce(p_addon_ids,'{}'::text[])))
      )
    )
  )
  select not exists(select 1 from shortages),
         coalesce((select array_agg(name order by name) from shortages),'{}'::text[]);
$$;
grant execute on function public.hibi_inventory_variant_availability(text,text,text[]) to authenticated,service_role;
grant execute on function public.hibi_apply_order_inventory(uuid) to service_role;

-- Allow live clients to refresh ingredient-derived availability and balances.
do $$ begin
  alter publication supabase_realtime add table public.inventory_balances;
exception when duplicate_object then null; when undefined_object then null; end $$;
