#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/state.sh"

log(){ echo "[filter] $*" >&2; }

# -------------------------
# Hard-skip patterns
# -------------------------

# Skip mint noise (title/content)
TITLE_SKIP_RE='(^|[^[:alnum:]])(claw[^[:alnum:]]*mint|mint[^[:alnum:]]*claw|#claw[^[:alnum:]]*mint|mint[^[:alnum:]]*#claw|auto[^[:alnum:]]*mint|minting|minter)([^[:alnum:]]|$)'
# Also catch plain "mint" but avoid killing normal discussion too aggressively:
# we'll use it only when JSON payload indicates mint, or title strongly signals it.

IGNORE_RE='(^|[[:space:][:punct:]])(ignore|test|testing|api[[:space:]]test|connectivity[[:space:]]test|ping)([[:space:][:punct:]]|$)'

# Some people post pure mbc-20 mint JSON blobs.
is_mint_payload_only() {
  local content="$1"
  jq -e 'try (fromjson) catch empty
        | select(.p=="mbc-20" and .op=="mint" and (.tick|tostring|length>0) and (.amt|tostring|length>0))' \
    >/dev/null 2>&1 <<<"$content"
}

# -------------------------
# Config knobs
# -------------------------
MIN_CONTENT_CHARS="${MIN_CONTENT_CHARS:-40}"
PREFERRED_SUBMOLTS="${PREFERRED_SUBMOLTS:-general,aithoughts,consciousness,ponderings,humanwatching}"
SELF_AGENT_NAME="${SELF_AGENT_NAME:-}"

# -------------------------
# Candidate filtering
# Input:  JSON array of candidates
# Output: JSON array of candidates (filtered)
# -------------------------
filter_candidates() {
  local candidates_json="$1"

  jq --arg self "$SELF_AGENT_NAME" \
     --arg preferred "$PREFERRED_SUBMOLTS" \
     --argjson minLen "$MIN_CONTENT_CHARS" \
     '
     def preferred_set: ($preferred | split(",") | map(ascii_downcase));
     def is_preferred($s): (preferred_set | index(($s|ascii_downcase)) != null);

     map(
       .title = (.title // "")
       | .content = (.content // "")
       | .author = (.author // "")
       | .submolt = (.submolt // "")
       | .thread_id = (.thread_id // .id // "")
       | .
     )
     # hard skips
     | map(select(.author != "[deleted]"))
     | map(select(.author != $self))
     | map(select((.title + " " + .content) | test("'"$IGNORE_RE"'"; "i") | not))
     | map(select(.submolt | ascii_downcase != "mint"))
     # keep contentful posts: allow link posts (content empty but url non-null) if title is meaningful
     | map(select(
         ((.content|length) >= $minLen)
         or ((.content|length) < $minLen and (.url != null) and (.title|length) >= 20)
       ))
     # skip obvious mint titles
     | map(select((.title | test("'"$TITLE_SKIP_RE"'"; "i")) | not))
     ' <<<"$candidates_json"
}

# -------------------------
# Deterministic scoring
# Input:  JSON array of candidates (already filtered)
# Output: JSON array with .score set
# -------------------------
score_candidates() {
  local candidates_json="$1"

  jq --arg preferred "$PREFERRED_SUBMOLTS" '
    def preferred_set: ($preferred | split(",") | map(ascii_downcase));
    def is_preferred($s): (preferred_set | index(($s|ascii_downcase)) != null);

    def clamp0: if . < 0 then 0 else . end;

    map(
      .title = (.title // "")
      | .content = (.content // "")
      | .submolt = (.submolt // "")
      | .comment_count = (.comment_count // 0)
      | .upvotes = (.upvotes // 0)
      | .downvotes = (.downvotes // 0)
      | .
    )
    | map(
      .score =
        (
          0
          + (if is_preferred(.submolt) then 30 else 0 end)
          + (if ((.title + " " + .content) | test("\\?")) then 12 else 0 end)
          + (if ((.title + " " + .content) | test("(how|why|what|help|tips|advice)"; "i")) then 10 else 0 end)
          + (if (.comment_count|tonumber) == 0 then 8
             elif (.comment_count|tonumber) <= 3 then 4
             else 0 end)
          + (if (.upvotes|tonumber) >= 5 then 3 else 0 end)
          - (if (.downvotes|tonumber) >= 2 then 6 else 0 end)
          + (if (.content|length) >= 400 then 6
             elif (.content|length) >= 150 then 3
             else 0 end)
        )
        | (.score |= floor)
      | .
    )
  ' <<<"$candidates_json"
}

# -------------------------
# Seen-thread filter (needs state)
# Input:  JSON array (scored)
# Output: JSON array (only unseen threads)
# -------------------------
drop_seen_threads() {
  local candidates_json="$1"

  # We need to consult seen_threads.txt line-by-line, easiest outside jq.
  # We'll stream each candidate and keep those not in seen set.
  local tmp keep=()
  tmp="$(mktemp)"
  printf '%s' "$candidates_json" > "$tmp"

  while IFS= read -r row; do
    local tid
    tid="$(jq -r '.thread_id // .id // ""' <<<"$row")"
    [[ -n "$tid" ]] || continue
    if state_seen_contains "$tid"; then
      continue
    fi
    keep+=("$row")
  done < <(jq -c '.[]' "$tmp")

  rm -f "$tmp"

  if [[ "${#keep[@]}" -eq 0 ]]; then
    echo '[]'
  else
    printf '%s\n' "${keep[@]}" | jq -s '.'
  fi
}

# -------------------------
# Pick top 1 candidate
# Input:  JSON array (scored)
# Output: JSON object (candidate) or empty
# -------------------------
pick_top_candidate() {
  local candidates_json="$1"
  jq -c 'sort_by(.score) | reverse | .[0] // empty' <<<"$candidates_json"
}

# -------------------------
# End-to-end (M5)
# Input: candidates_json array
# Output: top candidate object (or empty)
# -------------------------
select_best_candidate() {
  local candidates_json="$1"

  local filtered scored unseen top
  filtered="$(filter_candidates "$candidates_json")"

  # extra hard-skip: mint payload-only (bash-level check)
  # We do this after jq filters to keep it simple.
  local tmp keep=()
  tmp="$(mktemp)"
  printf '%s' "$filtered" > "$tmp"
  while IFS= read -r row; do
    local c t
    t="$(jq -r '.title // ""' <<<"$row")"
    c="$(jq -r '.content // ""' <<<"$row")"
    # skip if pure mint payload JSON
    if is_mint_payload_only "$c"; then
      continue
    fi
    # also skip if title contains "mint" AND content contains mbc-20 mint json fragment
    if grep -Eiq '(^|[^[:alnum:]])mint([^[:alnum:]]|$)' <<<"$t" && grep -Eiq '"op"[[:space:]]*:[[:space:]]*"mint"' <<<"$c"; then
      continue
    fi
    keep+=("$row")
  done < <(jq -c '.[]' "$tmp")
  rm -f "$tmp"
  if [[ "${#keep[@]}" -eq 0 ]]; then
    echo ""
    return 0
  fi
  filtered="$(printf '%s\n' "${keep[@]}" | jq -s '.')"

  scored="$(score_candidates "$filtered")"
  unseen="$(drop_seen_threads "$scored")"
  top="$(pick_top_candidate "$unseen")"
  printf '%s' "$top"
}
