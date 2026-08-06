use crate::app_config::AppType;

/// Whether CC-Switch runs in headless (live-isolated) mode.
///
/// Enabled when the `CC_SWITCH_HEADLESS` environment variable is set to a
/// truthy value (`1`, `true`, `yes`, `on`; case-insensitive). In headless mode
/// CC-Switch never writes any app's *live* configuration files (for example
/// `~/.claude/settings.json`). The local proxy still serves and routes via the
/// in-database `current_provider`, so a caller — such as a custom launcher that
/// points Claude at the proxy via `ANTHROPIC_BASE_URL` — drives the app purely
/// through environment variables, with zero touches to live config.
pub(crate) fn headless_mode() -> bool {
    std::env::var_os("CC_SWITCH_HEADLESS")
        .as_deref()
        .map(is_truthy_env)
        .unwrap_or(false)
}

fn is_truthy_env(value: &std::ffi::OsStr) -> bool {
    let value = value.to_ascii_lowercase();
    !(value.is_empty() || value == "0" || value == "false" || value == "no" || value == "off")
}

/// Whether we should write/delete "live" config files for a given app.
///
/// Policy: **auto** (safe default)
/// - If the target app looks uninitialized (its config dir / key live file is missing),
///   skip live writes/deletes and do **not** create any directories/files.
pub(crate) fn should_sync_live(app_type: &AppType) -> bool {
    match app_type {
        // Claude is considered initialized if either:
        // - ~/.claude (settings dir) exists, or
        // - ~/.claude.json (MCP file) exists
        AppType::Claude => {
            crate::config::get_claude_config_dir().exists()
                || crate::config::get_claude_mcp_path().exists()
        }
        // Codex is considered initialized if ~/.codex (or override dir) exists.
        AppType::Codex => crate::codex_config::get_codex_config_dir().exists(),
        // Gemini is considered initialized if ~/.gemini (or override dir) exists.
        AppType::Gemini => crate::gemini_config::get_gemini_dir().exists(),
        // OpenCode is considered initialized if ~/.config/opencode (or override dir) exists.
        AppType::OpenCode => crate::opencode_config::get_opencode_dir().exists(),
        // Hermes is considered initialized if ~/.hermes (or override dir) exists.
        AppType::Hermes => crate::hermes_config::get_hermes_dir().exists(),
        // OpenClaw is considered initialized if ~/.openclaw (or override dir) exists.
        AppType::OpenClaw => get_openclaw_dir().exists(),
    }
}

fn get_openclaw_dir() -> std::path::PathBuf {
    crate::settings::get_openclaw_override_dir()
        .or_else(|| dirs::home_dir().map(|home| home.join(".openclaw")))
        .unwrap_or_else(|| std::path::PathBuf::from(".openclaw"))
}
