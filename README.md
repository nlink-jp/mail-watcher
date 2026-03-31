# mail-watcher

Lightweight mail monitoring workflow — watches a directory for incoming eml/msg files (synced via OneDrive/Google Drive), converts them to structured data, analyzes with LLM, and posts Slack notifications.

[日本語版 README はこちら](README.ja.md)

## How It Works

```
OneDrive/Google Drive sync
  → eml/msg files appear in WATCH_DIR
  → mail-watcher detects new files (polling)
  → eml-to-jsonl / msg-to-jsonl converts to structured JSONL
  → gem-cli / lite-llm classifies and summarizes
  → swrite posts Block Kit notification to Slack
```

Idempotent: tracks processed files by SHA-256 hash. Safe to stop and restart — backlog is processed automatically. Files are processed in oldest-first order.

## Quick Start

```bash
# 1. Copy config
cp config.env.template config.env
# Edit config.env with your paths, Slack channel, etc.

# 2. Run
./mail-watcher.sh
```

## Prerequisites

The following CLI tools must be in `$PATH`:

| Tool | Purpose |
|------|---------|
| [eml-to-jsonl](https://github.com/nlink-jp/eml-to-jsonl) | Convert .eml files to JSONL |
| [msg-to-jsonl](https://github.com/nlink-jp/msg-to-jsonl) | Convert .msg files to JSONL |
| [gem-cli](https://github.com/nlink-jp/gem-cli) or [lite-llm](https://github.com/nlink-jp/lite-llm) | LLM analysis |
| [swrite](https://github.com/nlink-jp/swrite) or [scli](https://github.com/nlink-jp/scli) | Slack notification |
| `jq` | JSON processing |

## Configuration

| Variable | Description | Default |
|----------|-------------|---------|
| `WATCH_DIR` | Directory to monitor for eml/msg files | (required) |
| `OUTPUT_DIR` | Directory for converted JSONL and metadata | (required) |
| `POLL_INTERVAL` | Seconds between scans | `60` |
| `LLM_TOOL` | `gem-cli` or `lite-llm` | `gem-cli` |
| `GEM_MODEL` | Gemini model name | `gemini-2.5-flash` |
| `SUMMARY_LANG` | Summary language (e.g. `ja`, `en`; empty = auto-detect) | (empty) |
| `SLACK_TOOL` | `swrite` (bot) or `scli` (user token) | `swrite` |
| `SLACK_CHANNEL` | Slack channel for notifications | `#mail-digest` |
| `SLACK_PROFILE` | swrite profile name (swrite only) | `default` |
| `SLACK_WORKSPACE` | scli workspace name (scli only) | (empty) |

## Output

For each processed email, two files are saved:

```
data/
  2026-03-31_14-30-00_alert-unusual-login-detected.jsonl      # Structured mail data
  2026-03-31_14-30-00_alert-unusual-login-detected.meta.json   # Analysis metadata
```

The `.meta.json` contains:

```json
{
  "category": "security-alert",
  "priority": "high",
  "summary": "Alert about unusual login activity from...",
  "tags": ["login", "alert", "authentication"],
  "language": "en",
  "file": "original-filename.eml",
  "hash": "sha256...",
  "analyzed": true
}
```

## Failure Handling

- **Conversion failure**: File is marked as failed, skipped on subsequent runs
- **LLM failure** (e.g. context overflow): Converted JSONL is saved, failure metadata is written, Slack notification indicates analysis failed
- **Slack failure**: Does not block the pipeline — file is still marked as processed

## File Structure

```
mail-watcher/
  mail-watcher.sh      # Main polling loop
  process-one.sh       # Single-file processing pipeline
  format-slack.sh      # Block Kit payload generator
  config.env.template  # Configuration template
  config.env           # Local configuration (not committed)
  state/
    processed.txt      # Processed file hashes
    failed.txt         # Failed file hashes with reasons
```
