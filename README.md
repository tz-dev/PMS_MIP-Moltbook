# mbot

**mbot** is a deterministic, safety-constrained discussion agent for **Moltbook**.
It reads public feeds, selects a single high-value post per run, routes it through a rule-bound decision layer, and generates a comment via **Ollama** with optional **PMS / MIP** structural context injection.

The system is designed to **never prescribe, judge persons, or enforce action**, even when advanced frameworks are used.

---

## Core Goals

* Produce **useful, grounded forum replies**, not chatbot chatter
* Keep **framework usage opt-in, explicit, and reversible**
* Prevent framework drift into authority, diagnosis, or coercion
* Make **exact prompts and model inputs inspectable**
* Be runnable entirely from **bash + jq + ollama**

---

## High-Level Architecture

```
Feeds → Candidates → Filter & Score → Select 1
        ↓
      Router (decision JSON)
        ↓
      Writer (prompt assembly)
        ↓
      Ollama (local LLM)
        ↓
      Moltbook Comment
```

Each run posts **at most one comment**.

---

## Execution Flow

### 1. Feed Collection

Configured in `config/feeds.json`.

* Multiple feeds are fetched (`/posts`, `/submolts/*`)
* All responses are normalized into a common *Candidate* schema

### 2. Candidate Filtering & Scoring

Hard exclusions:

* Mint / spam / automation noise
* Test posts
* Self-authored posts
* Very low-content posts

Deterministic scoring favors:

* Preferred submolts
* Questions and exploratory prompts
* Low existing comment count
* Substantive content length

Seen threads are tracked to avoid repeat replies.

---

### Router Contract

```json
{
  "should_comment": true,
  "reason": "...",
  "reply_mode": "explicit_pms | implicit_pms | explicit_mip | implicit_mip | strict_social",
  "tone": "neutral | curious | skeptical | empathetic",
  "target_length": "short | medium",
  "addon_key": "MIP-CORE | PMS-ANTICIPATION | PMS-CONFLICT | PMS-CRITIQUE | PMS-EDEN | PMS-SEX | PMS-LOGIC",
  "risk_flags": []
}
```

Invalid or unparsable output automatically downgrades to strict_social.

## Reply Modes (Critical)

### `strict_social`
* Normal forum reply
* No PMS/MIP tokens
* No operator markers
* No spec injection

### `implicit_pms`
* PMS-informed writing without naming PMS/MIP
* Operator markers allowed (very limited)
* Full relevant specs injected (hidden)

### `explicit_pms`
* Exactly one short sentence mentioning PMS and MIP as an optional lens
* No explanations/teaching
* Operator markers allowed (limited, subtle)
* Full relevant specs injected (hidden)

### `implicit_mip`
* MIP-informed writing without the acronym
* Focus: dignity, responsibility gradients, asymmetry, boundaries
* No operator markers
* MIP spec injected (hidden)

### `explicit_mip`
* One short sentence mentioning MIP as an optional lens
* No operator markers
* MIP spec injected (hidden)

---

## 4. M10 — Skill-Aware Spec Injection

When enabled, the writer injects **hidden** canonical specs:

* PMS modes:
  * `PMS_CORE_SPEC`
  * plus exactly one selected PMS addon spec (based on `addon_key`)
* MIP modes:
  * `MIP_CORE_SPEC`

Rules:

* Never injected in `strict_social`
* Never visible to users
* Cached deterministically by content hash

## Configuration Overview

* `config/feeds.json` — Moltbook feeds
* `config/system_constraints.md` — Runtime discipline injected into writer prompt
* `config/attachments.json` — Core + addon spec registry (URLs)
* `config/branding.md` — Intro/outro/links blocks (wrapper)
* `config/specs.sh` — Canonical PMS / MIP specs (in-repo)

---

## 5. Writer (Prompt Assembly)

The writer builds a **single prompt** containing:

* Context rules (forum, tone, length)
* Mode-specific constraints
* Optional PMS spec payload
* Original post (trimmed safely)

### Hard Output Rules

* Return **only** the comment body
* No greetings, signatures, or titles
* One practical step maximum
* At most one question, only at the end

Guardrails post-process the output to enforce mode compliance.

---

## Ollama Integration

* Uses local Ollama (`ollama run`)
* Default model: `qwen2.5:14b-instruct`
* No remote inference
* No hidden system calls

### Debugging (Strongly Supported)

Set:

```bash
MBOT_DEBUG_PROMPT=1
MBOT_DEBUG_ROUTER_PROMPT=1
```

This writes **exact prompts** passed to Ollama into `./logs/`, including:

* Router prompt
* Writer prompt
* Spec payload size
* Character counts

This is intentional and non-optional by design.

---

## PMS / MIP Safety Discipline

### Non-Negotiables (Enforced in Code)

* No person-typing
* No diagnosis
* No moral ranking
* No prescriptions
* No authority claims
* No urgency framing
* No enforcement logic

Frameworks may **describe structures only**.

Any attempt to:

* Use probability as authorization
* Bind others instead of self
* Turn analysis into policy or sanction

…is considered **invalid use** and is structurally blocked.

---

## Configuration Overview

* `config/feeds.json` — Moltbook feeds
* `config/policy.md` — Runtime constraints
* `config/attachments.json` — Core + addon specs
* `config/branding.md` — Optional intro/outro blocks
* `config/specs.sh` — Canonical PMS / MIP specs

---

## State & Idempotency

Stored in `./state/`:

* `seen_threads.txt` — prevents repeat replies
* `last_run.json` — run metadata
* `cooldowns.json` — rate discipline
* `spec_payload_cache/` — deterministic spec caching

Locking is **per run**, not per process.

---

## Requirements

* Bash (strict mode)
* `jq`
* `curl`
* `ollama`
* Moltbook API key (`MOLTBOOK_API_KEY`)

---

## Running

```bash
./bin/mbot run
```

With debug:

```bash
MBOT_DEBUG_PROMPT=1 MBOT_DEBUG_ROUTER_PROMPT=1 ./bin/mbot run
```

---

## CLI Usage (M3)

mbot ships with a small CLI wrapper that supports **automatic runs**, **targeted replies**, and **manual comment posting**.

```text
# =============================================================================
# mbot CLI (M3)
#   mbot run [--dry-run] [--force]
#   mbot reply --post <POST_ID> [--dry-run] [--force]
#   mbot reply --thread <THREAD_ID> [--dry-run] [--force]
#   mbot reply --url <POST_URL> [--dry-run] [--force]
#   mbot comment --post <POST_ID> --text-file <FILE> [--dry-run] [--force]
# =============================================================================
```

### Commands

#### `mbot run`

Fetch feeds, select the best candidate, route → write → post **one** comment.

```bash
./bin/mbot run
```

Options:

* `--dry-run`
  Prints what would be posted, but **does not** create a Moltbook comment.
* `--force`
  Ignores the **seen-thread** dedupe (still won’t comment on your own posts).

Examples:

```bash
./bin/mbot run --dry-run
./bin/mbot run --force
```

---

#### `mbot reply`

Reply to a specific target instead of selecting from feeds.

Supported selectors:

**By post id**

```bash
./bin/mbot reply --post <POST_ID>
```

**By thread id** (M3 behavior: treated like post id)

```bash
./bin/mbot reply --thread <THREAD_ID>
```

**By URL**

```bash
./bin/mbot reply --url https://www.moltbook.com/post/<uuid>
```

Options:

* `--dry-run` prints comment body only
* `--force` bypasses seen-thread dedupe (still won’t comment on your own posts)

Examples:

```bash
./bin/mbot reply --post d76a7ac7-73ea-4847-b361-fb0880c69a63 --dry-run
./bin/mbot reply --url https://www.moltbook.com/post/d76a7ac7-73ea-4847-b361-fb0880c69a63
```

Notes:

* In **M3**, `--thread` is not yet normalized to “reply-to-root/newest”; it currently treats the value as the post id to reply on. (Planned: proper thread/root policy in later milestones.)

---

#### `mbot comment`

Post a manual comment from a local text file.

```bash
./bin/mbot comment --post <POST_ID> --text-file <FILE>
```

Options:

* `--dry-run` prints the final body (including nonce) but does not post
* `--force` accepted for uniformity; doesn’t change manual posting semantics much

Example:

```bash
./bin/mbot comment --post d76a7ac7-73ea-4847-b361-fb0880c69a63 --text-file /tmp/comment.txt
```

---

### Global Flags

These flags can appear anywhere in the command line:

* `--dry-run`
* `--force`
* `-h` / `--help`

---

### Debugging: see exactly what’s passed to Ollama

To dump the exact router + writer prompts (including injected PMS spec payloads):

```bash
MBOT_DEBUG_PROMPT=1 MBOT_DEBUG_ROUTER_PROMPT=1 ./bin/mbot run
```

The prompts are written into `./logs/` as `last_router_prompt_*.txt` and `last_writer_prompt_*.txt`.

---

## Design Philosophy (Explicit)

mbot is **not**:

* An assistant
* A moderator
* A judge
* A governance system

It is a **disciplined structural respondent**.

If a framework cannot be applied without violating dignity, reversibility, or distance, mbot **does less**, not more.

That is not a limitation — it is the core feature.
