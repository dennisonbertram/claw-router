#!/usr/bin/env bash
# common.sh — shared helpers for claude-router (cr).
# Sourced by `cr` and by the test harness. No side effects on source beyond
# defining functions and the CR_HOME/CONFIG path vars.

# --- Paths ---------------------------------------------------------------
: "${CR_HOME:=${HOME}/.claude-router}"
CR_CONFIG="${CR_HOME}/config.json"
CR_ACCOUNTS_DIR="${CR_HOME}/accounts"
CR_LOG="${CR_HOME}/logs/route.log"

# Production Claude Code OAuth client id (public; used for token refresh).
CR_OAUTH_CLIENT_ID="9d1c250a-e61b-44d9-88ed-5944d1962f5e"
CR_TOKEN_URL="https://platform.claude.com/v1/oauth/token"
CR_USAGE_URL="https://api.anthropic.com/api/oauth/usage"
CR_OAUTH_BETA="oauth-2025-04-20"

# Paths shared (symlinked) from ~/.claude into each account dir at onboarding.
CR_SHARE_PATHS=(settings.json CLAUDE.md commands rules)

# --- Output --------------------------------------------------------------
# All diagnostic output goes to stderr so `cr -p` stdout stays pipeable.
cr_say()  { printf '%s\n' "$*" >&2; }
cr_warn() { printf 'cr: %s\n' "$*" >&2; }
cr_die()  { printf 'cr: %s\n' "$*" >&2; exit 1; }

cr_have() { command -v "$1" >/dev/null 2>&1; }

cr_require_deps() {
  local missing=()
  local t
  for t in jq; do cr_have "$t" || missing+=("$t"); done
  if ((${#missing[@]})); then
    cr_die "missing required tools: ${missing[*]} (install them and retry)"
  fi
}

# --- Path expansion ------------------------------------------------------
# Expand a leading ~ to $HOME. Returns the path unchanged otherwise.
cr_expand() {
  local p="$1"
  case "$p" in
    "~") printf '%s' "$HOME" ;;
    "~/"*) printf '%s' "${HOME}/${p#\~/}" ;;
    *) printf '%s' "$p" ;;
  esac
}

# --- Config / registry ---------------------------------------------------
cr_default_config='{
  "selection": "round-robin",
  "accounts": [],
  "rotation": { "cursor": 0 },
  "share": { "settings.json": true, "CLAUDE.md": true, "commands": true, "rules": true }
}'

cr_ensure_home() {
  mkdir -p "$CR_HOME" "$CR_ACCOUNTS_DIR" "$(dirname "$CR_LOG")"
  if [[ ! -f "$CR_CONFIG" ]]; then
    printf '%s\n' "$cr_default_config" > "$CR_CONFIG"
  fi
}

# Read whole config to stdout.
cr_config_read() {
  if [[ -f "$CR_CONFIG" ]]; then cat "$CR_CONFIG"; else printf '%s\n' "$cr_default_config"; fi
}

# Atomically write stdin as the new config (validated as JSON first).
cr_config_write() {
  local tmp
  tmp="$(mktemp "${CR_CONFIG}.XXXXXX")" || cr_die "mktemp failed"
  cat > "$tmp"
  if ! jq empty "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    cr_die "refusing to write invalid JSON config"
  fi
  mv -f "$tmp" "$CR_CONFIG"
}

# Apply a jq program (arg 1) to the config and persist the result atomically.
# Extra args are forwarded to jq (e.g. --arg name foo).
cr_config_update() {
  local prog="$1"; shift
  local current updated
  current="$(cr_config_read)"
  updated="$(printf '%s' "$current" | jq "$@" "$prog")" || cr_die "config update failed"
  printf '%s' "$updated" | cr_config_write
}

# --- Account helpers -----------------------------------------------------
# Echo the absolute config dir for an account name, or empty for the
# null-configDir (default) account. Exits nonzero if the account is unknown.
cr_account_dir() {
  local name="$1" dir
  dir="$(cr_config_read | jq -r --arg n "$name" '
    .accounts[] | select(.name==$n) | (.configDir // "null")')"
  [[ -z "$dir" ]] && return 1
  if [[ "$dir" == "null" ]]; then printf ''; return 0; fi
  cr_expand "$dir"
}

cr_account_exists() {
  cr_config_read | jq -e --arg n "$1" '.accounts | any(.name==$n)' >/dev/null 2>&1
}

# Echo an account's kind: "subscription" (default) or "backend".
cr_account_kind() {
  cr_config_read | jq -r --arg n "$1" '
    .accounts[] | select(.name==$n) | (.kind // "subscription")'
}

# List enabled *subscription* account names — the pool that rotation draws from.
# Backends are excluded by design: they are an inferior fallback, reached only
# by explicit `cr --account <name>` / `cr@<name>`.
cr_enabled_accounts() {
  cr_config_read | jq -r '.accounts[]
    | select(.enabled != false)
    | select((.kind // "subscription") == "subscription")
    | .name'
}

# Keychain service under which cr stores its own backend API keys.
CR_BACKEND_KEYCHAIN_SVC="claude-router-backend"

# Read a backend account's API key from cr's keychain item (macOS) or, as a
# fallback, from a plaintext key cached in the registry. Echoes the key.
cr_backend_key() {
  local name="$1" key
  if cr_have security; then
    key="$(security find-generic-password -s "$CR_BACKEND_KEYCHAIN_SVC" -a "$name" -w 2>/dev/null)" || key=""
    [[ -n "$key" ]] && { printf '%s' "$key"; return 0; }
  fi
  key="$(cr_config_read | jq -r --arg n "$name" '.accounts[]|select(.name==$n)|.apiKey // empty')"
  [[ -n "$key" ]] && { printf '%s' "$key"; return 0; }
  return 1
}

# --- Keychain service name (mirrors Claude Code's own derivation) ---------
# No CLAUDE_CONFIG_DIR  -> "Claude Code-credentials"
# CLAUDE_CONFIG_DIR=dir -> "Claude Code-credentials-<sha256(NFC(dir))[0:8]>"
cr_keychain_service() {
  local dir="$1"  # absolute config dir, or empty for default
  if [[ -z "$dir" ]]; then
    printf 'Claude Code-credentials'
    return 0
  fi
  local nfc hash
  if cr_have python3; then
    nfc="$(printf '%s' "$dir" | python3 -c 'import sys,unicodedata; sys.stdout.write(unicodedata.normalize("NFC", sys.stdin.read()))')"
  else
    nfc="$dir"
  fi
  hash="$(printf '%s' "$nfc" | shasum -a 256 | cut -c1-8)"
  printf 'Claude Code-credentials-%s' "$hash"
}

# Does the Keychain hold a credential for this config dir? (macOS only)
cr_keychain_present() {
  local dir="$1" svc
  cr_have security || return 2
  svc="$(cr_keychain_service "$dir")"
  security find-generic-password -s "$svc" -a "${USER:-$(id -un)}" >/dev/null 2>&1
}

# --- Selection -----------------------------------------------------------
# These read the registry and return an account name on stdout. They are the
# unit-tested core of the router.

# round-robin: advance cursor over enabled accounts, persist, return chosen.
cr_select_round_robin() {
  local -a enabled
  while IFS= read -r line; do enabled+=("$line"); done < <(cr_enabled_accounts)
  local n=${#enabled[@]}
  ((n == 0)) && return 1
  local cursor
  cursor="$(cr_config_read | jq -r '.rotation.cursor // 0')"
  local idx=$(( cursor % n ))
  local next=$(( (idx + 1) % n ))
  cr_config_update '.rotation.cursor = ($c|tonumber)' --arg c "$next" >/dev/null
  printf '%s' "${enabled[$idx]}"
}

# lru: enabled account with smallest lastUsed (ties -> registry order).
cr_select_lru() {
  cr_config_read | jq -r '
    [.accounts[] | select(.enabled != false)]
    | sort_by(.lastUsed // 0)
    | .[0].name // empty'
}

# random: a uniformly random enabled account.
cr_select_random() {
  local -a enabled
  while IFS= read -r line; do enabled+=("$line"); done < <(cr_enabled_accounts)
  local n=${#enabled[@]}
  ((n == 0)) && return 1
  printf '%s' "${enabled[$(( RANDOM % n ))]}"
}

# usage-aware: pick enabled account with most remaining headroom from the
# cached usage figure (.usagePct, lower = more free). Falls back to lru.
cr_select_usage_aware() {
  local name
  name="$(cr_config_read | jq -r '
    [.accounts[] | select(.enabled != false) | select(.usagePct != null)]
    | sort_by(.usagePct) | .[0].name // empty')"
  if [[ -n "$name" ]]; then printf '%s' "$name"; else cr_select_lru; fi
}

# Dispatch on a policy name. Echoes chosen account.
cr_select() {
  local policy="$1"
  case "$policy" in
    round-robin) cr_select_round_robin ;;
    lru)         cr_select_lru ;;
    random)      cr_select_random ;;
    usage-aware) cr_select_usage_aware ;;
    *) return 2 ;;
  esac
}

# Stamp lastUsed=now (ms) for an account.
cr_mark_used() {
  local name="$1" now_ms
  now_ms="$(( $(date +%s) * 1000 ))"
  cr_config_update '(.accounts[] | select(.name==$n) | .lastUsed) = ($t|tonumber)' \
    --arg n "$name" --arg t "$now_ms" >/dev/null
}
