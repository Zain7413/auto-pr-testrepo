#!/usr/bin/env bash

set -euo pipefail

GITHUB_API="${GITHUB_API_URL:-https://api.github.com}"

log() {
  echo "[auto-pr] $*"
}

warn() {
  echo "[auto-pr] WARNING: $*" >&2
}

die() {
  echo "[auto-pr] ERROR: $*" >&2
  exit 1
}

require_var() {
  local variable_name="$1"

  if [[ -z "${!variable_name:-}" ]]; then
    die "$variable_name is not set."
  fi
}

is_excluded_branch() {
  local branch="$1"

  echo "${EXCLUDE_BRANCHES:-}" |
    tr ',' '\n' |
    sed 's/^ *//; s/ *$//' |
    grep -Fxq "$branch"
}

require_var GITHUB_REPOSITORY
require_var GH_TOKEN
require_var AUTO_PR_TRIGGER_BRANCH
require_var SOURCE_BRANCH
require_var SOURCE_REPOSITORY
require_var TARGET_BRANCH

TRIGGER_BRANCH="$AUTO_PR_TRIGGER_BRANCH"
EXCLUDE_BRANCHES="${EXCLUDE_BRANCHES:-$TRIGGER_BRANCH}"
SKIP_KEYWORD="${SKIP_KEYWORD:-no-pr}"

log "Original pull request:"
log "  source branch = $SOURCE_BRANCH"
log "  target branch = $TARGET_BRANCH"
log "  trigger branch = $TRIGGER_BRANCH"

# -------------------------------------------------------------------
# 1. Only continue when the merged PR targeted the configured branch
# -------------------------------------------------------------------

if [[ "$TARGET_BRANCH" != "$TRIGGER_BRANCH" ]]; then
  log "PR was merged into '$TARGET_BRANCH', not trigger branch '$TRIGGER_BRANCH'."
  log "Skipping follow-up PR creation."
  exit 0
fi

# -------------------------------------------------------------------
# 2. Only support source branches from the same repository
# -------------------------------------------------------------------

if [[ "$SOURCE_REPOSITORY" != "$GITHUB_REPOSITORY" ]]; then
  log "Source branch belongs to another repository/fork."
  log "Skipping for safety."
  exit 0
fi

# -------------------------------------------------------------------
# 3. Skip branches containing 'exam'
# -------------------------------------------------------------------

if [[ "$SOURCE_BRANCH" == *exam* ]]; then
  log "Source branch '$SOURCE_BRANCH' contains 'exam'."
  log "Skipping follow-up PR creation."
  exit 0
fi

# -------------------------------------------------------------------
# 4. Skip if original PR body contains the configured keyword
# -------------------------------------------------------------------

if echo "${ORIGINAL_PR_BODY:-}" | grep -qiF "$SKIP_KEYWORD"; then
  log "Original PR description contains '$SKIP_KEYWORD'."
  log "Skipping follow-up PR creation."
  exit 0
fi

# -------------------------------------------------------------------
# 5. Make sure source branch still exists
# -------------------------------------------------------------------

SOURCE_STATUS=$(curl \
  --silent \
  --output /dev/null \
  --write-out "%{http_code}" \
  --header "Accept: application/vnd.github+json" \
  --header "Authorization: Bearer ${GH_TOKEN}" \
  "${GITHUB_API}/repos/${GITHUB_REPOSITORY}/branches/${SOURCE_BRANCH//\//%2F}")

if [[ "$SOURCE_STATUS" != "200" ]]; then
  warn "Source branch '$SOURCE_BRANCH' no longer exists."
  warn "Follow-up PRs cannot be created."
  exit 0
fi

# -------------------------------------------------------------------
# 6. Discover protected branches dynamically
# -------------------------------------------------------------------

log "Fetching protected branches dynamically..."

PROTECTED_BRANCHES_JSON=$(curl \
  --silent \
  --show-error \
  --fail \
  --header "Accept: application/vnd.github+json" \
  --header "Authorization: Bearer ${GH_TOKEN}" \
  "${GITHUB_API}/repos/${GITHUB_REPOSITORY}/branches?protected=true&per_page=100")

TARGET_BRANCHES=$(echo "$PROTECTED_BRANCHES_JSON" |
  jq -r '.[].name' |
  sort -u)

if [[ -z "$TARGET_BRANCHES" ]]; then
  log "No protected branches found."
  exit 0
fi

log "Protected branches:"
while IFS= read -r branch; do
  [[ -n "$branch" ]] && log "  - $branch"
done <<< "$TARGET_BRANCHES"

# -------------------------------------------------------------------
# 7. Process each protected branch
# -------------------------------------------------------------------

while IFS= read -r TARGET; do

  [[ -z "$TARGET" ]] && continue

  log "--------------------------------------"
  log "Checking target branch: $TARGET"

  # Skip configured exclusions
  if is_excluded_branch "$TARGET"; then
    log "'$TARGET' is in EXCLUDE_BRANCHES -> skipping."
    continue
  fi

  # Never create PR from branch to itself
  if [[ "$TARGET" == "$SOURCE_BRANCH" ]]; then
    log "Source and target are the same -> skipping."
    continue
  fi

  # ---------------------------------------------------------------
  # 8. Check whether an open PR already exists
  # ---------------------------------------------------------------

  EXISTING_PR=$(curl \
    --silent \
    --show-error \
    --fail \
    --get \
    --header "Accept: application/vnd.github+json" \
    --header "Authorization: Bearer ${GH_TOKEN}" \
    --data-urlencode "state=open" \
    --data-urlencode "head=${GITHUB_REPOSITORY%%/*}:${SOURCE_BRANCH}" \
    --data-urlencode "base=${TARGET}" \
    "${GITHUB_API}/repos/${GITHUB_REPOSITORY}/pulls")

  EXISTING_COUNT=$(echo "$EXISTING_PR" | jq 'length')

  if [[ "$EXISTING_COUNT" -gt 0 ]]; then
    log "An open PR from '$SOURCE_BRANCH' to '$TARGET' already exists."
    log "Skipping duplicate."
    continue
  fi

  # ---------------------------------------------------------------
  # 9. Create PR title and description
  # ---------------------------------------------------------------

  NEW_TITLE="${ORIGINAL_PR_TITLE:-Automatic follow-up PR} (-> ${TARGET})"

  NEW_BODY=$(cat <<EOF
Automatically created after Pull Request #${ORIGINAL_PR_NUMBER:-unknown} was merged into \`${TRIGGER_BRANCH}\`.

**Original PR:** ${ORIGINAL_PR_URL:-N/A}
**Original source branch:** \`${SOURCE_BRANCH}\`
**Original target branch:** \`${TRIGGER_BRANCH}\`
**GitHub Actions run:** ${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}

---

This Pull Request was automatically created for another protected branch.

To skip automatic PR creation, add \`${SKIP_KEYWORD}\` to the original Pull Request description.

Branches containing \`exam\` are also skipped.
EOF
)

  # ---------------------------------------------------------------
  # 10. Build API request
  # ---------------------------------------------------------------

  PAYLOAD=$(jq -n \
    --arg title "$NEW_TITLE" \
    --arg head "$SOURCE_BRANCH" \
    --arg base "$TARGET" \
    --arg body "$NEW_BODY" \
    '{
      title: $title,
      head: $head,
      base: $base,
      body: $body
    }')

  RESPONSE=$(curl \
    --silent \
    --show-error \
    --request POST \
    --header "Accept: application/vnd.github+json" \
    --header "Authorization: Bearer ${GH_TOKEN}" \
    --header "Content-Type: application/json" \
    --data "$PAYLOAD" \
    "${GITHUB_API}/repos/${GITHUB_REPOSITORY}/pulls")

  CREATED_URL=$(echo "$RESPONSE" | jq -r '.html_url // empty')
  ERROR_MESSAGE=$(echo "$RESPONSE" | jq -r '.message // empty')

  if [[ -n "$CREATED_URL" ]]; then
    log "PR created: $CREATED_URL"
  else
    warn "Failed to create PR to '$TARGET'."

    if [[ -n "$ERROR_MESSAGE" ]]; then
      warn "GitHub API message: $ERROR_MESSAGE"
    fi
  fi

done <<< "$TARGET_BRANCHES"

log "--------------------------------------"
log "Done."