# claude-ccs.zsh — the `claude-ccs` zsh function (canonical copy; the live one
# is sourced from ~/.zshrc via the installer's marked block). Launch Claude Code
# through the HEADLESS cc-switch proxy at 127.0.0.1:15721, with CC_SWITCH_HEADLESS
# guaranteeing ~/.claude is never rewritten.
#
# Routing = Path B: multi-LLM via Anthropic->OpenAI translation.
#   1. meta key is CAMELCASE `apiFormat` (the struct reads camelCase; a prior
#      snake_case `api_format` was a dead key that never enabled translation).
#      Translation is required because some backends (e.g. kimi-k3) only work on
#      opencode-go's OpenAI endpoint, not its Anthropic endpoint.
#   2. Auth is `ANTHROPIC_AUTH_TOKEN` (-> Authorization: Bearer), not
#      `ANTHROPIC_API_KEY` (-> x-api-key). opencode-go's OpenAI endpoint requires
#      Bearer; its Anthropic endpoint requires x-api-key — mutually exclusive, so
#      Path B commits to Bearer + OpenAI translation.
#   3. Per-role backends: opus/haiku/default pass through (CC env carries the
#      literal backend id; the proxy forwards it verbatim after stripping [1m]),
#      and sonnet + the auto-mode classifier use a SONNET slot (CC exports the
#      role id claude-sonnet-5[1m], which the proxy maps to the configured sonnet
#      backend). CC only fires its auto-mode classifier when the Sonnet role
#      resolves to a Claude id, so the SONNET role must stay a role id, not a
#      literal backend id.
#   4. AUTH_TOKEN is sourced from the profile key ($key), NOT from the DB's
#      ANTHROPIC_API_KEY. This keeps the per-launch DB sync IDEMPOTENT: the sync
#      also removes ANTHROPIC_API_KEY, so sourcing AUTH_TOKEN from it would null
#      the key on the second launch (run 1 removes API_KEY -> run 2 extracts
#      NULL -> upstream 401 "Missing API key."). $key is the authoritative
#      source outside the DB.
#
# Provider profiles live in ~/.config/llm-profile/<name>/ :
#   base-url       OpenAI-compatible endpoint WITHOUT trailing /v1        (required)
#   auth-token     API key value                                         (required, or keyfile)
#   keyfile        path to a file holding the API key                    (alt to auth-token)
#   model          default backend model id (e.g. deepseek-v4-flash[1m]) (required)
#   model-opus     opus-role backend   (e.g. kimi-k3)                    (optional; default: $model)
#   model-sonnet   sonnet-role + auto-mode classifier backend            (optional; default: $model)
#                  (e.g. qwen3.8-max)
#   model-haiku    haiku-role backend  (e.g. deepseek-v4-flash[1m])      (optional; default: $model)
#
# Usage:   claude-ccs <name> [claude args...]
# Switch the main model at runtime with /model opus|sonnet|haiku (no restart).
claude-ccs() {
    emulate -L zsh
    local name="${1:-}"
    local profdir="$HOME/.config/llm-profile"

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
    [ -d "$prof" ] || { print -u2 "claude-ccs: no provider profile at $prof"; return 2 }

    # --- read profile ---
    local _trim
    _trim() {  # trim leading/trailing whitespace from $REPLY
        REPLY=${REPLY#"${REPLY%%[![:space:]]*}"}
        REPLY=${REPLY%"${REPLY##*[![:space:]]}"}
    }
    local base_url="" key="" model="" mopus="" msonnet="" mhaiku=""
    base_url=$(<"$prof/base-url" 2>/dev/null); REPLY=$base_url; _trim; base_url=$REPLY
    [ -r "$prof/model" ]        && { model=$(<"$prof/model");        REPLY=$model;    _trim; model=$REPLY; }
    [ -r "$prof/model-opus" ]   && { mopus=$(<"$prof/model-opus");   REPLY=$mopus;    _trim; mopus=$REPLY; }
    [ -r "$prof/model-sonnet" ] && { msonnet=$(<"$prof/model-sonnet"); REPLY=$msonnet; _trim; msonnet=$REPLY; }
    [ -r "$prof/model-haiku" ]  && { mhaiku=$(<"$prof/model-haiku"); REPLY=$mhaiku;   _trim; mhaiku=$REPLY; }
    [ -n "$model" ] || { print -u2 "claude-ccs: $prof/model is required (default backend model id)"; return 2; }
    [ -n "$mopus" ]   || mopus=$model
    [ -n "$msonnet" ] || msonnet=$model
    [ -n "$mhaiku" ]  || mhaiku=$model
    if   [ -r "$prof/auth-token" ]; then key=$(<"$prof/auth-token")
    elif [ -r "$prof/keyfile" ];   then local kf; kf=$(<"$prof/keyfile"); [ -r "$kf" ] && key=$(<"$kf"); fi
    REPLY=$key; _trim; key=$REPLY
    [ -n "$base_url" ] && [ -n "$key" ] || { print -u2 "claude-ccs: $prof needs base-url + (auth-token | keyfile)"; return 2; }

    # --- cc-switch binary + isolated headless state ---
    local CCS_BIN="${CCS_BIN:-$HOME/claude-ccs/src-tauri/target/release/cc-switch}"
    local CCS_HOME="${CCS_HOME:-$HOME/.cc-switch-headless}"
    [ -x "$CCS_BIN" ] || { print -u2 "claude-ccs: cc-switch binary not found at $CCS_BIN (set \$CCS_BIN)"; return 2; }
    command -v sqlite3 >/dev/null || { print -u2 "claude-ccs: sqlite3 required"; return 2; }
    export CC_SWITCH_HEADLESS=1 CC_SWITCH_CONFIG_DIR="$CCS_HOME"
    mkdir -p "$CCS_HOME"
    local db="$CCS_HOME/cc-switch.db"

    # --- create the provider if missing (openai_chat), then switch ---
    if ! "$CCS_BIN" provider switch "$name" >/dev/null 2>&1; then
        "$CCS_BIN" provider add --app claude --template custom \
            --name "$name" --id "$name" \
            --base-url "$base_url" --api-key "$key" --api-key-field api-key \
            --api-format openai_chat --model "$model" >/dev/null 2>&1 || {
            print -u2 "claude-ccs: failed to create provider $name"; return 1
        }
        "$CCS_BIN" provider switch "$name" >/dev/null 2>&1 || {
            print -u2 "claude-ccs: failed to switch to newly created provider $name"; return 1
        }
    fi

    # --- DB sync: Path B config (camelCase apiFormat + Bearer + SONNET slot) ---
    # `provider switch` re-serializes meta and can drop the format key the proxy
    # reads, so re-apply as the LAST write on every call.
    local _qname="${name//\'/\'\'}"
    local _qmsonnet="${msonnet//\'/\'\'}"
    local _qkey="${key//\'/\'\'}"
    # 1) meta.apiFormat (camelCase) = openai_chat
    # 2) ANTHROPIC_AUTH_TOKEN = profile key $key (Bearer); drop ANTHROPIC_API_KEY.
    #    Sourced from $key (NOT from DB ANTHROPIC_API_KEY) so the sync is
    #    IDEMPOTENT + self-healing across launches — otherwise the 2nd launch
    #    finds API_KEY already removed (run 1 removed it), extracts NULL, and
    #    nulls AUTH_TOKEN -> upstream 401 "Missing API key." on every request.
    # 3) SONNET slot = $msonnet (sonnet role + classifier backend)
    # 4) clear MODEL/OPUS/HAIKU/FABLE/SUBAGENT slots (pass-through for those)
    local _set="meta = json_set(json_remove(meta,'\$.apiFormat','\$.api_format'),'\$.apiFormat','openai_chat')"
    _set+=", settings_config = json_remove("
    _set+="  json_set(settings_config"
    _set+="    , '\$.env.\"ANTHROPIC_AUTH_TOKEN\"', '$_qkey'"
    _set+="    , '\$.env.\"ANTHROPIC_BASE_URL\"', '$base_url'"
    _set+="    , '\$.env.\"ANTHROPIC_DEFAULT_SONNET_MODEL\"', '$_qmsonnet'"
    _set+="  )"
    _set+="  , '\$.env.\"ANTHROPIC_API_KEY\"'"
    _set+="  , '\$.env.\"ANTHROPIC_MODEL\"'"
    _set+="  , '\$.env.\"ANTHROPIC_DEFAULT_OPUS_MODEL\"'"
    _set+="  , '\$.env.\"ANTHROPIC_DEFAULT_HAIKU_MODEL\"'"
    _set+="  , '\$.env.\"ANTHROPIC_DEFAULT_FABLE_MODEL\"'"
    _set+="  , '\$.env.\"CLAUDE_CODE_SUBAGENT_MODEL\"'"
    _set+=")"
    local _selector="app_type='claude' AND is_current=1 AND (id='$_qname' OR lower(trim(name))=lower(trim('$_qname')))"
    local _updated
    _updated=$(command sqlite3 -bail -batch -noheader -list -init /dev/null "$db" "BEGIN IMMEDIATE; UPDATE providers SET $_set WHERE $_selector AND (SELECT count(*) FROM providers WHERE $_selector)=1; SELECT changes(); COMMIT;" 2>/dev/null) || {
        print -u2 "claude-ccs: failed to synchronize Path B routing in $db"; return 1
    }
    [ "$_updated" = 1 ] || {
        print -u2 "claude-ccs: expected one active Claude provider, synchronized ${_updated:-0}"; return 1
    }

    # --- ensure the headless proxy is listening on 15721 ---
    if ! ss -tln 2>/dev/null | grep -q ':15721'; then
        local _px=""
        if   [[ $CCS_OUTBOUND_PROXY == none ]]; then :
        elif [[ -n $CCS_OUTBOUND_PROXY ]]; then _px=$CCS_OUTBOUND_PROXY
        elif [[ -n ${https_proxy:-${HTTPS_PROXY:-}} ]]; then _px=${https_proxy:-$HTTPS_PROXY}
        else
            local _pport
            for _pport in 7897 7890 7891 10809 1080; do
                if timeout 0.3 bash -c "</dev/tcp/127.0.0.1/$_pport" 2>/dev/null; then
                    _px=http://127.0.0.1:$_pport; break
                fi
            done
        fi
        if [[ -n $_px ]]; then
            setsid env "HTTPS_PROXY=$_px" "HTTP_PROXY=$_px" "https_proxy=$_px" "http_proxy=$_px" \
                "NO_PROXY=127.0.0.1,localhost,::1" "no_proxy=127.0.0.1,localhost,::1" \
                "$CCS_BIN" proxy serve >> "$CCS_HOME/proxy.log" 2>&1 </dev/null & disown
        else
            setsid "$CCS_BIN" proxy serve >> "$CCS_HOME/proxy.log" 2>&1 </dev/null & disown
        fi
        local i
        for ((i = 0; i < 60; i++)); do
            ss -tln 2>/dev/null | grep -q ':15721' && break
            sleep 0.5
        done
    fi
    ss -tln 2>/dev/null | grep -q ':15721' || { print -u2 "claude-ccs: proxy did not come up on 15721 (see $CCS_HOME/proxy.log)"; return 1; }

    # --- launch Claude through the proxy ---
    # opus/haiku/default: literal backend ids -> proxy pass-through.
    # sonnet: role id claude-sonnet-5[1m] -> proxy SONNET slot -> $msonnet. CC fires
    # its auto-mode classifier on the Sonnet role, so this also routes the
    # classifier to $msonnet (a strong model) — same trick as the incumbent fix.
    (
        _claude_clean_env 2>/dev/null
        unset CLAUDE_CODE_AUTO_MODE_MODEL
        export ANTHROPIC_MODEL="$model"
        export ANTHROPIC_DEFAULT_OPUS_MODEL="$mopus"
        export ANTHROPIC_DEFAULT_HAIKU_MODEL="$mhaiku"
        export ANTHROPIC_DEFAULT_SONNET_MODEL=claude-sonnet-5[1m]
        ANTHROPIC_BASE_URL="http://127.0.0.1:15721" \
        ANTHROPIC_AUTH_TOKEN="ccs-proxy" \
        CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT=1 \
        command claude "$@"
    )
}
