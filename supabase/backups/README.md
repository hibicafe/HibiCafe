# Hibi Cafe production backup inventory

This folder contains a point-in-time, metadata-only schema inventory and the current public database function definitions. It does not contain live customer or transaction data.

## Data backup from the POS

Superusers can use **Settings → Download Full Data Backup**. The downloaded JSON contains all 21 public application tables, including orders, online customer details, expenses, shifts, reconciliations, fund transactions, fund snapshots, monthly-report settings/logs, product availability, user profiles, and audit history. It also records the Hibi order-number sequence.

The export intentionally does not include Supabase Auth password hashes, project secrets, or provider credentials. Treat the downloaded JSON as confidential because it includes customer details and financial records. Store it outside the public GitHub repository.

## Source-code backup

All five currently deployed Supabase Edge Functions are versioned under `supabase/functions/`. Function source is captured without environment-secret values; runtime secrets remain in Supabase project secrets.

## Migration history

The production registry and current database metadata are recorded in `production-schema-snapshot.json`. At the start of this backup work, production had 15 applied migrations while the repository contained only two historical migration SQL files. This update adds the newly applied 16th migration source. The 13 missing historical SQL bodies cannot be recovered from the migration registry alone; the snapshot records the current schema state without pretending to recreate those historical scripts.

## Restore guidance

1. Rebuild the schema from reviewed SQL/schema exports and versioned migrations.
2. Restore application data using a controlled, superuser-authorized process; check IDs, foreign keys, sequence state, and duplicate rows before importing.
3. Redeploy Edge Functions from their versioned source and reconfigure secrets separately.
4. Restore Supabase Auth users and external storage/provider assets separately.
