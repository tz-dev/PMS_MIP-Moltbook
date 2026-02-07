#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load specs (needed for M10 payload + spec registry)
# shellcheck disable=SC1091
source "$ROOT_DIR/config/specs.sh"

MODEL_ROUTER="${MODEL_ROUTER:-${MODEL:-qwen2.5:14b-instruct}}"
MAX_ROUTER_CHARS="${MAX_ROUTER_CHARS:-15000}"

router_log(){ echo "[router] $*" >&2; }

MBOT_DEBUG_ROUTER_PROMPT="${MBOT_DEBUG_ROUTER_PROMPT:-0}"
MBOT_DEBUG_PROMPT_DIR="${MBOT_DEBUG_PROMPT_DIR:-$ROOT_DIR/logs}"
MBOT_DEBUG_PROMPT_MAX="${MBOT_DEBUG_PROMPT_MAX:-500000}"

trim_to() { local n="$1"; shift; printf '%s' "${1:0:n}"; }

ollama_ok() { command -v ollama >/dev/null 2>&1; }

# Deterministic mapping from addon_key -> name/url
addon_url_for_key() {
  case "$1" in
    MIP-CORE)         echo "MIP–CORE|https://raw.githubusercontent.com/tz-dev/MIP/refs/heads/main/model/MIP.yaml" ;;
    PMS-ANTICIPATION) echo "PMS–ANTICIPATION|https://raw.githubusercontent.com/tz-dev/PMS-ANTICIPATION/refs/heads/main/model/PMS-ANTICIPATION.yaml" ;;
    PMS-CONFLICT)     echo "PMS–CONFLICT|https://raw.githubusercontent.com/tz-dev/PMS-CONFLICT/refs/heads/main/model/PMS-CONFLICT.yaml" ;;
    PMS-CRITIQUE)     echo "PMS–CRITIQUE|https://raw.githubusercontent.com/tz-dev/PMS-CRITIQUE/refs/heads/main/model/PMS-CRITIQUE.yaml" ;;
    PMS-EDEN)         echo "PMS–EDEN|https://raw.githubusercontent.com/tz-dev/PMS-EDEN/refs/heads/main/model/PMS-EDEN.yaml" ;;
    PMS-SEX)          echo "PMS–SEX|https://raw.githubusercontent.com/tz-dev/PMS-SEX/refs/heads/main/model/PMS-SEX.yaml" ;;
    *)                echo "PMS–LOGIC|https://raw.githubusercontent.com/tz-dev/PMS-LOGIC/refs/heads/main/model/PMS-LOGIC.yaml" ;;
  esac
}

# Build router prompt and return JSON (stdout).
# Input: candidate JSON object
route_candidate() {
  local cand_json="$1"

  local title content submolt author
  title="$(jq -r '.title // ""' <<<"$cand_json")"
  content="$(jq -r '.content // ""' <<<"$cand_json")"
  submolt="$(jq -r '.submolt // ""' <<<"$cand_json")"
  author="$(jq -r '.author // ""' <<<"$cand_json")"

  local content_short
  content_short="$(trim_to "$MAX_ROUTER_CHARS" "$content")"

  # If no ollama, fallback deterministic route
  if ! ollama_ok; then
    echo '{"should_comment":true,"reason":"fallback_no_ollama","reply_mode":"strict_social","tone":"neutral","target_length":"short","addon_key":"PMS-LOGIC","risk_flags":[]}'
    return 0
  fi

  local prompt
  prompt="$(cat <<EOF
Return ONLY a single JSON object. No extra text.

Candidate:
submolt: $submolt
author: $author
title: $title
content: $content_short

Rules:
- If spam/mint/test/automation noise -> should_comment=false and add risk_flags.
- reply_mode must be one of:
  explicit_pms, implicit_pms, explicit_mip, implicit_mip, strict_social
- tone must be one of: neutral, curious, skeptical, empathetic
- target_length must be one of: short, medium
- addon_key must be one of:
  MIP-CORE, PMS-ANTICIPATION, PMS-CONFLICT, PMS-CRITIQUE, PMS-EDEN, PMS-SEX, PMS-LOGIC

Heuristic reply_mode priority:
- If the post is mainly about dignity/shaming/humiliation, responsibility/blame/accountability,
  power/asymmetry/coercion/manipulation, harm/safety/consent, governance/moderation/sanctions/HR,
  public callouts or enforcement dynamics -> prefer implicit_mip (or explicit_mip if it explicitly asks for frameworks).
- Else if it is clearly about PMS/praxis-structure/operator-grammar (Δ/∇/□/Λ/… terms, PMS overlays, formal operator talk)
  -> implicit_pms (or explicit_pms if it explicitly asks for frameworks).
- Else -> strict_social.

Heuristic addon_key:
- If reply_mode is implicit_mip or explicit_mip -> addon_key MUST be MIP-CORE
- Else (PMS modes):
  anticip|forecast|future|risk -> PMS-ANTICIPATION
  conflict|war|fight|polar -> PMS-CONFLICT
  critique|critic|judg -> PMS-CRITIQUE
  comparison|status|recognition -> PMS-EDEN
  sex|consent|intimacy -> PMS-SEX
  else -> PMS-LOGIC

Schema:
{"should_comment":true,"reason":"...","reply_mode":"...","tone":"...","target_length":"...","addon_key":"...","risk_flags":[]}
EOF
)"

  router_log "ollama route (model=$MODEL_ROUTER) prompt_chars=${#prompt}"
  local out json

  if [[ "$MBOT_DEBUG_ROUTER_PROMPT" == "1" ]]; then
    mkdir -p "$MBOT_DEBUG_PROMPT_DIR"
    local ts file
    ts="$(date '+%Y%m%dT%H%M%S')"
    file="$MBOT_DEBUG_PROMPT_DIR/last_router_prompt_${ts}_$$.txt"

    {
      echo "MBOT_ROUTER_PROMPT_META:"
      echo "  model=$MODEL_ROUTER"
      echo "  prompt_chars=${#prompt}"
      echo "MBOT_ROUTER_PROMPT_BEGIN"
      printf "%s\n" "$prompt" | head -c "$MBOT_DEBUG_PROMPT_MAX"
      echo
      echo "MBOT_ROUTER_PROMPT_END"
    } > "$file"

    router_log "debug: wrote prompt to $file"
  fi

  out="$(printf '%s' "$prompt" | ollama run "$MODEL_ROUTER" 2>/dev/null || true)"
  out="$(printf '%s' "$out" | tr -d '\r' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"

  # 1) If it's already JSON, keep it
  if jq -e . >/dev/null 2>&1 <<<"$out"; then
    json="$out"
  else
    # 2) Try to extract first {...} block if model wraps text
    json="$(python3 - <<'PY'
import re,sys
s=sys.stdin.read()
m=re.search(r'\{.*\}', s, re.S)
print(m.group(0) if m else "")
PY
<<<"$out")"
  fi

  if [[ -z "${json:-}" ]]; then
    echo '{"should_comment":true,"reason":"router_parse_fail","reply_mode":"strict_social","tone":"neutral","target_length":"short","addon_key":"PMS-LOGIC","risk_flags":["router_parse_fail"]}'
    return 0
  fi

  # Validate shape & fallback if invalid
  if ! jq -e '
    (.should_comment|type=="boolean") and
    (.reason|type=="string") and
    (.reply_mode|IN("explicit_pms","implicit_pms","explicit_mip","implicit_mip","strict_social")) and
    (.tone|IN("neutral","curious","skeptical","empathetic")) and
    (.target_length|IN("short","medium")) and
    (.addon_key|IN("MIP-CORE","PMS-ANTICIPATION","PMS-CONFLICT","PMS-CRITIQUE","PMS-EDEN","PMS-SEX","PMS-LOGIC")) and
    (.risk_flags|type=="array")
  ' >/dev/null 2>&1 <<<"$json"; then
    echo '{"should_comment":true,"reason":"router_invalid_schema","reply_mode":"strict_social","tone":"neutral","target_length":"short","addon_key":"PMS-LOGIC","risk_flags":["router_invalid_schema"]}'
    return 0
  fi

  # Enforce addon_key for MIP modes (belt + suspenders)
  local rm ak
  rm="$(jq -r '.reply_mode' <<<"$json")"
  ak="$(jq -r '.addon_key' <<<"$json")"
  if [[ "$rm" == "implicit_mip" || "$rm" == "explicit_mip" ]]; then
    if [[ "$ak" != "MIP-CORE" ]]; then
      json="$(jq '.addon_key="MIP-CORE" | .risk_flags += ["router_forced_mip_addon"]' <<<"$json")"
    fi
  fi

  echo "$json"
}

# Convenience: enrich router output with addon name+url
enrich_route_with_addon() {
  local route_json="$1"
  local key name url pair
  key="$(jq -r '.addon_key' <<<"$route_json")"
  pair="$(addon_url_for_key "$key")"
  name="${pair%%|*}"
  url="${pair##*|}"

  jq --arg n "$name" --arg u "$url" '
    . + { addon: { name: $n, url: $u } }
  ' <<<"$route_json"
}

# Returns: prints FULL spec payload to stdout, or nothing.
# This is used for skill-aware routing: inject the relevant spec(s) into the writer prompt.
# IMPORTANT: This payload must go into the system/developer prompt section (not user content).
router_m10_spec_payload() {
  local enable_specs="$1"   # "true"/"false" (explicit flag OR config switch)
  local reply_mode="$2"     # explicit_pms|implicit_pms|explicit_mip|implicit_mip|strict_social
  local addon_key="$3"      # PMS-* or MIP-CORE

  [[ "$enable_specs" == "true" ]] || return 0

  # Never inject specs for strict_social
  [[ "$reply_mode" != "strict_social" ]] || return 0

  # addon_key sanity
  [[ -n "$addon_key" ]] || return 0

  local payload=""

  # --- MIP family ---
  if [[ "$reply_mode" == "explicit_mip" || "$reply_mode" == "implicit_mip" ]]; then
    [[ -n "${MIP_CORE_SPEC:-}" ]] || return 0
    payload+=$'### MIP_CORE_SPEC (canonical)\n'
    payload+="${MIP_CORE_SPEC}"
    payload+=$'\n'
  fi

  # --- PMS family ---
  if [[ "$reply_mode" == "explicit_pms" || "$reply_mode" == "implicit_pms" ]]; then
    [[ -n "${PMS_CORE_SPEC:-}" ]] || return 0
    payload+=$'### PMS_CORE_SPEC (canonical)\n'
    payload+="${PMS_CORE_SPEC}"
    payload+=$'\n\n'

    if [[ "$addon_key" == PMS-* ]]; then
      local addon_id="${addon_key//-/_}"   # PMS-ANTICIPATION -> PMS_ANTICIPATION
      local reg_var="PMS_ADDON_SPEC_VAR_${addon_id}"
      local spec_var="${!reg_var:-}"

      if [[ -n "$spec_var" ]]; then
        local spec_content="${!spec_var:-}"
        if [[ -n "$spec_content" ]]; then
          payload+=$'### PMS_SELECTED_ADDON_SPEC (full)\n'
          payload+="${spec_content}"
          payload+=$'\n'
        fi
      fi
    fi
  fi

  [[ -n "$payload" ]] || return 0

  # Optional cache (full payload) — deterministic and cheap
  local h
  h="$(printf "%s" "$payload" | sha256sum | awk '{print $1}')"
  local cache_dir="$ROOT_DIR/state/spec_payload_cache"
  mkdir -p "$cache_dir"
  local cache_file="${cache_dir}/${reply_mode}_${addon_key}_${h}.txt"

  if [[ -f "$cache_file" ]]; then
    cat "$cache_file"
    return 0
  fi

  # IMPORTANT: emit ONLY the payload (no meta/header lines), so the writer can inject it verbatim.
  router_log "spec_payload cache_miss reply_mode=$reply_mode addon=$addon_key hash=$h chars=${#payload}"
  printf "%s\n" "$payload" > "$cache_file"
  printf "%s\n" "$payload"
  return 0
}
