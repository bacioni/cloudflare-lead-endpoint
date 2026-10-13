// Lead capture for the rank-and-rent portfolio.
//
// Cloudflare Pages serves this as dist/_worker.js ("advanced mode"): it handles
// every request, passing anything that is not a lead POST straight to the
// static assets. That form works under both Git-connected and Direct Upload
// Pages projects, which a functions/ directory does not.
//
// The one rule this file exists to enforce: NEVER tell a visitor their message
// was sent unless it was actually stored or actually emailed. A silent loss is
// worse than a visible error, because the visitor would have called instead.

const SITE = "__SITE_DOMAIN__";        // injected by build.py
const BRAND = "__SITE_BRAND__";        // injected by build.py

// Injected too, not read from Pages env vars. Cloudflare's project API accepts a
// plain_text var, echoes it back on write AND on an immediate read, then drops
// it before the next deployment; only secret_text survives. These two are not
// secrets, so they belong in site.config.json and in the build. The API key is
// the only thing that has to be a binding. An env var still wins if one is set.
const LEAD_FROM_DEFAULT = "__LEAD_FROM__";
const LEAD_TO_DEFAULT = "__LEAD_TO__";
const THANKS = "/thank-you/";
const FAILED = "/contact/?error=1";

// Columns worth querying across every site. Everything else lands in `raw`.
const KNOWN = ["name", "phone", "email", "city", "service_need", "urgency", "detail"];

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === "/api/lead") {
      if (request.method !== "POST") {
        return new Response("Method not allowed", { status: 405, headers: { Allow: "POST" } });
      }
      return handleLead(request, env, url);
    }

    return env.ASSETS.fetch(request);
  },
};

async function handleLead(request, env, url) {
  let fields;
  try {
    fields = await readFields(request);
  } catch {
    return redirect(url, FAILED);
  }

  // Honeypot. Bots fill hidden inputs; humans cannot see them. Answer as though
  // it worked so the bot does not learn anything, but store nothing.
  if ((fields._gotcha || "").trim() !== "") {
    return redirect(url, THANKS);
  }

  // A lead with no way to reach the person back is not a lead.
  const name = (fields.name || "").trim();
  const phone = (fields.phone || "").trim();
  const email = (fields.email || "").trim();
  if (!name || (!phone && !email)) {
    return redirect(url, FAILED);
  }

  const row = {
    id: crypto.randomUUID(),
    site: SITE,
    created_at: new Date().toISOString(),
    source_page: (fields.source_page || url.pathname).slice(0, 500),
    referer: (request.headers.get("referer") || "").slice(0, 500),
    user_agent: (request.headers.get("user-agent") || "").slice(0, 500),
    ip: request.headers.get("cf-connecting-ip") || "",
    country: (request.cf && request.cf.country) || "",
    raw: JSON.stringify(fields).slice(0, 20000),
  };
  for (const k of KNOWN) row[k] = (fields[k] || "").toString().slice(0, 2000);

  // Store first. The database is the system of record; email is a notification.
  // Same reasoning as R2 in the signing app: a missing credential on the
  // notification path must never cost us the record.
  const stored = await store(env, row);
  const emailed = await notify(env, row);

  if (stored || emailed) {
    if (stored && emailed) {
      // Best effort; a failure here costs nothing that matters.
      try {
        await env.LEADS_DB.prepare("UPDATE leads SET emailed = 1 WHERE id = ?").bind(row.id).run();
      } catch { /* the row exists, which is the part that counts */ }
    }
    return redirect(url, THANKS);
  }

  // Both paths failed. Do not show a thank-you page for a lead we do not have.
  console.error("LEAD LOST", SITE, row.created_at, row.name, row.phone, row.email);
  return redirect(url, FAILED);
}

async function readFields(request) {
  const type = request.headers.get("content-type") || "";
  const out = {};
  if (type.includes("application/json")) {
    Object.assign(out, await request.json());
  } else {
    const form = await request.formData();
    for (const [k, v] of form.entries()) out[k] = typeof v === "string" ? v : "";
  }
  return out;
}

async function store(env, row) {
  if (!env.LEADS_DB) return false;
  try {
    await env.LEADS_DB.prepare(
      `INSERT INTO leads
        (id, site, created_at, name, phone, email, city, service_need, urgency,
         detail, source_page, referer, user_agent, ip, country, raw)
       VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`
    ).bind(
      row.id, row.site, row.created_at, row.name, row.phone, row.email, row.city,
      row.service_need, row.urgency, row.detail, row.source_page, row.referer,
      row.user_agent, row.ip, row.country, row.raw
    ).run();
    return true;
  } catch (err) {
    console.error("D1 write failed", SITE, err && err.message);
    return false;
  }
}

async function notify(env, row) {
  const from = env.LEAD_FROM || LEAD_FROM_DEFAULT;
  const to = env.LEAD_TO || LEAD_TO_DEFAULT;
  if (!env.RESEND_API_KEY || !to || !from) {
    console.error("notify skipped", SITE, "key:", !!env.RESEND_API_KEY, "from:", !!from, "to:", !!to);
    return false;
  }

  const lines = [
    `Site:     ${SITE}`,
    `When:     ${row.created_at}`,
    `Name:     ${row.name}`,
    `Phone:    ${row.phone || "-"}`,
    `Email:    ${row.email || "-"}`,
    `Town:     ${row.city || "-"}`,
    `Need:     ${row.service_need || "-"}`,
    `Urgency:  ${row.urgency || "-"}`,
    "",
    "Detail:",
    row.detail || "(none given)",
    "",
    `Page:     ${row.source_page}`,
    `Country:  ${row.country}`,
    `Lead id:  ${row.id}`,
  ];

  try {
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${env.RESEND_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        from,
        to: [to],
        reply_to: row.email || undefined,
        subject: `${BRAND} lead - ${row.name}${row.city ? " - " + row.city : ""}`,
        text: lines.join("\n"),
      }),
    });
    if (!res.ok) {
      console.error("Resend failed", SITE, res.status, (await res.text()).slice(0, 300));
      return false;
    }
    return true;
  } catch (err) {
    console.error("Resend threw", SITE, err && err.message);
    return false;
  }
}

function redirect(url, path) {
  // 303 so the browser follows with GET and a refresh cannot resubmit.
  return Response.redirect(new URL(path, url.origin).toString(), 303);
}
