#!/usr/bin/env bash
# cr — Claw Router 🦞. Pick one of your Claude subscriptions and launch Claude
# Code under it, spreading usage so it lasts longer.
#
#   cr [claude args...]          route per policy, then exec claude
#   cr --account <name> [...]    force an account
#   cr@<name> [...]              shorthand for --account <name>
#
# Management subcommands (NOT passed to claude):
#   cr add <name>      cr login <name>   cr logout <name>   cr remove <name>
#   cr list|accounts   cr use <name>     cr policy <p>      cr usage [name]
#   cr status          cr doctor [name]  cr help
set -euo pipefail

# Resolve our own dir so we can source lib/ regardless of symlink/cwd.
_cr_self="${BASH_SOURCE[0]}"
while [[ -h "$_cr_self" ]]; do
  _cr_dir="$(cd -P "$(dirname "$_cr_self")" >/dev/null 2>&1 && pwd)"
  _cr_self="$(readlink "$_cr_self")"; [[ "$_cr_self" != /* ]] && _cr_self="$_cr_dir/$_cr_self"
done
CR_DIR="$(cd -P "$(dirname "$_cr_self")" >/dev/null 2>&1 && pwd)"
# shellcheck source=lib/common.sh
source "${CR_DIR}/lib/common.sh"
# shellcheck source=lib/usage.sh
source "${CR_DIR}/lib/usage.sh"
# shellcheck source=lib/watch.sh
source "${CR_DIR}/lib/watch.sh"

# Env that would override subscription OAuth (see precedence in PLAN.md §1.3).
CR_SCRUB_ENV=(ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN)

# ------------------------------------------------------------------------
# Launch hot path
# ------------------------------------------------------------------------

# Find the real `claude`, skipping ourselves if `cr` is symlinked as claude.
cr_find_claude() {
  local self_dir="$CR_DIR" d IFS=:
  for d in $PATH; do
    [[ "$d" == "$self_dir" ]] && continue
    if [[ -x "$d/claude" ]]; then printf '%s' "$d/claude"; return 0; fi
  done
  return 1
}

# Build the exec command for launching Claude Code, honoring sandbox mode.
# Sets the array CR_EXEC to the argv prefix; the caller appends claude args.
# In sandbox mode we run through `cco` (https://github.com/nikvdp/cco), which
# reads CLAUDE_CONFIG_DIR for both config and Keychain naming and forwards args
# after `--` straight to claude — so cr's per-account env carries into the box.
CR_EXEC=()
cr_build_exec() {
  CR_EXEC=()
  if [[ "${CR_SANDBOX:-0}" == 1 ]]; then
    local cco; cco="$(command -v cco 2>/dev/null || true)"
    if [[ -z "$cco" ]]; then
      cr_die "--sandbox needs 'cco' (not found). Install it:
    curl -fsSL https://raw.githubusercontent.com/nikvdp/cco/master/install.sh | bash
  then re-run, or drop --sandbox. See: https://github.com/nikvdp/cco"
    fi
    # `cco -- <claude args>` forces passthrough (cco's own -p is --packages).
    CR_EXEC=("$cco" "--")
  else
    local claude; claude="$(cr_find_claude)" || cr_die "could not find 'claude' on PATH"
    CR_EXEC=("$claude")
  fi
}

# Detect a resume/continue invocation so we don't rotate onto the wrong account.
# Echoes the kind on stdout: "resume <session-id>" | "resume" | "continue".
cr_args_resume_kind() {
  local i=1 a next
  for a in "$@"; do
    case "$a" in
      --continue|-c) printf 'continue'; return 0 ;;
      --resume)
        # The session id, if present, is the next argument.
        next="${@:$((i+1)):1}"
        if [[ -n "$next" && "$next" != -* ]]; then printf 'resume %s' "$next"
        else printf 'resume'; fi
        return 0 ;;
      --resume=*) printf 'resume %s' "${a#--resume=}"; return 0 ;;
    esac
    i=$((i+1))
  done
  return 1
}

# Given a session id, echo the name of the account that OWNS its transcript —
# i.e. holds the real file, not a symlink. A symlinked copy (from a prior
# auto-link) is explicitly NOT ownership, so we never chase our own links.
# Empty if no account holds a real transcript.
cr_account_owning_session() {
  local sid="$1" name dir base f
  [[ -z "$sid" ]] && return 1
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    dir="$(cr_account_dir "$name" 2>/dev/null || true)"
    base="${dir:-$HOME/.claude}"
    for f in "${base}"/projects/*/"${sid}".jsonl; do
      # Real file only: exists, is a regular file, and is NOT a symlink.
      if [[ -f "$f" && ! -L "$f" ]]; then printf '%s' "$name"; return 0; fi
    done
  done < <(cr_config_read | jq -r '.accounts[]|select((.kind//"subscription")=="subscription")|.name')
  return 1
}

cr_launch() {
  local forced="$1"; shift
  cr_ensure_home

  local policy account
  policy="$(cr_config_read | jq -r '.selection // "round-robin"')"

  if [[ -n "$forced" ]]; then
    cr_account_exists "$forced" || cr_die "unknown account: $forced (try: cr list)"
    account="$forced"
  else
    local n; n="$(cr_enabled_accounts | grep -c . || true)"
    if [[ "$n" -eq 0 ]]; then
      # No subscriptions to rotate. If a backend exists, name it in the hint.
      local be; be="$(cr_config_read | jq -r '[.accounts[]|select((.kind//"subscription")=="backend")][0].name // empty')"
      [[ -n "$be" ]] && cr_die "no subscription accounts to route. Use a backend explicitly: cr@$be ...  (or add one: cr add <name>)"
      cr_die "no accounts registered. Run: cr add <name>"
    fi
    # Keep usage fresh enough that "skip exhausted accounts" actually works.
    # Refreshes in the background only when the cache is stale (best-effort).
    [[ "$n" -gt 1 ]] && cr_refresh_usage_if_stale
    if [[ "$n" -eq 1 ]]; then
      account="$(cr_enabled_accounts | head -1)"
    else
      account="$(cr_select "$policy")" || cr_die "selection failed for policy '$policy'"
    fi
  fi

  # Resume/continue: make sure the chosen account can see the session. If another
  # account owns it, transparently symlink it in so the resume just works.
  local rkind sid; rkind="$(cr_args_resume_kind "$@" || true)"
  if [[ -n "$rkind" ]]; then
    sid="${rkind#resume }"; [[ "$rkind" == "$sid" ]] && sid=""   # set only for `resume <id>`
    if [[ -n "$sid" ]]; then
      if cr_link_session "$sid" "$account" >/dev/null 2>&1; then
        cr_say "${C_DIM}resume → linked session ${sid:0:8}… into '${account}'${C_RESET}"
      fi
      # exit 1 (no owner) or 2 (already owned) → nothing to link; let claude handle it.
    fi
  fi

  local kind; kind="$(cr_account_kind "$account")"
  cr_mark_used "$account"

  if [[ "$kind" == "backend" ]]; then
    if [[ "${CR_WATCH:-0}" == 1 ]]; then
      cr_warn "watch: backends have no usage data — running without watch"
    fi
    cr_launch_backend "$account" "$forced" "$@"
    return
  fi

  # --- subscription account ------------------------------------------------
  local dir; dir="$(cr_account_dir "$account")" || cr_die "cannot resolve dir for '$account'"

  # Identity for the banner (cached; no network).
  local email plan
  email="$(cr_config_read | jq -r --arg n "$account" '.accounts[]|select(.name==$n)|.email // "?"')"
  plan="$(cr_config_read  | jq -r --arg n "$account" '.accounts[]|select(.name==$n)|.plan  // "?"')"

  # Scrub overriding creds, set the account's config dir.
  local v; for v in "${CR_SCRUB_ENV[@]}"; do unset "$v"; done
  if [[ -n "$dir" ]]; then export CLAUDE_CONFIG_DIR="$dir"; else unset CLAUDE_CONFIG_DIR; fi

  printf '%s◆%s %s%s%s %s%s%s %s(%s)%s %s%s%s\n' \
    "$C_ACCENT" "$C_RESET" "$C_BOLD" "$account" "$C_RESET" \
    "$C_GREY" "$email" "$C_RESET" \
    "$C_GREY" "$plan" "$C_RESET" \
    "$C_DIM" "$([[ -n "$forced" ]] && echo "· forced" || echo "· $policy")" "$C_RESET" >&2
  printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$account" "${dir:-(default)}" >> "$CR_LOG" 2>/dev/null || true

  # --- watch mode bypasses -------------------------------------------------
  if [[ "${CR_WATCH:-0}" == 1 ]]; then
    # -p/--print is one-shot; no session to watch.
    local _warg
    for _warg in "$@"; do
      if [[ "$_warg" == "-p" || "$_warg" == "--print" ]]; then
        cr_warn "watch: -p/--print is one-shot — running without watch"
        CR_WATCH=0
        break
      fi
    done
  fi
  if [[ "${CR_WATCH:-0}" == 1 ]]; then
    local _naccts; _naccts="$(cr_enabled_accounts | grep -c . || true)"
    if [[ "$_naccts" -lt 2 ]]; then
      cr_warn "watch: only one account — nothing to hand off to"
      CR_WATCH=0
    fi
  fi
  if [[ "${CR_WATCH:-0}" == 1 ]]; then
    cr_watch_run "$account" "$policy" "$@"
    # cr_watch_run never returns (exits directly).
  fi

  cr_build_exec
  exec "${CR_EXEC[@]}" "$@"
}

# Launch a backend (alternate model endpoint, e.g. DeepSeek). Auth via env
# vars; HOME is left untouched so gh/keychain tools keep working.
cr_launch_backend() {
  local account="$1"; shift
  local forced="$1"; shift

  local baseurl model key
  baseurl="$(cr_config_read | jq -r --arg n "$account" '.accounts[]|select(.name==$n)|.baseUrl // empty')"
  model="$(cr_config_read   | jq -r --arg n "$account" '.accounts[]|select(.name==$n)|.model // empty')"
  [[ -z "$baseurl" ]] && cr_die "backend '$account' has no baseUrl configured"
  key="$(cr_backend_key "$account")" || cr_die "no API key for backend '$account' (set one: cr add-backend ...)"

  # Allow an inline `--model pro|flash|NAME` override before claude args.
  if [[ "${1:-}" == "--model" && -n "${2:-}" ]]; then
    case "$2" in pro) model="${model_pro:-$2}";; flash) model="${model_flash:-$2}";; *) model="$2";; esac
    # resolve aliases stored on the account
    local al; al="$(cr_config_read | jq -r --arg n "$account" --arg a "$2" \
      '.accounts[]|select(.name==$n)|.modelAliases[$a] // empty')"
    [[ -n "$al" ]] && model="$al"
    shift 2
  fi
  [[ "${1:-}" == "--" ]] && shift

  # Backend auth is via these env vars — set, don't scrub. Leave HOME alone.
  export ANTHROPIC_BASE_URL="$baseurl"
  export ANTHROPIC_AUTH_TOKEN="$key"
  export ANTHROPIC_API_KEY="$key"
  [[ -n "$model" ]] && export ANTHROPIC_MODEL="$model"
  unset CLAUDE_CONFIG_DIR

  printf '%s◆%s %s%s%s %s(backend %s)%s %smodel=%s%s %s· explicit%s\n' \
    "$C_YELLOW" "$C_RESET" "$C_BOLD" "$account" "$C_RESET" \
    "$C_GREY" "${baseurl##https://}" "$C_RESET" \
    "$C_GREY" "${model:-default}" "$C_RESET" \
    "$C_DIM" "$C_RESET" >&2
  printf '%s\t%s\tbackend:%s\n' "$(date -u +%FT%TZ)" "$account" "$baseurl" >> "$CR_LOG" 2>/dev/null || true

  cr_build_exec
  if [[ -n "$model" ]]; then exec "${CR_EXEC[@]}" --model "$model" "$@"; else exec "${CR_EXEC[@]}" "$@"; fi
}

# ------------------------------------------------------------------------
# Management subcommands
# ------------------------------------------------------------------------

cr_cmd_add() {
  local name="${1:-}"; [[ -z "$name" ]] && cr_die "usage: cr add <name>"
  cr_ensure_home
  if cr_account_exists "$name"; then cr_die "account '$name' already exists"; fi

  local dir="${CR_ACCOUNTS_DIR}/${name}"
  mkdir -p "$dir"

  # Symlink shared bits from ~/.claude so settings/commands aren't fragmented.
  local p src
  for p in "${CR_SHARE_PATHS[@]}"; do
    src="${HOME}/.claude/${p}"
    if [[ -e "$src" && ! -e "${dir}/${p}" ]]; then
      ln -s "$src" "${dir}/${p}" 2>/dev/null || cr_warn "could not symlink $p"
    fi
  done

  cr_say "Logging in for account '$name' (a browser window will open)…"
  local claude; claude="$(cr_find_claude)" || cr_die "could not find 'claude' on PATH"
  CLAUDE_CONFIG_DIR="$dir" "$claude" /login || cr_warn "login command returned nonzero"

  # Cache identity from the freshly written config.
  local email="" plan=""
  if [[ -f "${dir}/.claude.json" ]]; then
    email="$(jq -r '.oauthAccount.emailAddress // ""'    "${dir}/.claude.json" 2>/dev/null)"
    plan="$(jq -r  '.oauthAccount.organizationType // ""' "${dir}/.claude.json" 2>/dev/null)"
  fi

  cr_config_update '.accounts += [{
      name:$n, configDir:$d, email:$e, plan:$pl, lastUsed:0, enabled:true, usagePct:null }]' \
    --arg n "$name" --arg d "$dir" --arg e "$email" --arg pl "$plan"

  cr_say "Added account '$name'${email:+ ($email)}."
  cr_doctor "$name" || true
}

# Register a backend account (alternate model endpoint, e.g. DeepSeek).
# Backends are NEVER in rotation — reach them with: cr@<name> / cr --account <name>.
#   cr add-backend <name> [--base-url URL] [--model NAME]
#                         [--alias short=full ...] [--seed-from-deep-claude]
cr_cmd_add_backend() {
  local name="${1:-}"; shift || true
  [[ -z "$name" ]] && cr_die "usage: cr add-backend <name> [--base-url URL] [--model NAME] [--alias s=full] [--seed-from-deep-claude]"
  cr_ensure_home
  cr_account_exists "$name" && cr_die "account '$name' already exists"

  local baseurl="https://api.deepseek.com/anthropic" model="deepseek-v4-pro"
  local seed_dc=0 key=""
  local aliases='{"pro":"deepseek-v4-pro","flash":"deepseek-v4-flash"}'
  while (($#)); do
    case "$1" in
      --base-url) baseurl="${2:?--base-url needs a value}"; shift 2 ;;
      --model)    model="${2:?--model needs a value}"; shift 2 ;;
      --alias)    local kv="${2:?--alias needs short=full}"; shift 2
                  aliases="$(printf '%s' "$aliases" | jq --arg k "${kv%%=*}" --arg v "${kv#*=}" '.[$k]=$v')" ;;
      --seed-from-deep-claude) seed_dc=1; shift ;;
      *) cr_die "add-backend: unknown flag '$1'" ;;
    esac
  done

  # Obtain the key: seed from deep-claude's keychain, else prompt.
  if (( seed_dc )); then
    cr_have security || cr_die "--seed-from-deep-claude needs the macOS 'security' tool"
    key="$(security find-generic-password -s deep-claude -a deepseek -w 2>/dev/null)" \
      || cr_die "no deep-claude key found (service 'deep-claude', account 'deepseek')"
    cr_say "Seeded key from deep-claude's keychain item."
  else
    printf 'Enter API key for backend "%s" (input hidden): ' "$name" >&2
    read -rs key; printf '\n' >&2
    [[ -z "$key" ]] && cr_die "no key entered"
  fi

  # Store the key under cr's own keychain item (macOS), else plaintext in config.
  local stored="keychain"
  if cr_have security; then
    security add-generic-password -U -s "$CR_BACKEND_KEYCHAIN_SVC" -a "$name" -w "$key" 2>/dev/null \
      || cr_die "failed to store key in keychain"
  else
    stored="config"
  fi

  cr_config_update '.accounts += [{
      name:$n, kind:"backend", configDir:null,
      baseUrl:$b, model:$m, modelAliases:$al,
      email:null, plan:"backend", lastUsed:0, enabled:true, usagePct:null,
      apiKey: (if $store=="config" then $k else null end) }]' \
    --arg n "$name" --arg b "$baseurl" --arg m "$model" \
    --argjson al "$aliases" --arg store "$stored" --arg k "$key"

  cr_say "Added backend '$name' → $baseurl  (model=$model, key in $stored)."
  cr_say "It is NOT in rotation. Use it explicitly:  cr@$name [--model pro|flash] [claude args...]"
}

# Register the existing ~/.claude login as an account (default has no dir).
cr_cmd_register_default() {
  local name="${1:-default}"
  cr_ensure_home
  cr_account_exists "$name" && cr_die "account '$name' already exists"
  local email="" plan=""
  if [[ -f "${HOME}/.claude.json" ]]; then
    email="$(jq -r '.oauthAccount.emailAddress // ""'    "${HOME}/.claude.json" 2>/dev/null)"
    plan="$(jq -r  '.oauthAccount.organizationType // ""' "${HOME}/.claude.json" 2>/dev/null)"
  fi
  cr_config_update '.accounts += [{
      name:$n, configDir:null, email:$e, plan:$pl, lastUsed:0, enabled:true, usagePct:null }]' \
    --arg n "$name" --arg e "$email" --arg pl "$plan"
  cr_say "Registered existing ~/.claude login as '$name'${email:+ ($email)}."
}

cr_cmd_login() {
  local name="${1:-}"; [[ -z "$name" ]] && cr_die "usage: cr login <name>"
  cr_account_exists "$name" || cr_die "unknown account: $name"
  local dir claude; dir="$(cr_account_dir "$name")"
  claude="$(cr_find_claude)" || cr_die "could not find 'claude' on PATH"
  if [[ -n "$dir" ]]; then CLAUDE_CONFIG_DIR="$dir" "$claude" /login
  else "$claude" /login; fi
}

cr_cmd_logout() {
  local name="${1:-}"; [[ -z "$name" ]] && cr_die "usage: cr logout <name>"
  cr_account_exists "$name" || cr_die "unknown account: $name"
  local dir claude; dir="$(cr_account_dir "$name")"
  claude="$(cr_find_claude)" || cr_die "could not find 'claude' on PATH"
  if [[ -n "$dir" ]]; then CLAUDE_CONFIG_DIR="$dir" "$claude" /logout
  else "$claude" /logout; fi
}

cr_cmd_remove() {
  local name="${1:-}"; [[ -z "$name" ]] && cr_die "usage: cr remove <name>"
  cr_account_exists "$name" || cr_die "unknown account: $name"
  local kind; kind="$(cr_account_kind "$name")"
  local dir; dir="$(cr_account_dir "$name" 2>/dev/null || true)"
  cr_config_update 'del(.accounts[] | select(.name==$n))' --arg n "$name"
  cr_say "Unregistered '$name'."
  if [[ "$kind" == "backend" ]]; then
    if cr_have security && security find-generic-password -s "$CR_BACKEND_KEYCHAIN_SVC" -a "$name" >/dev/null 2>&1; then
      cr_say "Its API key is still in your keychain. Remove it with:"
      cr_say "  security delete-generic-password -s '$CR_BACKEND_KEYCHAIN_SVC' -a '$name'"
    fi
  elif [[ -n "$dir" && -d "$dir" ]]; then
    cr_say "Its config dir still exists: $dir"
    cr_say "  Remove it with:  rm -rf '$dir'"
    cr_say "  Remove its keychain item with:  security delete-generic-password -s '$(cr_keychain_service "$dir")' -a '${USER}'"
  fi
}

cr_cmd_use() {
  local name="${1:-}"; [[ -z "$name" ]] && cr_die "usage: cr use <name>  (or: cr use --clear)"
  if [[ "$name" == "--clear" || "$name" == "none" ]]; then
    cr_config_update 'del(.defaultAccount)'
    cr_say "Cleared pinned account. Plain 'cr' now follows the '$(cr_config_read | jq -r '.selection')' policy."
    return 0
  fi
  cr_account_exists "$name" || cr_die "unknown account: $name"
  cr_config_update '.defaultAccount = $n' --arg n "$name"
  cr_say "Default account for plain 'cr' set to '$name'. (Note: overrides rotation policy. Undo with: cr use --clear)"
}

cr_cmd_unuse() { cr_cmd_use --clear; }

cr_cmd_policy() {
  local p="${1:-}"
  case "$p" in
    round-robin|lru|random|usage-aware)
      cr_config_update '.selection = $p' --arg p "$p"
      cr_say "Selection policy set to '$p'." ;;
    "") cr_say "Current policy: $(cr_config_read | jq -r '.selection')" ;;
    *) cr_die "unknown policy '$p' (round-robin|lru|random|usage-aware)" ;;
  esac
}

# Tune routing knobs:  cr config [exhausted-at <pct> | auto-refresh on|off | ttl <sec>]
cr_cmd_config() {
  cr_ensure_home
  local key="${1:-}" val="${2:-}"
  case "$key" in
    "" )
      local c; c="$(cr_config_read)"
      cr_say "routing config:"
      cr_say "  exhausted-at  $(printf '%s' "$c" | jq -r '.exhaustedAtPct // 100')%   (skip accounts at/above this usage)"
      cr_say "  auto-refresh  $(printf '%s' "$c" | jq -r 'if (.autoRefreshUsage // true) then "on" else "off" end')   (poll usage before routing when stale)"
      cr_say "  ttl           $(printf '%s' "$c" | jq -r '.usageTtlSeconds // 900')s   (how long cached usage stays fresh)"
      cr_say "  watch-at      $(printf '%s' "$c" | jq -r '.watchAtPct // 90')%   (hand off when usage reaches this % in watch mode)"
      cr_say "  watch-interval $(printf '%s' "$c" | jq -r '.watchIntervalSeconds // 120')s  (poll interval in watch mode)"
      cr_say "  watch-idle    $(printf '%s' "$c" | jq -r '.watchIdleSeconds // 30')s   (seconds of session inactivity before handing off)"
      ;;
    exhausted-at)
      [[ "$val" =~ ^[0-9]+$ ]] || cr_die "usage: cr config exhausted-at <0-100>"
      cr_config_update '.exhaustedAtPct = ($v|tonumber)' --arg v "$val"
      cr_say "Accounts at/above ${val}% usage will be skipped by rotation." ;;
    auto-refresh)
      case "$val" in
        on|true)  cr_config_update '.autoRefreshUsage = true';  cr_say "Auto-refresh on." ;;
        off|false) cr_config_update '.autoRefreshUsage = false'; cr_say "Auto-refresh off (run 'cr usage' to update manually)." ;;
        *) cr_die "usage: cr config auto-refresh on|off" ;;
      esac ;;
    ttl)
      [[ "$val" =~ ^[0-9]+$ ]] || cr_die "usage: cr config ttl <seconds>"
      cr_config_update '.usageTtlSeconds = ($v|tonumber)' --arg v "$val"
      cr_say "Usage cache TTL set to ${val}s." ;;
    watch-at)
      [[ "$val" =~ ^[0-9]+$ ]] || cr_die "usage: cr config watch-at <0-100>"
      cr_config_update '.watchAtPct = ($v|tonumber)' --arg v "$val"
      cr_say "Watch mode will hand off at ${val}% usage." ;;
    watch-interval)
      [[ "$val" =~ ^[0-9]+$ && "$val" -ge 1 ]] || cr_die "usage: cr config watch-interval <positive integer seconds>"
      cr_config_update '.watchIntervalSeconds = ($v|tonumber)' --arg v "$val"
      cr_say "Watch poll interval set to ${val}s." ;;
    watch-idle)
      [[ "$val" =~ ^[0-9]+$ && "$val" -ge 1 ]] || cr_die "usage: cr config watch-idle <positive integer seconds>"
      cr_config_update '.watchIdleSeconds = ($v|tonumber)' --arg v "$val"
      cr_say "Watch idle threshold set to ${val}s." ;;
    *) cr_die "unknown config key '$key' (exhausted-at | auto-refresh | ttl | watch-at | watch-interval | watch-idle)" ;;
  esac
}

cr_cmd_list() {
  cr_ensure_home
  local rows; rows="$(cr_config_read)"
  if [[ "$(printf '%s' "$rows" | jq '.accounts|length')" -eq 0 ]]; then
    cr_say "No accounts yet. Add one with:  cr add <name>"
    cr_say "Register your current ~/.claude login with:  cr register-default"
    return 0
  fi
  local pinned; pinned="$(printf '%s' "$rows" | jq -r '.defaultAccount // empty')"
  # Build the table uncolored (so `column -t` aligns on true widths), then tint
  # only whole lines afterwards — header bold, backend rows yellow, pinned row bold.
  local table
  table="$(printf '%s\n' "$rows" | jq -r --arg PIN "$pinned" '
    "NAME\tKIND\tEMAIL / ENDPOINT\tPLAN / MODEL\tLAST USED\tUSAGE\tON\tROTATES",
    (.accounts[] |
      ( (.kind // "subscription") ) as $k |
      [ (if .name==$PIN then "★ "+.name else .name end),
        $k,
        (if $k=="backend" then (.baseUrl // "?" | sub("^https?://";"")) else (.email // "?") end),
        (if $k=="backend" then (.model // "?") else (.plan // "?") end),
        (if (.lastUsed // 0) == 0 then "never" else (.lastUsed/1000 | strftime("%Y-%m-%d %H:%M")) end),
        (if .usagePct == null then "-" else "\(.usagePct|floor)%" end),
        (if .enabled == false then "no" else "yes" end),
        (if $k=="backend" then "explicit-only" else "yes" end)
      ] | @tsv)' | column -t -s $'\t')"

  printf '\n' >&2
  local first=1 line
  while IFS= read -r line; do
    if ((first)); then
      printf '  %s%s%s\n' "$C_BOLD" "$line" "$C_RESET" >&2; first=0
    elif [[ "$line" == *"backend"* ]]; then
      printf '  %s%s%s\n' "$C_YELLOW" "$line" "$C_RESET" >&2
    elif [[ "$line" == "★ "* ]]; then
      printf '  %s%s%s\n' "$C_BOLD" "$line" "$C_RESET" >&2
    else
      printf '  %s\n' "$line" >&2
    fi
  done <<< "$table"
  [[ -n "$pinned" ]] && printf '\n  %s★ pinned via '\''cr use'\'' — clear with '\''cr use --clear'\''%s\n' "$C_DIM" "$C_RESET" >&2
  printf '\n' >&2
}

cr_cmd_usage() {
  cr_ensure_home
  cr_require_deps
  cr_have curl || cr_die "cr usage needs curl"
  local plain=0
  if [[ "${1:-}" == "--plain" ]]; then plain=1; shift; fi
  local name="${1:-}"
  [[ -n "$name" ]] && { cr_account_exists "$name" || cr_die "unknown account: $name"; }

  if [[ "$plain" -eq 1 ]]; then
    if [[ -n "$name" ]]; then cr_poll_account "$name" >&2
    else local a; while IFS= read -r a; do cr_poll_account "$a" >&2 || true; done < <(cr_enabled_accounts); fi
  else
    cr_render_meters "$name"
  fi
}

# Symlink a session (transcript + subagents dir) from its owner into another
# account's store, so the target can resume it. Returns nonzero if the owner or
# transcript can't be found. Quiet by default; pass "verbose" as arg 3 to narrate.
cr_link_session() {
  local sid="$1" target="$2" verbose="${3:-}"
  local owner; owner="$(cr_account_owning_session "$sid" || true)"
  [[ -z "$owner" ]] && return 1
  [[ "$owner" == "$target" ]] && return 2   # target already owns it

  local src_base tgt_base
  src_base="$(cr_account_dir "$owner" 2>/dev/null || true)"; src_base="${src_base:-$HOME/.claude}"
  tgt_base="$(cr_account_dir "$target" 2>/dev/null || true)"; tgt_base="${tgt_base:-$HOME/.claude}"

  # Find the owner's REAL transcript (owner detection guarantees it's a real
  # file, but re-check before we ever touch the filesystem).
  local src_file proj f
  for f in "${src_base}"/projects/*/"${sid}".jsonl; do
    [[ -f "$f" && ! -L "$f" ]] && { src_file="$f"; break; }
  done
  [[ -z "${src_file:-}" ]] && return 1
  proj="$(basename "$(dirname "$src_file")")"

  local tgt_dir="${tgt_base}/projects/${proj}"
  local tgt_file="${tgt_dir}/${sid}.jsonl"

  # SAFETY: never destroy a real transcript at the target. Only replace a stale
  # symlink. If a real file is already there, leave it — the target owns its own.
  if [[ -f "$tgt_file" && ! -L "$tgt_file" ]]; then
    CR_LINK_OWNER="$owner"; return 0   # target already has a real copy; nothing to do
  fi
  # Don't link a file onto itself (same inode / resolves to the same path).
  if [[ "$src_file" -ef "$tgt_file" ]]; then CR_LINK_OWNER="$owner"; return 0; fi

  mkdir -p "$tgt_dir"
  [[ -L "$tgt_file" ]] && rm -f "$tgt_file"   # stale symlink only
  ln -s "$src_file" "$tgt_file"

  local src_sub="${src_base}/projects/${proj}/${sid}"
  if [[ -d "$src_sub" && ! -L "$src_sub" ]]; then
    local tgt_sub="${tgt_dir}/${sid}"
    [[ -d "$tgt_sub" && ! -L "$tgt_sub" ]] || {   # only touch if target isn't a real dir
      [[ -L "$tgt_sub" ]] && rm -f "$tgt_sub"
      ln -s "$src_sub" "$tgt_sub"
    }
  fi
  [[ "$verbose" == verbose ]] && cr_say "${C_DIM}linked session ${sid:0:8}… from '${owner}' → '${target}'${C_RESET}"
  CR_LINK_OWNER="$owner"   # expose for callers
  return 0
}

# Make a session owned by one account resumable under another (explicit command).
#   cr adopt <session-id> <target-account>
cr_cmd_adopt() {
  local sid="${1:-}" target="${2:-}"
  [[ -z "$sid" || -z "$target" ]] && cr_die "usage: cr adopt <session-id> <target-account>"
  cr_ensure_home
  cr_account_exists "$target" || cr_die "unknown target account: $target"
  [[ "$(cr_account_kind "$target")" == "backend" ]] && cr_die "backends don't store sessions; pick a subscription account"

  cr_link_session "$sid" "$target"
  case $? in
    0) cr_say "Adopted session ${sid:0:8}… → '${target}' (symlinked, shared history)."
       cr_say "Resume it under the target with:  cr@${target} --resume ${sid}" ;;
    2) cr_die "'$target' already owns that session" ;;
    *) cr_die "no account owns session ${sid} (nothing to adopt)" ;;
  esac
}

cr_cmd_status() {
  cr_ensure_home
  # Optional: refresh live usage before drawing (otherwise use cached snapshot).
  if [[ "${1:-}" == "--refresh" || "${1:-}" == "-r" ]]; then
    if cr_have curl; then
      cr_say "${C_DIM}refreshing usage…${C_RESET}"
      local a; while IFS= read -r a; do cr_poll_account "$a" >/dev/null 2>&1 || true; done < <(cr_enabled_accounts)
    else
      cr_warn "curl not found — showing cached usage"
    fi
  fi
  local policy def n
  policy="$(cr_config_read | jq -r '.selection // "round-robin"')"
  def="$(cr_config_read | jq -r '.defaultAccount // empty')"
  n="$(cr_enabled_accounts | grep -c . || true)"
  printf '\n  %spolicy%s %s%s%s    %ssubscriptions%s %s%s%s%s\n' \
    "$C_GREY" "$C_RESET" "$C_CYAN" "$policy" "$C_RESET" \
    "$C_GREY" "$C_RESET" "$C_BOLD" "$n" "$C_RESET" \
    "$([[ -n "$def" ]] && printf '    %spinned%s %s%s%s' "$C_GREY" "$C_RESET" "$C_YELLOW" "$def" "$C_RESET")" >&2
  if [[ "$n" -gt 0 ]]; then
    local pick note
    if [[ -n "$def" ]]; then pick="$def"; note="pinned via 'cr use'"
    elif [[ "$policy" == lru ]]; then pick="$(cr_select_lru)"; note="would pick now"
    elif [[ "$policy" == usage-aware ]]; then pick="$(cr_select_usage_aware)"; note="most headroom"
    else pick=""; note="next in rotation — run a plain 'cr' to advance"; fi
    if [[ -n "$pick" ]]; then
      printf '  %snext%s   %s◆ %s%s %s(%s)%s\n' \
        "$C_GREY" "$C_RESET" "$C_ACCENT$C_BOLD" "$pick" "$C_RESET" "$C_DIM" "$note" "$C_RESET" >&2
    else
      printf '  %snext%s   %s%s%s\n' "$C_GREY" "$C_RESET" "$C_DIM" "$note" "$C_RESET" >&2
    fi
  fi

  # Per-account usage dashboard (cached; pass --refresh to poll live first).
  printf '\n' >&2
  if ! cr_render_cached_bars; then
    printf '  %sno usage cached yet — run %scr usage%s%s or %scr status --refresh%s\n\n' \
      "$C_DIM" "$C_CYAN" "$C_RESET$C_DIM" "" "$C_CYAN" "$C_RESET" >&2
  fi
}

cr_doctor() {
  local name="${1:-}"
  local check
  check() {
    local a dir svc kc
    a="$1"
    if [[ "$(cr_account_kind "$a")" == "backend" ]]; then
      if cr_backend_key "$a" >/dev/null 2>&1; then kc="ok"; else kc="MISSING (re-run: cr add-backend)"; fi
      cr_say "  $a: backend  key=$kc  (explicit-only, not in rotation)"
      return
    fi
    dir="$(cr_account_dir "$a")"
    if cr_keychain_present "$dir"; then kc="ok"; else kc="MISSING (run: cr login $a)"; fi
    svc="$(cr_keychain_service "$dir")"
    cr_say "  $a: dir=${dir:-(default ~/.claude)}  keychain[$svc]=$kc"
  }
  cr_ensure_home
  if [[ -n "$name" ]]; then
    cr_account_exists "$name" || cr_die "unknown account: $name"
    cr_say "doctor:"; check "$name"
  else
    cr_say "doctor:"
    local a; while IFS= read -r a; do check "$a"; done < <(cr_config_read | jq -r '.accounts[].name')
  fi
}

cr_cmd_help() {
  local b="$C_BOLD" d="$C_DIM" r="$C_RESET" a="$C_ACCENT" cy="$C_CYAN" gn="$C_GREEN" gy="$C_GREY"
  # cmd col desc — aligns the description column with padding.
  cmd() { printf '  %s%-30s%s %s%s%s\n' "$cy" "$1" "$r" "$gy" "$2" "$r" >&2; }
  head() { printf '\n%s%s%s\n' "$b" "$1" "$r" >&2; }
  ex()  { printf '  %s%-36s%s %s%s%s\n' "$gn" "$1" "$r" "$d" "$2" "$r" >&2; }

  printf '\n  %s🦞 Claw Router%s %s(cr)%s  %s— effortlessly manage your Claude subscriptions%s\n' \
    "$a$b" "$r" "$d" "$r" "$d" "$r" >&2

  head "Launch"
  cmd "cr [claude args...]"          "pick an account by policy, then run claude"
  cmd "cr --account <name> [args]" "force a specific account for this run"
  cmd "cr@<name> [args]"           "shorthand for --account <name>"
  cmd "cr --account <name> -- ..."   "everything after -- is passed to claude"
  cmd "cr --resume <id>"           "resume any session — auto-linked into the picked account"
  cmd "cr --sandbox  (-s) [args]"  "run the session inside a cco sandbox (isolation)"
  cmd "cr --watch   (-w) [args]"   "auto-handoff to a fresher account near the usage limit"

  head "Accounts"
  cmd "cr add <name>"              "browser-login a subscription, cache identity"
  cmd "cr add-backend <name> ..."    "register an alt-model endpoint (e.g. DeepSeek)"
  cmd "cr register-default [name]" "adopt your existing ~/.claude login"
  cmd "cr login / logout <name>"   "(re)authenticate / sign out an account"
  cmd "cr remove <name>"           "unregister an account"
  cmd "cr list"                    "show all accounts (alias: accounts, ls)"

  head "Routing"
  cmd "cr policy <p>"              "round-robin | lru | random | usage-aware"
  cmd "cr use <name>"              "pin the account a plain 'cr' uses"
  cmd "cr use --clear  (unuse)"    "unpin; return to the rotation policy"
  cmd "cr config [key val]"        "tune exhausted-at / auto-refresh / ttl / watch-at / …"
  cmd "cr status [--refresh]"      "dashboard: next pick + per-account usage bars"

  head "Sessions"
  cmd "cr adopt <id> <account>"    "manually link a session into <account> (--resume does this automatically)"

  head "Inspect"
  cmd "cr usage [name]"            "usage meters per window (--plain = one line)"
  cmd "cr doctor [name]"           "verify dirs + keychain credentials"
  cmd "cr help"                    "this help"

  head "First-time setup"
  ex "cr register-default"          "adopt your current ~/.claude login"
  ex "cr add work"                  "browser-login a 2nd subscription"
  ex "cr list"                      "confirm they're registered"
  ex 'cr -p "hello"'                "round-robins across them"

  head "Examples"
  ex 'cr -p "summarize this repo"'  "one-shot, account picked by policy"
  ex "cr --dangerously-skip-permissions" "any claude flag is forwarded as-is"
  ex 'cr@work -p "draft the PR"'     "force the 'work' subscription"
  ex 'cr@deepseek --model flash ...'   "use a backend (DeepSeek), explicit only"
  ex "cr policy usage-aware && cr usage" "route to whichever has most headroom"

  printf '\n%s  Plain %scr%s%s rotates over subscriptions only — backends are explicit-only (%scr@<name>%s%s).%s\n' \
    "$d" "$cy" "$r" "$d" "$cy" "$r" "$d" "$r" >&2
  printf '%s  The “which account” banner goes to stderr, so %scr -p%s%s output stays pipeable.%s\n\n' \
    "$d" "$cy" "$r" "$d" "$r" >&2
}

# ------------------------------------------------------------------------
# Dispatch
# ------------------------------------------------------------------------
main() {
  cr_require_deps

  # Extract the cr-owned --sandbox / -s and --watch / -w flags from the launch
  # flags (everything up to a `--` separator, after which args belong to claude).
  # Sets CR_SANDBOX and CR_WATCH.
  CR_SANDBOX=0
  CR_WATCH=0
  local _a _rest=() _seen_sep=0
  for _a in "$@"; do
    if [[ "$_seen_sep" == 0 && ( "$_a" == "--sandbox" || "$_a" == "-s" ) ]]; then
      CR_SANDBOX=1; continue
    fi
    if [[ "$_seen_sep" == 0 && ( "$_a" == "--watch" || "$_a" == "-w" ) ]]; then
      CR_WATCH=1; continue
    fi
    [[ "$_a" == "--" ]] && _seen_sep=1
    _rest+=("$_a")
  done
  set -- "${_rest[@]}"
  # Fail fast on --sandbox without cco, before any banner/launch side effects.
  if [[ "$CR_SANDBOX" == 1 ]] && ! command -v cco >/dev/null 2>&1; then
    cr_die "--sandbox needs 'cco' (not found). Install it:
    curl -fsSL https://raw.githubusercontent.com/nikvdp/cco/master/install.sh | bash
  then re-run, or drop --sandbox. See: https://github.com/nikvdp/cco"
  fi

  # cr@name shorthand
  if [[ "${1:-}" == cr@* ]]; then set -- --account "${1#cr@}" "${@:2}"; fi

  # Global --account <name> (before subcommand or before claude args)
  local forced=""
  if [[ "${1:-}" == "--account" ]]; then
    forced="${2:-}"; [[ -z "$forced" ]] && cr_die "--account needs a name"
    shift 2
    # Drop an optional `--` separator between cr flags and claude args.
    [[ "${1:-}" == "--" ]] && shift
    cr_launch "$forced" "$@"; return
  fi

  case "${1:-}" in
    add)              shift; cr_cmd_add "$@" ;;
    add-backend)      shift; cr_cmd_add_backend "$@" ;;
    register-default) shift; cr_cmd_register_default "$@" ;;
    login)            shift; cr_cmd_login "$@" ;;
    logout)           shift; cr_cmd_logout "$@" ;;
    remove|rm)        shift; cr_cmd_remove "$@" ;;
    list|accounts|ls) shift; cr_cmd_list ;;
    use)              shift; cr_cmd_use "$@" ;;
    unuse)            shift; cr_cmd_unuse ;;
    policy)           shift; cr_cmd_policy "$@" ;;
    config)           shift; cr_cmd_config "$@" ;;
    usage)            shift; cr_cmd_usage "$@" ;;
    adopt)            shift; cr_cmd_adopt "$@" ;;
    status)           shift; cr_cmd_status "$@" ;;
    doctor)           shift; cr_doctor "${1:-}" ;;
    help|--help|-h)   cr_cmd_help ;;
    "")               # plain `cr`: with no accounts yet, show help instead of erroring
                      if [[ "$(cr_config_read | jq '.accounts|length')" -eq 0 ]]; then
                        cr_cmd_help; return
                      fi
                      local def; def="$(cr_config_read | jq -r '.defaultAccount // empty')"
                      cr_launch "$def" ;;
    *)                # anything else → claude args; route by policy/pin
                      local def; def="$(cr_config_read | jq -r '.defaultAccount // empty')"
                      cr_launch "$def" "$@" ;;
  esac
}

main "$@"
