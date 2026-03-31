#!/usr/bin/env bash
# format-slack.sh — Generate Slack Block Kit payload for mail notifications.
#
# Usage:
#   format-slack.sh --category X --priority X --summary X --tags X --subject X --from X --date X
#   format-slack.sh --failed --subject X --from X --date X --file X

set -euo pipefail

# Parse args
FAILED=false
CATEGORY="" PRIORITY="" SUMMARY="" TAGS="" SUBJECT="" FROM="" DATE="" FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --failed)    FAILED=true; shift ;;
    --category)  CATEGORY="$2"; shift 2 ;;
    --priority)  PRIORITY="$2"; shift 2 ;;
    --summary)   SUMMARY="$2"; shift 2 ;;
    --tags)      TAGS="$2"; shift 2 ;;
    --subject)   SUBJECT="$2"; shift 2 ;;
    --from)      FROM="$2"; shift 2 ;;
    --date)      DATE="$2"; shift 2 ;;
    --file)      FILE="$2"; shift 2 ;;
    *)           shift ;;
  esac
done

# ── Category emoji mapping ──
category_emoji() {
  case "$1" in
    security-alert)  echo ":rotating_light:" ;;
    incident)        echo ":fire:" ;;
    vulnerability)   echo ":warning:" ;;
    compliance)      echo ":shield:" ;;
    threat-intel)    echo ":mag:" ;;
    newsletter)      echo ":newspaper:" ;;
    announcement)    echo ":loudspeaker:" ;;
    discussion)      echo ":speech_balloon:" ;;
    *)               echo ":email:" ;;
  esac
}

# ── Priority emoji mapping ──
priority_emoji() {
  case "$1" in
    high)   echo ":red_circle:" ;;
    medium) echo ":large_orange_circle:" ;;
    low)    echo ":white_circle:" ;;
    *)      echo ":white_circle:" ;;
  esac
}

if [[ "$FAILED" = true ]]; then
  # ── Failure notification ──
  jq -n \
    --arg subject "$SUBJECT" \
    --arg from "$FROM" \
    --arg date "$DATE" \
    --arg file "$FILE" \
    '{
      "blocks": [
        {
          "type": "header",
          "text": {"type": "plain_text", "text": ":x: Mail Analysis Failed"}
        },
        {
          "type": "section",
          "fields": [
            {"type": "mrkdwn", "text": ("*Subject:*\n" + $subject)},
            {"type": "mrkdwn", "text": ("*From:*\n" + $from)}
          ]
        },
        {
          "type": "section",
          "fields": [
            {"type": "mrkdwn", "text": ("*Date:*\n" + $date)},
            {"type": "mrkdwn", "text": ("*File:*\n`" + $file + "`")}
          ]
        },
        {
          "type": "context",
          "elements": [
            {"type": "mrkdwn", "text": ":warning: LLM analysis failed (possible context overflow). Mail data was converted but not analyzed."}
          ]
        }
      ]
    }'
else
  # ── Success notification ──
  CAT_EMOJI=$(category_emoji "$CATEGORY")
  PRI_EMOJI=$(priority_emoji "$PRIORITY")
  CAT_UPPER=$(echo "$CATEGORY" | tr '[:lower:]' '[:upper:]' | tr '-' ' ')

  jq -n \
    --arg subject "$SUBJECT" \
    --arg from "$FROM" \
    --arg date "$DATE" \
    --arg summary "$SUMMARY" \
    --arg tags "$TAGS" \
    --arg cat_emoji "$CAT_EMOJI" \
    --arg cat_upper "$CAT_UPPER" \
    --arg pri_emoji "$PRI_EMOJI" \
    --arg priority "$PRIORITY" \
    '{
      "blocks": [
        {
          "type": "header",
          "text": {"type": "plain_text", "text": ($cat_emoji + " " + $subject)}
        },
        {
          "type": "section",
          "fields": [
            {"type": "mrkdwn", "text": ("*Category:*\n" + $cat_emoji + " " + $cat_upper)},
            {"type": "mrkdwn", "text": ("*Priority:*\n" + $pri_emoji + " " + ($priority | ascii_upcase))}
          ]
        },
        {
          "type": "section",
          "fields": [
            {"type": "mrkdwn", "text": ("*From:*\n" + $from)},
            {"type": "mrkdwn", "text": ("*Date:*\n" + $date)}
          ]
        },
        {
          "type": "section",
          "text": {"type": "mrkdwn", "text": ("*Summary:*\n" + $summary)}
        },
        {
          "type": "context",
          "elements": [
            {"type": "mrkdwn", "text": (":label: " + $tags)}
          ]
        }
      ]
    }'
fi
