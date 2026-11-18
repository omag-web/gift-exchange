# OMAG Holiday Gift Exchange

A festive Secret Santa site for OMAG staff:

- Staff fill out a wish list → their name appears on the **Who's in** board.
- Each person picks a **4-digit PIN**. Their browser remembers them, and on any other computer or phone they **sign in with email + PIN**. Only they can see their match.
- At the **reveal time**, names draw automatically (one big loop: nobody gets themselves, no two-person swaps). Everyone opens their link, taps the gift, and sees who they're shopping for plus that person's whole list.
- Extras: countdown, spending limit and exchange day, **anonymous Q&A** between gifter and giftee (with "new" badges), **printable lists**, and an **organizer panel**.
- **No email setup needed.** On reveal day, send staff one normal Outlook or Teams message: "Names are out, go to the site." (Automatic emails are optional; see step 3.)

```
index.html                              ← the whole website (host on GitHub Pages)
supabase/schema.sql                     ← database + all server logic (paste into Supabase)
supabase/functions/send-emails/index.ts ← email sender (Supabase Edge Function + Resend)
supabase/email-schedule.sql             ← runs the email sender every minute
```

---

## Try it first (demo mode)

Open `index.html` in a browser. With no Supabase keys filled in, it runs in **demo mode**: data is saved only in your browser, with sample people. The admin passcode is `demo`. Sign up, open **Organizer → Reveal now**, then go to **My page** and tap the gift.

---

## 1. Create the database (about 5 min)

1. Go to **supabase.com** and create a new project (the free plan is fine). Pick a region near Oklahoma, such as East US.
2. Open **SQL Editor → New query**, paste all of `supabase/schema.sql`, and click **Run**.
3. Set your admin passcode with a new query:
   ```sql
   select gx.set_admin_passcode('pick-a-long-passcode-here');
   ```

## 2. Connect the site

1. In Supabase, open **Project Settings → API** (or **API Keys**). Copy the **Project URL** and the **anon / publishable** key.
2. Put them at the top of `index.html`:
   ```js
   SUPABASE_URL: "https://abcd1234.supabase.co",
   SUPABASE_ANON_KEY: "eyJ...or sb_publishable_...",
   ```
   It's safe for this key to be public. The website can only call the locked-down `gx_*` functions; it can't read any table directly.
3. Host `index.html` on GitHub Pages (for example, a repo `omag-web/gift-exchange` → Settings → Pages → deploy from `main`).
4. Open `https://<your-site>/#admin`, sign in, and fill in **Settings**: dates, budget, exchange day, and **Site address** (your GitHub Pages URL, used for links in emails). Setting **Only allow emails ending in** to `omag.org` keeps outsiders out.

That's it. The site is fully working.

### Updating an existing project
If you ran an older `schema.sql`, paste the newest one into the SQL Editor and run it again. It keeps all data and passcodes.

## 3. Automatic emails (optional, needs DNS)

Not required, since people sign in with email + PIN. Only set this up if you want automatic link, reveal and question emails. It needs DNS records added to a domain you control.

Emails cover personal links, "Lost your link?", the reveal notice, and anonymous question alerts. They're sent through **Resend** (free tier: 3,000 emails a month).

1. **Resend:** create an account at resend.com, then **Domains → Add domain** `omag.org`. Add the DNS records it shows to Route 53 and wait for "Verified". Then create an **API key**.
2. **Deploy the sender.** Either:
   - **Supabase CLI:**
     ```bash
     supabase login
     supabase link --project-ref YOUR-PROJECT-REF
     supabase secrets set RESEND_API_KEY=re_xxx EMAIL_FROM="OMAG Gift Exchange <giftexchange@omag.org>" CRON_SECRET=some-long-random-string
     supabase functions deploy send-emails --no-verify-jwt
     ```
   - **Or in the dashboard:** Edge Functions → Deploy a new function → name it `send-emails`, paste `index.ts`, and **turn off "Verify JWT"**. Then add the three secrets under Edge Functions → Secrets.
3. Open `supabase/email-schedule.sql`, replace `YOUR-PROJECT-REF` and `YOUR-CRON-SECRET`, and run it in the SQL Editor.
4. In the admin panel, check **Send emails** and save.

To test, sign up with your own email. The link email should arrive within about a minute. The admin panel shows queued and failed emails.

---

## Day-to-day

| You want to… | Do this |
|---|---|
| Change the form questions | Edit `QUESTIONS` at the top of `index.html`. Keep each `id` the same once people have signed up. |
| Close sign-ups | Set **Sign-ups close** (or draw names, which also closes them). |
| Reveal at a set time | Set **Names revealed**. The database checks every 5 minutes, draws, and emails everyone. |
| Reveal right now | Organizer → **🎁 Reveal now** |
| Draw early but keep it secret | Organizer → **Draw names now (keep sealed)** |
| Someone joined late after the draw | **Reset the draw**, then draw again. Everyone gets a new match, so do this before the reveal. |
| Someone forgot their PIN | Organizer → **Reset PIN** next to their name. You'll see a new 4-digit PIN once; give it to them. |
| Announce the reveal | Send staff an Outlook or Teams message with the site link once names are revealed. |
| See who has whom | Check **Show me who drew whom** (leave it off if you're playing too). |

## Next year

Run this in the SQL Editor to clear everything except your settings and passcode:

```sql
delete from gx.messages; delete from gx.outbox; delete from gx.people;
update gx.config set drawn_at = null, emails_sent_at = null, signup_deadline = null, reveal_at = null where id = 1;
```

## Good to know

- **Free Supabase projects pause after about a week with no activity.** While the exchange is running there's plenty of activity. If you open it in the off-season and it's paused, click **Restore** in the dashboard.
- PINs are stored scrambled (bcrypt), never in plain text. Five wrong tries locks that person's sign-in for 15 minutes.
- Behind the scenes each person also has a random 48-character sign-in code, which their browser keeps after signing up or signing in.
- Admin actions all require the passcode, and wrong guesses are slowed down. Use a long passcode.
- The anonymous Q&A never shows names in either direction, on the site or in emails.
