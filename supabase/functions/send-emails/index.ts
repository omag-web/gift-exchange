// OMAG Gift Exchange — email sender (Supabase Edge Function)
//
// Runs every minute (scheduled in supabase/email-schedule.sql). It takes queued
// emails from the database outbox and sends them through Resend.
//
// Secrets to set (Supabase → Edge Functions → Secrets):
//   RESEND_API_KEY  – from resend.com
//   EMAIL_FROM      – e.g. "OMAG Gift Exchange <giftexchange@omag.org>"
//   CRON_SECRET     – any long random string; must match email-schedule.sql
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided automatically.
//
// Deploy with:  supabase functions deploy send-emails --no-verify-jwt

const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY") ?? "";
const EMAIL_FROM = Deno.env.get("EMAIL_FROM") ?? "";
const CRON_SECRET = Deno.env.get("CRON_SECRET") ?? "";
const SB_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SB_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

type Mail = { id: number; to_email: string; subject: string; html: string };

async function rpc<T>(fn: string, args: Record<string, unknown>): Promise<T> {
  const res = await fetch(`${SB_URL}/rest/v1/rpc/${fn}`, {
    method: "POST",
    headers: { apikey: SB_KEY, Authorization: `Bearer ${SB_KEY}`, "content-type": "application/json" },
    body: JSON.stringify(args),
  });
  if (!res.ok) throw new Error(`${fn} failed: ${res.status} ${await res.text()}`);
  const text = await res.text();
  return (text ? JSON.parse(text) : null) as T;
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

Deno.serve(async (req) => {
  if (!CRON_SECRET || req.headers.get("x-cron-secret") !== CRON_SECRET) {
    return new Response("Unauthorized", { status: 401 });
  }
  if (!RESEND_API_KEY || !EMAIL_FROM) {
    return Response.json({ error: "RESEND_API_KEY and EMAIL_FROM secrets are required" }, { status: 500 });
  }

  const batch = await rpc<Mail[]>("gx_outbox_next", { p_limit: 40 });
  let sent = 0;
  const errors: string[] = [];

  for (const m of batch) {
    try {
      const r = await fetch("https://api.resend.com/emails", {
        method: "POST",
        headers: { Authorization: `Bearer ${RESEND_API_KEY}`, "content-type": "application/json" },
        body: JSON.stringify({ from: EMAIL_FROM, to: [m.to_email], subject: m.subject, html: m.html }),
      });
      if (!r.ok) throw new Error(`Resend ${r.status}: ${await r.text()}`);
      await rpc("gx_outbox_mark", { p_id: m.id, p_error: null });
      sent++;
    } catch (e) {
      const msg = String(e instanceof Error ? e.message : e).slice(0, 500);
      errors.push(msg);
      await rpc("gx_outbox_mark", { p_id: m.id, p_error: msg }).catch(() => {});
    }
    await sleep(550); // stay under Resend's default 2 requests/second
  }

  return Response.json({ attempted: batch.length, sent, errors });
});
