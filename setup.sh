#!/bin/bash
# Provision the Cloudflare lead endpoint for one site.
#
#   ./setup.sh <pages-project-name> [d1-database-name]
#
# Creates the D1 database if it does not exist, applies the schema, binds it to
# the Pages project, and sets the Resend key as a secret. Idempotent: safe to
# run again.
#
# Expects, in the repo root .env (chmod 600, gitignored):
#   CLOUDFLARE_API_TOKEN=...      needs Pages:Edit and D1:Edit
#   CLOUDFLARE_ACCOUNT_ID=...
#   RESEND_API_KEY=...            sending access only
#
# Two traps this script exists to avoid, both found the hard way:
#
#  1. Cloudflare's Pages API accepts a plain_text env var, echoes it back on
#     write AND on an immediate read, then drops it before the next deployment.
#     Only secret_text survives. So LEAD_FROM / LEAD_TO are NOT set here - they
#     are injected into the worker at build time from your site config.
#
#  2. Bindings only apply to deployments made AFTER they are set. Setting a
#     binding does not touch the deployment already running, so this script
#     tells you to redeploy at the end. Skipping that is why a lead lands in
#     the database with emailed=0 and no error anywhere.

set -euo pipefail

PROJECT="${1:-}"
DB_NAME="${2:-portfolio-leads}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
ENV_FILE="$ROOT/.env"

if [ -z "$PROJECT" ]; then
  /usr/bin/sed -n '2,6p' "$0" | /usr/bin/sed 's/^# \{0,1\}//'
  exit 1
fi

# Read the dotenv rather than sourcing it: it is data, not a script to execute.
getenv() { /usr/bin/grep -m1 "^$1=" "$ENV_FILE" 2>/dev/null | /usr/bin/cut -d= -f2- | /usr/bin/tr -d '\r\n'; }

CLOUDFLARE_API_TOKEN="$(getenv CLOUDFLARE_API_TOKEN)"
CLOUDFLARE_ACCOUNT_ID="$(getenv CLOUDFLARE_ACCOUNT_ID)"
RESEND_API_KEY="$(getenv RESEND_API_KEY)"
export CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID

for v in CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID RESEND_API_KEY; do
  [ -n "${!v}" ] || { echo "setup: $v missing from $ENV_FILE" >&2; exit 2; }
done

API="https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID"
auth=(-H "Authorization: Bearer $CLOUDFLARE_API_TOKEN")

echo "== 1. D1 database '$DB_NAME'"
DB_ID="$(/usr/bin/curl -sS "${auth[@]}" "$API/d1/database?name=$DB_NAME" \
  | /usr/bin/python3 -c "import sys,json;r=json.load(sys.stdin).get('result') or [];print(r[0]['uuid'] if r else '')")"

if [ -z "$DB_ID" ]; then
  DB_ID="$(/usr/bin/curl -sS -X POST "${auth[@]}" -H "Content-Type: application/json" \
    -d "{\"name\":\"$DB_NAME\"}" "$API/d1/database" \
    | /usr/bin/python3 -c "import sys,json;d=json.load(sys.stdin);print(d['result']['uuid'] if d.get('success') else '')")"
  [ -n "$DB_ID" ] || { echo "   failed to create the database" >&2; exit 1; }
  echo "   created: $DB_ID"
else
  echo "   exists:  $DB_ID"
fi

echo "== 2. schema"
wrangler d1 execute "$DB_NAME" --remote --file="$HERE/schema.sql" --yes >/dev/null 2>&1 \
  && echo "   applied (CREATE TABLE IF NOT EXISTS, so re-running is safe)" \
  || { echo "   schema failed - run it yourself to see why:" >&2
       echo "   wrangler d1 execute $DB_NAME --remote --file=$HERE/schema.sql" >&2; exit 1; }

echo "== 3. bind to Pages project '$PROJECT'"
TMP="$(/usr/bin/mktemp)"
trap '/bin/rm -f "$TMP"' EXIT
/usr/bin/python3 - "$DB_ID" "$RESEND_API_KEY" > "$TMP" <<'PY'
import json, sys
db_id, resend = sys.argv[1], sys.argv[2]
print(json.dumps({"deployment_configs": {"production": {
    "d1_databases": {"LEADS_DB": {"id": db_id}},
    # Only secret_text persists. See trap 1 in the header.
    "env_vars": {"RESEND_API_KEY": {"type": "secret_text", "value": resend}},
}}}))
PY
/usr/bin/curl -sS -X PATCH "${auth[@]}" -H "Content-Type: application/json" \
  --data "@$TMP" "$API/pages/projects/$PROJECT" \
  | /usr/bin/python3 -c "
import sys,json
d=json.load(sys.stdin)
if not d.get('success'):
    print('   FAILED:', [e.get('message') for e in d.get('errors',[])]); sys.exit(1)
p=d['result']['deployment_configs']['production']
print('   d1:     ', list((p.get('d1_databases') or {}).keys()))
print('   secrets:', list((p.get('env_vars') or {}).keys()))"

cat <<DONE

Done. Two things left, in this order:

  1. Put your from/to addresses in the site's config, not in Pages env vars:
       "lead_from": "onboarding@resend.dev",
       "lead_to":   "you@example.com"

  2. REDEPLOY. Bindings only reach deployments made after they are set:
       wrangler pages deploy dist --project-name $PROJECT --branch main

Then submit the real form in a browser and check the row landed:

  wrangler d1 execute $DB_NAME --remote \\
    --command "SELECT created_at, name, phone, city, emailed FROM leads ORDER BY created_at DESC LIMIT 5;"

emailed=1 means stored AND sent. emailed=0 means stored but email failed,
which is the point: the lead is never lost to a broken notification.
DONE
