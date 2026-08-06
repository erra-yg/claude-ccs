//! Headless mode red-line tests.
//!
//! With `CC_SWITCH_HEADLESS=1`, provider switching and related operations must
//! NEVER modify any file under the user's `~/.claude`. Provider selection still
//! updates the DB `current_provider` (the proxy's `ProviderRouter` reads the DB,
//! not live files), so switching keeps working without touching live config.
//!
//! These tests observe behavior at the highest seam — the live file on disk —
//! not the internal `headless_mode()` predicate.

use serde_json::json;
use std::fs;

use cc_switch_lib::{
    get_claude_settings_path, AppType, MultiAppConfig, Provider, ProviderService,
};

#[path = "support.rs"]
mod support;
use support::{ensure_test_home, lock_test_mutex, reset_test_fs, state_from_config};

/// RAII guard that sets an env var for the duration of a test and restores the
/// prior value on drop. Tests are serialized via `lock_test_mutex`, so there is
/// no concurrent access to the key.
struct EnvVarGuard {
    key: &'static str,
    previous: Option<std::ffi::OsString>,
}

impl EnvVarGuard {
    fn set(key: &'static str, value: &str) -> Self {
        let previous = std::env::var_os(key);
        // SAFETY: no other test reads or writes `CC_SWITCH_HEADLESS`; the test
        // mutex serializes this test against other env-mutating tests.
        unsafe {
            std::env::set_var(key, value);
        }
        Self { key, previous }
    }
}

impl Drop for EnvVarGuard {
    fn drop(&mut self) {
        match &self.previous {
            Some(value) => unsafe { std::env::set_var(self.key, value) },
            None => unsafe { std::env::remove_var(self.key) },
        }
    }
}

fn claude_provider(id: &str, token: &str, base_url: &str) -> Provider {
    Provider::with_id(
        id.to_string(),
        id.to_string(),
        json!({
            "env": {
                "ANTHROPIC_AUTH_TOKEN": token,
                "ANTHROPIC_BASE_URL": base_url,
            }
        }),
        None,
    )
}

/// Seed a hand-tuned user `~/.claude/settings.json` and return its exact bytes,
/// so a test can assert the file is left byte-for-byte untouched.
fn seed_user_settings() -> Vec<u8> {
    let settings_path = get_claude_settings_path();
    fs::create_dir_all(settings_path.parent().expect("settings.json has a parent dir"))
        .expect("create ~/.claude");
    let original = json!({
        "theme": "dark",
        "hooks": { "PostToolUse": [] },
        "statusLine": { "type": "command", "command": "echo status" }
    });
    let bytes = serde_json::to_vec_pretty(&original).expect("serialize original settings");
    fs::write(&settings_path, &bytes).expect("seed ~/.claude/settings.json");
    bytes
}

#[test]
fn headless_switch_leaves_live_claude_settings_untouched() {
    let _guard = lock_test_mutex();
    reset_test_fs();
    let _home = ensure_test_home();
    let _headless = EnvVarGuard::set("CC_SWITCH_HEADLESS", "1");

    let original_bytes = seed_user_settings();
    let settings_path = get_claude_settings_path();

    // Two providers; current = p-old.
    let mut config = MultiAppConfig::default();
    {
        let manager = config
            .get_manager_mut(&AppType::Claude)
            .expect("claude manager");
        manager.current = "p-old".to_string();
        manager
            .providers
            .insert("p-old".to_string(), claude_provider("p-old", "old-key", "https://old"));
        manager
            .providers
            .insert("p-new".to_string(), claude_provider("p-new", "new-key", "https://new"));
    }
    let state = state_from_config(config);

    // Switching in headless mode must succeed and update the DB current provider
    // (so the proxy still routes correctly) ...
    ProviderService::switch(&state, AppType::Claude, "p-new").expect("switch succeeds");
    assert_eq!(
        ProviderService::current(&state, AppType::Claude).expect("resolve current provider"),
        "p-new",
        "headless: DB current_provider must still update so the proxy routes correctly"
    );

    // ... while leaving the live file byte-for-byte unchanged.
    let after_bytes = fs::read(&settings_path).expect("read settings.json after switch");
    assert_eq!(
        after_bytes,
        original_bytes,
        "headless red-line: ~/.claude/settings.json must not be modified by provider switch"
    );
}
