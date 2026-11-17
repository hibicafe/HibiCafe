-- Permit signed recipe quantities so add-ons can subtract a base ingredient
-- (for example, remove dairy milk when oat milk is selected).
alter table public.inventory_recipe_lines
  drop constraint if exists inventory_recipe_lines_quantity_per_unit_check;
alter table public.inventory_recipe_lines
  add constraint inventory_recipe_lines_quantity_per_unit_check
  check (quantity_per_unit <> 0);

-- Saving a recipe accepts positive consumption and negative substitution adjustments.
create or replace function public.hibi_save_inventory_recipe(
  p_recipe_type text,p_product_id text,p_product_size text,p_addon_id text,p_lines jsonb
)
returns integer language plpgsql security definer
set search_path=pg_catalog,public
as $$
declare v_line jsonb;v_count integer:=0;v_item uuid;v_qty numeric;
begin
  if not public.hibi_is_superuser() then raise exception 'Only a superuser can manage recipes'; end if;
  if p_recipe_type not in ('product','addon') then raise exception 'Invalid recipe type'; end if;
  if jsonb_typeof(p_lines) is distinct from 'array' or jsonb_array_length(p_lines)=0 then raise exception 'Add at least one ingredient'; end if;
  if p_recipe_type='product' and (nullif(btrim(p_product_id),'') is null or nullif(btrim(p_product_size),'') is null or p_addon_id is not null) then raise exception 'Select a product size'; end if;
  if p_recipe_type='addon' and (nullif(btrim(p_addon_id),'') is null or p_product_id is not null or p_product_size is not null) then raise exception 'Select an add-on'; end if;
  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_item:=(v_line->>'item_id')::uuid;v_qty:=(v_line->>'quantity_per_unit')::numeric;
    if v_qty is null or v_qty=0 then raise exception 'Recipe quantities must be non-zero; use a negative quantity to subtract an ingredient'; end if;
    if not exists(select 1 from public.inventory_items where id=v_item and active) then raise exception 'A recipe ingredient is missing or inactive'; end if;
  end loop;
  if p_recipe_type='product' then
    delete from public.inventory_recipe_lines where recipe_type='product' and product_id=p_product_id and product_size=p_product_size;
  else
    delete from public.inventory_recipe_lines where recipe_type='addon' and addon_id=p_addon_id;
  end if;
  for v_line in select * from jsonb_array_elements(p_lines) loop
    insert into public.inventory_recipe_lines(recipe_type,product_id,product_size,addon_id,item_id,quantity_per_unit,optional,created_by,updated_at)
    values(p_recipe_type,p_product_id,p_product_size,p_addon_id,(v_line->>'item_id')::uuid,
      (v_line->>'quantity_per_unit')::numeric,coalesce((v_line->>'optional')::boolean,false),auth.uid(),now());
    v_count:=v_count+1;
  end loop;
  return v_count;
end;
$$;
grant execute on function public.hibi_save_inventory_recipe(text,text,text,text,jsonb) to authenticated;

-- Deduct only the net positive quantity per ingredient. Negative add-on lines
-- offset the base recipe's ingredient use; they never create stock or a refund.
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
  v_enabled_at timestamptz;
begin
  select * into v_order from public.pos_orders where id=p_order_id for update;
  if not found or v_order.status<>'Preparing' then return; end if;
  select enabled_at into v_enabled_at from public.inventory_deduction_config where singleton=true;
  if v_enabled_at is null or v_order.created_at<v_enabled_at then return; end if;
  if exists(select 1 from public.inventory_order_deduction_runs where order_id=p_order_id) then return; end if;
  insert into public.inventory_order_deduction_runs(order_id) values(p_order_id);

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
    -- A zero/negative net means this ingredient is fully substituted or removed.
    if v_need.required_qty<=0 then continue; end if;
    select coalesce(quantity_on_hand,0) into v_available from public.inventory_balances where item_id=v_need.item_id for update;
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
grant execute on function public.hibi_apply_order_inventory(uuid) to service_role;
