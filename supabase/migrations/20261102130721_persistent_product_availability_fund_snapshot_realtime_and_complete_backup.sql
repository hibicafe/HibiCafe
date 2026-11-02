-- Persistent product availability, fund snapshot Realtime, and complete app-data backups.
CREATE OR REPLACE FUNCTION public.sync_online_product_availability()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'pg_catalog'
AS $function$
DECLARE v_business_date date;
BEGIN
  IF tg_op = 'DELETE' THEN
    DELETE FROM public.online_product_availability WHERE product_id = old.product_id;
    RETURN old;
  END IF;
  v_business_date := coalesce(new.business_date, public.hibi_business_day());
  INSERT INTO public.online_product_availability (product_id, status, business_date, updated_at)
  VALUES (new.product_id, CASE WHEN new.status = 'SoldOut' THEN 'SoldOut' ELSE 'Available' END,
          v_business_date, coalesce(new.updated_at, now()))
  ON CONFLICT (product_id) DO UPDATE
    SET status = excluded.status, business_date = excluded.business_date, updated_at = excluded.updated_at;
  RETURN new;
END;
$function$;

INSERT INTO public.online_product_availability (product_id, status, business_date, updated_at)
SELECT product_id, status, business_date, updated_at FROM public.product_availability
ON CONFLICT (product_id) DO UPDATE
  SET status = excluded.status, business_date = excluded.business_date, updated_at = excluded.updated_at;

DO $publication$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_publication_tables WHERE pubname='supabase_realtime'
                 AND schemaname='public' AND tablename='fund_balance_snapshots') THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.fund_balance_snapshots;
  END IF;
END
$publication$;

CREATE OR REPLACE FUNCTION public.hibi_backup()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE result jsonb;
BEGIN
  IF NOT public.hibi_is_superuser() THEN RAISE EXCEPTION 'Superuser required'; END IF;
  SELECT jsonb_build_object(
    'format','hibi-application-backup-v2','created_at',now(),
    'tables',jsonb_build_object(
      'user_profiles',coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM public.user_profiles t),'[]'::jsonb),
      'app_data',coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM public.app_data t),'[]'::jsonb),
      'hibi_fee_rates',coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM public.hibi_fee_rates t),'[]'::jsonb),
      'cash_shifts',coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM public.cash_shifts t),'[]'::jsonb),
      'pos_orders',coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM public.pos_orders t),'[]'::jsonb),
      'pos_order_items',coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM public.pos_order_items t),'[]'::jsonb),
      'pos_refunds',coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM public.pos_refunds t),'[]'::jsonb),
      'daily_expenses',coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM public.daily_expenses t),'[]'::jsonb),
      'owner_expenses',coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM public.owner_expenses t),'[]'::jsonb),
      'cash_movements',coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM public.cash_movements t),'[]'::jsonb),
      'eod_reconciliations',coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM public.eod_reconciliations t),'[]'::jsonb),
      'product_availability',coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM public.product_availability t),'[]'::jsonb),
      'online_product_availability',coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM public.online_product_availability t),'[]'::jsonb),
      'online_order_details',coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM public.online_order_details t),'[]'::jsonb),
      'fund_transactions',coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM public.fund_transactions t),'[]'::jsonb),
      'fund_balance_snapshots',coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM public.fund_balance_snapshots t),'[]'::jsonb),
      'monthly_report_settings',coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM public.monthly_report_settings t),'[]'::jsonb),
      'monthly_report_log',coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM public.monthly_report_log t),'[]'::jsonb),
      'hibi_order_refs',coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM public.hibi_order_refs t),'[]'::jsonb),
      'hibi_requests',coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM public.hibi_requests t),'[]'::jsonb),
      'audit_logs',coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM public.audit_logs t),'[]'::jsonb)
    ),
    'sequences',jsonb_build_object('hibi_order_number_seq',(SELECT last_value FROM public.hibi_order_number_seq))
  ) INTO result;
  RETURN result;
END;
$function$;
