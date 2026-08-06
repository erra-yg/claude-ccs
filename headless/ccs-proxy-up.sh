#!/usr/bin/env bash
# ccs-proxy-up.sh — idempotently start the HEADLESS cc-switch proxy.
#
# Starts cc-switch's local proxy on 127.0.0.1:15721 ONLY if nothing is already
# listening there. The proxy runs with CC_SWITCH_HEADLESS=1, so it serves
# (Anthropic<->OpenAI translation + failover) but NEVER writes ~/.claude.
#
# Env:
#   CCS_BIN    cc-switch binary (default: cc-switch on PATH)
#   CCS_HOME   CC_SWITCH_CONFIG_DIR (default: ~/.cc-switch-headless)
#   CCS_PORT   listen port (default: 15721)
set -euo pipefail

CCS_BIN="${CCS_BIN:-cc-switch}"
CCS_HOME="${CCS_HOME:-$HOME/.cc-switch-headless}"
CCS_PORT="${CCS_PORT:-15721}"

export CC_SWITCH_HEADLESS=1
export CC_SWITCH_CONFIG_DIR="$CCS_HOME"

listening() { ss -tln 2>/dev/null | grep -q ":$CCS_PORT"; }

if listened_check=$(ss -tln 2>/dev/null | grep ":$CCS_PORT"); then
  echo "cc-switch proxy already listening on 127.0.0.1:$CCS_PORT"
  exit 0
fi

mkdir -p "$CCS_HOME"
LOG="$CCS_HOME/proxy.log"
# Detach from the shell so it survives terminal exit (mirrors how the GUI ccs is launched here).
setsid "$CCS_BIN" proxy serve >"$LOG" 2>&1 < /dev/null &
disown 2>/dev/null || true

for _ in $(seq 1 60); do
  if listened_check=$(ss -tln 2>/dev/null | grep ":$CCS_PORT"); then
    echo "cc-switch proxy up on 127.0.0.1:$CCS_PORT (headless; log: $LOG)"
    exit 0
  fi
  sleep 0.5
done

echo "ERROR: proxy did not come up on :$CCS_PORT within 30s; see $LOG" >&2
exit 1
