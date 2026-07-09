#!/usr/bin/env bash
# common.sh — shared helpers for Claw Router (cr).
# Sourced by `cr` and by the test harness. No side effects on source beyond
# defining functions and the CR_HOME/CONFIG path vars.

# --- Paths ---------------------------------------------------------------
# Data dir: prefer the new ~/.claw-router, but keep using a pre-existing
# ~/.claude-router so we never orphan accounts (each account's Keychain login is
# keyed off the absolute path of its config dir — moving it would break logins).
if [[ -z "${CR_HOME:-}" ]]; then
  if [[ -d "${HOME}/.claude-router" && ! -d "${HOME}/.claw-router" ]]; then
    CR_HOME="${HOME}/.claude-router"   # legacy install — leave it in place
  else
    CR_HOME="${HOME}/.claw-router"     # fresh install
  fi
fi
CR_CONFIG="${CR_HOME}/config.json"
CR_ACCOUNTS_DIR="${CR_HOME}/accounts"
CR_LOG="${CR_HOME}/logs/route.log"

# Production Claude Code OAuth client id (public; used for token refresh).
CR_OAUTH_CLIENT_ID="9d1c250a-e61b-44d9-88ed-5944d1962f5e"
CR_TOKEN_URL="https://platform.claude.com/v1/oauth/token"
CR_USAGE_URL="https://api.anthropic.com/api/oauth/usage"
CR_OAUTH_BETA="oauth-2025-04-20"

# Paths shared (symlinked) from the user's ~/.claude into each account dir.
# skills/agents/hooks/workflows/plugins carry the user's full extension environment.
CR_SHARE_PATHS=(settings.json CLAUDE.md commands rules skills agents hooks workflows plugins)

# Source locations for sharing (override in tests via env vars).
CR_CLAUDE_HOME="${CR_CLAUDE_HOME:-$HOME/.claude}"       # dir the share paths come from
CR_CLAUDE_JSON="${CR_CLAUDE_JSON:-$HOME/.claude.json}"  # default account's config file (mcpServers source)

# --- Color palette -------------------------------------------------------
# Enabled only when stderr is a TTY and NO_COLOR is unset (https://no-color.org).
# Every name is always defined (empty when disabled) so callers never break.
if [[ -t 2 && -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]; then
  C_RESET=$'\033[0m';  C_DIM=$'\033[2m';    C_BOLD=$'\033[1m'
  C_RED=$'\033[31m';   C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m';  C_MAGENTA=$'\033[35m'; C_CYAN=$'\033[36m'
  C_GREY=$'\033[90m'
else
  C_RESET='' C_DIM='' C_BOLD='' C_RED='' C_GREEN='' C_YELLOW='' \
  C_BLUE='' C_MAGENTA='' C_CYAN='' C_GREY=''
fi
# Accent used for the brand mark / arrows.
C_ACCENT="$C_MAGENTA"

# --- Output --------------------------------------------------------------
# All diagnostic output goes to stderr so `cr -p` stdout stays pipeable.
cr_say()  { printf '%s\n' "$*" >&2; }
cr_warn() { printf '%scr%s %s%s\n' "$C_YELLOW" "$C_RESET" "$*" "" >&2; }
cr_die()  { printf '%scr%s %s%s\n' "$C_RED" "$C_RESET" "$*" "" >&2; exit 1; }

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
  "providers": {
    "codex": { "selection": "round-robin", "rotation": { "cursor": 0 } }
  },
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

# Portable mkdir-based config lock. macOS ships Bash 3.2 without flock, so the
# lock is an atomic directory with a pid marker. A dead owner's lock is removed;
# live writers wait for at most ~10 seconds rather than silently racing.
cr_config_lock_acquire() {
  local lock="${CR_CONFIG}.lock" tries=0 owner=""
  while ! mkdir "$lock" 2>/dev/null; do
    if [[ -f "$lock/pid" ]]; then
      owner="$(cat "$lock/pid" 2>/dev/null || true)"
      if [[ -n "$owner" ]] && ! kill -0 "$owner" 2>/dev/null; then
        rm -rf "$lock" 2>/dev/null || true
        continue
      fi
    fi
    tries=$(( tries + 1 ))
    (( tries >= 200 )) && cr_die "timed out waiting for config lock: $lock"
    sleep 0.05
  done
  printf '%s\n' "$$" > "$lock/pid"
  CR_CONFIG_LOCK_HELD="$lock"
}

cr_config_lock_release() {
  local lock="${CR_CONFIG_LOCK_HELD:-}"
  [[ -n "$lock" ]] && rm -rf "$lock" 2>/dev/null || true
  CR_CONFIG_LOCK_HELD=""
}

# Apply a jq program (arg 1) to the config and persist the result atomically.
# Extra args are forwarded to jq (e.g. --arg name foo).
cr_config_update() {
  local prog="$1"; shift
  local current updated rc=0
  cr_ensure_home
  cr_config_lock_acquire
  current="$(cr_config_read)"
  if ! updated="$(printf '%s' "$current" | jq "$@" "$prog")"; then
    cr_config_lock_release
    cr_die "config update failed"
  fi
  printf '%s' "$updated" | cr_config_write || rc=$?
  cr_config_lock_release
  return "$rc"
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

# Account provider. Existing registries predate providers, so a missing value
# is always Claude. Provider names are intentionally a closed set.
cr_account_provider() {
  cr_config_read | jq -r --arg n "$1" '
    .accounts[] | select(.name==$n) | (.provider // "claude")'
}

cr_validate_provider() {
  case "${1:-}" in claude|codex) return 0 ;; *) return 1 ;; esac
}

# Provider-scoped policy / pin / cursor. Claude keeps using the legacy top-level
# fields so existing configs, scripts, and status consumers remain compatible.
cr_provider_selection() {
  local provider="${1:-claude}"
  if [[ "$provider" == "claude" ]]; then
    cr_config_read | jq -r '.selection // "round-robin"'
  else
    cr_config_read | jq -r --arg p "$provider" '.providers[$p].selection // "round-robin"'
  fi
}

cr_provider_pinned() {
  local provider="${1:-claude}"
  if [[ "$provider" == "claude" ]]; then
    cr_config_read | jq -r '.defaultAccount // empty'
  else
    cr_config_read | jq -r --arg p "$provider" '.providers[$p].defaultAccount // empty'
  fi
}

cr_provider_cursor() {
  local provider="${1:-claude}"
  if [[ "$provider" == "claude" ]]; then
    cr_config_read | jq -r '.rotation.cursor // 0'
  else
    cr_config_read | jq -r --arg p "$provider" '.providers[$p].rotation.cursor // 0'
  fi
}

cr_provider_set_cursor() {
  local provider="$1" cursor="$2"
  if [[ "$provider" == "claude" ]]; then
    cr_config_update '.rotation.cursor = ($c|tonumber)' --arg c "$cursor" >/dev/null
  else
    cr_config_update '
      .providers = (.providers // {})
      | .providers[$p] = (.providers[$p] // {})
      | .providers[$p].rotation = (.providers[$p].rotation // {})
      | .providers[$p].rotation.cursor = ($c|tonumber)' \
      --arg p "$provider" --arg c "$cursor" >/dev/null
  fi
}

# Echo an account's kind: "subscription" (default), "backend", or "api".
cr_account_kind() {
  cr_config_read | jq -r --arg n "$1" '
    .accounts[] | select(.name==$n) | (.kind // "subscription")'
}

# List enabled *subscription-only* account names — used for usage polling.
# api accounts have no OAuth usage endpoint; backends are explicit-only.
cr_subscription_accounts() {
  local provider="${1:-${CR_PROVIDER:-claude}}"
  cr_config_read | jq -r --arg p "$provider" '.accounts[]
    | select((.provider // "claude") == $p)
    | select(.enabled != false)
    | select((.kind // "subscription") == "subscription")
    | .name'
}

# List enabled accounts in the rotation pool: subscriptions + api accounts
# with .rotate==true. Backends are always excluded (explicit-only).
# api accounts with rotate==false (the safety default) are also excluded.
cr_enabled_accounts() {
  local provider="${1:-${CR_PROVIDER:-claude}}"
  cr_config_read | jq -r --arg p "$provider" '.accounts[]
    | select((.provider // "claude") == $p)
    | select(.enabled != false)
    | select(
        ((.kind // "subscription") == "subscription")
        or ((.kind == "api") and (.rotate == true))
      )
    | .name'
}

# Keychain service under which cr stores its own backend API keys.
CR_BACKEND_KEYCHAIN_SVC="claw-router-backend"

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

# An account counts as "exhausted" when its cached usagePct is at/above this
# threshold. Override per-config with .exhaustedAtPct. Accounts with NO cached
# usage are treated as available (unknown ≠ exhausted).
cr_exhausted_threshold() {
  cr_config_read | jq -r '.exhaustedAtPct // 100'
}

# Enabled accounts (subscriptions + rotate=true api accounts) that are NOT out
# of usage (per cached usagePct). This is the pool round-robin / lru / random
# actually draw from. If EVERY account is exhausted, this prints nothing —
# callers fall back to all enabled rather than hard-failing.
# api accounts have usagePct=null (pay-per-token) → always count as available.
cr_available_accounts() {
  local provider="${1:-${CR_PROVIDER:-claude}}" thr; thr="$(cr_exhausted_threshold)"
  cr_config_read | jq -r --arg p "$provider" --argjson t "$thr" '
    .accounts[]
    | select((.provider // "claude") == $p)
    | select(.enabled != false)
    | select(
        ((.kind // "subscription") == "subscription")
        or ((.kind == "api") and (.rotate == true))
      )
    | select((.usagePct == null) or (.usagePct < $t))
    | .name'
}

# Echo the available pool, or fall back to all enabled if none are available.
# Also sets CR_POOL_FELL_BACK=1 when it had to fall back (all exhausted).
cr_selection_pool() {
  local provider="${1:-${CR_PROVIDER:-claude}}"
  CR_POOL_FELL_BACK=0
  local out; out="$(cr_available_accounts "$provider")"
  if [[ -z "$out" ]]; then CR_POOL_FELL_BACK=1; cr_enabled_accounts "$provider"; else printf '%s\n' "$out"; fi
}

# round-robin: advance cursor over the available pool, persist, return chosen.
cr_select_round_robin() {
  local provider="${1:-${CR_PROVIDER:-claude}}"
  local -a pool
  while IFS= read -r line; do [[ -n "$line" ]] && pool+=("$line"); done < <(cr_selection_pool "$provider")
  local n=${#pool[@]}
  ((n == 0)) && return 1
  local cursor
  cursor="$(cr_provider_cursor "$provider")"
  local idx=$(( cursor % n ))
  local next=$(( (idx + 1) % n ))
  cr_provider_set_cursor "$provider" "$next"
  printf '%s' "${pool[$idx]}"
}

# lru: account in the available pool with the smallest lastUsed.
cr_select_lru() {
  local provider="${1:-${CR_PROVIDER:-claude}}"
  local -a pool
  while IFS= read -r line; do [[ -n "$line" ]] && pool+=("$line"); done < <(cr_selection_pool "$provider")
  ((${#pool[@]} == 0)) && return 1
  # Build a jq filter restricting to the pool, then pick min lastUsed.
  local names_json; names_json="$(printf '%s\n' "${pool[@]}" | jq -R . | jq -cs .)"
  cr_config_read | jq -r --argjson pool "$names_json" '
    [.accounts[] | select(.name as $n | $pool | index($n))]
    | sort_by(.lastUsed // 0) | .[0].name // empty'
}

# random: a uniformly random account from the available pool.
cr_select_random() {
  local provider="${1:-${CR_PROVIDER:-claude}}"
  local -a pool
  while IFS= read -r line; do [[ -n "$line" ]] && pool+=("$line"); done < <(cr_selection_pool "$provider")
  local n=${#pool[@]}
  ((n == 0)) && return 1
  printf '%s' "${pool[$(( RANDOM % n ))]}"
}

# usage-aware: pick the rotation-pool account with most remaining headroom from
# the cached usage figure (.usagePct, lower = more free). Draws from the same
# rotation pool as round-robin/lru/random (subscriptions + rotate=true api
# accounts; backends and rotate=false api accounts are never considered).
# Falls back to lru when no rotation-pool account has a cached usagePct.
cr_select_usage_aware() {
  local provider="${1:-${CR_PROVIDER:-claude}}" name
  name="$(cr_config_read | jq -r --arg p "$provider" '
    [.accounts[]
     | select((.provider // "claude") == $p)
     | select(.enabled != false)
     | select(((.kind // "subscription") == "subscription") or ((.kind == "api") and (.rotate == true)))
     | select(.usagePct != null)]
    | sort_by(.usagePct) | .[0].name // empty')"
  if [[ -n "$name" ]]; then printf '%s' "$name"; else cr_select_lru "$provider"; fi
}

# Dispatch on a policy name. Echoes chosen account.
cr_select() {
  local policy="$1" provider="${2:-${CR_PROVIDER:-claude}}"
  case "$policy" in
    round-robin) cr_select_round_robin "$provider" ;;
    lru)         cr_select_lru "$provider" ;;
    random)      cr_select_random "$provider" ;;
    usage-aware) cr_select_usage_aware "$provider" ;;
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

# --- Sharing helpers --------------------------------------------------------

# cr_link_shared_paths <account_dir>
# Idempotent: symlink every CR_SHARE_PATHS entry from CR_CLAUDE_HOME into
# <account_dir>. If a real file/dir occupies the destination it is backed up as
# <name>.bak.<epoch>[.<counter>] before the symlink is created. Only rm a stale
# symlink — never rm a real path. Skips any source that doesn't exist (no dangling
# links). Reports linked/backed-up counts via cr_say.
cr_link_shared_paths() {
  local account_dir="$1"
  local p src dst linked=0 backed=0 ts counter bak

  ts="$(date +%s)"

  for p in "${CR_SHARE_PATHS[@]}"; do
    src="${CR_CLAUDE_HOME}/${p}"

    # Skip entirely if the source doesn't exist — don't create a dangling link.
    if [[ ! -e "$src" ]]; then
      # If a stale symlink already points at this missing source, remove it.
      dst="${account_dir}/${p}"
      if [[ -L "$dst" && "$(readlink "$dst")" == "$src" ]]; then
        rm -f "$dst" || cr_warn "could not remove stale symlink: $dst"
      fi
      continue
    fi

    dst="${account_dir}/${p}"

    # Already correct — skip (idempotent).
    if [[ -L "$dst" && "$(readlink "$dst")" == "$src" ]]; then
      continue
    fi

    # Something exists at dst that is NOT the right symlink.
    if [[ -e "$dst" || -L "$dst" ]]; then
      if [[ -L "$dst" ]]; then
        # Stale symlink pointing somewhere else — safe to remove.
        rm -f "$dst" || { cr_warn "could not remove stale symlink: $dst"; continue; }
      else
        # Real file or directory — back it up, never rm.
        bak="${dst}.bak.${ts}"
        counter=1
        while [[ -e "$bak" ]]; do
          bak="${dst}.bak.${ts}.${counter}"
          counter=$(( counter + 1 ))
        done
        if mv "$dst" "$bak"; then
          cr_say "  backed up: ${p} → $(basename "$bak")"
          backed=$(( backed + 1 ))
        else
          cr_warn "could not back up $dst — skipping $p"
          continue
        fi
      fi
    fi

    if ln -s "$src" "$dst" 2>/dev/null; then
      linked=$(( linked + 1 ))
    else
      cr_warn "could not symlink $p into $(basename "$account_dir")"
    fi
  done

  local backed_note=""; [[ "$backed" -gt 0 ]] && backed_note=", backed up ${backed}"
  cr_say "  shared: linked ${linked} path(s)${backed_note} in $(basename "$account_dir")"
}

# cr_merge_account_mcp <account_name>
# Surgically merges .mcpServers from CR_CLAUDE_JSON into the account's .claude.json,
# with the shared source winning on key conflicts. Identity (oauthAccount) and all
# other keys are untouched. Atomic: writes to a temp file in the same dir, validates
# JSON, then mv -f. Safe to call multiple times (idempotent merge).
cr_merge_account_mcp() {
  local name="$1"
  local dir acct_json src tmp n

  dir="$(cr_account_dir "$name" 2>/dev/null || true)"

  # Skip the null-configDir (default) account — it IS the source.
  if [[ -z "$dir" ]]; then return 0; fi

  # Skip backends — they have no .claude.json of their own.
  local kind; kind="$(cr_account_kind "$name" 2>/dev/null || true)"
  if [[ "$kind" == "backend" ]]; then return 0; fi

  acct_json="${dir}/.claude.json"
  if [[ ! -f "$acct_json" ]]; then return 0; fi

  # Read shared mcpServers from the source config.
  src="$(jq -c '.mcpServers // {}' "$CR_CLAUDE_JSON" 2>/dev/null || echo '{}')"
  if [[ -z "$src" || "$src" == '{}' ]]; then return 0; fi

  n="$(printf '%s' "$src" | jq 'keys|length' 2>/dev/null || echo 0)"

  # Merge: account-only servers preserved, source wins on conflicts.
  tmp="$(mktemp "${acct_json}.XXXXXX")" || { cr_warn "mktemp failed for $name mcp merge"; return 1; }
  if jq --argjson shared "$src" '.mcpServers = ((.mcpServers // {}) * $shared)' \
       "$acct_json" > "$tmp" 2>/dev/null; then
    if jq empty "$tmp" 2>/dev/null; then
      mv -f "$tmp" "$acct_json" || { cr_warn "could not replace $acct_json after mcp merge"; rm -f "$tmp"; return 1; }
      cr_say "  merged ${n} mcp server(s) into '${name}' (source wins on conflicts; identity preserved)"
    else
      cr_warn "mcp merge produced invalid JSON for '$name' — leaving .claude.json untouched"
      rm -f "$tmp"
    fi
  else
    cr_warn "jq failed merging mcp servers for '$name' — leaving .claude.json untouched"
    rm -f "$tmp"
  fi
}

# cr_relink_account <name>
# Run cr_link_shared_paths + cr_merge_account_mcp for a single account.
# Skips the null-configDir default account and backends with a friendly note.
cr_relink_account() {
  local name="$1"
  local dir kind

  dir="$(cr_account_dir "$name" 2>/dev/null || true)"
  kind="$(cr_account_kind "$name" 2>/dev/null || true)"

  if [[ -z "$dir" ]]; then
    cr_say "  skip '$name': null configDir (this IS the default ~/.claude environment)"
    return 0
  fi
  if [[ "$kind" == "backend" ]]; then
    cr_say "  skip '$name': backend accounts have no config dir to share into"
    return 0
  fi

  cr_say "relink '$name' (${dir}):"
  cr_link_shared_paths "$dir"
  cr_merge_account_mcp "$name"
}
