-- =====================================================================
--  Upgrade: draw names the moment the countdown hits zero.
--  Run once in Supabase -> SQL Editor. Safe to re-run. Keeps all data.
-- =====================================================================

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

create or replace function public.gx_tick_now() returns jsonb
language plpgsql security definer set search_path = gx, public, extensions as $$
begin
  perform gx.tick();
  return jsonb_build_object('phase', gx.phase(gx.cfg()));
end $$;

revoke all on function public.gx_tick_now() from public;
grant execute on function public.gx_tick_now() to anon, authenticated;
