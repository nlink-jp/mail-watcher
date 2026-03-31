# mail-watcher

軽量メール監視ワークフロー — OneDrive/Google Drive で同期されるディレクトリの eml/msg ファイルを検知し、構造化データに変換、LLM で分析、Slack に通知します。

[English README is here](README.md)

## 仕組み

```
OneDrive/Google Drive 同期
  → eml/msg ファイルが WATCH_DIR に出現
  → mail-watcher がポーリングで検知
  → eml-to-jsonl / msg-to-jsonl で構造化 JSONL に変換
  → gem-cli / lite-llm で分類・要約
  → swrite で Block Kit 通知を Slack に投稿
```

べき等: SHA-256 ハッシュで処理済みファイルを追跡。停止・再起動しても未処理分を自動で処理。ファイルは古い順に処理される。

## クイックスタート

```bash
# 1. 設定ファイルをコピー
cp config.env.template config.env
# config.env を編集（パス、Slack チャンネル等）

# 2. 起動
./mail-watcher.sh
```

## 前提ツール

以下の CLI ツールが `$PATH` に必要:

| ツール | 用途 |
|--------|------|
| [eml-to-jsonl](https://github.com/nlink-jp/eml-to-jsonl) | .eml → JSONL 変換 |
| [msg-to-jsonl](https://github.com/nlink-jp/msg-to-jsonl) | .msg → JSONL 変換 |
| [gem-cli](https://github.com/nlink-jp/gem-cli) or [lite-llm](https://github.com/nlink-jp/lite-llm) | LLM 分析 |
| [swrite](https://github.com/nlink-jp/swrite) or [scli](https://github.com/nlink-jp/scli) | Slack 通知 |
| `jq` | JSON 処理 |

## 設定

| 変数 | 説明 | デフォルト |
|------|------|-----------|
| `WATCH_DIR` | eml/msg ファイルの監視ディレクトリ | (必須) |
| `OUTPUT_DIR` | 変換済み JSONL・メタデータの保存先 | (必須) |
| `POLL_INTERVAL` | スキャン間隔（秒） | `60` |
| `LLM_TOOL` | `gem-cli` または `lite-llm` | `gem-cli` |
| `GEM_MODEL` | Gemini モデル名 | `gemini-2.5-flash` |
| `SUMMARY_LANG` | 要約の言語（例: `ja`, `en`; 空欄 = 自動検出） | (空欄) |
| `SLACK_TOOL` | `swrite`（bot）または `scli`（ユーザートークン） | `swrite` |
| `SLACK_CHANNEL` | 通知先 Slack チャンネル | `#mail-digest` |
| `SLACK_PROFILE` | swrite プロファイル名（swrite のみ） | `default` |
| `SLACK_WORKSPACE` | scli ワークスペース名（scli のみ） | (空欄) |

## 出力

処理されたメールごとに2ファイルを保存:

```
data/
  2026-03-31_14-30-00_alert-unusual-login-detected.jsonl      # 構造化メールデータ
  2026-03-31_14-30-00_alert-unusual-login-detected.meta.json   # 分析メタデータ
```

## エラーハンドリング

- **変換失敗**: failed としてマーク、以降スキップ
- **LLM 失敗**（コンテキストオーバーフロー等）: JSONL は保存、失敗メタデータを記録、Slack に分析失敗を通知
- **Slack 失敗**: パイプラインをブロックしない — ファイルは処理済みとしてマーク
