# claude-ccs.zsh — the `claude-ccs` zsh function (canonical copy; the live one
# is inlined in ~/.zshrc). Launch Claude Code through the HEADLESS cc-switch proxy
# at 127.0.0.1:15721 (Anthropic<->OpenAI translation + failover), with
# CC_SWITCH_HEADLESS guaranteeing ~/.claude is never rewritten.
#
# Provider profiles live in ~/.config/ccs-providers/<name>/ :
#   base-url    OpenAI-compatible endpoint WITHOUT trailing /v1   (required)
#   auth-token  API key value                                     (required, or keyfile)
#   keyfile     path to a file holding the API key                (alt to auth-token)
#   model       model id                                          (optional)
#
# Usage:   claude-ccs <name> [claude args...]
# Example: claude-ccs opencode
# First run for <name> creates the provider in cc-switch; later runs just switch + launch.
claude-ccs() {
    emulate -L zsh
    local name="${1:-}"
    local profdir="$HOME/.config/ccs-providers"

    if [ -z "$name" ]; then
        print -P "%F{cyan}ccs providers:%f"
        local d
        for d in "$profdir"/*/; do
            [ -d "$d" ] && print -- "  ${d:t}"
        done 2>/dev/null
        print -u2 "usage: claude-ccs <name> [claude args...]"
        return 2
    fi
    shift

    local prof="$profdir/$name"
    [ -d "$prof" ] || { print -u2 "claude-ccs: no provider profile at $prof"; return 2; }

    local base_url="" model="" key=""
    base_url=$(<"$prof/base-url" 2>/dev/null)
    [ -r "$prof/model" ] && model=$(<"$prof/model")
    if   [ -r "$prof/auth-token" ]; then key=$(<"$prof/auth-token")
    elif [ -r "$prof/keyfile" ];   then local kf; kf=$(<"$prof/keyfile"); [ -r "$kf" ] && key=$(<"$kf"); fi
    [ -n "$base_url" ] && [ -n "$key" ] || { print -u2 "claude-ccs: $prof needs base-url + (auth-token | keyfile)"; return 2; }

    # cc-switch binary + isolated, portable headless state
    local CCS_BIN="${CCS_BIN:-$HOME/claude-wksp/cc-switch-headless/src-tauri/target/release/cc-switch}"
    local CCS_HOME="${CCS_HOME:-$HOME/.cc-switch-headless}"
    [ -x "$CCS_BIN" ] || { print -u2 "claude-ccs: cc-switch binary not found at $CCS_BIN (set \$CCS_BIN)"; return 2; }
    command -v sqlite3 >/dev/null || { print -u2 "claude-ccs: sqlite3 required"; return 2; }
    export CC_SWITCH_HEADLESS=1 CC_SWITCH_CONFIG_DIR="$CCS_HOME"
    mkdir -p "$CCS_HOME"
    local db="$CCS_HOME/cc-switch.db"

    # Create the provider if it doesn't exist yet (openai_chat format), then switch to it.
    # Work around upstream's apiFormat(camel)/api_format(snake) mismatch so the proxy translates.
    if ! "$CCS_BIN" provider switch "$name" >/dev/null 2>&1; then
        local m=(); [ -n "$model" ] && m=(--model "$model")
        "$CCS_BIN" provider add --app claude --template custom \
            --name "$name" --id "$name" \
            --base-url "$base_url" --api-key "$key" --api-key-field api-key \
            --api-format openai_chat "${m[@]}" >/dev/null 2>&1 || true
        "$CCS_BIN" provider switch "$name" >/dev/null 2>&1
    fi
    # `provider switch` re-serializes meta and drops the snake_case `api_format`
    # the proxy actually reads (upstream stores camelCase `apiFormat`), so re-add
    # the snake key as the LAST write — after every switch, on every call.
    local _norm="UPDATE providers SET meta = json_set(json_remove(meta,'\$.apiFormat'),'\$.api_format','openai_chat') WHERE id='$name' AND app_type='claude';"
    sqlite3 "$db" "$_norm" 2>/dev/null

    # Ensure the headless proxy is listening on 15721.
    if ! ss -tln 2>/dev/null | grep -q ':15721'; then
        setsid "$CCS_BIN" proxy serve >>"$CCS_HOME/proxy.log" 2>&1 </dev/null & disown
        local i
        for ((i = 0; i < 60; i++)); do
            ss -tln 2>/dev/null | grep -q ':15721' && break
            sleep 0.5
        done
    fi
    ss -tln 2>/dev/null | grep -q ':15721' || { print -u2 "claude-ccs: proxy did not come up on 15721 (see $CCS_HOME/proxy.log)"; return 1; }

    # Launch Claude through the proxy. The proxy injects the real upstream key;
    # it accepts any inbound token on localhost, so a placeholder is fine.
    # Run in a subshell so model env vars + _claude_clean_env's unsets never leak
    # into the interactive shell.
    (
        _claude_clean_env 2>/dev/null
        # Export the proxy's model id so Claude Code recognizes + restores it instead
        # of falling back to claude-opus-5 ("Session model <id> could not be restored").
        if [ -n "$model" ]; then
            export ANTHROPIC_MODEL="$model"
            export ANTHROPIC_DEFAULT_OPUS_MODEL="$model"
            export ANTHROPIC_DEFAULT_SONNET_MODEL="$model"
            export ANTHROPIC_DEFAULT_HAIKU_MODEL="$model"
        fi
        # Don't let CC assume a 200k ceiling for an unrecognized model id; let the
        # upstream API decide context size (silences the "unknown model window" notice).
        ANTHROPIC_BASE_URL="http://127.0.0.1:15721" \
        ANTHROPIC_AUTH_TOKEN="ccs-proxy" \
        CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT=1 \
        command claude "$@"
    )
}
