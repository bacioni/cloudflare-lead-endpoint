-- Shared lead store for the whole portfolio. One database, one row per
-- submission, a `site` column to tell them apart. Twenty-five databases would
-- be twenty-five things to forget about.

CREATE TABLE IF NOT EXISTS leads (
  id            TEXT PRIMARY KEY,
  site          TEXT NOT NULL,
  created_at    TEXT NOT NULL,

  name          TEXT,
  phone         TEXT,
  email         TEXT,
  city          TEXT,
  service_need  TEXT,
  urgency       TEXT,
  detail        TEXT,

  source_page   TEXT,
  referer       TEXT,
  user_agent    TEXT,
  ip            TEXT,
  country       TEXT,

  -- Every submitted field, verbatim. Niches differ: the towing form asks about
  -- a vehicle, the garage door form asks about a door. Rather than add a column
  -- per trade, the named columns above are the ones worth querying across sites
  -- and this holds the rest so nothing is ever thrown away.
  raw           TEXT NOT NULL,

  emailed       INTEGER NOT NULL DEFAULT 0,
  notes         TEXT
);

CREATE INDEX IF NOT EXISTS idx_leads_site_created ON leads (site, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_leads_created      ON leads (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_leads_unemailed    ON leads (emailed) WHERE emailed = 0;
