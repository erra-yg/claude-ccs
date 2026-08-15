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

# Egress policy (operator decision 2026-08-15, same as claude-ccs.zsh):
# DIRECT first; fall back to the local proxy ladder only after repeated direct
# failures. Every probe is a REAL HTTPS round trip to CCS_PROBE_URL — a bare TCP
# connect passes even when Clash's selected node is dead (2026-08-15 incident:
# hand-picked timeout node; proxy had 7897 baked in and every forward 502'd
# while opencode.ai was fine direct). Shell proxy vars are stripped so they
# cannot silently defeat direct-first.
# Override: CCS_OUTBOUND_PROXY=none (force direct) | <url> (force that proxy).
CCS_PROBE_URL="${CCS_PROBE_URL:-https://opencode.ai/}"
px=""
if [ "${CCS_OUTBOUND_PROXY:-}" = "none" ]; then
  :
elif [ -n "${CCS_OUTBOUND_PROXY:-}" ]; then
  px="$CCS_OUTBOUND_PROXY"
else
  code=$(curl --noproxy '*' -m 5 -s -o /dev/null -w '%{http_code}' "$CCS_PROBE_URL" 2>/dev/null || true)
  if [ -z "$code" ] || [ "$code" = "000" ]; then
    sleep 1   # direct tried twice before falling back to a proxy
    code=$(curl --noproxy '*' -m 5 -s -o /dev/null -w '%{http_code}' "$CCS_PROBE_URL" 2>/dev/null || true)
  fi
  if [ -z "$code" ] || [ "$code" = "000" ]; then
    for p in 7897 7890 7891 10809 1080; do
      code=$(curl -x "http://127.0.0.1:$p" -m 6 -s -o /dev/null -w '%{http_code}' "$CCS_PROBE_URL" 2>/dev/null || true)
      if [ -n "$code" ] && [ "$code" != "000" ]; then px="http://127.0.0.1:$p"; break; fi
    done
    [ -n "$px" ] || echo "ccs-proxy-up: egress probes failed direct AND proxied for $CCS_PROBE_URL; starting direct anyway" >&2
  fi
fi

# Detach from the shell so it survives terminal exit (mirrors how the GUI ccs is launched here).
if [ -n "$px" ]; then
  setsid env "HTTPS_PROXY=$px" "HTTP_PROXY=$px" "https_proxy=$px" "http_proxy=$px" \
    "NO_PROXY=127.0.0.1,localhost,::1" "no_proxy=127.0.0.1,localhost,::1" \
    "$CCS_BIN" proxy serve >>"$LOG" 2>&1 < /dev/null &
else
  setsid env -u HTTPS_PROXY -u HTTP_PROXY -u https_proxy -u http_proxy \
    "$CCS_BIN" proxy serve >>"$LOG" 2>&1 < /dev/null &
fi
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
