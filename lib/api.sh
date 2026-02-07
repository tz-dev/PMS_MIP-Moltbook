#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Moltbook API client (bash+jq) with safety + retries
# =============================================================================
# Requirements: curl, jq
#
# ENV:
#   MOLTBOOK_API_KEY   (required)
#   MOLTBOOK_API_BASE  (optional, default: https://www.moltbook.com/api/v1)
#   CONNECT_TIMEOUT    (optional, default: 10)
#   MAX_TIME           (optional, default: 60)
#   API_TRIES          (optional, default: 4)
#   RETRY_SLEEP_BASE   (optional, default: 2)
# =============================================================================

: "${MOLTBOOK_API_KEY:?MOLTBOOK_API_KEY missing}"

MOLTBOOK_API_BASE="${MOLTBOOK_API_BASE:-https://www.moltbook.com/api/v1}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-10}"
MAX_TIME="${MAX_TIME:-60}"
API_TRIES="${API_TRIES:-4}"
RETRY_SLEEP_BASE="${RETRY_SLEEP_BASE:-2}"

# --- Safety: enforce exact base (www + /api/v1) ---
_api_enforce_base() {
  local base="$1"
  if [[ "$base" != "https://www.moltbook.com/api/v1" ]]; then
    echo "[api] ERROR: Unsafe API base: '$base' (must be https://www.moltbook.com/api/v1)" >&2
    return 1
  fi
}

# --- Helpers ---
_api_tmp() { mktemp "${TMPDIR:-/tmp}/mbot.XXXXXX"; }

_api_sleep_backoff() {
  local attempt="$1"
  sleep $(( attempt * RETRY_SLEEP_BASE ))
}

# Build absolute url from either:
# - absolute https://www.moltbook.com/api/v1/...
# - relative /posts?...
_api_url() {
  local path="$1"
  if [[ "$path" =~ ^https:// ]]; then
    echo "$path"
  else
    # ensure leading slash
    [[ "$path" == /* ]] || path="/$path"
    echo "${MOLTBOOK_API_BASE}${path}"
  fi
}

# Validate URL points to allowed host+prefix.
_api_enforce_url() {
  local url="$1"
  if [[ "$url" != https://www.moltbook.com/api/v1/* ]]; then
    echo "[api] ERROR: Refusing to call non-matching URL: $url" >&2
    return 1
  fi
}

# Core request: method + path + optional JSON body
# Outputs response JSON to stdout.
# Returns non-zero on permanent failure.
_api_request() {
  local method="$1"
  local path="$2"
  local body_json="${3:-}"

  _api_enforce_base "$MOLTBOOK_API_BASE"

  local url; url="$(_api_url "$path")"
  _api_enforce_url "$url"

  local tmp; tmp="$(_api_tmp)"
  local http_code=""
  local attempt

  for ((attempt=1; attempt<=API_TRIES; attempt++)); do
    # shellcheck disable=SC2086
    if [[ "$method" == "GET" ]]; then
      http_code="$(curl -sS -L \
        --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
        -o "$tmp" -w "%{http_code}" \
        -H "Authorization: Bearer $MOLTBOOK_API_KEY" \
        "$url" || true)"
    else
      http_code="$(curl -sS -L \
        --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
        -o "$tmp" -w "%{http_code}" \
        -X "$method" \
        -H "Authorization: Bearer $MOLTBOOK_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$body_json" \
        "$url" || true)"
    fi

    # Must be JSON (even on errors Moltbook claims JSON format)
    if jq -e . >/dev/null 2>&1 < "$tmp"; then
      # 2xx success
      if [[ "$http_code" == 2* ]]; then
        cat "$tmp"
        rm -f "$tmp"
        return 0
      fi

      # Handle rate limiting: 429 with retry hints
      if [[ "$http_code" == "429" ]]; then
        local retry_s retry_m
        retry_s="$(jq -r '.retry_after_seconds // empty' < "$tmp" 2>/dev/null || true)"
        retry_m="$(jq -r '.retry_after_minutes // empty' < "$tmp" 2>/dev/null || true)"
        if [[ -n "$retry_s" ]]; then
          sleep "$retry_s"
        elif [[ -n "$retry_m" ]]; then
          sleep $(( retry_m * 60 ))
        else
          _api_sleep_backoff "$attempt"
        fi
        continue
      fi

      # 5xx: retry
      if [[ "$http_code" =~ ^5 ]]; then
        _api_sleep_backoff "$attempt"
        continue
      fi

      # Other non-2xx: return error immediately (but still output body for logs)
      cat "$tmp"
      rm -f "$tmp"
      return 2
    fi

    # Non-JSON or empty: retry
    _api_sleep_backoff "$attempt"
  done

  echo "[api] ERROR: Request failed after retries: $method $url (last_code=${http_code:-none})" >&2
  rm -f "$tmp"
  return 3
}

# =============================================================================
# Public API
# =============================================================================

# get_feed <path_or_url>
get_feed() {
  local path="$1"
  _api_request "GET" "$path"
}

# get_post <post_id>
get_post() {
  local post_id="$1"
  _api_request "GET" "/posts/$post_id"
}

# get_comments <post_id> [sort] [limit]
get_comments() {
  local post_id="$1"
  local sort="${2:-new}"
  local limit="${3:-50}"
  _api_request "GET" "/posts/$post_id/comments?sort=$sort&limit=$limit"
}

# create_comment <post_id> <content_string>
create_comment() {
  local post_id="$1"
  local content="$2"
  local body
  body="$(jq -nc --arg c "$content" '{content:$c}')"
  _api_request "POST" "/posts/$post_id/comments" "$body"
}
