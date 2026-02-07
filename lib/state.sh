#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# State & Idempotency (cron-safe)
# =============================================================================
# Requirements: jq, flock
#
# Files (defaults under ./state):
#   state/lock
#   state/seen_threads.txt
#   state/cooldowns.json
#   state/last_run.json
#
# ENV:
#   STATE_DIR (optional) default: ./state
# =============================================================================

STATE_DIR="${STATE_DIR:-./state}"
LOCK_FILE="${LOCK_FILE:-$STATE_DIR/lock}"
SEEN_FILE="${SEEN_FILE:-$STATE_DIR/seen_threads.txt}"
COOLDOWNS_FILE="${COOLDOWNS_FILE:-$STATE_DIR/cooldowns.json}"
LAST_RUN_FILE="${LAST_RUN_FILE:-$STATE_DIR/last_run.json}"

# comment limits (Moltbook documented)
COMMENT_COOLDOWN_SECONDS="${COMMENT_COOLDOWN_SECONDS:-20}"
COMMENT_DAILY_LIMIT="${COMMENT_DAILY_LIMIT:-50}"

# internal lock fd
STATE_LOCK_FD=9

state_init() {
  mkdir -p "$STATE_DIR"
  touch "$SEEN_FILE"

  if [[ ! -f "$COOLDOWNS_FILE" ]]; then
    cat > "$COOLDOWNS_FILE" <<'JSON'
{
  "last_comment_at": null,
  "daily_comment_count": 0,
  "daily_comment_date": null
}
JSON
  fi

  if [[ ! -f "$LAST_RUN_FILE" ]]; then
    cat > "$LAST_RUN_FILE" <<'JSON'
{
  "last_run_at": null,
  "last_nonce": null,
  "last_selected_post_id": null,
  "last_selected_thread_id": null
}
JSON
  fi
}

# Acquire a non-blocking lock for this run.
# Keeps lock as long as FD 9 is open (process lifetime).
state_lock_acquire() {
  mkdir -p "$STATE_DIR"

  # open lock file on FD 9 for lifetime of this process
  exec 9>"$LOCK_FILE"

  if ! flock -n 9; then
    echo "[state] INFO: Another instance is running. Exiting." >&2
    return 1
  fi

  # Optional debug info inside lock file
  printf 'pid=%s started=%s\n' "$$" "$(date -Is)" 1>&9 || true
  return 0
}

# Generate a per-run nonce
state_gen_run_nonce() {
  local run_id
  run_id="$(date '+%Y%m%dT%H%M%S')-$$-$RANDOM"
  echo "mbot:${run_id}"
}

# Track last run metadata
state_set_last_run() {
  local nonce="$1"
  local post_id="${2:-null}"
  local thread_id="${3:-null}"
  local now
  now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  jq -nc --arg now "$now" --arg nonce "$nonce" \
        --arg post "$post_id" --arg thread "$thread_id" \
    '{
      last_run_at: $now,
      last_nonce: $nonce,
      last_selected_post_id: ($post | if .=="null" then null else . end),
      last_selected_thread_id: ($thread | if .=="null" then null else . end)
    }' > "$LAST_RUN_FILE"
}

# Normalize ID for robust line matching
state_norm_id() {
  printf '%s' "$1" | tr -d '\r\n'
}

# Seen threads: check/add
state_seen_contains() {
  local thread_id
  thread_id="$(state_norm_id "$1")"
  grep -Fxq "$thread_id" "$SEEN_FILE"
}

state_seen_add() {
  local thread_id
  thread_id="$(state_norm_id "$1")"
  # idempotent append
  if ! state_seen_contains "$thread_id"; then
    printf '%s\n' "$thread_id" >> "$SEEN_FILE"
  fi
}

# Cooldown handling
_state_today_utc() { date -u '+%Y-%m-%d'; }
_state_now_epoch() { date -u '+%s'; }

state_cooldowns_read() {
  jq -c '.' "$COOLDOWNS_FILE"
}

state_cooldowns_write() {
  local json="$1"
  # validate
  echo "$json" | jq -e . >/dev/null
  echo "$json" > "$COOLDOWNS_FILE"
}

state_daily_rollover_if_needed() {
  local today
  today="$(_state_today_utc)"

  local cur_date
  cur_date="$(jq -r '.daily_comment_date // empty' "$COOLDOWNS_FILE")"

  if [[ -z "$cur_date" || "$cur_date" != "$today" ]]; then
    jq --arg today "$today" '.daily_comment_date=$today | .daily_comment_count=0' \
      "$COOLDOWNS_FILE" > "$COOLDOWNS_FILE.tmp"
    mv "$COOLDOWNS_FILE.tmp" "$COOLDOWNS_FILE"
  fi
}

# Returns:
#  0 => ok to comment
#  1 => blocked by cooldown
#  2 => blocked by daily limit
state_can_comment() {
  state_daily_rollover_if_needed

  local now last_epoch delta count
  now="$(_state_now_epoch)"
  count="$(jq -r '.daily_comment_count // 0' "$COOLDOWNS_FILE")"

  if (( count >= COMMENT_DAILY_LIMIT )); then
    return 2
  fi

  local last
  last="$(jq -r '.last_comment_at // empty' "$COOLDOWNS_FILE")"
  if [[ -z "$last" ]]; then
    return 0
  fi

  # Parse ISO8601-like UTC stamp: %Y-%m-%dT%H:%M:%SZ
  if ! last_epoch="$(date -u -d "$last" '+%s' 2>/dev/null)"; then
    # if unparsable, be safe and allow
    return 0
  fi

  delta=$(( now - last_epoch ))
  if (( delta < COMMENT_COOLDOWN_SECONDS )); then
    return 1
  fi

  return 0
}

# Call after successful comment post
state_note_comment_success() {
  state_daily_rollover_if_needed
  local now_iso
  now_iso="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  jq --arg now "$now_iso" \
     '.last_comment_at=$now | .daily_comment_count=((.daily_comment_count // 0) + 1)' \
     "$COOLDOWNS_FILE" > "$COOLDOWNS_FILE.tmp"
  mv "$COOLDOWNS_FILE.tmp" "$COOLDOWNS_FILE"
}

# Basic file-based idempotency marker in comment body:
# check whether a nonce already exists in comments for that post is handled in higher layers.
# Here we provide helper to embed/run nonce.
state_wrap_nonce_line() {
  local nonce="$1"
  printf 'mbot: %s' "$nonce"
}
