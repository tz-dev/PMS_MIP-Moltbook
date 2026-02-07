#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

BRANDING_FILE="${BRANDING_FILE:-$ROOT_DIR/config/branding.md}"
MAX_WRAPPED_CHARS="${MAX_WRAPPED_CHARS:-20000}"

wrap_log(){ echo "[wrap] $*" >&2; }

# Parse branding.md into intro/outro/links blocks.
# branding.md format:
# ---INTRO---
# ...
# ---OUTRO---
# ...
# ---LINKS---
# ...
branding_load_blocks() {
  [[ -f "$BRANDING_FILE" ]] || { echo "[wrap] ERROR: branding file not found: $BRANDING_FILE" >&2; return 1; }

  local intro outro links
  intro="$(awk '
    BEGIN{p=0}
    /^---INTRO---/{p=1;next}
    /^---OUTRO---/{p=0}
    p==1{print}
  ' "$BRANDING_FILE")"

  outro="$(awk '
    BEGIN{p=0}
    /^---OUTRO---/{p=1;next}
    /^---LINKS---/{p=0}
    p==1{print}
  ' "$BRANDING_FILE")"

  links="$(awk '
    BEGIN{p=0}
    /^---LINKS---/{p=1;next}
    p==1{print}
  ' "$BRANDING_FILE")"

  # emit as JSON so caller can jq
  jq -nc --arg intro "$intro" --arg outro "$outro" --arg links "$links" \
    '{intro:$intro,outro:$outro,links:$links}'
}

# Router can decide wrapper_size: short|full
# - short: intro+body+links+nonce (no outro) OR shorter intro if you want later
# - full: intro+outro+body+links+nonce
wrap_comment() {
  local body="$1"
  local route_json="$2"
  local addon_json="$3"   # {name,url} OR null/empty
  local nonce="$4"

  local wrapper_size
  wrapper_size="$(jq -r '.wrapper_size // "full"' <<<"$route_json")"

  local blocks intro outro links
  blocks="$(branding_load_blocks)"
  intro="$(jq -r '.intro' <<<"$blocks")"
  outro="$(jq -r '.outro' <<<"$blocks")"
  links="$(jq -r '.links' <<<"$blocks")"

  # Optional: include addon line if present
  local addon_line=""
  if [[ -n "$addon_json" ]] && jq -e . >/dev/null 2>&1 <<<"$addon_json"; then
    local an au
    an="$(jq -r '.name // ""' <<<"$addon_json")"
    au="$(jq -r '.url // ""' <<<"$addon_json")"
    if [[ -n "$an" && -n "$au" ]]; then
      addon_line="${an}: ${au}"
    fi
  fi

  # Build link block: branding links + addon (if any)
  local link_block="$links"
  if [[ -n "$addon_line" ]]; then
    link_block="${link_block}"$'\n\n'"${addon_line}"
  fi

  # Normalize spacing
  intro="$(printf '%s' "$intro" | sed -E 's/[[:space:]]+$//')"
  outro="$(printf '%s' "$outro" | sed -E 's/[[:space:]]+$//')"
  body="$(printf '%s' "$body" | sed -E 's/[[:space:]]+$//')"
  link_block="$(printf '%s' "$link_block" | sed -E 's/[[:space:]]+$//')"

  local out=""
  case "$wrapper_size" in
    short)
      out="${intro}"$'\n\n'"${body}"$'\n\n'"----------------------"$'\n'"${link_block}"$'\n\n'"----------------------"$'\n'"${nonce}"
      ;;
    full|*)
      out="${intro}"$'\n\n'"${outro}"$'\n\n'"${body}"$'\n\n'"----------------------"$'\n'"${link_block}"$'\n\n'"----------------------"$'\n'"${nonce}"
      ;;
  esac

  # Hard cap
  printf '%s' "$out" | head -c "$MAX_WRAPPED_CHARS"
}
