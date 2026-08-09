#!/usr/bin/env bash
# uninstall-claude-ccs.sh — the reliable, clean, thorough uninstaller for claude-ccs.
#
# Reverses EVERYTHING install-claude-ccs.sh + the runtime create, in a safe order:
#   1. stop the detached cc-switch proxy on 127.0.0.1:15721
#   2. remove the marked `claude-ccs` block from ~/.zshrc (backup first)
#   3. secure-erase key material (provider auth-tokens/keyfiles, the proxy DB) then rm the dirs
#   4. remove the stray ~/.config/ccs-profiles (install-script leftover), if empty
#   5. remove the cloned repo itself (deferred, so the script can finish first)
#
# Usage:
#   ./uninstall-claude-ccs.sh              # interactive: shows plan, asks y/N
#   ./uninstall-claude-ccs.sh --dry-run    # preview only, change nothing
#   ./uninstall-claude-ccs.sh -y           # skip the confirmation prompt
#   ./uninstall-claude-ccs.sh --keep-repo --keep-profiles --keep-state   # keep any subset
#
# NEVER touched: ~/.claude/ (the whole point of claude-ccs), system packages
# (build-essential/curl/pkg-config), the Rust toolchain (~/.cargo, ~/.rustup), and any
# ~/.zshrc content outside the marked `# >>> claude-ccs (headless) >>>` block.
#
# The Rust toolchain / build deps are shared system assets, so they are left in place;
# the final report prints opt-in manual commands to remove them if you really want to.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZSHRC="${ZDOTDIR:-$HOME}/.zshrc"
CCS_HOME="$HOME/.cc-switch-headless"
PROFILES_DIR="$HOME/.config/llm-profile"
STRAY_DIR="$HOME/.config/ccs-profiles"   # leftover from an install-script default-name bug
PORT="${CCS_PORT:-15721}"                 # overridable for tests (mirrors ccs-proxy-up.sh)
BLOCK_START='# >>> claude-ccs (headless) >>>'
BLOCK_END='# <<< claude-ccs (headless) <<<'

# flags
DRY_RUN=false
YES=false
KEEP_REPO=false
KEEP_PROFILES=false
KEEP_STATE=false

say()  { printf '[claude-ccs] %s\n' "$*"; }
warn() { printf '[claude-ccs warn] %s\n' "$*" >&2; }

usage() {
  sed -n '2,27p' "$0"
  exit 0
}

# ---- arg parsing ----
while [ $# -gt 0 ]; do
  case "$1" in
    -n|--dry-run)      DRY_RUN=true; shift ;;
    -y|--yes)          YES=true; shift ;;
    --keep-repo)       KEEP_REPO=true; shift ;;
    --keep-profiles)   KEEP_PROFILES=true; shift ;;
    --keep-state)      KEEP_STATE=true; shift ;;
    -h|--help)         usage ;;
    *) printf 'unknown arg: %s (try --help)\n' "$1" >&2; exit 2 ;;
  esac
done

# Resolve the cc-switch binary path from the .zshrc block (the installer wrote it there);
# fall back to the in-repo release binary. Used only to describe/locate the proxy process.
ccs_bin_from_zshrc() {
  [ -f "$ZSHRC" ] || return 0
  awk -v s="$BLOCK_START" -v e="$BLOCK_END" '$0==s{f=1;next} $0==e{f=0} f' "$ZSHRC" \
    | grep -E '^export CCS_BIN=' | head -1 | sed -E 's/^export CCS_BIN="(.*)"$/\1/'
}
CCS_BIN="$(ccs_bin_from_zshrc)"
[ -n "$CCS_BIN" ] || CCS_BIN="$REPO_DIR/src-tauri/target/release/cc-switch"

# ---- detection helpers ----
block_present() { [ -f "$ZSHRC" ] && grep -qxF "$BLOCK_START" "$ZSHRC"; }

# Is this PID a cc-switch proxy? (verify cmdline so we never kill an unrelated process)
proc_is_ccs_proxy() {
  local pid="$1" cmd
  [ -d "/proc/$pid" ] || return 1
  cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)"
  case "$cmd" in *"cc-switch"*"proxy serve"*) return 0 ;; *) return 1 ;; esac
}

# PIDs of OUR proxy: the cc-switch process(es) listening on $PORT, cmdline-verified.
# Port-based ONLY — never a broad `pgrep -f 'cc-switch proxy serve'`: that would also match
# an unrelated cc-switch proxy on another port, or even a shell whose command line merely
# contains that string. The claude-ccs proxy IS the one bound to $PORT (default 15721).
proxy_pids() {
  local pids="" p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if proc_is_ccs_proxy "$p"; then pids="$pids $p"; fi
  done < <(ss -ltnp 2>/dev/null | grep ":$PORT" | grep -oE 'pid=[0-9]+' | grep -oE '[0-9]+')
  echo "$pids" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -u
}

# ---- secure delete (best-effort; shred is unreliable on SSD/CoW, rm is the fallback) ----
shred_file() {
  if command -v shred >/dev/null 2>&1; then
    shred -u "$1" 2>/dev/null || rm -f "$1"
  else
    rm -f "$1"
  fi
}

# ---- action steps (each no-ops its case under --dry-run / --keep-*) ----
stop_proxy() {
  local pids p i
  pids="$(proxy_pids)"
  if [ -z "$pids" ]; then
    # warn if the port is held by something that is NOT our proxy
    local holder
    holder="$(ss -ltnp 2>/dev/null | grep ":$PORT" | grep -oE 'pid=[0-9]+' | grep -oE '[0-9]+' | head -1)"
    if [ -n "$holder" ] && ! proc_is_ccs_proxy "$holder"; then
      warn "port $PORT held by non-cc-switch pid $holder — leaving it alone"
    fi
    say "no cc-switch proxy found on :$PORT (already stopped)"
    return 0
  fi
  $DRY_RUN && { say "[dry-run] would stop cc-switch proxy (pids:$(echo "$pids" | tr '\n' ' '))"; return 0; }
  for p in $pids; do kill -TERM "$p" 2>/dev/null || true; done
  for ((i = 0; i < 30; i++)); do           # wait up to ~6s for graceful exit
    sleep 0.2
    [ -z "$(proxy_pids)" ] && { say "proxy stopped"; return 0; }
  done
  for p in $(proxy_pids); do kill -KILL "$p" 2>/dev/null || true; done  # SIGKILL stragglers
  sleep 0.3
  if [ -n "$(proxy_pids)" ]; then warn "proxy survived SIGKILL (pids:$(proxy_pids | tr '\n' ' '))"
  else say "proxy stopped (after SIGKILL)"; fi
}

remove_zshrc_block() {
  if ! block_present; then warn "no claude-ccs block in $ZSHRC — skipping"; return 0; fi
  $DRY_RUN && { say "[dry-run] would remove claude-ccs block from $ZSHRC"; return 0; }
  cp -a "$ZSHRC" "$ZSHRC.ccs-uninstall.bak"
  sed -i "/^${BLOCK_START}\$/,/^${BLOCK_END}\$/d" "$ZSHRC"
  if block_present; then warn "block markers still present after edit — review $ZSHRC (backup: $ZSHRC.ccs-uninstall.bak)"
  else say "removed claude-ccs block from $ZSHRC (backup: $ZSHRC.ccs-uninstall.bak)"; fi
}

remove_state() {
  if $KEEP_STATE; then say "--keep-state: keeping $CCS_HOME"; return 0; fi
  [ -d "$CCS_HOME" ] || { say "no state dir at $CCS_HOME (nothing to remove)"; return 0; }
  local n=0 f
  for f in cc-switch.db cc-switch.db-wal cc-switch.db-shm settings.json proxy.log; do
    if [ -f "$CCS_HOME/$f" ]; then
      $DRY_RUN && { say "[dry-run] would shred $CCS_HOME/$f"; } || { shred_file "$CCS_HOME/$f"; n=$((n + 1)); }
    fi
  done
  $DRY_RUN && { say "[dry-run] would rm -rf $CCS_HOME"; return 0; }
  rm -rf -- "$CCS_HOME"
  say "removed $CCS_HOME (shredded $n sensitive file(s))"
}

remove_profiles() {
  if $KEEP_PROFILES; then say "--keep-profiles: keeping $PROFILES_DIR"; return 0; fi
  [ -d "$PROFILES_DIR" ] || { say "no profiles dir at $PROFILES_DIR (nothing to remove)"; return 0; }
  local n=0 kf tgt f
  $DRY_RUN && { say "[dry-run] would shred key files + rm -rf $PROFILES_DIR"; return 0; }
  # a `keyfile` points at an external key path; shred that target too if it's under $HOME
  while IFS= read -r -d '' kf; do
    tgt="$(cat "$kf" 2>/dev/null || true)"
    case "$tgt" in
      "$HOME"/*) [ -f "$tgt" ] && { shred_file "$tgt"; n=$((n + 1)); } ;;
    esac
  done < <(find "$PROFILES_DIR" -type f -name keyfile -print0 2>/dev/null)
  # then the auth-token / keyfile files themselves
  while IFS= read -r -d '' f; do shred_file "$f"; n=$((n + 1)); done \
    < <(find "$PROFILES_DIR" -type f \( -name auth-token -o -name keyfile \) -print0 2>/dev/null)
  rm -rf -- "$PROFILES_DIR"
  say "removed $PROFILES_DIR (shredded $n key file(s))"
}

remove_stray() {
  [ -d "$STRAY_DIR" ] || return 0
  $DRY_RUN && { say "[dry-run] would rmdir stray $STRAY_DIR (only if empty)"; return 0; }
  if rmdir "$STRAY_DIR" 2>/dev/null; then say "removed empty stray dir $STRAY_DIR"
  else warn "$STRAY_DIR not empty (may be repurposed) — leaving it"; fi
}

remove_repo() {
  if $KEEP_REPO; then
    say "--keep-repo: keeping $REPO_DIR"
    say "to remove later:  rm -rf -- \"$REPO_DIR\""
    return 0
  fi
  $DRY_RUN && { say "[dry-run] would rm -rf $REPO_DIR after exit"; return 0; }
  say "removing repo $REPO_DIR (deferred — runs after this script exits)"
  warn "your terminal's current directory may become invalid afterward — run 'cd ~'."
  # Deferred so the script can finish printing; the subshell outlives this process.
  ( sleep 1; rm -rf -- "$REPO_DIR" ) >/dev/null 2>&1 &
}

# ---- summary (shown before confirm and on dry-run) ----
print_summary() {
  local label pids kc
  echo
  echo "claude-ccs uninstall plan:"
  pids="$(proxy_pids | tr '\n' ' ')"
  if [ -n "$pids" ]; then echo "  - STOP cc-switch proxy on :$PORT (pid ${pids})"
  else echo "  - proxy: none running on :$PORT"; fi
  if block_present; then echo "  - REMOVE claude-ccs block from $ZSHRC (backup will be made)"
  else echo "  - zshrc: no claude-ccs block"; fi
  if [ -d "$CCS_HOME" ]; then
    if $KEEP_STATE; then label="KEEP"; else label="SHRED+REMOVE"; fi
    echo "  - $label state dir $CCS_HOME"
  fi
  if [ -d "$PROFILES_DIR" ]; then
    kc="$(find "$PROFILES_DIR" -type f \( -name auth-token -o -name keyfile \) 2>/dev/null | wc -l | tr -d ' ')"
    if $KEEP_PROFILES; then label="KEEP"; else label="SHRED+REMOVE"; fi
    echo "  - $label profiles $PROFILES_DIR ($kc key file(s))"
  fi
  [ -d "$STRAY_DIR" ] && echo "  - remove stray $STRAY_DIR (only if empty)"
  if $KEEP_REPO; then label="KEEP"; else label="REMOVE"; fi
  echo "  - $label repo $REPO_DIR"
  echo "  - NOT touched: ~/.claude/, system packages, Rust toolchain, rest of ~/.zshrc"
  echo
}

confirm() {
  $YES && return 0
  printf '[claude-ccs] Proceed with uninstall? [y/N] '
  local reply
  read -r reply </dev/tty 2>/dev/null || reply=n
  case "$reply" in y|Y|yes|YES) return 0 ;; *) say "aborted — nothing changed."; exit 1 ;; esac
}

# ---- main ----
print_summary
$DRY_RUN && { say "[dry-run] no changes made."; exit 0; }
confirm

stop_proxy
remove_zshrc_block
remove_state
remove_profiles
remove_stray

say "the 'claude-ccs' function stays loaded in your CURRENT shell until you open a new"
say "terminal (or run: unset -f claude-ccs)."
say "optional toolchain removal (shared — only if nothing else uses them):"
say "  rustup self uninstall        # removes ~/.cargo and ~/.rustup"
say "  sudo apt purge build-essential pkg-config curl   # build deps"
say "done. ~/.claude/ was never touched."

remove_repo    # MUST be last — may delete this script's own directory
exit 0
