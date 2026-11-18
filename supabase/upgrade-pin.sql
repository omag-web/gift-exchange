-- =====================================================================
--  Upgrade: PIN sign-in. Run once in Supabase -> SQL Editor.
--  Safe to re-run. Keeps all data and your admin passcode.
-- =====================================================================

alter table gx.people add column if not exists pin_hash text;
alter table gx.people add column if not exists pin_fails int not null default 0;
alter table gx.people add column if not exists pin_locked_until timestamptz;

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

create or replace function gx.check_pin(p_pin text) returns void
language plpgsql immutable as $$
begin
  if coalesce(p_pin,'') !~ '^[0-9]{4}$' then raise exception 'Your PIN needs to be exactly 4 numbers.'; end if;
end $$;

drop function if exists public.gx_signup(text, text, jsonb);
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

create or replace function public.gx_admin_reset_pin(p_key text, p_id uuid) returns jsonb
language plpgsql security definer set search_path = gx, public, extensions as $$
declare v_pin text := lpad((floor(random() * 10000))::int::text, 4, '0');
begin
  perform gx.check_admin(p_key);
  update gx.people set pin_hash = extensions.crypt(v_pin, extensions.gen_salt('bf')), pin_fails = 0, pin_locked_until = null where id = p_id;
  if not found then raise exception 'Person not found.'; end if;
  return jsonb_build_object('ok', true, 'pin', v_pin);
end $$;

revoke all on function public.gx_signup(text,text,jsonb,text) from public;
revoke all on function public.gx_login(text,text) from public;
revoke all on function public.gx_set_pin(text,text) from public;
revoke all on function public.gx_admin_reset_pin(text,uuid) from public;
grant execute on function public.gx_signup(text,text,jsonb,text) to anon, authenticated;
grant execute on function public.gx_login(text,text) to anon, authenticated;
grant execute on function public.gx_set_pin(text,text) to anon, authenticated;
grant execute on function public.gx_admin_reset_pin(text,uuid) to anon, authenticated;
