#!/usr/bin/env bash
# install-claude-ccs.sh — install the `claude-ccs` headless proxy launcher.
#
# Run from the repo root after `git clone`. Idempotent; safe to re-run.
#   git clone https://github.com/erra-yg/claude-ccs && cd claude-ccs && ./install-claude-ccs.sh
#
# What it does:
#   1. ensure a C toolchain (build-essential) and Rust (rustup) are present
#   2. build cc-switch (release) -> src-tauri/target/release/cc-switch
#   3. wire `claude-ccs` into ~/.zshrc (CCS_BIN / CCS_HOME + source), idempotently
#   4. create ~/.config/ccs-providers/ (where provider profiles live)
#
# Then you create one provider profile and run `claude-ccs <name>` (see headless/USAGE.md).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$REPO_DIR/src-tauri/target/release/cc-switch"
ZSHRC="${ZDOTDIR:-$HOME}/.zshrc"
PROFILES_DIR="${CCS_PROFILES_DIR:-$HOME/.config/ccs-providers}"

say() { printf '[claude-ccs] %s\n' "$*"; }
die() { printf '[claude-ccs error] %s\n' "$*" >&2; exit 1; }

# --- 1. C toolchain (cc-switch: rusqlite bundled + reqwest rustls -> needs cc + make, no system sqlite/openssl) ---
if ! command -v cc >/dev/null 2>&1 || ! command -v make >/dev/null 2>&1; then
    say "C toolchain missing; installing build-essential (will prompt for sudo)..."
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update -y
        sudo apt-get install -y build-essential pkg-config curl
    else
        die "cc/make missing and apt-get not found. Install a C compiler + make + curl manually, then re-run."
    fi
fi

# --- 2. Rust ---
if [ -f "$HOME/.cargo/env" ]; then . "$HOME/.cargo/env"; fi
if ! command -v cargo >/dev/null 2>&1; then
    say "Rust not found; installing rustup (non-interactive)..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile default --default-toolchain stable
    # shellcheck disable=SC1091
    . "$HOME/.cargo/env"
fi
command -v cargo >/dev/null 2>&1 || die "cargo still unavailable after rustup install"
# Cargo.toml sets rust-version (MSRV); we build with the user's installed Rust.
# No rust-toolchain.toml channel pin -> no forced old-toolchain download (which
# fails in restricted networks); cargo errors only if the installed Rust < MSRV.

# --- 2b. outbound proxy for the build (crates.io / rustup fetches) ---
# In WSL/VPN setups direct HTTPS is often blackholed; if a local HTTP proxy
# (Clash/V2Ray/mihomo) is reachable, export it so cargo/rustup can fetch.
# Override: HTTPS_PROXY already set -> honored as-is; CCS_OUTBOUND_PROXY=none -> skip.
if [ "${CCS_OUTBOUND_PROXY:-}" != "none" ] && [ -z "${HTTPS_PROXY:-}${https_proxy:-}" ]; then
    for _p in 7897 7890 7891 10809 1080; do
        if timeout 0.3 bash -c "</dev/tcp/127.0.0.1/$_p" 2>/dev/null; then
            export HTTPS_PROXY="http://127.0.0.1:$_p" https_proxy="$HTTPS_PROXY"
            export HTTP_PROXY="$HTTPS_PROXY" http_proxy="$HTTPS_PROXY"
            export NO_PROXY="127.0.0.1,localhost,::1" no_proxy="$NO_PROXY"
            say "detected local outbound proxy 127.0.0.1:$_p for build (set CCS_OUTBOUND_PROXY=none to disable)"
            break
        fi
    done
fi

# --- 3. build ---
say "building cc-switch (release). First build downloads + compiles many crates (~5-10 min)..."
( cd "$REPO_DIR/src-tauri" && cargo build --release )
[ -x "$BIN" ] || die "build finished but binary not found at $BIN"
say "built: $BIN"

# --- 4. wire claude-ccs into ~/.zshrc (idempotent marked block) ---
mkdir -p "$(dirname "$ZSHRC")"
touch "$ZSHRC"
START='# >>> claude-ccs (headless) >>>'
END='# <<< claude-ccs (headless) <<<'
if grep -qxF "$START" "$ZSHRC"; then
    sed -i.bak "/^${START}\$/,/^${END}\$/d" "$ZSHRC" || true   # replace existing block
fi
{
    printf '\n%s\n' "$START"
    printf 'export CCS_BIN="%s"\n' "$BIN"
    printf 'export CCS_HOME="$HOME/.cc-switch-headless"\n'
    printf '[ -f "%s/headless/claude-ccs.zsh" ] && source "%s/headless/claude-ccs.zsh"\n' "$REPO_DIR" "$REPO_DIR"
    printf '%s\n' "$END"
} >>"$ZSHRC"
say "wired claude-ccs into $ZSHRC"

# --- 5. provider profiles dir ---
mkdir -p "$PROFILES_DIR"
say "provider profiles dir: $PROFILES_DIR"

# --- 6. next steps ---
cat <<EOF

Done. Next:

  1. Reload the shell:
       source ~/.zshrc        # or open a new terminal

  2. Create a provider profile (example: opencode Go). Put each value in its own file:
       mkdir -p ~/.config/ccs-providers/opencode
       echo 'https://opencode.ai/zen/go' > ~/.config/ccs-providers/opencode/base-url
       echo 'deepseek-v4-flash[1m]'          > ~/.config/ccs-providers/opencode/model
       echo 'YOUR_API_KEY'            > ~/.config/ccs-providers/opencode/auth-token
       chmod 600 ~/.config/ccs-providers/opencode/auth-token
     # auth-token = your API key value (chmod 600). base-url must NOT end in /v1.
     # Full reference: headless/USAGE.md

  3. Launch Claude Code through the proxy:
       claude-ccs opencode

The proxy runs detached (survives terminal close) and NEVER writes ~/.claude.
Logs: ~/.cc-switch-headless/proxy.log

Uninstall (fully reverses everything above): ./uninstall-claude-ccs.sh
EOF
