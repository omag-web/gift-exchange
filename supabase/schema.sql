-- =====================================================================
--  OMAG Holiday Gift Exchange — Supabase backend
--  Paste this whole file into Supabase → SQL Editor → Run.
--  Safe to re-run (it updates functions in place, keeps your data).
--
--  Security model
--  • All tables live in a private schema "gx" that the public API never
--    exposes, and RLS is on with no policies. The website can't read or
--    write any table directly.
--  • The website can only call the public.gx_* functions below. Each one
--    checks a personal token (participants) or the admin passcode.
--  • Nobody can see who drew whom through the website unless the admin
--    turns on "Show matches to admin" in the admin panel.
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;
create extension if not exists pg_cron;

create schema if not exists gx;
revoke all on schema gx from public, anon, authenticated;

-- ---------------------------------------------------------------------
--  Tables
-- ---------------------------------------------------------------------
create table if not exists gx.config (
  id                     int primary key default 1 check (id = 1),
  event_name             text not null default 'OMAG Holiday Gift Exchange',
  budget                 text not null default '$25',
  exchange_date          text not null default '',
  location               text not null default '',
  notes                  text not null default '',
  signup_deadline        timestamptz,
  reveal_at              timestamptz,
  allowed_domain         text not null default '',      -- e.g. omag.org ('' = any email)
  show_matches_to_admin  boolean not null default false,
  site_url               text not null default '',      -- e.g. https://omag-web.github.io/gift-exchange/
  email_enabled          boolean not null default false,
  drawn_at               timestamptz,
  emails_sent_at         timestamptz,
  admin_hash             text
);
insert into gx.config (id) values (1) on conflict (id) do nothing;

create table if not exists gx.people (
  id                 uuid primary key default gen_random_uuid(),
  name               text not null,
  email              text not null,
  answers            jsonb not null default '{}'::jsonb,
  token              text not null unique,
  assigned_to        uuid references gx.people(id) on delete set null,
  joined_at          timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  last_link_sent_at  timestamptz
);
create unique index if not exists people_email_uq on gx.people (lower(email));
-- PIN sign-in (added after first release; safe to re-run)
alter table gx.people add column if not exists pin_hash text;
alter table gx.people add column if not exists pin_fails int not null default 0;
alter table gx.people add column if not exists pin_locked_until timestamptz;

create table if not exists gx.messages (
  id            uuid primary key default gen_random_uuid(),
  giver_id      uuid not null references gx.people(id) on delete cascade,
  recipient_id  uuid not null references gx.people(id) on delete cascade,
  question      text not null,
  answer        text,
  asked_at      timestamptz not null default now(),
  answered_at   timestamptz
);
create index if not exists messages_recipient_idx on gx.messages (recipient_id);

create table if not exists gx.outbox (
  id          bigserial primary key,
  to_email    text not null,
  subject     text not null,
  html        text not null,
  created_at  timestamptz not null default now(),
  sent_at     timestamptz,
  attempts    int not null default 0,
  last_error  text
);
create index if not exists outbox_pending_idx on gx.outbox (id) where sent_at is null;

alter table gx.config   enable row level security;
alter table gx.people   enable row level security;
alter table gx.messages enable row level security;
alter table gx.outbox   enable row level security;
revoke all on all tables in schema gx from public, anon, authenticated;

-- ---------------------------------------------------------------------
--  Private helpers (schema gx — not reachable from the website)
-- ---------------------------------------------------------------------
create or replace function gx.cfg() returns gx.config
language sql stable as $$ select * from gx.config where id = 1 $$;

create or replace function gx.phase(c gx.config) returns text
language sql stable as $$
  select case
    when c.drawn_at is not null and (c.reveal_at is null or now() >= c.reveal_at) then 'revealed'
    when c.drawn_at is not null or (c.signup_deadline is not null and now() >= c.signup_deadline) then 'closed'
    else 'open'
  end
$$;

create or replace function gx.h(t text) returns text
language sql immutable as $$
  select replace(replace(replace(replace(coalesce(t,''),'&','&amp;'),'<','&lt;'),'>','&gt;'),'"','&quot;')
$$;

create or replace function gx.clean_answers(a jsonb) returns jsonb
language plpgsql immutable as $$
declare r jsonb;
begin
  if a is null or jsonb_typeof(a) <> 'object' then return '{}'::jsonb; end if;
  select coalesce(jsonb_object_agg(key, left(btrim(val), 1000)), '{}'::jsonb) into r
  from (
    select key, value #>> '{}' as val
    from jsonb_each(a)
    where key ~ '^[A-Za-z0-9_-]{1,40}$' and jsonb_typeof(value) in ('string','number')
    limit 40
  ) s
  where val is not null and btrim(val) <> '';
  return r;
end $$;

create or replace function gx.me(p_token text) returns gx.people
language plpgsql stable as $$
declare p gx.people;
begin
  select * into p from gx.people where token = p_token;
  if not found or coalesce(p_token,'') = '' then
    raise exception 'That sign-in has expired. Please sign in again with your email and PIN.';
  end if;
  return p;
end $$;

create or replace function gx.check_admin(p_key text) returns void
language plpgsql as $$
declare c gx.config := gx.cfg();
begin
  if c.admin_hash is null then
    raise exception 'Admin passcode has not been set yet. Run select gx.set_admin_passcode(''...''); in the SQL editor.';
  end if;
  if p_key is null or extensions.crypt(p_key, c.admin_hash) <> c.admin_hash then
    perform pg_sleep(1);  -- slows down guessing
    raise exception 'Incorrect admin passcode.';
  end if;
end $$;

create or replace function gx.set_admin_passcode(p_new text) returns text
language plpgsql as $$
begin
  if length(coalesce(p_new,'')) < 8 then raise exception 'Use at least 8 characters.'; end if;
  update gx.config set admin_hash = extensions.crypt(p_new, extensions.gen_salt('bf')) where id = 1;
  return 'Admin passcode set.';
end $$;

create or replace function gx.link(p_token text) returns text
language sql stable as $$
  select case when c.site_url = '' then null
              else rtrim(c.site_url, '/') || '/?t=' || p_token || '#me' end
  from gx.config c where c.id = 1
$$;

create or replace function gx.email_shell(p_heading text, p_body_html text, p_link text, p_button text)
returns text language sql stable as $$
  select
  '<div style="background:#f6efe2;padding:32px 12px;font-family:Georgia,serif">'
  || '<div style="max-width:520px;margin:0 auto;background:#fffdf8;border-radius:14px;overflow:hidden;border:1px solid #e6dccb">'
  || '<div style="background:#0e3b2e;color:#fbf5e9;padding:22px 28px;font-size:13px;letter-spacing:.14em;text-transform:uppercase">'
  || gx.h(c.event_name) || '</div>'
  || '<div style="padding:28px">'
  || '<h1 style="margin:0 0 14px;color:#0e3b2e;font-size:26px;line-height:1.2">' || gx.h(p_heading) || '</h1>'
  || '<div style="font-family:Arial,sans-serif;color:#2b3330;font-size:15px;line-height:1.6">' || p_body_html || '</div>'
  || case when p_link is not null then
       '<p style="margin:26px 0 8px"><a href="' || gx.h(p_link) || '" style="background:#b0283f;color:#fff;text-decoration:none;padding:13px 22px;border-radius:999px;font-family:Arial,sans-serif;font-weight:bold;display:inline-block">'
       || gx.h(p_button) || '</a></p>'
       || '<p style="font-family:Arial,sans-serif;font-size:12px;color:#6b746f">This link is just for you — please don''t forward it.</p>'
     else '' end
  || '</div></div></div>'
  from gx.config c where c.id = 1
$$;

create or replace function gx.queue(p_to text, p_subject text, p_html text) returns void
language plpgsql as $$
begin
  if (select email_enabled from gx.config where id = 1) then
    insert into gx.outbox (to_email, subject, html) values (p_to, p_subject, p_html);
  end if;
end $$;

create or replace function gx.queue_link_email(p gx.people) returns void
language plpgsql as $$
declare c gx.config := gx.cfg();
begin
  perform gx.queue(p.email, 'Your link for the ' || c.event_name,
    gx.email_shell('You''re on the list, ' || split_part(p.name,' ',1) || '!',
      '<p>Thanks for joining the ' || gx.h(c.event_name) || '. Use your personal link any time to update your wish list, and come back on reveal day to see who you''re shopping for.</p>',
      gx.link(p.token), 'Open my gift exchange page'));
  update gx.people set last_link_sent_at = now() where id = p.id;
end $$;

create or replace function gx.do_draw() returns void
language plpgsql as $$
declare ids uuid[]; n int; i int;
begin
  -- One big loop: everyone gives to the next person in a random order.
  -- Nobody draws themselves and there are no two-person swaps.
  select array_agg(id order by gen_random_uuid()) into ids from gx.people;
  n := coalesce(array_length(ids, 1), 0);
  if n < 3 then
    raise exception 'You need at least 3 people to draw names (currently %).', n;
  end if;
  delete from gx.messages;
  for i in 1..n loop
    update gx.people set assigned_to = ids[(i % n) + 1] where id = ids[i];
  end loop;
  update gx.config set drawn_at = now(), emails_sent_at = null where id = 1;
end $$;

create or replace function gx.queue_reveal_emails() returns void
language plpgsql as $$
declare c gx.config := gx.cfg(); p gx.people;
begin
  if not c.email_enabled or c.emails_sent_at is not null or gx.phase(c) <> 'revealed' then return; end if;
  for p in select * from gx.people loop
    perform gx.queue(p.email, '🎁 Names are drawn — see who you''re shopping for',
      gx.email_shell('The names are drawn!',
        '<p>Hi ' || gx.h(split_part(p.name,' ',1)) || ', the ' || gx.h(c.event_name) || ' is officially on.</p>'
        || '<p>Open your page to see who you''re shopping for and their whole wish list.'
        || case when c.budget <> '' then ' Spending limit: <b>' || gx.h(c.budget) || '</b>.' else '' end
        || case when c.exchange_date <> '' then ' Exchange: <b>' || gx.h(c.exchange_date) || '</b>.' else '' end
        || '</p>',
        gx.link(p.token), 'See who I drew'));
  end loop;
  update gx.config set emails_sent_at = now() where id = 1;
end $$;

-- Runs every 5 minutes (pg_cron), and when anyone's countdown reaches zero
-- (public.gx_tick_now). Locks the settings row so the draw only ever happens once.
create or replace function gx.tick() returns void
language plpgsql as $$
declare c gx.config;
begin
  select * into c from gx.config where id = 1 for update;
  if c.drawn_at is null and c.reveal_at is not null and now() >= c.reveal_at
     and (select count(*) from gx.people) >= 3 then
    perform gx.do_draw();
  end if;
  perform gx.queue_reveal_emails();
end $$;

create or replace function gx.public_config(c gx.config) returns jsonb
language sql stable as $$
  select jsonb_build_object(
    'eventName', c.event_name, 'budget', c.budget, 'exchangeDate', c.exchange_date,
    'location', c.location, 'notes', c.notes, 'signupDeadline', c.signup_deadline,
    'revealAt', c.reveal_at, 'allowedDomain', c.allowed_domain)
$$;

-- ---------------------------------------------------------------------
--  Public API (called by the website)
-- ---------------------------------------------------------------------
create or replace function public.gx_get_public() returns jsonb
language plpgsql security definer set search_path = gx, public, extensions as $$
declare c gx.config := gx.cfg();
begin
  return jsonb_build_object(
    'config', gx.public_config(c),
    'phase', gx.phase(c),
    'emailEnabled', c.email_enabled,
    'now', now(),
    'participants', coalesce((select jsonb_agg(jsonb_build_object('name', name, 'joinedAt', joined_at) order by joined_at) from gx.people), '[]'::jsonb));
end $$;

create or replace function gx.check_pin(p_pin text) returns void
language plpgsql immutable as $$
begin
  if coalesce(p_pin,'') !~ '^[0-9]{4}$' then raise exception 'Your PIN needs to be exactly 4 numbers.'; end if;
end $$;

drop function if exists public.gx_signup(text, text, jsonb);   -- older version without PIN
create or replace function public.gx_signup(p_name text, p_email text, p_answers jsonb, p_pin text) returns jsonb
language plpgsql security definer set search_path = gx, public, extensions as $$
declare
  c gx.config := gx.cfg();
  v_name text := left(btrim(coalesce(p_name,'')), 80);
  v_email text := lower(left(btrim(coalesce(p_email,'')), 200));
  p gx.people;
begin
  if gx.phase(c) <> 'open' then raise exception 'Sign-ups are closed.'; end if;
  if v_name = '' then raise exception 'Please enter your name.'; end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Please enter a valid email address.'; end if;
  if c.allowed_domain <> '' and v_email not like '%@' || lower(c.allowed_domain) then
    raise exception 'Please use your @% email address.', c.allowed_domain;
  end if;
  perform gx.check_pin(p_pin);
  if exists (select 1 from gx.people where lower(email) = v_email) then
    raise exception 'That email is already signed up. Use "Sign in" with your email and PIN.';
  end if;
  insert into gx.people (name, email, answers, token, pin_hash)
  values (v_name, v_email, gx.clean_answers(p_answers), encode(extensions.gen_random_bytes(24), 'hex'),
          extensions.crypt(p_pin, extensions.gen_salt('bf')))
  returning * into p;
  perform gx.queue_link_email(p);
  return jsonb_build_object('token', p.token, 'id', p.id, 'emailEnabled', c.email_enabled);
end $$;

-- Sign in from any device with email + 4-digit PIN.
-- Returns {ok:false,error} instead of raising so failed attempts are counted
-- (5 wrong tries locks that person's sign-in for 15 minutes).
create or replace function public.gx_login(p_email text, p_pin text) returns jsonb
language plpgsql security definer set search_path = gx, public, extensions as $$
declare p gx.people;
begin
  select * into p from gx.people where lower(email) = lower(btrim(coalesce(p_email,'')));
  if not found or p.pin_hash is null then
    perform pg_sleep(0.5);
    return jsonb_build_object('ok', false, 'error', 'That email and PIN don''t match. Check both and try again.');
  end if;
  if p.pin_locked_until is not null and p.pin_locked_until > now() then
    return jsonb_build_object('ok', false, 'error', 'Too many tries. Wait 15 minutes, or ask the organizer to reset your PIN.');
  end if;
  if extensions.crypt(coalesce(p_pin,''), p.pin_hash) <> p.pin_hash then
    update gx.people
       set pin_fails = case when pin_fails + 1 >= 5 then 0 else pin_fails + 1 end,
           pin_locked_until = case when pin_fails + 1 >= 5 then now() + interval '15 minutes' else pin_locked_until end
     where id = p.id;
    perform pg_sleep(0.5);
    return jsonb_build_object('ok', false, 'error', 'That email and PIN don''t match. Check both and try again.');
  end if;
  update gx.people set pin_fails = 0, pin_locked_until = null where id = p.id;
  return jsonb_build_object('ok', true, 'token', p.token);
end $$;

create or replace function public.gx_set_pin(p_token text, p_pin text) returns jsonb
language plpgsql security definer set search_path = gx, public, extensions as $$
declare p gx.people := gx.me(p_token);
begin
  perform gx.check_pin(p_pin);
  update gx.people set pin_hash = extensions.crypt(p_pin, extensions.gen_salt('bf')), pin_fails = 0, pin_locked_until = null where id = p.id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.gx_resend_link(p_email text) returns jsonb
language plpgsql security definer set search_path = gx, public, extensions as $$
declare c gx.config := gx.cfg(); p gx.people;
begin
  if not c.email_enabled then
    return jsonb_build_object('ok', false, 'emailEnabled', false);
  end if;
  select * into p from gx.people where lower(email) = lower(btrim(coalesce(p_email,'')));
  -- Same answer whether or not the email exists; at most one email per 2 minutes.
  if found and (p.last_link_sent_at is null or p.last_link_sent_at < now() - interval '2 minutes') then
    perform gx.queue_link_email(p);
  end if;
  return jsonb_build_object('ok', true, 'emailEnabled', true);
end $$;

create or replace function public.gx_get_me(p_token text) returns jsonb
language plpgsql security definer set search_path = gx, public, extensions as $$
declare
  p gx.people := gx.me(p_token);
  c gx.config := gx.cfg();
  ph text := gx.phase(c);
  r gx.people; santa uuid;
  recipient jsonb := null; sent jsonb := '[]'; received jsonb := '[]';
begin
  if ph = 'revealed' and p.assigned_to is not null then
    select * into r from gx.people where id = p.assigned_to;
    recipient := jsonb_build_object('name', r.name, 'answers', r.answers);
    select coalesce(jsonb_agg(jsonb_build_object('id', id, 'question', question, 'answer', answer, 'askedAt', asked_at, 'answeredAt', answered_at) order by asked_at), '[]')
      into sent from gx.messages where giver_id = p.id and recipient_id = r.id;
    select id into santa from gx.people where assigned_to = p.id;
    select coalesce(jsonb_agg(jsonb_build_object('id', id, 'question', question, 'answer', answer, 'askedAt', asked_at, 'answeredAt', answered_at) order by asked_at), '[]')
      into received from gx.messages where recipient_id = p.id and giver_id = santa;
  end if;
  return jsonb_build_object(
    'me', jsonb_build_object('id', p.id, 'name', p.name, 'email', p.email, 'answers', p.answers, 'hasPin', p.pin_hash is not null),
    'config', gx.public_config(c), 'phase', ph, 'drawn', c.drawn_at is not null,
    'recipient', recipient, 'sentQuestions', sent, 'receivedQuestions', received);
end $$;

create or replace function public.gx_update_me(p_token text, p_name text, p_answers jsonb) returns jsonb
language plpgsql security definer set search_path = gx, public, extensions as $$
declare p gx.people := gx.me(p_token); v_name text := left(btrim(coalesce(p_name,'')), 80);
begin
  update gx.people
     set name = case when v_name = '' then name else v_name end,
         answers = gx.clean_answers(p_answers), updated_at = now()
   where id = p.id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.gx_withdraw_me(p_token text) returns jsonb
language plpgsql security definer set search_path = gx, public, extensions as $$
declare p gx.people := gx.me(p_token);
begin
  if (select drawn_at from gx.config where id = 1) is not null then
    raise exception 'Names have already been drawn. Please talk to the organizer.';
  end if;
  delete from gx.people where id = p.id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.gx_ask(p_token text, p_question text) returns jsonb
language plpgsql security definer set search_path = gx, public, extensions as $$
declare p gx.people := gx.me(p_token); c gx.config := gx.cfg(); r gx.people; q text := left(btrim(coalesce(p_question,'')), 500);
begin
  if gx.phase(c) <> 'revealed' or p.assigned_to is null then raise exception 'You can ask questions once names are revealed.'; end if;
  if q = '' then raise exception 'Type a question first.'; end if;
  if (select count(*) from gx.messages where giver_id = p.id) >= 50 then raise exception 'That''s a lot of questions! Try asking in person.'; end if;
  select * into r from gx.people where id = p.assigned_to;
  insert into gx.messages (giver_id, recipient_id, question) values (p.id, r.id, q);
  perform gx.queue(r.email, '🤫 Your Secret Santa has a question',
    gx.email_shell('Your Secret Santa has a question',
      '<p style="font-size:17px;font-style:italic;border-left:3px solid #c8a24a;padding-left:12px">“' || gx.h(q) || '”</p><p>Open your page to answer. They won''t see who you are, and you won''t see who they are.</p>',
      gx.link(r.token), 'Answer anonymously'));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.gx_reply(p_token text, p_id uuid, p_answer text) returns jsonb
language plpgsql security definer set search_path = gx, public, extensions as $$
declare p gx.people := gx.me(p_token); m gx.messages; g gx.people; a text := left(btrim(coalesce(p_answer,'')), 500);
begin
  if a = '' then raise exception 'Type an answer first.'; end if;
  select * into m from gx.messages where id = p_id and recipient_id = p.id;
  if not found then raise exception 'Question not found.'; end if;
  update gx.messages set answer = a, answered_at = now() where id = m.id;
  select * into g from gx.people where id = m.giver_id;
  perform gx.queue(g.email, '🎁 Your giftee answered your question',
    gx.email_shell('You got an answer!',
      '<p><b>You asked:</b> ' || gx.h(m.question) || '</p><p><b>They said:</b> ' || gx.h(a) || '</p>',
      gx.link(g.token), 'Open my page'));
  return jsonb_build_object('ok', true);
end $$;

-- Called by the website when a countdown reaches zero, so names draw right
-- on time instead of waiting for the next 5-minute scheduler run.
-- Does nothing unless the "Names drawn" time has passed.
create or replace function public.gx_tick_now() returns jsonb
language plpgsql security definer set search_path = gx, public, extensions as $$
begin
  perform gx.tick();
  return jsonb_build_object('phase', gx.phase(gx.cfg()));
end $$;

-- ---------------------------------------------------------------------
--  Admin API (every call checks the admin passcode)
-- ---------------------------------------------------------------------
create or replace function public.gx_admin_get(p_key text) returns jsonb
language plpgsql security definer set search_path = gx, public, extensions as $$
declare c gx.config;
begin
  perform gx.check_admin(p_key);
  c := gx.cfg();
  return jsonb_build_object(
    'config', gx.public_config(c) || jsonb_build_object(
       'showMatchesToAdmin', c.show_matches_to_admin, 'siteUrl', c.site_url,
       'emailEnabled', c.email_enabled, 'drawnAt', c.drawn_at, 'emailsSentAt', c.emails_sent_at),
    'phase', gx.phase(c),
    'pendingEmails', (select count(*) from gx.outbox where sent_at is null and attempts < 5),
    'failedEmails', (select count(*) from gx.outbox where sent_at is null and attempts >= 5),
    'people', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', p.id, 'name', p.name, 'email', p.email, 'joinedAt', p.joined_at, 'updatedAt', p.updated_at,
        'answerCount', (select count(*) from jsonb_object_keys(p.answers)),
        'assignedToName', case when c.show_matches_to_admin then (select name from gx.people x where x.id = p.assigned_to) end
      ) order by p.joined_at) from gx.people p), '[]'::jsonb));
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
    email_enabled         = coalesce((p_cfg->>'emailEnabled')::boolean, email_enabled)
  where id = 1;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.gx_admin_draw(p_key text) returns jsonb
language plpgsql security definer set search_path = gx, public, extensions as $$
begin
  perform gx.check_admin(p_key);
  if (select drawn_at from gx.config where id = 1) is not null then raise exception 'Names are already drawn. Reset first to redraw.'; end if;
  perform gx.do_draw();
  perform gx.queue_reveal_emails();   -- only sends if the reveal time has passed
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.gx_admin_reveal_now(p_key text) returns jsonb
language plpgsql security definer set search_path = gx, public, extensions as $$
begin
  perform gx.check_admin(p_key);
  if (select drawn_at from gx.config where id = 1) is null then perform gx.do_draw(); end if;
  update gx.config set reveal_at = now() where id = 1;
  perform gx.queue_reveal_emails();
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.gx_admin_reset(p_key text) returns jsonb
language plpgsql security definer set search_path = gx, public, extensions as $$
begin
  perform gx.check_admin(p_key);
  delete from gx.messages;
  update gx.people set assigned_to = null;
  update gx.config set drawn_at = null, emails_sent_at = null where id = 1;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.gx_admin_resend_reveal(p_key text) returns jsonb
language plpgsql security definer set search_path = gx, public, extensions as $$
begin
  perform gx.check_admin(p_key);
  if gx.phase(gx.cfg()) <> 'revealed' then raise exception 'Names haven''t been revealed yet.'; end if;
  update gx.config set emails_sent_at = null where id = 1;
  perform gx.queue_reveal_emails();
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.gx_admin_send_link(p_key text, p_id uuid) returns jsonb
language plpgsql security definer set search_path = gx, public, extensions as $$
declare p gx.people;
begin
  perform gx.check_admin(p_key);
  if not (select email_enabled from gx.config where id = 1) then raise exception 'Email is turned off. Turn it on in Settings first.'; end if;
  select * into p from gx.people where id = p_id;
  if not found then raise exception 'Person not found.'; end if;
  perform gx.queue_link_email(p);
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.gx_admin_remove(p_key text, p_id uuid) returns jsonb
language plpgsql security definer set search_path = gx, public, extensions as $$
begin
  perform gx.check_admin(p_key);
  if (select drawn_at from gx.config where id = 1) is not null then
    raise exception 'Reset the draw before removing someone (removing them would break the loop).';
  end if;
  delete from gx.people where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

-- Gives someone a new random PIN (shown once to the organizer) if they forget theirs.
create or replace function public.gx_admin_reset_pin(p_key text, p_id uuid) returns jsonb
language plpgsql security definer set search_path = gx, public, extensions as $$
declare v_pin text := lpad((floor(random() * 10000))::int::text, 4, '0');
begin
  perform gx.check_admin(p_key);
  update gx.people set pin_hash = extensions.crypt(v_pin, extensions.gen_salt('bf')), pin_fails = 0, pin_locked_until = null where id = p_id;
  if not found then raise exception 'Person not found.'; end if;
  return jsonb_build_object('ok', true, 'pin', v_pin);
end $$;

create or replace function public.gx_admin_change_passcode(p_key text, p_new text) returns jsonb
language plpgsql security definer set search_path = gx, public, extensions as $$
begin
  perform gx.check_admin(p_key);
  perform gx.set_admin_passcode(p_new);
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------
--  Email outbox API (only the send-emails Edge Function can call these)
-- ---------------------------------------------------------------------
create or replace function public.gx_outbox_next(p_limit int default 40) returns jsonb
language plpgsql security definer set search_path = gx, public, extensions as $$
declare r jsonb;
begin
  with picked as (
    select id from gx.outbox
     where sent_at is null and attempts < 5
     order by id limit least(greatest(p_limit,1),100)
     for update skip locked
  ), bumped as (
    update gx.outbox o set attempts = o.attempts + 1
      from picked where o.id = picked.id
    returning o.id, o.to_email, o.subject, o.html
  )
  select coalesce(jsonb_agg(to_jsonb(bumped) order by id), '[]'::jsonb) into r from bumped;
  return r;
end $$;

create or replace function public.gx_outbox_mark(p_id bigint, p_error text) returns void
language sql security definer set search_path = gx, public, extensions as $$
  update gx.outbox
     set sent_at = case when p_error is null then now() else null end,
         last_error = p_error
   where id = p_id
$$;

-- ---------------------------------------------------------------------
--  Permissions
-- ---------------------------------------------------------------------
do $$
declare f text;
begin
  foreach f in array array[
    'gx_get_public()', 'gx_signup(text,text,jsonb,text)', 'gx_resend_link(text)',
    'gx_login(text,text)', 'gx_set_pin(text,text)', 'gx_admin_reset_pin(text,uuid)', 'gx_tick_now()',
    'gx_get_me(text)', 'gx_update_me(text,text,jsonb)', 'gx_withdraw_me(text)',
    'gx_ask(text,text)', 'gx_reply(text,uuid,text)',
    'gx_admin_get(text)', 'gx_admin_save(text,jsonb)', 'gx_admin_draw(text)',
    'gx_admin_reveal_now(text)', 'gx_admin_reset(text)', 'gx_admin_resend_reveal(text)',
    'gx_admin_send_link(text,uuid)', 'gx_admin_remove(text,uuid)', 'gx_admin_change_passcode(text,text)'
  ] loop
    execute format('revoke all on function public.%s from public', f);
    execute format('grant execute on function public.%s to anon, authenticated', f);
  end loop;

  foreach f in array array['gx_outbox_next(int)', 'gx_outbox_mark(bigint,text)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;

-- ---------------------------------------------------------------------
--  Scheduled job: auto-draw at reveal time + queue reveal emails
-- ---------------------------------------------------------------------
select cron.schedule('gx-tick', '*/5 * * * *', 'select gx.tick()');

-- ---------------------------------------------------------------------
--  LAST STEP: set your admin passcode (change this!) and run it once.
-- ---------------------------------------------------------------------
-- select gx.set_admin_passcode('pick-a-long-passcode-here');
