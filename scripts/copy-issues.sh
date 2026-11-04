#!/usr/bin/env bash
#
# copy-issues.sh — clone labels, milestones and issues from one GitHub repo into
# another. Designed to run from the template repo (source defaults to
# $GITHUB_REPOSITORY) via the copy-issues.yml workflow_dispatch workflow.
#
# Why this exists: GitHub's "template repository" feature copies files, not
# issues. This repo's value is its issue list, so we replay it with the API.
#
# Order of operations (matters — issues reference both):
#   1. labels      (create, or update colour/description if they already exist)
#   2. milestones  (create if missing; due dates are NOT copied — they'd be stale)
#   3. issues      (oldest first, always created open). Only OPEN source issues
#                  are copied by default: closing an issue in the template retires
#                  it from future copies. --include-closed copies the rest too.
#   4. fix-up pass (rewrite #N cross-references to the new issue numbers)
#
# Deliberately NOT copied: assignees (notifies people, may not be collaborators),
# comments, closed state, reactions, projects. @mentions in bodies are wrapped in
# backticks so the copy doesn't ping anyone.
#
# Auth: relies on the gh CLI. GH_TOKEN/GITHUB_TOKEN is used for both repos by
# default; set SOURCE_GH_TOKEN and/or DEST_GH_TOKEN to use different tokens.
# Tokens are only ever passed by environment variable, never printed.
#
# Needs: bash >=3.2, gh, jq >=1.6.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: copy-issues.sh --source OWNER/REPO --dest OWNER/REPO [options]

Options:
  --source REPO       Repo to copy from (default: $GITHUB_REPOSITORY)
  --dest REPO         Repo to copy into (required)
  --include-closed    Also copy closed issues (they are still created open)
  --author LOGIN      Only copy issues created by this user
  --min-number N      Only copy issues with number greater than N (default: 0)
  --exclude-title T   Skip issues whose title equals T (case-insensitive, trimmed).
                      May be given more than once.
  --delay SECONDS     Pause between issue creations (default: 2; avoids GitHub's
                      secondary rate limit on content creation)
  --allow-existing    Proceed even if the destination already has issues
                      (default: abort, so a double-run can't duplicate everything)
  --dry-run           Read from source, print the plan, write nothing
  -h, --help          Show this help
EOF
}

SOURCE_REPO="${GITHUB_REPOSITORY:-}" DEST_REPO="" INCLUDE_CLOSED=0 AUTHOR="" MIN_NUMBER=0 DELAY=2 DRY_RUN=0 ALLOW_EXISTING=0 EXCLUDE_JSON='[]'

while (( $# )); do
  case "$1" in
    --source)         SOURCE_REPO="${2:?--source needs a value}"; shift 2 ;;
    --dest)           DEST_REPO="${2:?--dest needs a value}"; shift 2 ;;
    --author)         AUTHOR="${2:?--author needs a value}"; shift 2 ;;
    --min-number)     MIN_NUMBER="${2:?--min-number needs a value}"; shift 2 ;;
    --exclude-title)  EXCLUDE_JSON=$(jq -c --arg t "${2:?--exclude-title needs a value}" '. + [$t | gsub("^\\s+|\\s+$"; "") | ascii_downcase]' <<<"$EXCLUDE_JSON"); shift 2 ;;
    --delay)          DELAY="${2:?--delay needs a value}"; shift 2 ;;
    --allow-existing) ALLOW_EXISTING=1; shift ;;
    --include-closed) INCLUDE_CLOSED=1; shift ;;
    --dry-run)        DRY_RUN=1; shift ;;
    -h|--help)        usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$SOURCE_REPO" && -n "$DEST_REPO" ]] || { usage >&2; exit 2; }
# These end up in API paths; in Actions they come from user-supplied workflow inputs.
for r in "$SOURCE_REPO" "$DEST_REPO"; do
  [[ "$r" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "'$r' is not a valid OWNER/REPO" >&2; exit 2; }
done
[[ "$MIN_NUMBER" =~ ^[0-9]+$ ]] || { echo "--min-number must be an integer" >&2; exit 2; }
[[ "$SOURCE_REPO" != "$DEST_REPO" ]] || { echo "source and dest are the same repo" >&2; exit 2; }
command -v gh >/dev/null || { echo "gh CLI not found" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq not found" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

log() { printf '%s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# Read from the source repo (optionally with its own token).
src() {
  if [[ -n "${SOURCE_GH_TOKEN:-}" ]]; then GH_TOKEN="$SOURCE_GH_TOKEN" gh "$@"; else gh "$@"; fi
}

# Talk to the destination repo. Request body comes from $PAYLOAD (JSON) when set.
# Retries GitHub rate-limit responses with a growing back-off; on any other
# failure prints gh's output (stdout JSON + stderr message) and returns non-zero
# so callers can inspect it (e.g. to detect "already_exists").
dst_api() {
  local attempt=1 out err rc args=("$@")
  if [[ -n "${PAYLOAD:-}" ]]; then
    printf '%s' "$PAYLOAD" > "$WORK/payload.json"
    args+=(--input "$WORK/payload.json")
  fi
  while :; do
    rc=0
    if [[ -n "${DEST_GH_TOKEN:-}" ]]; then
      out=$(GH_TOKEN="$DEST_GH_TOKEN" gh api "${args[@]}" 2>"$WORK/err" </dev/null) || rc=$?
    else
      out=$(gh api "${args[@]}" 2>"$WORK/err" </dev/null) || rc=$?
    fi
    err=$(<"$WORK/err")
    if (( rc == 0 )); then printf '%s' "$out"; return 0; fi
    if [[ "$out$err" =~ ([Rr]ate\ limit|secondary|abuse) ]] && (( attempt < 6 )); then
      log "  rate limited; sleeping $(( attempt * 30 ))s (attempt $attempt/5)"
      sleep $(( attempt * 30 )); attempt=$(( attempt + 1 )); continue
    fi
    printf '%s\n%s' "$out" "$err"
    return "$rc"
  done
}

uri() { jq -rn --arg s "$1" '$s|@uri'; }

# --- Fetch everything we need from the source up front (read-only) -----------

log "Source: $SOURCE_REPO   Dest: $DEST_REPO${AUTHOR:+   Author: $AUTHOR}   Min issue #: >$MIN_NUMBER   Excluded titles: $(jq -c . <<<"$EXCLUDE_JSON")"
(( DRY_RUN )) && log "*** DRY RUN — nothing will be written ***"

# Fail early with a useful message: GitHub returns 404 (not 403) for a private repo the token can't see.
if ! src_err=$(src api "repos/$SOURCE_REPO" --jq .full_name 2>&1 >/dev/null); then
  die "cannot read source repo $SOURCE_REPO (${src_err//$'\n'/ }). A 404 usually means the repo is private and the token in use can't see it. Set SOURCE_GH_TOKEN to a token with read access to $SOURCE_REPO."
fi

src api --paginate "repos/$SOURCE_REPO/labels?per_page=100" | jq -s 'add // []' > "$WORK/labels.json"
src api --paginate "repos/$SOURCE_REPO/milestones?state=all&per_page=100" | jq -s 'add // [] | sort_by(.due_on // "9999")' > "$WORK/milestones.json"

ISSUE_STATE=open; (( INCLUDE_CLOSED )) && ISSUE_STATE=all
# /issues also returns PRs; drop them. Creator filter is applied server-side.
src api --paginate "repos/$SOURCE_REPO/issues?state=$ISSUE_STATE&sort=created&direction=asc&per_page=100${AUTHOR:+&creator=$AUTHOR}" \
  | jq -s --argjson min "$MIN_NUMBER" --argjson ex "$EXCLUDE_JSON" \
      'add // [] | map(select((.pull_request|not) and .number > $min and ((.title | gsub("^\\s+|\\s+$"; "") | ascii_downcase) as $t | $ex | index($t) | not))) | sort_by(.number)' \
  > "$WORK/issues.json"

n_labels=$(jq length "$WORK/labels.json")
n_ms=$(jq length "$WORK/milestones.json")
n_issues=$(jq length "$WORK/issues.json")
log "Found $n_labels labels, $n_ms milestones, $n_issues issues to copy."
(( n_issues > 0 )) || die "no issues matched the filter; refusing to continue (state=$ISSUE_STATE)"

# Set of source issue numbers being copied, used to decide which #refs can be remapped.
jq -c 'map({key: (.number|tostring), value: true}) | from_entries' "$WORK/issues.json" > "$WORK/set.json"

# --- Body rewriting (jq) ------------------------------------------------------
# mentions: `@user` -> `` `@user` `` so GitHub doesn't notify them.
# refs:     #N where N is copied -> {{ref:N}} placeholder (resolved in pass 2);
#           #N where N is not copied -> `#N` (not copied), because the number
#           would otherwise point at an unrelated issue in the new repo.
read -r -d '' JQ_REWRITE <<'JQ' || true
def mentions: gsub("(?<![\\w`@])@(?<u>[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)"; "`@\(.u)`");
def refs($set): gsub("(?<![\\w&/`])#(?<n>[0-9]+)\\b"; if $set[.n] then "{{ref:\(.n)}}" else "`#\(.n)` (not copied)" end);
def clean_body($set): (. // "") | mentions | refs($set);
JQ

# Payload for POST /issues. Assignees are intentionally absent; state is always open.
read -r -d '' JQ_CREATE <<'JQ' || true
{
  title: (.title | gsub("^\\s+|\\s+$"; "")),
  body: (.body | clean_body($set[0])),
  labels: [.labels[].name],
  milestone: (if .milestone then $ms[0][.milestone.title] else null end)
}
JQ

# --- Dry run: print the plan and stop -----------------------------------------

if (( DRY_RUN )); then
  log ""; log "Labels:";     jq -r '.[] | "  \(.name)  #\(.color)"' "$WORK/labels.json" >&2
  log ""; log "Milestones:"; jq -r '.[] | "  \(.title)"' "$WORK/milestones.json" >&2
  log ""; log "Issues (always created open; assignees dropped):"
  read -r -d '' JQ_PLAN <<'JQ' || true
.[] | . as $i | ($i.body | clean_body($set[0])) as $b
| "  #\(.number) [\(.state)] \(.title | gsub("^\\s+|\\s+$"; "")) | labels: \(.labels | map(.name) | join(",")) | milestone: \(.milestone.title // "-")"
  + (if ($b | test("\\{\\{ref:")) then "  (refs remapped)" else "" end)
  + (if (($i.body // "") | test("(?<![\\w`@])@[A-Za-z0-9]")) then "  (@mentions neutralized)" else "" end)
JQ
  jq -r --slurpfile set "$WORK/set.json" "$JQ_REWRITE"$'\n'"$JQ_PLAN" "$WORK/issues.json" >&2
  exit 0
fi

# --- Safety: a second run would duplicate every issue --------------------------

existing=$(dst_api "repos/$DEST_REPO/issues?state=all&per_page=100" --jq '[.[]|select(.pull_request|not)]|length') \
  || die "cannot read $DEST_REPO — check it exists and the token can see it: $existing"
if (( existing > 0 && ALLOW_EXISTING == 0 )); then
  die "$DEST_REPO already has $existing issue(s). Re-run with --allow-existing if you really want to add more."
fi

# --- 1. Labels -----------------------------------------------------------------

log ""; log "==> Labels"
created=0 updated=0
while IFS= read -r label; do
  name=$(jq -r .name <<<"$label")
  body=$(jq -c '{name, color, description: (.description // "")}' <<<"$label")
  if resp=$(PAYLOAD="$body" dst_api -X POST "repos/$DEST_REPO/labels"); then
    created=$(( created + 1 )); log "  + $name"
  elif [[ "$resp" == *already_exists* ]]; then
    # New repos ship with default labels (bug, duplicate…); align them with the source.
    PAYLOAD=$(jq -c '{color, description}' <<<"$body") dst_api -X PATCH "repos/$DEST_REPO/labels/$(uri "$name")" >/dev/null \
      || die "failed to update label '$name'"
    updated=$(( updated + 1 )); log "  ~ $name (already existed, updated)"
  else
    die "failed to create label '$name' in $DEST_REPO (no write access to the repo?): $resp"
  fi
done < <(jq -c '.[]' "$WORK/labels.json")
log "Labels: $created created, $updated updated."

# --- 2. Milestones --------------------------------------------------------------

log ""; log "==> Milestones"
dst_api --paginate "repos/$DEST_REPO/milestones?state=all&per_page=100" | jq -s 'add // [] | map({key: .title, value: .number}) | from_entries' > "$WORK/ms-map.json"
while IFS= read -r ms; do
  title=$(jq -r .title <<<"$ms")
  if jq -e --arg t "$title" 'has($t)' "$WORK/ms-map.json" >/dev/null; then
    log "  = $title (already exists)"; continue
  fi
  # No due_on: the source dates belong to last year's event.
  num=$(PAYLOAD=$(jq -c '{title, description: (.description // "")}' <<<"$ms") dst_api -X POST "repos/$DEST_REPO/milestones" --jq .number) \
    || die "failed to create milestone '$title': $num"
  jq --arg t "$title" --argjson n "$num" '. + {($t): $n}' "$WORK/ms-map.json" > "$WORK/ms-map.tmp" && mv "$WORK/ms-map.tmp" "$WORK/ms-map.json"
  log "  + $title (#$num)"
done < <(jq -c '.[]' "$WORK/milestones.json")

# --- 3. Issues -------------------------------------------------------------------

log ""; log "==> Issues"
echo '{}' > "$WORK/num-map.json"   # old number -> new number
: > "$WORK/fixups.jsonl"           # issues whose bodies still hold {{ref:N}} placeholders
i=0
while IFS= read -r issue; do
  i=$(( i + 1 ))
  old=$(jq -r .number <<<"$issue")
  payload=$(jq -c --slurpfile set "$WORK/set.json" --slurpfile ms "$WORK/ms-map.json" "$JQ_REWRITE"$'\n'"$JQ_CREATE" <<<"$issue")
  resp=$(PAYLOAD="$payload" dst_api -X POST "repos/$DEST_REPO/issues") \
    || die "failed creating issue (source #$old) after $(( i - 1 )) of $n_issues; already-created issues remain in $DEST_REPO: $resp"
  new=$(jq -r .number <<<"$resp")
  jq --arg o "$old" --argjson n "$new" '. + {($o): $n}' "$WORK/num-map.json" > "$WORK/num-map.tmp" && mv "$WORK/num-map.tmp" "$WORK/num-map.json"
  if jq -e '.body | test("\\{\\{ref:")' <<<"$payload" >/dev/null; then
    jq -c --argjson n "$new" '{new: $n, body}' <<<"$payload" >> "$WORK/fixups.jsonl"
  fi
  log "  [$i/$n_issues] source #$old -> $DEST_REPO#$new  $(jq -r .title <<<"$payload")"
  sleep "$DELAY"
done < <(jq -c '.[]' "$WORK/issues.json")

# --- 4. Fix-up pass: resolve {{ref:N}} placeholders ---------------------------------

log ""; log "==> Rewriting cross-references"
fixed=0
while IFS= read -r fx; do
  new=$(jq -r .new <<<"$fx")
  body=$(jq -c --slurpfile map "$WORK/num-map.json" \
    '{body: (.body | gsub("\\{\\{ref:(?<n>[0-9]+)\\}\\}"; if $map[0][.n] then "#\($map[0][.n])" else "`#\(.n)` (not copied)" end))}' <<<"$fx")
  PAYLOAD="$body" dst_api -X PATCH "repos/$DEST_REPO/issues/$new" >/dev/null || die "failed to rewrite refs in $DEST_REPO#$new"
  fixed=$(( fixed + 1 )); log "  ~ #$new"
  sleep "$DELAY"
done < "$WORK/fixups.jsonl"

log ""
log "Done: $n_labels labels processed, $n_ms milestones processed, $i issues created, $fixed bodies had references remapped."
