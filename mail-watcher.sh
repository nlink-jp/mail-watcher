#!/usr/bin/env bash
# mail-watcher — Poll a directory for new eml/msg files, convert, analyze, and notify.
#
# Usage:
#   ./mail-watcher.sh [config.env]
#
# Idempotent: tracks processed files by SHA-256 hash. Safe to stop and restart
# at any time — backlog is automatically processed on next cycle.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${1:-$SCRIPT_DIR/config.env}"

if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: Config file not found: $CONFIG" >&2
  echo "Copy config.env.template to config.env and edit values." >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG"

# ── Defaults ──
WATCH_DIR="${WATCH_DIR:?WATCH_DIR is required}"
OUTPUT_DIR="${OUTPUT_DIR:?OUTPUT_DIR is required}"
POLL_INTERVAL="${POLL_INTERVAL:-60}"
LLM_TOOL="${LLM_TOOL:-gem-cli}"
SLACK_CHANNEL="${SLACK_CHANNEL:-#mail-digest}"
SLACK_PROFILE="${SLACK_PROFILE:-default}"
GEM_MODEL="${GEM_MODEL:-gemini-2.5-flash}"

STATE_DIR="$SCRIPT_DIR/state"
PROCESSED_FILE="$STATE_DIR/processed.txt"
FAILED_FILE="$STATE_DIR/failed.txt"

mkdir -p "$OUTPUT_DIR" "$STATE_DIR"
touch "$PROCESSED_FILE" "$FAILED_FILE"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }

# ── Hash-based dedup ──
file_hash() { shasum -a 256 "$1" | cut -d' ' -f1; }

is_processed() {
  local hash="$1"
  grep -qF "$hash" "$PROCESSED_FILE" 2>/dev/null
}

is_failed() {
  local hash="$1"
  grep -qF "$hash" "$FAILED_FILE" 2>/dev/null
}

mark_processed() {
  local hash="$1" file="$2"
  echo "$hash  $file" >> "$PROCESSED_FILE"
}

mark_failed() {
  local hash="$1" file="$2" reason="$3"
  echo "$hash  $file  $reason" >> "$FAILED_FILE"
}

# ── Main loop ──
log "mail-watcher started"
log "  WATCH_DIR:     $WATCH_DIR"
log "  OUTPUT_DIR:    $OUTPUT_DIR"
log "  POLL_INTERVAL: ${POLL_INTERVAL}s"
log "  LLM_TOOL:      $LLM_TOOL"
log "  SLACK_CHANNEL: $SLACK_CHANNEL"

while true; do
  # Find all eml/msg files (case insensitive)
  while IFS= read -r -d '' file; do
    hash=$(file_hash "$file")

    # Skip already processed or failed
    if is_processed "$hash" || is_failed "$hash"; then
      continue
    fi

    log "Processing: $(basename "$file") [$hash]"

    if "$SCRIPT_DIR/process-one.sh" "$file" "$hash"; then
      mark_processed "$hash" "$file"
      log "  Done: $(basename "$file")"
    else
      reason="process-one failed (exit $?)"
      mark_failed "$hash" "$file" "$reason"
      log "  FAILED: $(basename "$file") — $reason"
    fi

  done < <(find "$WATCH_DIR" -maxdepth 2 \( -iname '*.eml' -o -iname '*.msg' \) -print0 2>/dev/null | xargs -0 stat -f '%m%t%N' 2>/dev/null | sort -n | cut -f2- | tr '\n' '\0')

  sleep "$POLL_INTERVAL"
done
