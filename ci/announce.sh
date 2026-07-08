#!/usr/bin/env bash
# ci/announce.sh VERSION
#
# Draft a PostgreSQL-style release announcement for pg_fts and submit it to the
# postgresql.org news/announce system (a login-authorized web submission).
#
# The postgresql.org "News" submission is an authenticated form on the
# organisation's account site; approved news is what feeds the pgsql-announce
# list.  This script BUILDS the announcement text (from CHANGELOG.md + META.json)
# and posts it using PGORG_USER / PGORG_PASSWORD.  If those secrets are unset it
# prints the drafted announcement and exits 0 (so a release never fails just
# because announcing isn't configured).
#
# ponytail: the exact postgresql.org news-submission endpoint + form fields are
# filled in from PGORG_NEWS_URL (default below); if the org changes the form,
# set PGORG_NEWS_URL / the field names via env rather than editing this script.
set -euo pipefail

VERSION="${1:?usage: announce.sh VERSION}"
NEWS_URL="${PGORG_NEWS_URL:-https://www.postgresql.org/account/submit/news/}"
REPO_WEB="https://codeberg.org/gregburd/pg_fts"

# --- Build the announcement body from the CHANGELOG's top section ------------
# Take the lines from the first "## <version>" heading to the next "## " heading.
changelog_section() {
  awk -v ver="$VERSION" '
    /^## / { if (inblk) exit; if ($0 ~ "## " ver || $0 ~ "## v?" ver) inblk=1 }
    inblk { print }
  ' CHANGELOG.md
}
CHANGES="$(changelog_section || true)"
[ -n "$CHANGES" ] || CHANGES="See ${REPO_WEB}/src/branch/main/CHANGELOG.md"

TITLE="pg_fts ${VERSION} released"
BODY="$(cat <<EOF
pg_fts ${VERSION} is now available.

pg_fts is a PostgreSQL extension for full-text search with BM25/BM25F relevance
ranking and a dedicated inverted-index access method: boolean, phrase, NEAR,
prefix, fuzzy, and regex queries over one operator, an index-native count(*),
and MVCC- and crash-safe storage (all page writes via GenericXLog). It supports
PostgreSQL 17, 18, and 19.

Changes in ${VERSION}:

${CHANGES}

Install from PGXN (\`pgxn install pg_fts\`) or from source:
  ${REPO_WEB}

Documentation and the migration guide from Timescale pg_textsearch are in the
repository.
EOF
)"

# --- Submit (or dry-run) -----------------------------------------------------
if [ -z "${PGORG_USER:-}" ] || [ -z "${PGORG_PASSWORD:-}" ]; then
  echo "PGORG_USER/PGORG_PASSWORD not set — printing drafted announcement (no submission):"
  echo "----------------------------------------------------------------------"
  echo "Title: ${TITLE}"
  echo
  echo "${BODY}"
  echo "----------------------------------------------------------------------"
  exit 0
fi

# postgresql.org uses a Django session + CSRF token on the account forms.
# Log in, capture the CSRF token, then POST the news submission. Organisation id
# and the exact field names may need adjusting per the account form; override via
# PGORG_ORG_ID if required.
CJ="$(mktemp)"
trap 'rm -f "$CJ"' EXIT
login_page="$(curl -sS -c "$CJ" https://www.postgresql.org/account/login/)"
csrf="$(printf '%s' "$login_page" | grep -oE 'csrfmiddlewaretoken[^>]*value="[^"]+"' | grep -oE 'value="[^"]+"' | head -1 | sed 's/value="//;s/"//')"
curl -sS -c "$CJ" -b "$CJ" -e https://www.postgresql.org/account/login/ \
  -d "csrfmiddlewaretoken=${csrf}" \
  --data-urlencode "username=${PGORG_USER}" \
  --data-urlencode "password=${PGORG_PASSWORD}" \
  https://www.postgresql.org/account/login/ >/dev/null

form_page="$(curl -sS -c "$CJ" -b "$CJ" "$NEWS_URL")"
csrf2="$(printf '%s' "$form_page" | grep -oE 'csrfmiddlewaretoken[^>]*value="[^"]+"' | grep -oE 'value="[^"]+"' | head -1 | sed 's/value="//;s/"//')"
code="$(curl -sS -o /tmp/pgorg_resp.txt -w '%{http_code}' -c "$CJ" -b "$CJ" -e "$NEWS_URL" \
  -d "csrfmiddlewaretoken=${csrf2}" \
  ${PGORG_ORG_ID:+--data-urlencode "organisation=${PGORG_ORG_ID}"} \
  --data-urlencode "title=${TITLE}" \
  --data-urlencode "content=${BODY}" \
  "$NEWS_URL")"
echo "postgresql.org news submission HTTP ${code}"
head -c 400 /tmp/pgorg_resp.txt || true
case "$code" in
  2*|3*) echo "Announcement submitted (pending moderation)." ;;
  *) echo "::warning::Announcement submission returned HTTP ${code}; submit manually at ${NEWS_URL}" ;;
esac
