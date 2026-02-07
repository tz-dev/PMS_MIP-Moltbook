#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/api.sh"

FEEDS_FILE="${FEEDS_FILE:-$ROOT_DIR/config/feeds.json}"

log(){ echo "[candidates] $*" >&2; }

_require_jq() { command -v jq >/dev/null 2>&1 || { echo "[candidates] ERROR: jq missing" >&2; exit 1; }; }

# Read feeds.json and output NUL-safe list of relative paths
feeds_list() {
  _require_jq
  jq -r '(.feeds // []) | .[]' "$FEEDS_FILE"
}

# Normalize one "post" object to a Candidate object
# Candidate schema:
# { id, thread_id, title, content, submolt, author, created_at, source, score }
normalize_post_jq='
def root: (.data? // .);
def tid: (root | (.thread_id // .root_id // .parent_id // .id));
{
  id: (root.id // ""),
  thread_id: (tid // (root.id // "")),
  title: (root.title // ""),
  content: (root.content // ""),
  url: (root.url // null),
  submolt: (root.submolt.name // ""),
  author: (root.author.name // ""),
  created_at: (root.created_at // ""),
  upvotes: (root.upvotes // 0),
  downvotes: (root.downvotes // 0),
  comment_count: (root.comment_count // 0),
  source: ($source // ""),
  score: 0
}
';

# Fetch and normalize candidates from one feed path (relative, beginning with /)
get_candidates_from_feed() {
  _require_jq
  local path="$1"
  local source="$2"

  # api.sh get_feed expects either a full URL or a path like "/posts?..."
  local json
  json="$(get_feed "$path")"

  # Some endpoints return {posts:[...]} others {data:{posts:[...]}}.
  # We'll scan possible shapes.
  jq -c --arg source "$source" '
    def posts:
      (.posts? // .data.posts? // .data? // []);
    posts
    | map('"$normalize_post_jq"')
    | .[]
  ' <<<"$json"
}

# Gather candidates from all feeds in feeds.json and output a JSON array
gather_candidates() {
  _require_jq
  local -a items=()
  local base
  base="$(jq -r '(.base // "https://www.moltbook.com/api/v1")' "$FEEDS_FILE")"

  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    log "fetching feed: $path"
    # Each line output is a JSON candidate object
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      items+=("$line")
    done < <(get_candidates_from_feed "$path" "$base$path" || true)
  done < <(feeds_list)

  if [[ "${#items[@]}" -eq 0 ]]; then
    echo '[]'
    return 0
  fi

  # Emit as JSON array (each item already JSON)
  printf '%s\n' "${items[@]}" | jq -s '
    # de-dup by id (keep first occurrence)
    unique_by(.id)
  '
}
