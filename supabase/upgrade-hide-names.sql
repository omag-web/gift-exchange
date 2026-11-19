-- =====================================================================
--  Upgrade: organizer switch to hide participant names on the home page.
--  Run once in Supabase -> SQL Editor. Safe to re-run. Keeps all data.
-- =====================================================================

alter table gx.config add column if not exists hide_participants boolean not null default false;

create or replace function gx.public_config(c gx.config) returns jsonb
language sql stable as $$
  select jsonb_build_object(
    'eventName', c.event_name, 'budget', c.budget, 'exchangeDate', c.exchange_date,
    'location', c.location, 'notes', c.notes, 'signupDeadline', c.signup_deadline,
    'revealAt', c.reveal_at, 'allowedDomain', c.allowed_domain,
    'hideParticipants', c.hide_participants)
$$;

create or replace function public.gx_get_public() returns jsonb
language plpgsql security definer set search_path = gx, public, extensions as $$
declare c gx.config := gx.cfg();
begin
  return jsonb_build_object(
    'config', gx.public_config(c),
    'phase', gx.phase(c),
    'emailEnabled', c.email_enabled,
    'now', now(),
    'count', (select count(*) from gx.people),
    'participants', case when c.hide_participants then '[]'::jsonb
      else coalesce((select jsonb_agg(jsonb_build_object('name', name, 'joinedAt', joined_at) order by joined_at) from gx.people), '[]'::jsonb) end);
end $$;

create or replace function public.gx_admin_save(p_key text, p_cfg jsonb) returns jsonb
language plpgsql security definer set search_path = gx, public, extensions as $$
begin
  perform gx.check_admin(p_key);
  update gx.config set
    event_name            = coalesce(nullif(left(btrim(p_cfg->>'eventName'),120),''), event_name),
    budget                = coalesce(left(btrim(p_cfg->>'budget'),40), budget),
    exchange_date         = coalesce(left(btrim(p_cfg->>'exchangeDate'),120), exchange_date),
    location              = coalesce(left(btrim(p_cfg->>'location'),160), location),
    notes                 = coalesce(left(btrim(p_cfg->>'notes'),1000), notes),
    signup_deadline       = case when p_cfg ? 'signupDeadline' then nullif(p_cfg->>'signupDeadline','')::timestamptz else signup_deadline end,
    reveal_at             = case when p_cfg ? 'revealAt' then nullif(p_cfg->>'revealAt','')::timestamptz else reveal_at end,
    allowed_domain        = coalesce(lower(ltrim(btrim(p_cfg->>'allowedDomain'),'@')), allowed_domain),
    show_matches_to_admin = coalesce((p_cfg->>'showMatchesToAdmin')::boolean, show_matches_to_admin),
    site_url              = coalesce(btrim(p_cfg->>'siteUrl'), site_url),
    email_enabled         = coalesce((p_cfg->>'emailEnabled')::boolean, email_enabled),
    hide_participants     = coalesce((p_cfg->>'hideParticipants')::boolean, hide_participants)
  where id = 1;
  return jsonb_build_object('ok', true);
end $$;
