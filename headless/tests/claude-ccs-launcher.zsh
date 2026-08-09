#!/usr/bin/env zsh
set -eu

repo_root=${0:A:h:h:h}
test_root=$(mktemp -d /tmp/ccs-auto-mode-launcher-test.XXXXXX)
trap 'rm -rf -- "$test_root"' EXIT

test_home="$test_root/home"
profiles_dir="$test_home/.config/llm-profile"
profile_dir="$profiles_dir/test"
stub_bin="$test_root/bin"
capture="$test_root/claude-env.txt"
expected="$test_root/expected-env.txt"
cc_switch_log="$test_root/cc-switch.log"
sqlite_log="$test_root/sqlite.log"
provider_state="$test_root/providers"
provider_map="$test_root/provider-map"
mkdir -p "$profile_dir" "$stub_bin" "$provider_state" "$provider_map"

print -r -- 'https://provider.example.test' >"$profile_dir/base-url"
print -r -- 'test-token' >"$profile_dir/auth-token"
print -r -- 'deepseek-v4-flash[1m]' >"$profile_dir/model"
print -r -- 'qwen3.7-max' >"$profile_dir/classifier-model"

for profile_name in fallback whitespace trimmed classifier-only existing display-name sync-miss add-failure switch-failure multi-current; do
  mkdir -p "$profiles_dir/$profile_name"
  print -r -- 'https://provider.example.test' >"$profiles_dir/$profile_name/base-url"
  print -r -- 'test-token' >"$profiles_dir/$profile_name/auth-token"
done
print -r -- 'deepseek-v4-flash[1m]' >"$profiles_dir/fallback/model"
print -r -- 'deepseek-v4-flash[1m]' >"$profiles_dir/whitespace/model"
print -r -- '   ' >"$profiles_dir/whitespace/classifier-model"
print -r -- 'deepseek-v4-flash[1m]' >"$profiles_dir/trimmed/model"
print -r -- $'  qwen3.7-max \t' >"$profiles_dir/trimmed/classifier-model"
print -r -- 'qwen3.7-max' >"$profiles_dir/classifier-only/classifier-model"
print -r -- 'deepseek-v4-flash[1m]' >"$profiles_dir/existing/model"
print -r -- 'qwen3.7-max' >"$profiles_dir/existing/classifier-model"
print -r -- 'deepseek-v4-flash[1m]' >"$profiles_dir/display-name/model"
print -r -- 'qwen3.7-max' >"$profiles_dir/display-name/classifier-model"
print -r -- 'deepseek-v4-flash[1m]' >"$profiles_dir/sync-miss/model"
print -r -- 'qwen3.7-max' >"$profiles_dir/sync-miss/classifier-model"
print -r -- 'deepseek-v4-flash[1m]' >"$profiles_dir/add-failure/model"
print -r -- 'qwen3.7-max' >"$profiles_dir/add-failure/classifier-model"
print -r -- 'deepseek-v4-flash[1m]' >"$profiles_dir/switch-failure/model"
print -r -- 'qwen3.7-max' >"$profiles_dir/switch-failure/classifier-model"
print -r -- 'deepseek-v4-flash[1m]' >"$profiles_dir/multi-current/model"
print -r -- 'qwen3.7-max' >"$profiles_dir/multi-current/classifier-model"
touch "$provider_state/existing" "$provider_state/actual-id"
print -r -- 'actual-id' >"$provider_map/display-name"

cat >"$stub_bin/cc-switch" <<'EOF'
#!/bin/sh
{
  printf 'call'
  for arg in "$@"; do printf '\t%s' "$arg"; done
  printf '\n'
} >>"$CCS_TEST_SWITCH_LOG"

if [ "$1" = provider ] && [ "$2" = switch ]; then
  if [ "$3" = sync-miss ]; then
    exit 0
  fi
  if [ "$3" = multi-current ]; then
    sqlite3 "$CC_SWITCH_CONFIG_DIR/cc-switch.db" \
      "UPDATE providers SET is_current=0 WHERE app_type='claude'; UPDATE providers SET is_current=1 WHERE id IN ('multi-current','multi-current-row') AND app_type='claude';"
    exit 0
  fi
  if [ "$3" = switch-failure ] && [ -e "$CCS_TEST_PROVIDER_STATE/$3" ]; then
    exit 1
  fi
  resolved=$3
  if [ -r "$CCS_TEST_PROVIDER_MAP/$3" ]; then
    resolved=$(cat "$CCS_TEST_PROVIDER_MAP/$3")
  fi
  [ -e "$CCS_TEST_PROVIDER_STATE/$resolved" ] || exit 1
  sqlite3 "$CC_SWITCH_CONFIG_DIR/cc-switch.db" \
    "UPDATE providers SET is_current=0 WHERE app_type='claude'; UPDATE providers SET is_current=1 WHERE id='$resolved' AND app_type='claude';"
  exit 0
fi

if [ "$1" = provider ] && [ "$2" = add ]; then
  id=''
  name=''
  while [ "$#" -gt 0 ]; do
    [ "$1" = --id ] && id=$2
    [ "$1" = --name ] && name=$2
    shift
  done
  [ "$id" = add-failure ] && exit 1
  touch "$CCS_TEST_PROVIDER_STATE/$id"
  sqlite3 "$CC_SWITCH_CONFIG_DIR/cc-switch.db" \
    "INSERT INTO providers(id,app_type,name,settings_config,meta,is_current) VALUES('$id','claude','$name','{\"env\":{}}','{}',0);"
fi

exit 0
EOF

cat >"$stub_bin/ss" <<'EOF'
#!/bin/sh
printf '%s\n' 'LISTEN 0 1024 127.0.0.1:15721 0.0.0.0:*'
EOF

cat >"$stub_bin/claude" <<'EOF'
#!/bin/sh
{
  printf 'ANTHROPIC_MODEL=%s\n' "${ANTHROPIC_MODEL-<unset>}"
  printf 'ANTHROPIC_DEFAULT_OPUS_MODEL=%s\n' "${ANTHROPIC_DEFAULT_OPUS_MODEL-<unset>}"
  printf 'ANTHROPIC_DEFAULT_SONNET_MODEL=%s\n' "${ANTHROPIC_DEFAULT_SONNET_MODEL-<unset>}"
  printf 'ANTHROPIC_DEFAULT_HAIKU_MODEL=%s\n' "${ANTHROPIC_DEFAULT_HAIKU_MODEL-<unset>}"
  printf 'CLAUDE_CODE_AUTO_MODE_MODEL=%s\n' "${CLAUDE_CODE_AUTO_MODE_MODEL-<unset>}"
} >"$CCS_TEST_CAPTURE"
EOF

chmod 700 "$stub_bin/cc-switch" "$stub_bin/ss" "$stub_bin/claude"

export HOME="$test_home"
export PATH="$stub_bin:/usr/bin:/bin"
export CCS_BIN="$stub_bin/cc-switch"
export CCS_HOME="$test_root/ccs-home"
export CCS_TEST_CAPTURE="$capture"
export CCS_TEST_PROVIDER_STATE="$provider_state"
export CCS_TEST_PROVIDER_MAP="$provider_map"
export CCS_TEST_SWITCH_LOG="$cc_switch_log"
export CLAUDE_CODE_AUTO_MODE_MODEL=unsafe-inherited
mkdir -p "$CCS_HOME"
sqlite3 "$CCS_HOME/cc-switch.db" <<'EOF'
CREATE TABLE providers (
  id TEXT NOT NULL,
  app_type TEXT NOT NULL,
  name TEXT NOT NULL,
  settings_config TEXT NOT NULL,
  meta TEXT NOT NULL DEFAULT '{}',
  is_current BOOLEAN NOT NULL DEFAULT 0,
  PRIMARY KEY (id, app_type)
);
INSERT INTO providers(id,app_type,name,settings_config,meta,is_current)
VALUES('existing','claude','existing','{"env":{}}','{}',0);
INSERT INTO providers(id,app_type,name,settings_config,meta,is_current)
VALUES('actual-id','claude','display-name','{"env":{}}','{}',0);
INSERT INTO providers(id,app_type,name,settings_config,meta,is_current)
VALUES('multi-current','claude','other-name','{"env":{}}','{}',0);
INSERT INTO providers(id,app_type,name,settings_config,meta,is_current)
VALUES('multi-current-row','claude','multi-current','{"env":{}}','{}',0);
EOF
print -r -- '.headers on' >"$HOME/.sqliterc"
print -r -- '.mode box' >>"$HOME/.sqliterc"

_claude_clean_env() {
  unset ANTHROPIC_MODEL
  unset ANTHROPIC_DEFAULT_OPUS_MODEL
  unset ANTHROPIC_DEFAULT_SONNET_MODEL
  unset ANTHROPIC_DEFAULT_HAIKU_MODEL
}

sqlite3() {
  command sqlite3 -cmd '.headers on' "$@"
}

source "$repo_root/headless/claude-ccs.zsh"
claude-ccs test --version

cat >"$expected" <<'EOF'
ANTHROPIC_MODEL=deepseek-v4-flash[1m]
ANTHROPIC_DEFAULT_OPUS_MODEL=deepseek-v4-flash[1m]
ANTHROPIC_DEFAULT_SONNET_MODEL=claude-sonnet-5
ANTHROPIC_DEFAULT_HAIKU_MODEL=deepseek-v4-flash[1m]
CLAUDE_CODE_AUTO_MODE_MODEL=<unset>
EOF

if ! cmp -s "$expected" "$capture"; then
  diff -u "$expected" "$capture"
  exit 1
fi

if ! grep -F $'call\tprovider\tadd' "$cc_switch_log" | grep -F -- $'--sonnet-model\tqwen3.7-max' >/dev/null; then
  print -u2 'provider add did not configure the classifier Sonnet slot'
  sed -n '1,20p' "$cc_switch_log" >&2
  exit 1
fi

if [ "$(command sqlite3 -batch -noheader -list -init /dev/null "$CCS_HOME/cc-switch.db" "SELECT json_extract(settings_config,'$.env.ANTHROPIC_DEFAULT_SONNET_MODEL') FROM providers WHERE id='test' AND app_type='claude';")" != qwen3.7-max ]; then
  print -u2 'fresh provider Sonnet slot was not synchronized'
  exit 1
fi

fallback_capture="$test_root/fallback-env.txt"
fallback_expected="$test_root/fallback-expected.txt"
export CCS_TEST_CAPTURE="$fallback_capture"
claude-ccs fallback --version
cat >"$fallback_expected" <<'EOF'
ANTHROPIC_MODEL=deepseek-v4-flash[1m]
ANTHROPIC_DEFAULT_OPUS_MODEL=deepseek-v4-flash[1m]
ANTHROPIC_DEFAULT_SONNET_MODEL=deepseek-v4-flash[1m]
ANTHROPIC_DEFAULT_HAIKU_MODEL=deepseek-v4-flash[1m]
CLAUDE_CODE_AUTO_MODE_MODEL=<unset>
EOF
if ! cmp -s "$fallback_expected" "$fallback_capture"; then
  diff -u "$fallback_expected" "$fallback_capture"
  exit 1
fi
fallback_add=$(grep -F $'\t--id\tfallback\t' "$cc_switch_log")
if print -r -- "$fallback_add" | grep -F -- '--sonnet-model' >/dev/null; then
  print -u2 'provider without classifier-model unexpectedly configured a Sonnet slot'
  exit 1
fi

whitespace_capture="$test_root/whitespace-env.txt"
export CCS_TEST_CAPTURE="$whitespace_capture"
claude-ccs whitespace --version
if ! cmp -s "$fallback_expected" "$whitespace_capture"; then
  diff -u "$fallback_expected" "$whitespace_capture"
  exit 1
fi
whitespace_add=$(grep -F $'\t--id\twhitespace\t' "$cc_switch_log")
if print -r -- "$whitespace_add" | grep -F -- '--sonnet-model' >/dev/null; then
  print -u2 'whitespace classifier-model unexpectedly configured a Sonnet slot'
  exit 1
fi

trimmed_capture="$test_root/trimmed-env.txt"
export CCS_TEST_CAPTURE="$trimmed_capture"
claude-ccs trimmed --version
if ! cmp -s "$expected" "$trimmed_capture"; then
  diff -u "$expected" "$trimmed_capture"
  exit 1
fi
trimmed_add=$(grep -F $'\t--id\ttrimmed\t' "$cc_switch_log")
if ! print -r -- "$trimmed_add" | grep -F -- $'--sonnet-model\tqwen3.7-max' >/dev/null; then
  print -u2 'classifier-model was not trimmed before provider creation'
  exit 1
fi

classifier_only_capture="$test_root/classifier-only-env.txt"
classifier_only_expected="$test_root/classifier-only-expected.txt"
export CCS_TEST_CAPTURE="$classifier_only_capture"
claude-ccs classifier-only --version
cat >"$classifier_only_expected" <<'EOF'
ANTHROPIC_MODEL=<unset>
ANTHROPIC_DEFAULT_OPUS_MODEL=<unset>
ANTHROPIC_DEFAULT_SONNET_MODEL=claude-sonnet-5
ANTHROPIC_DEFAULT_HAIKU_MODEL=<unset>
CLAUDE_CODE_AUTO_MODE_MODEL=<unset>
EOF
if ! cmp -s "$classifier_only_expected" "$classifier_only_capture"; then
  diff -u "$classifier_only_expected" "$classifier_only_capture"
  exit 1
fi
classifier_only_add=$(grep -F $'\t--id\tclassifier-only\t' "$cc_switch_log")
if print -r -- "$classifier_only_add" | grep -F -- $'--model\t' >/dev/null; then
  print -u2 'classifier-only provider unexpectedly configured a default model'
  exit 1
fi
if ! print -r -- "$classifier_only_add" | grep -F -- $'--sonnet-model\tqwen3.7-max' >/dev/null; then
  print -u2 'classifier-only provider did not configure its Sonnet slot'
  exit 1
fi

existing_capture="$test_root/existing-env.txt"
export CCS_TEST_CAPTURE="$existing_capture"
claude-ccs existing --version
if ! cmp -s "$expected" "$existing_capture"; then
  diff -u "$expected" "$existing_capture"
  exit 1
fi
if grep -F $'\t--id\texisting\t' "$cc_switch_log" >/dev/null; then
  print -u2 'existing provider was unexpectedly recreated'
  exit 1
fi
if [ "$(command sqlite3 -batch -noheader -list -init /dev/null "$CCS_HOME/cc-switch.db" "SELECT json_extract(settings_config,'$.env.ANTHROPIC_DEFAULT_SONNET_MODEL') FROM providers WHERE id='existing' AND app_type='claude';")" != qwen3.7-max ]; then
  print -u2 'existing provider Sonnet slot was not synchronized'
  exit 1
fi

display_capture="$test_root/display-name-env.txt"
export CCS_TEST_CAPTURE="$display_capture"
claude-ccs display-name --version
if ! cmp -s "$expected" "$display_capture"; then
  diff -u "$expected" "$display_capture"
  exit 1
fi
if [ "$(command sqlite3 -batch -noheader -list -init /dev/null "$CCS_HOME/cc-switch.db" "SELECT json_extract(settings_config,'$.env.ANTHROPIC_DEFAULT_SONNET_MODEL') FROM providers WHERE id='actual-id' AND app_type='claude';")" != qwen3.7-max ]; then
  print -u2 'display-name switch did not synchronize the resolved provider id'
  exit 1
fi

for failure_name in sync-miss add-failure switch-failure; do
  failure_capture="$test_root/$failure_name-env.txt"
  rm -f -- "$failure_capture"
  export CCS_TEST_CAPTURE="$failure_capture"
  if claude-ccs "$failure_name" --version 2>/dev/null; then
    print -u2 "$failure_name unexpectedly launched Claude"
    exit 1
  fi
  if [ -e "$failure_capture" ]; then
    print -u2 "$failure_name invoked Claude after provider setup failed"
    exit 1
  fi
done

multi_capture="$test_root/multi-current-env.txt"
rm -f -- "$multi_capture"
export CCS_TEST_CAPTURE="$multi_capture"
if claude-ccs multi-current --version 2>/dev/null; then
  print -u2 'multi-current unexpectedly launched Claude'
  exit 1
fi
if [ -e "$multi_capture" ]; then
  print -u2 'multi-current invoked Claude after ambiguous provider selection'
  exit 1
fi
multi_changed=$(command sqlite3 -batch -noheader -list -init /dev/null "$CCS_HOME/cc-switch.db" \
  "SELECT count(*) FROM providers WHERE id IN ('multi-current','multi-current-row') AND (meta <> '{}' OR json_extract(settings_config,'$.env.ANTHROPIC_DEFAULT_SONNET_MODEL') IS NOT NULL);")
if [ "$multi_changed" != 0 ]; then
  print -u2 'ambiguous provider synchronization modified rows before aborting'
  exit 1
fi

print 'claude-ccs launcher classifier role: ok'
