#!/usr/bin/env bash
# ccs-setup-provider.sh — add an OpenAI-compatible provider under HEADLESS cc-switch,
# work around the upstream apiFormat(apiFormat camel vs api_format snake) mismatch so
# the proxy actually translates, set it current, and queue it for failover.
#
# The API key is read from a file (never echoed / never stored in the repo).
#
# Usage:
#   ccs-setup-provider.sh --name opencode-go \
#                         --base-url https://opencode.ai/zen/go \
#                         --keyfile ~/.config/claude-profiles/opencode/auth-token \
#                         --model deepseek-v4-flash
#
# Env:
#   CCS_BIN    cc-switch binary (default: cc-switch on PATH)
#   CCS_HOME   CC_SWITCH_CONFIG_DIR (default: ~/.cc-switch-headless)
#
# NOTE on base-url: pass it WITHOUT a trailing /v1. The proxy appends /v1/chat/completions.
#   e.g. opencode Go's endpoint https://opencode.ai/zen/go/v1/chat/completions
#        -> --base-url https://opencode.ai/zen/go
set -euo pipefail

CCS_BIN="${CCS_BIN:-cc-switch}"
CCS_HOME="${CCS_HOME:-$HOME/.cc-switch-headless}"
export CC_SWITCH_HEADLESS=1
export CC_SWITCH_CONFIG_DIR="$CCS_HOME"

NAME=""
BASE_URL=""
KEYFILE=""
MODEL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --name)     NAME="$2"; shift 2 ;;
    --base-url) BASE_URL="$2"; shift 2 ;;
    --keyfile)  KEYFILE="$2"; shift 2 ;;
    --model)    MODEL="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -n "$NAME" ] && [ -n "$BASE_URL" ] && [ -n "$KEYFILE" ] || { echo "usage: $0 --name <id> --base-url <url> --keyfile <path> [--model <m>]" >&2; exit 2; }
[ -r "$KEYFILE" ] || { echo "keyfile not readable: $KEYFILE" >&2; exit 2; }

mkdir -p "$CCS_HOME"
DB="$CCS_HOME/cc-switch.db"

# Read key without echoing; $() trims the trailing newline.
KEY="$(cat "$KEYFILE")"

MODEL_ARG=()
[ -n "$MODEL" ] && MODEL_ARG=(--model "$MODEL")

# Add with openai_chat so the proxy translates Anthropic<->OpenAI. --api-key-field api-key
# stores ANTHROPIC_API_KEY; the proxy forwards it as Authorization: Bearer to the upstream.
"$CCS_BIN" provider add --app claude --template custom \
  --name "$NAME" --id "$NAME" \
  --base-url "$BASE_URL" --api-key "$KEY" --api-key-field api-key \
  --api-format openai_chat "${MODEL_ARG[@]}" >/dev/null

"$CCS_BIN" provider switch "$NAME" >/dev/null
"$CCS_BIN" failover add "$NAME" >/dev/null || echo "note: failover add skipped (already queued?)" >&2

# Normalize meta LAST (provider switch re-serializes meta and would undo this).
# The proxy translates only when meta has snake_case `api_format` and NOT camelCase
# `apiFormat` (A/B: snake-only -> 200, snake+camel -> 401, camel-only -> 401).
sqlite3 "$DB" "UPDATE providers SET meta = json_set(json_remove(meta, '\$.apiFormat'), '\$.api_format', 'openai_chat') WHERE id = '$NAME' AND app_type='claude';" \
  || echo "warn: could not normalize meta (sqlite3 missing?); translation will not engage — see headless/README.md" >&2

echo "provider '$NAME' ready: openai_chat, current, queued for failover."
echo "  db: $DB"
echo "Next: enable auto-failover INTERACTIVELY (TTY) — 'CC_SWITCH_HEADLESS=1 CC_SWITCH_CONFIG_DIR=$CCS_HOME cc-switch failover enable' — or via the TUI."
echo "Then point Claude at the proxy: ANTHROPIC_BASE_URL=http://127.0.0.1:15721 (any dummy token)."
