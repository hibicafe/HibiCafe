-- Practical stock units with conversion to canonical quantity units.
alter table public.inventory_items add column if not exists stock_unit text;
alter table public.inventory_items add column if not exists conversion_to_base numeric(14,3);
update public.inventory_items set stock_unit=coalesce(stock_unit,base_unit), conversion_to_base=coalesce(conversion_to_base,1);
alter table public.inventory_items alter column stock_unit set not null;
alter table public.inventory_items alter column stock_unit set default 'g';
alter table public.inventory_items alter column conversion_to_base set not null;
alter table public.inventory_items alter column conversion_to_base set default 1;
alter table public.inventory_items drop constraint if exists inventory_items_conversion_positive;
alter table public.inventory_items add constraint inventory_items_conversion_positive check(conversion_to_base>0);
alter table public.inventory_items drop constraint if exists inventory_items_stock_unit_valid;
alter table public.inventory_items add constraint inventory_items_stock_unit_valid check(stock_unit in ('g','kg','ml','L','pc','bottle','bag','pack','carton'));
