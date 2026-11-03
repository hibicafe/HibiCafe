-- Hibi Cafe Inventory Foundation (Phase 1)
-- Prepared on a feature branch only. Do not apply to production until reviewed.
create table if not exists public.inventory_categories (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  sort_order integer not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id)
);

create table if not exists public.inventory_items (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  category_id uuid references public.inventory_categories(id),
  base_unit text not null check (base_unit in ('g','kg','ml','L','pc')),
  minimum_stock numeric(14,3) not null default 0 check (minimum_stock >= 0),
  notes text,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid references auth.users(id),
  updated_by uuid references auth.users(id)
);
create unique index if not exists inventory_items_active_name_uidx
  on public.inventory_items (lower(name)) where active;

create table if not exists public.inventory_balances (
  item_id uuid primary key references public.inventory_items(id),
  quantity_on_hand numeric(14,3) not null default 0 check (quantity_on_hand >= 0),
  updated_at timestamptz not null default now()
);

create table if not exists public.inventory_movements (
  id uuid primary key default gen_random_uuid(),
  item_id uuid not null references public.inventory_items(id),
  movement_type text not null check (movement_type in ('opening','stock_in','adjustment','waste')),
  quantity_delta numeric(14,3) not null check (quantity_delta <> 0),
  reason text,
  reference text,
  supplier text,
  created_at timestamptz not null default now(),
  created_by uuid not null default auth.uid() references auth.users(id),
  created_by_name text not null default ''
);
create index if not exists inventory_movements_item_created_idx
  on public.inventory_movements(item_id, created_at desc);

create or replace function public.hibi_inventory_apply_movement()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
declare
  item_active boolean;
  next_qty numeric(14,3);
begin
  select active into item_active from public.inventory_items where id = new.item_id for update;
  if not found or not item_active then
    raise exception 'Inventory item is missing or archived';
  end if;
  if new.movement_type in ('adjustment','waste') and length(btrim(coalesce(new.reason,''))) = 0 then
    raise exception 'A reason is required for adjustments and waste';
  end if;
  if new.movement_type in ('opening','stock_in') and new.quantity_delta <= 0 then
    raise exception 'Opening stock and deliveries must increase stock';
  end if;
  if new.movement_type = 'waste' and new.quantity_delta >= 0 then
    raise exception 'Waste must decrease stock';
  end if;

  insert into public.inventory_balances(item_id, quantity_on_hand, updated_at)
  values(new.item_id, new.quantity_delta, now())
  on conflict(item_id) do update
    set quantity_on_hand = public.inventory_balances.quantity_on_hand + excluded.quantity_on_hand,
        updated_at = now()
  returning quantity_on_hand into next_qty;

  if next_qty < 0 then
    raise exception 'Insufficient stock. Available quantity: %', next_qty - new.quantity_delta;
  end if;
  return new;
end;
$$;

drop trigger if exists inventory_movement_apply on public.inventory_movements;
create trigger inventory_movement_apply
before insert on public.inventory_movements
for each row execute function public.hibi_inventory_apply_movement();

-- Movement history is append-only. Corrections are compensating movements.
create or replace function public.hibi_inventory_block_history_mutation()
returns trigger language plpgsql security invoker set search_path=public as $$
begin
  raise exception 'Inventory movement history is append-only; create a correcting movement instead';
end;
$$;
drop trigger if exists inventory_movement_no_update on public.inventory_movements;
create trigger inventory_movement_no_update before update or delete on public.inventory_movements
for each row execute function public.hibi_inventory_block_history_mutation();

alter table public.inventory_categories enable row level security;
alter table public.inventory_items enable row level security;
alter table public.inventory_balances enable row level security;
alter table public.inventory_movements enable row level security;

grant select on public.inventory_categories, public.inventory_items, public.inventory_balances, public.inventory_movements to authenticated;
grant insert, update on public.inventory_categories, public.inventory_items to authenticated;
grant insert on public.inventory_movements to authenticated;

drop policy if exists inventory_categories_read on public.inventory_categories;
create policy inventory_categories_read on public.inventory_categories for select to authenticated
using (public.hibi_is_active_user());
drop policy if exists inventory_categories_manage on public.inventory_categories;
create policy inventory_categories_manage on public.inventory_categories for all to authenticated
using (public.hibi_is_superuser()) with check (public.hibi_is_superuser());

drop policy if exists inventory_items_read on public.inventory_items;
create policy inventory_items_read on public.inventory_items for select to authenticated
using (public.hibi_is_active_user());
drop policy if exists inventory_items_manage on public.inventory_items;
create policy inventory_items_manage on public.inventory_items for all to authenticated
using (public.hibi_is_superuser()) with check (public.hibi_is_superuser());

drop policy if exists inventory_balances_read on public.inventory_balances;
create policy inventory_balances_read on public.inventory_balances for select to authenticated
using (public.hibi_is_active_user());

drop policy if exists inventory_movements_read on public.inventory_movements;
create policy inventory_movements_read on public.inventory_movements for select to authenticated
using (public.hibi_is_active_user());
drop policy if exists inventory_movements_insert on public.inventory_movements;
create policy inventory_movements_insert on public.inventory_movements for insert to authenticated
with check (public.hibi_is_active_user() and created_by = auth.uid());
