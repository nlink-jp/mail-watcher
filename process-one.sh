#!/usr/bin/env bash
# process-one.sh — Process a single eml/msg file through the full pipeline.
#
# Usage: ./process-one.sh <input-file> <hash>
#
# Pipeline:
#   1. Convert to JSONL (eml-to-jsonl / msg-to-jsonl)
#   2. Extract metadata → generate standardized filename
#   3. Analyze with LLM (gem-cli / lite-llm)
#   4. Notify via Slack (swrite or scli)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${MAIL_WATCHER_CONFIG:-$SCRIPT_DIR/config.env}"

# shellcheck source=/dev/null
source "$CONFIG"

# ── Slack posting helper ──
post_to_slack() {
  # Reads Block Kit JSON from stdin, posts via configured tool.
  # Block Kit payload is extracted to just the blocks array for scli.
  local payload
  payload=$(cat)
  case "${SLACK_TOOL:-swrite}" in
    swrite)
      echo "$payload" | swrite post -c "$SLACK_CHANNEL" -p "$SLACK_PROFILE" --format payload --no-unfurl
      ;;
    scli)
      local ws_flag=""
      [[ -n "${SLACK_WORKSPACE:-}" ]] && ws_flag="-w $SLACK_WORKSPACE"
      # scli --blocks-file expects the blocks array, not the full payload
      local blocks
      blocks=$(echo "$payload" | jq -c '.blocks')
      # shellcheck disable=SC2086
      echo "$blocks" | scli post "$SLACK_CHANNEL" $ws_flag --blocks-file -
      ;;
    *)
      echo "Unknown SLACK_TOOL: $SLACK_TOOL" >&2
      return 1
      ;;
  esac
}

INPUT_FILE="$1"
HASH="$2"
EXT="${INPUT_FILE##*.}"
EXT_LOWER="$(echo "$EXT" | tr '[:upper:]' '[:lower:]')"

# ── Step 1: Convert to JSONL ──
case "$EXT_LOWER" in
  eml) JSONL=$(eml-to-jsonl "$INPUT_FILE") ;;
  msg) JSONL=$(msg-to-jsonl "$INPUT_FILE") ;;
  *)   echo "Unsupported extension: $EXT" >&2; exit 1 ;;
esac

if [[ -z "$JSONL" ]]; then
  echo "Conversion produced empty output" >&2
  exit 1
fi

# ── Step 2: Extract metadata and generate filename ──
# JSONL may contain multiple lines (message + attachments); take the first (message line)
FIRST_LINE=$(echo "$JSONL" | head -1)

DATE_RAW=$(echo "$FIRST_LINE" | jq -r '.date // .Date // ""')
SUBJECT_RAW=$(echo "$FIRST_LINE" | jq -r '.subject // .Subject // "no-subject"')
FROM_RAW=$(echo "$FIRST_LINE" | jq -r '.from // .From // ""')

# Parse date to sortable format
if [[ -n "$DATE_RAW" ]]; then
  # Try parsing with date command (handles RFC 2822)
  PARSED_DATE=$(date -j -f "%a, %d %b %Y %H:%M:%S %z" "$DATE_RAW" "+%Y-%m-%d_%H-%M-%S" 2>/dev/null) ||
  PARSED_DATE=$(date -j -f "%d %b %Y %H:%M:%S %z" "$DATE_RAW" "+%Y-%m-%d_%H-%M-%S" 2>/dev/null) ||
  PARSED_DATE=$(echo "$DATE_RAW" | sed 's/[^0-9T:-]/_/g' | cut -c1-19 | tr 'T:' '_-') ||
  PARSED_DATE="unknown-date"
else
  PARSED_DATE="unknown-date"
fi

# Slugify subject (ASCII-safe, max 80 chars)
SUBJECT_SLUG=$(echo "$SUBJECT_RAW" | \
  sed 's/[Rr][Ee]: *//g; s/[Ff][Ww]: *//g' | \
  tr '[:upper:]' '[:lower:]' | \
  sed 's/[^a-z0-9 ]//g; s/  */ /g; s/ /-/g' | \
  cut -c1-80 | \
  sed 's/-$//')

if [[ -z "$SUBJECT_SLUG" ]]; then
  SUBJECT_SLUG="no-subject"
fi

BASENAME="${PARSED_DATE}_${SUBJECT_SLUG}"
JSONL_PATH="$OUTPUT_DIR/${BASENAME}.jsonl"
META_PATH="$OUTPUT_DIR/${BASENAME}.meta.json"

# Save JSONL
echo "$JSONL" > "$JSONL_PATH"

# ── Step 3: LLM Analysis ──
# System prompt: analysis instructions (sent as system role)
SYSTEM_PROMPT="Analyze the provided email and return JSON with these fields:
- category: one of [security-alert, incident, vulnerability, compliance, threat-intel, newsletter, announcement, discussion, other]
- priority: one of [high, medium, low]
- summary: 2-3 sentence summary of the email content
- tags: array of relevant tags (max 5)
- language: detected language code (e.g. en, ja)"

# User data: email content (sent as user role via stdin)
EMAIL_BODY=$(echo "$FIRST_LINE" | jq -r '.body // .text // ""' | head -500)
USER_DATA="Subject: ${SUBJECT_RAW}
From: ${FROM_RAW}
Date: ${DATE_RAW}

${EMAIL_BODY}"

LLM_OK=true
case "${LLM_TOOL:-gem-cli}" in
  gem-cli)
    ANALYSIS=$(echo "$USER_DATA" | gem-cli \
      -s "$SYSTEM_PROMPT" \
      -f - \
      -m "${GEM_MODEL:-gemini-2.5-flash}" \
      --format json \
      -q 2>/dev/null) || LLM_OK=false
    ;;
  lite-llm)
    LITE_ARGS=""
    [[ -n "${LITE_LLM_ENDPOINT:-}" ]] && LITE_ARGS="$LITE_ARGS --endpoint $LITE_LLM_ENDPOINT"
    [[ -n "${LITE_LLM_MODEL:-}" ]] && LITE_ARGS="$LITE_ARGS -m $LITE_LLM_MODEL"
    # shellcheck disable=SC2086
    ANALYSIS=$(echo "$USER_DATA" | lite-llm \
      -s "$SYSTEM_PROMPT" \
      -f - \
      --format json \
      -q $LITE_ARGS 2>/dev/null) || LLM_OK=false
    ;;
  *)
    echo "Unknown LLM_TOOL: $LLM_TOOL" >&2
    LLM_OK=false
    ;;
esac

if [[ "$LLM_OK" = false ]]; then
  # Save failure metadata
  jq -n \
    --arg file "$(basename "$INPUT_FILE")" \
    --arg hash "$HASH" \
    --arg date "$DATE_RAW" \
    --arg subject "$SUBJECT_RAW" \
    --arg from "$FROM_RAW" \
    --arg error "LLM analysis failed" \
    '{file: $file, hash: $hash, date: $date, subject: $subject, from: $from, error: $error, analyzed: false}' \
    > "$META_PATH"

  # Notify Slack about failure
  "$SCRIPT_DIR/format-slack.sh" --failed \
    --subject "$SUBJECT_RAW" \
    --from "$FROM_RAW" \
    --date "$DATE_RAW" \
    --file "$(basename "$INPUT_FILE")" | \
    post_to_slack

  exit 1
fi

# Save analysis metadata
echo "$ANALYSIS" | jq \
  --arg file "$(basename "$INPUT_FILE")" \
  --arg hash "$HASH" \
  --arg date "$DATE_RAW" \
  --arg subject "$SUBJECT_RAW" \
  --arg from "$FROM_RAW" \
  --arg jsonl_path "$JSONL_PATH" \
  '. + {file: $file, hash: $hash, date: $date, subject: $subject, from: $from, jsonl_path: $jsonl_path, analyzed: true}' \
  > "$META_PATH"

# ── Step 4: Slack notification ──
CATEGORY=$(echo "$ANALYSIS" | jq -r '.category // "other"')
PRIORITY=$(echo "$ANALYSIS" | jq -r '.priority // "low"')
SUMMARY=$(echo "$ANALYSIS" | jq -r '.summary // "No summary available"')
TAGS=$(echo "$ANALYSIS" | jq -r '(.tags // []) | join(", ")')

"$SCRIPT_DIR/format-slack.sh" \
  --category "$CATEGORY" \
  --priority "$PRIORITY" \
  --summary "$SUMMARY" \
  --tags "$TAGS" \
  --subject "$SUBJECT_RAW" \
  --from "$FROM_RAW" \
  --date "$DATE_RAW" | \
  post_to_slack
