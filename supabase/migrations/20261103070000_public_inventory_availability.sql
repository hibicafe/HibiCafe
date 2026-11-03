-- Publish only derived product availability to anonymous online-ordering clients.
-- Never expose ingredient names, quantities, purchase prices, or recipe details.

create table if not exists public.inventory_product_availability (
  product_id text primary key,
  sold_out boolean not null default false,
  updated_at timestamptz not null default now()
);
alter table public.inventory_product_availability enable row level security;
grant select on public.inventory_product_availability to anon,authenticated;
drop policy if exists inventory_product_availability_public_read on public.inventory_product_availability;
create policy inventory_product_availability_public_read
  on public.inventory_product_availability for select to anon,authenticated using (true);

create or replace function public.hibi_refresh_inventory_product_availability()
returns void language plpgsql security definer
set search_path=pg_catalog,public
as $$
declare
  v_menu jsonb;
  v_product jsonb;
  v_size text;
  v_available boolean;
  v_all_unavailable boolean;
  v_has_size boolean;
begin
  select value into v_menu from public.app_data where key='hibi-menu';
  if v_menu is null or jsonb_typeof(v_menu->'products') is distinct from 'array' then return; end if;
  for v_product in select value from jsonb_array_elements(v_menu->'products') loop
    if coalesce((v_product->>'active')::boolean,true)=false then continue; end if;
    v_all_unavailable:=true;
    v_has_size:=false;
    for v_size in select jsonb_object_keys(coalesce(v_product->'sizes','{}'::jsonb)) loop
      v_has_size:=true;
      select a.is_available into v_available
        from public.hibi_inventory_variant_availability(v_product->>'id',v_size,'{}'::text[],1) a;
      if coalesce(v_available,true) then v_all_unavailable:=false; exit; end if;
    end loop;
    insert into public.inventory_product_availability(product_id,sold_out,updated_at)
    values(v_product->>'id',v_has_size and v_all_unavailable,now())
    on conflict(product_id) do update set sold_out=excluded.sold_out,updated_at=now();
  end loop;
end;
$$;

create or replace function public.hibi_inventory_refresh_availability_trigger()
returns trigger language plpgsql security definer
set search_path=pg_catalog,public
as $$
begin
  perform public.hibi_refresh_inventory_product_availability();
  return coalesce(new,old);
end;
$$;

drop trigger if exists inventory_balance_refresh_product_availability on public.inventory_balances;
create trigger inventory_balance_refresh_product_availability
after insert or update or delete on public.inventory_balances
for each row execute function public.hibi_inventory_refresh_availability_trigger();

drop trigger if exists inventory_recipe_refresh_product_availability on public.inventory_recipe_lines;
create trigger inventory_recipe_refresh_product_availability
after insert or update or delete on public.inventory_recipe_lines
for each row execute function public.hibi_inventory_refresh_availability_trigger();

drop trigger if exists inventory_item_refresh_product_availability on public.inventory_items;
create trigger inventory_item_refresh_product_availability
after update of active on public.inventory_items
for each row execute function public.hibi_inventory_refresh_availability_trigger();

alter publication supabase_realtime add table public.inventory_product_availability;

select public.hibi_refresh_inventory_product_availability();
