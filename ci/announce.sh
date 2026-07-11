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
# Note: the exact postgresql.org news-submission endpoint + form fields are
# set the field ids via the PGORG_* env vars rather than editing this script.
set -euo pipefail

VERSION="${1:?usage: announce.sh VERSION}"
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
# The postgresql.org news system (pgweb) requires: a password-login account
# (no OAuth/2FA), an APPROVED Organisation you manage, a confirmed org email,
# and one or more NewsTag ids. Submission is a two-step form: create the article
# (POST /account/news/new/) then confirm-submit it (POST /account/news/<id>/submit/),
# after which TWO moderators must approve it -- it is never auto-published.
# CI cannot bootstrap the org/email/tags, so unless ALL of these are provided we
# print the drafted announcement and exit 0 (a release never fails for lack of
# announce config; paste the draft into https://www.postgresql.org/account/news/new/).
#   PGORG_USER, PGORG_PASSWORD  - a password-login postgresql.org account
#   PGORG_ORG_ID                - approved Organisation id (managed by that account)
#   PGORG_EMAIL_ID              - confirmed OrganisationEmail id (same org)
#   PGORG_TAGS                  - space-separated NewsTag ids (see
#                                 https://www.postgresql.org/about/news/taglist.json/)
BASE="https://www.postgresql.org"
if [ -z "${PGORG_USER:-}" ] || [ -z "${PGORG_PASSWORD:-}" ] \
   || [ -z "${PGORG_ORG_ID:-}" ] || [ -z "${PGORG_EMAIL_ID:-}" ] || [ -z "${PGORG_TAGS:-}" ]; then
  echo "PGORG_* not fully set (need USER, PASSWORD, ORG_ID, EMAIL_ID, TAGS) --"
  echo "printing the drafted announcement; submit it by hand at ${BASE}/account/news/new/ :"
  echo "----------------------------------------------------------------------"
  echo "Title: ${TITLE}"
  echo
  echo "${BODY}"
  echo "----------------------------------------------------------------------"
  exit 0
fi

CJ="$(mktemp)"; trap 'rm -f "$CJ"' EXIT
csrf() { grep -oE 'name="csrfmiddlewaretoken" value="[^"]+"' | head -1 | sed 's/.*value="//;s/"//'; }

# 1. Log in (Django LoginView).
LOGIN_CSRF="$(curl -sS -c "$CJ" "$BASE/account/login/" | csrf)"
curl -sS -c "$CJ" -b "$CJ" -e "$BASE/account/login/" -H "Origin: $BASE" \
  --data-urlencode "csrfmiddlewaretoken=$LOGIN_CSRF" \
  --data-urlencode "username=$PGORG_USER" \
  --data-urlencode "password=$PGORG_PASSWORD" \
  --data-urlencode "next=/account/news/new/" \
  "$BASE/account/login/" >/dev/null

# 2. Create the article (state CREATED). org/email/tags are required.
NEW_CSRF="$(curl -sS -c "$CJ" -b "$CJ" "$BASE/account/news/new/" | csrf)"
tagargs=(); for t in $PGORG_TAGS; do tagargs+=(--data-urlencode "tags=$t"); done
curl -sS -c "$CJ" -b "$CJ" -e "$BASE/account/news/new/" -H "Origin: $BASE" \
  --data-urlencode "csrfmiddlewaretoken=$NEW_CSRF" \
  --data-urlencode "org=$PGORG_ORG_ID" \
  --data-urlencode "email=$PGORG_EMAIL_ID" \
  --data-urlencode "title=$TITLE" \
  --data-urlencode "content=$BODY" \
  --data-urlencode "date=$(date +%F)" \
  "${tagargs[@]}" \
  "$BASE/account/news/new/" >/dev/null

# 3. Find the new article id, then confirm-submit it into the moderation queue.
# Note: newest-id heuristic (we just created it); match on title if two runs race.
ID="$(curl -sS -c "$CJ" -b "$CJ" "$BASE/account/edit/news/" \
      | grep -oE '/account/news/[0-9]+/' | grep -oE '[0-9]+' | sort -rn | head -1)"
if [ -z "$ID" ]; then
  echo "::warning::could not find the new article id; finish manually at $BASE/account/edit/news/"
  exit 0
fi
SUB_CSRF="$(curl -sS -c "$CJ" -b "$CJ" "$BASE/account/news/$ID/submit/" | csrf)"
code="$(curl -sS -o /tmp/pgorg_resp.txt -w '%{http_code}' -c "$CJ" -b "$CJ" \
  -e "$BASE/account/news/$ID/submit/" -H "Origin: $BASE" \
  --data-urlencode "csrfmiddlewaretoken=$SUB_CSRF" \
  --data-urlencode "confirm=on" \
  "$BASE/account/news/$ID/submit/")"
echo "news submit HTTP ${code} (article ${ID}) -- now pending moderation (two moderators approve)."
case "$code" in
  2*|3*) echo "Announcement queued." ;;
  *) echo "::warning::submit returned HTTP ${code}; finish manually at $BASE/account/edit/news/" ;;
esac
