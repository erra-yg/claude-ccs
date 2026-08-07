# cc-switch-headless — `claude-ccs`

A headless fork of [cc-switch-cli](https://github.com/saladday/cc-switch-cli) that adds **one environment variable** — `CC_SWITCH_HEADLESS=1` — so the local proxy (Anthropic↔OpenAI translation + failover) keeps serving Claude Code via env vars while **never writing anything under `~/.claude/`**.

It ships a one-command zsh launcher, **`claude-ccs`**, that routes Claude Code through any OpenAI-compatible provider (opencode Go, DeepSeek, OpenRouter, …) without clobbering your `~/.claude/settings.json`.

> Why: stock cc-switch "switches" a provider by overwriting `~/.claude/settings.json` (for Claude it replaces the whole file, wiping your hooks/statusLine/plugins). This fork keeps cc-switch's proxy/routing but makes live-config writes opt-out via `CC_SWITCH_HEADLESS`.

## Install (new machine: WSL/Linux + Claude Code CLI)

```bash
git clone https://github.com/erra-yg/claude-ccs && cd claude-ccs && ./install-claude-ccs.sh
```

`install-claude-ccs.sh` ensures a C toolchain + Rust, builds cc-switch, wires `claude-ccs` into `~/.zshrc` (with the correct `CCS_BIN` path), and creates `~/.config/ccs-providers/`. First build is ~5–10 min. Then:

```bash
source ~/.zshrc        # or open a new terminal
```

👉 **Full usage guide: [headless/USAGE.md](headless/USAGE.md)**

## Quick start

```bash
# 1. create a provider profile (example: opencode Go)
mkdir -p ~/.config/ccs-providers/opencode
echo 'https://opencode.ai/zen/go' > ~/.config/ccs-providers/opencode/base-url   # NO trailing /v1
echo 'deepseek-v4-flash[1m]'          > ~/.config/ccs-providers/opencode/model   # [1m] = 1M context; proxy strips the suffix before upstream
echo 'YOUR_API_KEY'            > ~/.config/ccs-providers/opencode/auth-token # the API key value itself
chmod 600 ~/.config/ccs-providers/opencode/auth-token

# 2. launch Claude Code through the proxy
claude-ccs opencode
```

`claude-ccs` creates the provider (first run), switches to it, starts the headless proxy on `127.0.0.1:15721`, and launches `claude` pointed at it. The proxy runs detached and never touches `~/.claude`.

## Uninstall

```bash
./uninstall-claude-ccs.sh            # stops proxy, unwires ~/.zshrc, secure-erases keys+state, removes repo
./uninstall-claude-ccs.sh --dry-run  # preview; --keep-repo / --keep-profiles / --keep-state to preserve parts
```

Reverses the install + runtime footprint in a safe order; never touches `~/.claude/`, system packages, the Rust toolchain, or `~/.zshrc` outside the marked block.

## What changed vs upstream

Only ~500 lines across 5 source files (live-write guards) + the `headless/` tooling. No upstream feature removed. Upstream docs preserved at [README-upstream.md](README-upstream.md).

- Design + known issues: [headless/README.md](headless/README.md)
- Usage tutorial: [headless/USAGE.md](headless/USAGE.md)
- Decisions/history: see the project journal in the maintainer's workspace.

## Credit

Upstream MIT: [saladday/cc-switch-cli](https://github.com/saladday/cc-switch-cli) (itself a CLI fork of [farion1231/cc-switch](https://github.com/farion1231/cc-switch)). This fork only adds the `CC_SWITCH_HEADLESS` guards and the `claude-ccs` launcher.
