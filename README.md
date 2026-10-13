# Cloudflare lead endpoint

Replace Formspree (or any third-party form service) with ~170 lines of Cloudflare
Worker that writes every lead to a D1 database **first**, then emails it.

Built for static rank-and-rent microsites on Cloudflare Pages, but there is
nothing site-specific in it.

## Why

**A wrong form endpoint fails silently.** The form submits, the visitor sees a
thank-you page, and the lead is gone with no error anywhere. I nearly shipped a
site with a different site's endpoint baked into all twenty pages.

**You cannot test a Formspree endpoint.** It returns byte-identical responses for
a real form id and a made-up one:

```
GET  /f/realformid → 405      GET  /f/zzzzzzzz → 405
POST /f/realformid → {"error":"Bad form post request"}
POST /f/zzzzzzzz   → {"error":"Bad form post request"}
```

The only way to verify is to put a real lead through it. Which means you find out
from the customer who says they filled your form two weeks ago.

**Leads become queryable.** `SELECT count(*) FROM leads WHERE site = ? AND
created_at > ?` is the number you show a contractor when you rent him the site.
An inbox cannot produce it.

**One manual step per site disappears.** Formspree's public API has a single read
operation and no way to create a form, so every new site meant logging in and
clicking. Here it is one command.

**Storage outlives notification.** The database is the record; email is a notice.
Mine broke mid-build: three leads arrived, all three stored, each flagged
`emailed=0`. Nothing was lost and the flag said exactly what had happened.

**Free** at microsite scale — D1 and Pages free tiers, and Resend's free tier is
3,000 emails a month.

## The rule it enforces

A visitor is never shown a thank-you page unless the lead was **actually stored**
or **actually sent**. If both fail they get an error page and the Pages log gets a
`LEAD LOST` line.

Someone who sees an error picks up the phone. Someone who sees a false thank-you
does not.

| Bound | Behaviour | Visitor sees |
|---|---|---|
| D1 + Resend | stored, emailed, `emailed=1` | thank-you |
| D1 only | stored, `emailed=0` — nothing lost | thank-you |
| Resend only | emailed, not stored | thank-you |
| neither | `LEAD LOST` logged | error page |

## Two Cloudflare traps

Neither is in the documentation. Both cost me an afternoon.

**1. Pages silently discards plain-text environment variables.** The Pages project
API accepts a `plain_text` env var, echoes it back on write *and* on an immediate
read-back, then drops it before the next deployment. Only `secret_text` survives.

My from/to addresses vanished this way and three leads stored with `emailed=0`
before I caught it — by checking what the *deployment* carried rather than what
the *project config* claimed:

```bash
curl -H "Authorization: Bearer $TOKEN" \
  "https://api.cloudflare.com/client/v4/accounts/$ACC/pages/projects/$PROJECT/deployments"
```

Keep non-secrets out of Pages env vars. Inject them at build time.

**2. Bindings only reach deployments made after they are set.** Setting a binding
does nothing to the deployment already running. Bind, then redeploy — or you will
test against a worker with no database and conclude the code is broken.

## Files

| File | What it is |
|---|---|
| `worker.js` | the handler — stores, then notifies, then decides what to show |
| `schema.sql` | one shared table for a whole portfolio, with a `site` column per row |
| `setup.sh` | idempotent provisioning for one Pages project |

## Setup

You need a Cloudflare API token with **Pages:Edit** and **D1:Edit**, and a
[Resend](https://resend.com) API key with sending access. Resend's
`onboarding@resend.dev` sender needs no domain verification, but only delivers to
your own account address — verify a domain when leads should reach someone else.

Put these in a `.env` at your repo root (`chmod 600`, and gitignore it):

```
CLOUDFLARE_API_TOKEN=...
CLOUDFLARE_ACCOUNT_ID=...
RESEND_API_KEY=...
```

**1. Copy `worker.js` into your build output as `_worker.js`.**

Pages treats `_worker.js` in the published directory as the handler for every
request, falling through to static assets. That works for Direct Upload *and*
Git-connected projects, which a `functions/` directory does not.

Replace the four placeholders as you copy it — in my build script that is one
line:

```python
js = (src.read_text()
        .replace("__SITE_DOMAIN__", cfg["domain"])
        .replace("__SITE_BRAND__",  cfg["brand"])
        .replace("__LEAD_FROM__",   cfg["lead_from"])
        .replace("__LEAD_TO__",     cfg["lead_to"]))
(dist / "_worker.js").write_text(js)
```

**2. Provision and deploy.**

```bash
./setup.sh my-pages-project
wrangler pages deploy dist --project-name my-pages-project --branch main
```

The redeploy is not optional — see trap 2.

**3. Point your form at it.**

```html
<form action="/api/lead" method="POST">
```

Keep a hidden `_gotcha` input for the honeypot. The worker answers bots with a
thank-you and stores nothing.

**4. Verify by submitting the real form in a browser.**

Not curl. A successful curl against an endpoint is not evidence the form works —
that distinction is exactly how a broken form ships. Fill it in, click the button,
then:

```bash
wrangler d1 execute portfolio-leads --remote \
  --command "SELECT created_at, name, phone, city, emailed FROM leads ORDER BY created_at DESC LIMIT 5;"
```

`emailed=1` means stored and sent. `emailed=0` means stored but the email failed,
which is the whole point: the lead survives a broken notification path.

## Notes

**One database for the whole portfolio**, with a `site` column, rather than one
per site to forget about. The named columns are the ones worth querying across
sites; a `raw` column keeps every submitted field verbatim, so forms for different
trades coexist without a schema change.

**The honeypot** is a hidden `_gotcha` field. Bots fill hidden inputs; people
cannot see them. The worker answers as though it worked, so the bot learns
nothing, and stores nothing.

**Validation** is deliberately minimal: a name, plus a phone or an email. A lead
with no way to reach the person back is not a lead.

## Licence

MIT. Use it, change it, no attribution needed.
