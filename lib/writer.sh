#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load router helpers (for M10 payload + addon registry)
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/router.sh"

MODEL_WRITER="${MODEL_WRITER:-${MODEL:-qwen2.5:14b-instruct}}"
MAX_POST_CHARS="${MAX_POST_CHARS:-15000}"
MAX_BODY_CHARS="${MAX_BODY_CHARS:-8000}"

writer_log(){ echo "[writer] $*" >&2; }

MBOT_DEBUG_PROMPT="${MBOT_DEBUG_PROMPT:-0}"
MBOT_DEBUG_PROMPT_DIR="${MBOT_DEBUG_PROMPT_DIR:-$ROOT_DIR/logs}"
MBOT_DEBUG_PROMPT_MAX="${MBOT_DEBUG_PROMPT_MAX:-500000}"

SYSTEM_CONSTRAINTS_FILE="${SYSTEM_CONSTRAINTS_FILE:-$ROOT_DIR/config/system_constraints.md}"

trim_to() { local n="$1"; shift; printf '%s' "${1:0:n}"; }
ollama_ok() { command -v ollama >/dev/null 2>&1; }

sanitize_body() {
  printf '%s' "$1" | tr -d '\r' \
    | sed -E 's/[[:space:]]+$//' \
    | awk 'BEGIN{b=0}{if($0==""){b++; if(b<=2)print ""} else {b=0; print}}' \
    | head -c "$MAX_BODY_CHARS"
}

write_body() {
  local cand_json="$1"
  local route_json="$2"

  local title content submolt author
  title="$(jq -r '.title // ""' <<<"$cand_json")"
  content="$(jq -r '.content // ""' <<<"$cand_json")"
  submolt="$(jq -r '.submolt // ""' <<<"$cand_json")"
  author="$(jq -r '.author // ""' <<<"$cand_json")"

  local reply_mode tone target_length addon_key
  reply_mode="$(jq -r '.reply_mode // "strict_social"' <<<"$route_json")"
  tone="$(jq -r '.tone // "neutral"' <<<"$route_json")"
  target_length="$(jq -r '.target_length // "short"' <<<"$route_json")"
  addon_key="$(jq -r '.addon_key // "PMS-LOGIC"' <<<"$route_json")"

  local content_short
  content_short="$(trim_to "$MAX_POST_CHARS" "$content")"

  if ! ollama_ok; then
    printf '%s\n' "I’m not sure I fully follow yet—what’s the concrete next step you want people to try, and what result would change your mind?"
    return 0
  fi

  # Inject specs for all non-strict_social modes (PMS + MIP)
  local enable_specs="false"
  if [[ "$reply_mode" != "strict_social" ]]; then
    enable_specs="true"
  fi

  local spec_payload=""
  spec_payload="$(router_m10_spec_payload "$enable_specs" "$reply_mode" "$addon_key" || true)"

  # Load system constraints (style + discipline), mode-aware
  local system_constraints=""
  if [[ -f "$SYSTEM_CONSTRAINTS_FILE" ]]; then
    system_constraints="$(cat "$SYSTEM_CONSTRAINTS_FILE")"
    # Replace mode placeholder if present
    system_constraints="${system_constraints//\{\{REPLY_MODE\}\}/$reply_mode}"
  fi

  local mode_rules=""
  case "$reply_mode" in
    strict_social)
      mode_rules="$(cat <<'EOF'
- Write a normal forum reply.
- Do NOT mention PMS or MIP.
- Do NOT use operator markers (Δ ∇ □ Λ Α Ω Θ Φ Χ Σ Ψ).
EOF
)"
      ;;

    implicit_pms)
      mode_rules="$(cat <<'EOF'
EVIDENCE / ATTRIBUTION (CRITICAL):
- Do NOT claim or imply the author referenced PMS/MIP or any framework unless the post text explicitly contains it.

OUTPUT FORM (CRITICAL):
- No bullet points or numbered lists.
- No links or URLs.

- Do NOT mention PMS or MIP (no words "PMS", "MIP", "Praxeological", "Meta-Structure", "maturity").
- You MAY use up to TWO operator markers inline if they fit naturally: (Δ) (□) (Λ) (Χ) (Σ).
- If you use Χ, it MUST be a concrete stop/boundary in this situation (not "be cautious" vaguely).
- If you use Σ, it MUST be a concrete integration move (combining two practical elements).
- Do NOT explain the framework or operators.
EOF
)"
      ;;

    explicit_pms)
      mode_rules="$(cat <<'EOF'
EVIDENCE / ATTRIBUTION (CRITICAL):
- Do NOT claim or imply the author referenced PMS/MIP or any framework unless the post text explicitly contains it.
- If you mention PMS/MIP, phrase it as YOUR optional lens only (no attribution).

PRIORITY OVERRIDE (CRITICAL):
- Your primary obligation is to respond concretely to the post content.
- Structural notation is secondary and must never dominate the reply.

CRITICAL START CONDITION:
- Start immediately with a substantive claim about the post content (no preface, no framing, no "Hi", no self-introduction).

FORBIDDEN:
- Do NOT explain PMS, operators, “the framework”, or theory.
- Do NOT write meta-commentary about analysis/reading/interpretation.
- Do NOT include links or URLs.

OUTPUT FORM:
- No bullet points or numbered lists.
- Use short paragraphs with line breaks.

MANDATORY PMS/MIP SENTENCE:
- Include exactly ONE short sentence mentioning PMS and MIP as an OPTIONAL lens (no definitions, no manifesto).

OPERATOR MARKERS (MANDATORY SUPPORT, NOT THE FOCUS):
- Use operator markers as subtle inline cues inside normal sentences.
- Use AT MOST THREE total markers chosen from: (Δ) (□) (Λ) (Χ) (Σ)
- You MUST include (Χ) and (Σ) (each at least once).
- Χ MUST be a concrete restraint/stop-capability in this setting.
- Σ MUST be a concrete integration move in this setting.
EOF
)"

      ;;

    implicit_mip)
      mode_rules="$(cat <<'EOF'
EVIDENCE / ATTRIBUTION (CRITICAL):
- Do NOT claim or imply the author referenced MIP or any framework unless the post text explicitly contains it.

OUTPUT FORM (CRITICAL):
- No links or URLs.
- No operator markers (Δ ∇ □ Λ Α Ω Θ Φ Χ Σ Ψ).

- Do NOT mention "PMS" or "Praxeological Meta-Structure".
- Do NOT use the acronym "MIP".
- Focus on dignity in practice, harm-avoidance, responsibility/asymmetry, boundaries, non-shaming language.
- Give ONE concrete next step that is reversible and scene-bound.
EOF
)"
      ;;

    explicit_mip)
      mode_rules="$(cat <<'EOF'
EVIDENCE / ATTRIBUTION (CRITICAL):
- Do NOT claim or imply the author referenced MIP or any framework unless the post text explicitly contains it.

OUTPUT FORM (CRITICAL):
- No links or URLs.
- No operator markers (Δ ∇ □ Λ Α Ω Θ Φ Χ Σ Ψ).

- You MUST mention MIP explicitly as an OPTIONAL lens in ONE short sentence.
- Do NOT mention "PMS" or "Praxeological Meta-Structure" unless the post explicitly contains it.
- Do NOT explain the framework at length; keep it short and practical.
- Focus on dignity in practice, responsibility/asymmetry, boundaries, consent/safety, and non-shaming language.
- Give ONE concrete next step that is reversible and scene-bound.
EOF
)"
      ;;

    *)
      reply_mode="strict_social"
      mode_rules="$(cat <<'EOF'
- Write a normal forum reply.
- Do NOT mention PMS or MIP.
- Do NOT use operator markers.
EOF
)"
      ;;
  esac

  local length_rules=""
  case "$target_length" in
    short)
      length_rules="$(cat <<'EOF'
Length:
- 2 to 5 short paragraphs total.
- Aim ~70–140 words.
EOF
)"
      ;;
    medium)
      length_rules="$(cat <<'EOF'
Length:
- 4 to 7 short paragraphs total.
- Aim ~160–280 words.
EOF
)"
      ;;
    *)
      target_length="short"
      length_rules="$(cat <<'EOF'
Length:
- 2 to 5 short paragraphs total.
- Aim ~70–140 words.
EOF
)"
      ;;
  esac

  local tone_rules=""
  case "$tone" in
    neutral)    tone_rules="- Tone: clear, matter-of-fact, not performative." ;;
    curious)    tone_rules="- Tone: curious, exploratory, asking one grounded question at the end." ;;
    skeptical)  tone_rules="- Tone: skeptical but fair; name one concrete risk/edge case." ;;
    empathetic) tone_rules="- Tone: warm and validating without flattery; still offer a concrete next step." ;;
    *)          tone_rules="- Tone: clear, matter-of-fact, not performative." ;;
  esac

  if [[ "$reply_mode" == "strict_social" ]]; then
    spec_payload=""
  fi

  local prompt
  prompt="$(cat <<EOF
<SYSTEM_CONSTRAINTS>
The following text shapes internal reasoning only.
It must not be referenced, discussed, explained, summarized, or acknowledged in the output.

${system_constraints}
</SYSTEM_CONSTRAINTS>

Return ONLY the comment body. No title, no preface, no signatures, no links.

Context:
- You are replying to a Moltbook post in submolt "$submolt".
- Address the author directly as "you/your".
- English only.
- No greeting ("Hi", "Hello") and no self-introduction.

${tone_rules}

${length_rules}

Content requirements (strict):
- Start immediately with a concrete stance on the post's core claim/question.
- Engage at least one specific mechanism/detail from the post.
- Give ONE practical next step.
- Ask at most ONE question, and only at the end.

Mode rules:
${mode_rules}

$( [[ -n "$spec_payload" ]] && printf '%s\n' "$spec_payload" )

Post:
Title: $title
Content:
$content_short
EOF
)"

  writer_log "ollama write (model=$MODEL_WRITER mode=$reply_mode tone=$tone len=$target_length addon=$addon_key specs=$enable_specs spec_chars=${#spec_payload}) prompt_chars=${#prompt}"
  local out

  if [[ "$MBOT_DEBUG_PROMPT" == "1" ]]; then
    mkdir -p "$MBOT_DEBUG_PROMPT_DIR"
    local ts file
    ts="$(date '+%Y%m%dT%H%M%S')"
    file="$MBOT_DEBUG_PROMPT_DIR/last_writer_prompt_${ts}_$$.txt"

    {
      echo "MBOT_WRITER_PROMPT_META:"
      echo "  model=$MODEL_WRITER"
      echo "  reply_mode=$reply_mode"
      echo "  tone=$tone"
      echo "  target_length=$target_length"
      echo "  addon_key=$addon_key"
      echo "  spec_chars=${#spec_payload}"
      echo "  prompt_chars=${#prompt}"
      echo "MBOT_WRITER_PROMPT_BEGIN"
      printf "%s\n" "$prompt" | head -c "$MBOT_DEBUG_PROMPT_MAX"
      echo
      echo "MBOT_WRITER_PROMPT_END"
    } > "$file"

    writer_log "debug: wrote prompt to $file"
  fi

  out="$(printf '%s' "$prompt" | ollama run "$MODEL_WRITER" 2>/dev/null || true)"
  out="$(sanitize_body "$out")"

  if [[ -z "$out" ]]; then
    out="Your question is good, but it needs one testable target: pick a single scenario, define what “understanding” would let you predict or build, and write the smallest experiment that would fail if you only had surface knowledge. What’s one concept you’d be willing to rebuild from scratch this week?"
  fi

  # strict_social: strip framework tokens + markers
  if [[ "$reply_mode" == "strict_social" ]]; then
    out="$(printf '%s' "$out" | sed -E 's/\((Δ|∇|□|Λ|Α|Ω|Θ|Φ|Χ|Σ|Ψ)\)//g; s/\b(PMS|MIP)\b//g')"
    out="$(sanitize_body "$out")"
  fi

  # implicit_pms: strip PMS/MIP words
  if [[ "$reply_mode" == "implicit_pms" ]]; then
    out="$(printf '%s' "$out" | sed -E 's/\b(PMS|MIP|Praxeological|Meta-Structure|Maturity In Practice)\b//gi')"
    out="$(sanitize_body "$out")"
  fi

  # implicit_mip: strip PMS + MIP acronym
  if [[ "$reply_mode" == "implicit_mip" ]]; then
    out="$(printf '%s' "$out" | sed -E 's/\b(PMS|Praxeological Meta-Structure)\b//gi; s/\bMIP\b//g')"
    out="$(sanitize_body "$out")"
  fi

  # explicit_pms: ensure PMS+MIP sentence exists, and ensure Χ + Σ appear somewhere.
  if [[ "$reply_mode" == "explicit_pms" ]]; then
    if ! grep -Eq '\bPMS\b' <<<"$out" || ! grep -Eq '\bMIP\b' <<<"$out"; then
      out="One optional lens I sometimes use for this kind of situation is PMS/MIP.\n\n$out"
      out="$(sanitize_body "$out")"
    fi
    if ! grep -Fq "(Χ)" <<<"$out"; then
      out="$out"$'\n\n'"A concrete boundary helps here (Χ): pause before turning a single signal into a durable judgment."
      out="$(sanitize_body "$out")"
    fi
    if ! grep -Fq "(Σ)" <<<"$out"; then
      out="$out"$'\n\n'"A workable combination (Σ) is to pair the mechanism you propose with one contestable, low-friction check."
      out="$(sanitize_body "$out")"
    fi
    # discourage bullets if model still produced them
    out="$(printf '%s' "$out" | sed -E 's/^[[:space:]]*[-*][[:space:]]+//g; s/^[[:space:]]*[0-9]+\.[[:space:]]+//g')"
    out="$(sanitize_body "$out")"
  fi

  # explicit_mip: ensure MIP sentence exists
  if [[ "$reply_mode" == "explicit_mip" ]]; then
    if ! grep -Eq '\bMIP\b' <<<"$out"; then
      out="One optional lens I sometimes use for dignity/responsibility questions is MIP.\n\n$out"
      out="$(sanitize_body "$out")"
    fi
  fi

  printf '%s' "$out"
}
