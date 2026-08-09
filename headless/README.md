# cc-switch headless mode

A tiny patch on top of [cc-switch-cli](https://github.com/saladday/cc-switch-cli) (itself a CLI fork of [cc-switch](https://github.com/farion1231/cc-switch)) that adds one environment variable, **`CC_SWITCH_HEADLESS`**, with a single guarantee:

> When `CC_SWITCH_HEADLESS=1`, the process **never writes any file under `~/.claude/`** (nor any other app's live config). The local proxy — Anthropic↔OpenAI translation + failover — still runs and serves Claude Code via environment variables.

This exists for the operator who launches `claude` through per-process env (e.g. a `llm-profile` shell launcher) and does **not** want a GUI app rewriting `~/.claude/settings.json` out from under them.

## Why

Stock cc-switch (GUI or CLI) "switches" a provider by rewriting `~/.claude/settings.json` — and for Claude it **replaces the whole file** with the provider's `env` block, wiping `theme` / `hooks` / `statusLine` / plugins. That clobbers any coexisting launcher. In headless mode the provider selection is kept in cc-switch's SQLite DB only (the proxy's `ProviderRouter` reads the DB, not live files), so a launcher points Claude at the proxy via `ANTHROPIC_BASE_URL` and the live config is never touched.

## Build

```bash
cd src-tauri
cargo build --release      # binary: src-tauri/target/release/cc-switch
```

Requires Rust 1.91+ (`rust-toolchain.toml` pins it; `rustup` auto-installs).

## Run

Two environment variables drive headless operation:

| var | purpose |
|---|---|
| `CC_SWITCH_HEADLESS=1` | disable **all** live-config writes (the patch) |
| `CC_SWITCH_CONFIG_DIR=<dir>` | relocate cc-switch's own state (`cc-switch.db`, settings, skills) — makes the install portable |

Then:

```bash
# 1. configure a provider once (OpenAI-compatible; see script below)
CC_SWITCH_HEADLESS=1 CC_SWITCH_CONFIG_DIR=~/.cc-switch-headless \
  cc-switch provider add --app claude --template custom \
    --name opencode --id opencode \
    --base-url https://opencode.ai/zen/go --api-key "$KEY" --api-key-field api-key \
    --model deepseek-v4-flash[1m] --sonnet-model qwen3.7-max \
    --api-format openai_chat   # [1m] = 1M context; proxy strips the suffix before upstream
# (see "Known issue: apiFormat" below for the one-line normalize)

# 2. start the proxy (headless, no takeover — it will NOT touch ~/.claude)
CC_SWITCH_HEADLESS=1 CC_SWITCH_CONFIG_DIR=~/.cc-switch-headless cc-switch proxy serve
```

Point Claude at the proxy with the launcher you already use. For a `llm-profile`-style launcher, add a profile whose `base-url` is the proxy and whose `auth-token` is any placeholder (the proxy injects the real upstream key; it accepts any inbound token on localhost):

```
~/.config/llm-profile/opencode/
  base-url     -> http://127.0.0.1:15721
  auth-token   -> dummy
  model        -> deepseek-v4-flash[1m]   # [1m] tells Claude Code 1M context; proxy strips it upstream
```

Then `claude-opencode` (or whatever your function is called) routes through the proxy.

Claude Code 2.1.224 and 2.1.226 use the Sonnet role for auto-mode safety
classification. Keep the ordinary request on the default model and configure a
classifier-capable upstream in the Sonnet slot; `claude-ccs.zsh` does this from
the profile's `classifier-model` file and re-applies the mapping on every launch.

## Helpers

- `ccs-proxy-up.sh` — idempotently start the headless proxy if `127.0.0.1:15721` is not already serving.
- `ccs-setup-provider.sh` — add an OpenAI-compatible provider with the correct `openai_chat` format + the snake-case normalize, set it current, and queue it for failover.

## Failover

Auto-failover is the **unmodified** upstream feature (circuit breaker + queue). Enabling it (`cc-switch failover enable`) is interactive (it confirms on a TTY), so run it in a real terminal or the TUI — not from a non-interactive script. Headless mode does not alter failover behaviour; it only gates live-config writes.

## Known issue: `apiFormat` camel/snake mismatch (upstream)

`cc-switch provider add --api-format openai_chat` stores the format as **camelCase `apiFormat`** in the provider `meta`, but the running proxy translates only when meta has **snake_case `api_format` AND NOT camelCase `apiFormat`**. A/B on one running proxy:

| meta state | result |
|---|---|
| camelCase `apiFormat` only | 401 (Anthropic-native, no translation) |
| snake `api_format` + camel `apiFormat` | 401 |
| **snake `api_format` only** | **200 (translates)** |

Worse, `cc-switch provider switch` **re-serializes `meta`** and drops the snake key (re-emitting camelCase). So the snake key must be written **after** any `provider switch`, every time.

Both helpers handle this: they `add` → `switch` → then a final `sqlite3` step that does `json_set(json_remove(meta,'$.apiFormat'),'$.api_format','openai_chat')` (snake-only), as the last write. `claude-ccs` re-applies it on every invocation (since the leading `provider switch` re-serializes). Fixing it properly means changing `ProviderMeta.api_format` serde + the re-serialize path, which ripples through 40+ test assertions and TUI code — out of scope for this minimal patch.

## Portability

Everything cc-switch needs lives under `$CC_SWITCH_CONFIG_DIR` (DB + settings + skills). To move machines: install the binary, copy that directory, set the two env vars, `provider add` your keys. The Rust toolchain is the only build prerequisite.

## Credit / license

Upstream is MIT (SaladDay/cc-switch-cli, farion1231/cc-switch). This fork only adds the `CC_SWITCH_HEADLESS` guards in `src/sync_policy.rs`, `src/services/provider/mod.rs`, `src/services/proxy.rs`, `src/database/dao/settings.rs`, and `src/claude_plugin.rs`, plus these `headless/` docs/scripts.
