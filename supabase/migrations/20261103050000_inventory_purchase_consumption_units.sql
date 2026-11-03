-- Separate purchasing units from recipe-consumption units.
-- Existing stock and movement quantities remain in their current base_unit.
alter table public.inventory_items
  add column if not exists consumption_unit text,
  add column if not exists purchase_unit text,
  add column if not exists purchase_conversion_to_base numeric(14,3);

update public.inventory_items
set consumption_unit = coalesce(consumption_unit, base_unit),
    purchase_unit = coalesce(purchase_unit, stock_unit, base_unit),
    purchase_conversion_to_base = coalesce(purchase_conversion_to_base, conversion_to_base, 1);

alter table public.inventory_items
  alter column consumption_unit set not null,
  alter column consumption_unit set default 'g',
  alter column purchase_unit set not null,
  alter column purchase_unit set default 'g',
  alter column purchase_conversion_to_base set not null,
  alter column purchase_conversion_to_base set default 1;

alter table public.inventory_items
  drop constraint if exists inventory_items_consumption_unit_valid,
  add constraint inventory_items_consumption_unit_valid
    check (consumption_unit in ('g','kg','ml','L','pc')),
  drop constraint if exists inventory_items_purchase_conversion_positive,
  add constraint inventory_items_purchase_conversion_positive
    check (purchase_conversion_to_base > 0),
  drop constraint if exists inventory_items_purchase_unit_valid,
  add constraint inventory_items_purchase_unit_valid
    check (purchase_unit in ('g','kg','ml','L','pc','bottle','carton','bag','pack','tray','box','jar','sachet','can','tin','case','bundle'));

alter table public.inventory_items
  drop constraint if exists inventory_items_stock_unit_valid,
  add constraint inventory_items_stock_unit_valid
    check (stock_unit in ('g','kg','ml','L','pc','bottle','carton','bag','pack','tray','box','jar','sachet','can','tin','case','bundle'));

-- Preserve the quantity originally entered by staff for clear purchase-unit history.
alter table public.inventory_movements
  add column if not exists entered_quantity numeric(14,3),
  add column if not exists entered_unit text;
