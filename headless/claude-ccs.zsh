# claude-ccs.zsh — the `claude-ccs` zsh function (canonical copy; the live one
# is sourced from ~/.zshrc via the installer's marked block). Launch Claude Code
# through the HEADLESS cc-switch proxy at 127.0.0.1:15721 (Anthropic<->OpenAI
# translation + failover), with CC_SWITCH_HEADLESS guaranteeing ~/.claude is
# never rewritten.
#
# Provider profiles live in ~/.config/ccs-providers/<name>/ :
#   base-url           OpenAI-compatible endpoint WITHOUT trailing /v1   (required)
#   auth-token         API key value                                     (required, or keyfile)
#   keyfile            path to a file holding the API key                (alt to auth-token)
#   model              model id                                          (optional)
#   classifier-model   upstream model id for auto-mode classification; the
#                      launcher binds Claude's Sonnet role to this model
#                      (for example, qwen3.7-max)                           (optional)
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

    local base_url="" model="" key="" cmodel=""
    base_url=$(<"$prof/base-url" 2>/dev/null)
    [ -r "$prof/model" ] && model=$(<"$prof/model")
    [ -r "$prof/classifier-model" ] && cmodel=$(<"$prof/classifier-model")
    cmodel=${cmodel#"${cmodel%%[![:space:]]*}"}
    cmodel=${cmodel%"${cmodel##*[![:space:]]}"}
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
        local sm=(); [ -n "$cmodel" ] && sm=(--sonnet-model "$cmodel")
        "$CCS_BIN" provider add --app claude --template custom \
            --name "$name" --id "$name" \
            --base-url "$base_url" --api-key "$key" --api-key-field api-key \
            --api-format openai_chat "${m[@]}" "${sm[@]}" >/dev/null 2>&1 || {
            print -u2 "claude-ccs: failed to create provider $name"
            return 1
        }
        "$CCS_BIN" provider switch "$name" >/dev/null 2>&1 || {
            print -u2 "claude-ccs: failed to switch to newly created provider $name"
            return 1
        }
    fi
    # `provider switch` re-serializes meta and drops the snake_case `api_format`
    # the proxy actually reads (upstream stores camelCase `apiFormat`), so re-add
    # the snake key as the LAST write — after every switch, on every call.
    local _qname="${name//\'/\'\'}"
    local _set="meta = json_set(json_remove(meta,'\$.apiFormat'),'\$.api_format','openai_chat')"
    if [ -n "$cmodel" ]; then
        local _qcmodel="${cmodel//\'/\'\'}"
        _set+=", settings_config = json_set(settings_config,'\$.env.\"ANTHROPIC_DEFAULT_SONNET_MODEL\"','$_qcmodel')"
    fi
    local _selector="app_type='claude' AND is_current=1 AND (id='$_qname' OR lower(trim(name))=lower(trim('$_qname')))"
    local _updated
    _updated=$(command sqlite3 -bail -batch -noheader -list -init /dev/null "$db" "BEGIN IMMEDIATE; UPDATE providers SET $_set WHERE $_selector AND (SELECT count(*) FROM providers WHERE $_selector)=1; SELECT changes(); COMMIT;" 2>/dev/null) || {
        print -u2 "claude-ccs: failed to synchronize provider routing in $db"
        return 1
    }
    [ "$_updated" = 1 ] || {
        print -u2 "claude-ccs: expected one active Claude provider, synchronized ${_updated:-0}"
        return 1
    }

    # Ensure the headless proxy is listening on 15721.
    if ! ss -tln 2>/dev/null | grep -q ':15721'; then
        # The detached proxy must reach OpenAI-compatible upstreams. In WSL/VPN
        # setups a local HTTP proxy (Clash/V2Ray/mihomo) often runs but isn't
        # exported into every shell, so the proxy's outbound calls fail. Resolve
        # an outbound proxy URL and pass it to the proxy subprocess ONLY (never
        # mutate the interactive shell). Precedence: CCS_OUTBOUND_PROXY env >
        # already-exported *_proxy > auto-detected common local port. Disable
        # with CCS_OUTBOUND_PROXY=none.
        local _px=""
        if [[ $CCS_OUTBOUND_PROXY == none ]]; then
            :
        elif [[ -n $CCS_OUTBOUND_PROXY ]]; then
            _px=$CCS_OUTBOUND_PROXY
        elif [[ -n ${https_proxy:-${HTTPS_PROXY:-}} ]]; then
            _px=${https_proxy:-$HTTPS_PROXY}
        else
            local _pport
            for _pport in 7897 7890 7891 10809 1080; do
                if timeout 0.3 bash -c "</dev/tcp/127.0.0.1/$_pport" 2>/dev/null; then
                    _px=http://127.0.0.1:$_pport
                    break
                fi
            done
        fi
        if [[ -n $_px ]]; then
            setsid env "HTTPS_PROXY=$_px" "HTTP_PROXY=$_px" "https_proxy=$_px" "http_proxy=$_px" \
                "NO_PROXY=127.0.0.1,localhost,::1" "no_proxy=127.0.0.1,localhost,::1" \
                "$CCS_BIN" proxy serve >>"$CCS_HOME/proxy.log" 2>&1 </dev/null & disown
        else
            setsid "$CCS_BIN" proxy serve >>"$CCS_HOME/proxy.log" 2>&1 </dev/null & disown
        fi
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
        # This variable is ignored by Claude Code 2.1.224/2.1.226, but an
        # inherited value could override the controlled Sonnet role in another
        # build. The launcher owns classifier routing, so never pass it through.
        unset CLAUDE_CODE_AUTO_MODE_MODEL
        # Export the proxy's model id so Claude Code recognizes + restores it instead
        # of falling back to claude-opus-5 ("Session model <id> could not be restored").
        if [ -n "$model" ]; then
            export ANTHROPIC_MODEL="$model"
            export ANTHROPIC_DEFAULT_OPUS_MODEL="$model"
            export ANTHROPIC_DEFAULT_HAIKU_MODEL="$model"
        fi
        # Claude Code 2.1.224 and 2.1.226 derive auto-mode classification from
        # the Sonnet role. The proxy maps this role id to classifier-model while
        # ordinary requests remain on the profile model.
        if [ -n "$cmodel" ]; then
            export ANTHROPIC_DEFAULT_SONNET_MODEL=claude-sonnet-5
        elif [ -n "$model" ]; then
            export ANTHROPIC_DEFAULT_SONNET_MODEL="$model"
        fi
        # Don't let CC assume a 200k ceiling for an unrecognized model id; let the
        # upstream API decide context size (silences the "unknown model window" notice).
        ANTHROPIC_BASE_URL="http://127.0.0.1:15721" \
        ANTHROPIC_AUTH_TOKEN="ccs-proxy" \
        CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT=1 \
        command claude "$@"
    )
}
