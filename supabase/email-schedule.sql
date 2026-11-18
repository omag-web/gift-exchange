-- =====================================================================
--  Email schedule — run this AFTER deploying the send-emails function.
--  Replace the two placeholders, then run in Supabase → SQL Editor.
--
--  YOUR-PROJECT-REF  → the ID in your project URL (https://YOUR-PROJECT-REF.supabase.co)
--  YOUR-CRON-SECRET  → the same CRON_SECRET you set as an Edge Function secret
-- =====================================================================

create extension if not exists pg_net;

select cron.schedule(
  'gx-send-emails',
  '* * * * *',
  $$
  select net.http_post(
    url     := 'https://YOUR-PROJECT-REF.supabase.co/functions/v1/send-emails',
    headers := jsonb_build_object('content-type', 'application/json', 'x-cron-secret', 'YOUR-CRON-SECRET'),
    body    := '{}'::jsonb
  );
  $$
);

-- Finally, turn email on (or flip the switch in the admin panel's Settings):
-- update gx.config set email_enabled = true where id = 1;
