-- =====================================================================
--  Fix: "DELETE requires a WHERE clause" on Reset the draw / Draw names.
--  Supabase blocks DELETE/UPDATE without WHERE when called from the website.
--  Run once in Supabase -> SQL Editor. Safe to re-run. Keeps all data.
-- =====================================================================

create or replace function gx.do_draw() returns void
language plpgsql as $$
declare ids uuid[]; n int; i int;
begin
  select array_agg(id order by gen_random_uuid()) into ids from gx.people;
  n := coalesce(array_length(ids, 1), 0);
  if n < 3 then
    raise exception 'You need at least 3 people to draw names (currently %).', n;
  end if;
  delete from gx.messages where true;
  for i in 1..n loop
    update gx.people set assigned_to = ids[(i % n) + 1] where id = ids[i];
  end loop;
  update gx.config set drawn_at = now(), emails_sent_at = null where id = 1;
end $$;

create or replace function public.gx_admin_reset(p_key text) returns jsonb
language plpgsql security definer set search_path = gx, public, extensions as $$
begin
  perform gx.check_admin(p_key);
  delete from gx.messages where true;
  update gx.people set assigned_to = null where assigned_to is not null;
  update gx.config set drawn_at = null, emails_sent_at = null where id = 1;
  return jsonb_build_object('ok', true);
end $$;
