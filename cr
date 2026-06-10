#!/usr/bin/env bash
# cr — Claude Router. Pick one of your Claude subscriptions and launch Claude
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

# Detect a resume/continue invocation so we don't rotate onto the wrong account.
cr_args_have_resume() {
  local a
  for a in "$@"; do
    case "$a" in --continue|-c|--resume) return 0 ;; esac
  done
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
    if [[ "$n" -eq 1 ]]; then
      account="$(cr_enabled_accounts | head -1)"
    elif cr_args_have_resume "$@"; then
      account="$(cr_select lru)"
      cr_warn "resume/continue detected — routing to least-recently-used ('$account'). Use --account to pin."
    else
      account="$(cr_select "$policy")" || cr_die "selection failed for policy '$policy'"
    fi
  fi

  local kind; kind="$(cr_account_kind "$account")"
  cr_mark_used "$account"

  if [[ "$kind" == "backend" ]]; then
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

  cr_say "▶ claude-router → ${account}  ${email}  (${plan})  [${forced:+forced}${forced:-policy: $policy}]"
  printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$account" "${dir:-(default)}" >> "$CR_LOG" 2>/dev/null || true

  local claude; claude="$(cr_find_claude)" || cr_die "could not find 'claude' on PATH"
  exec "$claude" "$@"
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

  cr_say "▶ claude-router → ${account}  (backend: ${baseurl##https://})  model=${model:-default}  [explicit]"
  printf '%s\t%s\tbackend:%s\n' "$(date -u +%FT%TZ)" "$account" "$baseurl" >> "$CR_LOG" 2>/dev/null || true

  local claude; claude="$(cr_find_claude)" || cr_die "could not find 'claude' on PATH"
  if [[ -n "$model" ]]; then exec "$claude" --model "$model" "$@"; else exec "$claude" "$@"; fi
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

cr_cmd_list() {
  cr_ensure_home
  local rows; rows="$(cr_config_read)"
  if [[ "$(printf '%s' "$rows" | jq '.accounts|length')" -eq 0 ]]; then
    cr_say "No accounts yet. Add one with:  cr add <name>"
    cr_say "Register your current ~/.claude login with:  cr register-default"
    return 0
  fi
  printf '%s\n' "$rows" | jq -r '
    "NAME\tKIND\tEMAIL / ENDPOINT\tPLAN / MODEL\tLAST USED\tUSAGE\tON\tROTATES",
    (.accounts[] |
      ( (.kind // "subscription") ) as $k |
      [ .name,
        $k,
        (if $k=="backend" then (.baseUrl // "?" | sub("^https?://";"")) else (.email // "?") end),
        (if $k=="backend" then (.model // "?") else (.plan // "?") end),
        (if (.lastUsed // 0) == 0 then "never"
         else (.lastUsed/1000 | strftime("%Y-%m-%d %H:%M")) end),
        (if .usagePct == null then "-" else "\(.usagePct|floor)%" end),
        (if .enabled == false then "no" else "yes" end),
        (if $k=="backend" then "explicit-only" else "yes" end)
      ] | @tsv)' | column -t -s $'\t' >&2
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

cr_cmd_status() {
  cr_ensure_home
  local policy def n
  policy="$(cr_config_read | jq -r '.selection // "round-robin"')"
  def="$(cr_config_read | jq -r '.defaultAccount // empty')"
  n="$(cr_enabled_accounts | grep -c . || true)"
  cr_say "policy: $policy   enabled accounts: $n${def:+   default(use): $def}"
  if [[ "$n" -gt 0 ]]; then
    local pick
    if [[ -n "$def" ]]; then pick="$def (pinned via 'cr use')"
    elif [[ "$policy" == lru ]]; then pick="$(cr_select_lru) (would pick now)"
    elif [[ "$policy" == usage-aware ]]; then pick="$(cr_select_usage_aware) (would pick now)"
    else pick="(next in rotation — run a plain 'cr' to advance)"; fi
    cr_say "next plain 'cr' → $pick"
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
  cr_say "claude-router (cr) — route Claude Code across multiple subscriptions

Launch:
  cr [claude args...]         pick an account by policy, then run claude
  cr --account <name> [...]   force an account for this run
  cr@<name> [...]             shorthand for --account <name>
  cr --account <name> -- ...  everything after -- goes to claude

Manage:
  cr add <name>               create an account + browser login, cache identity
  cr add-backend <name> …     register an alt-model endpoint (e.g. DeepSeek);
                              flags: --base-url URL --model NAME --alias s=full
                                     --seed-from-deep-claude
                              (backends are explicit-only, never in rotation)
  cr register-default [name]  register your existing ~/.claude login (default)
  cr login <name>             (re)authenticate an account
  cr logout <name>            log an account out (clears its keychain item)
  cr remove <name>            unregister an account
  cr list                     show accounts (alias: cr accounts)
  cr use <name>               pin the account a plain 'cr' uses
  cr use --clear  (unuse)     unpin; go back to the rotation policy
  cr policy <p>               round-robin | lru | random | usage-aware
  cr usage [name]             show usage meters per window (--plain for one line)
  cr status                   show which account would run next
  cr doctor [name]            verify dirs + keychain credentials
  cr help                     this help

First-time setup:
  cr register-default                  # adopt your current ~/.claude login
  cr add work                          # browser-login a 2nd subscription
  cr add personal                      # …and a 3rd
  cr list                              # confirm they're registered
  cr -p \"hello\"                        # round-robins across them

Examples:
  cr                                   # interactive session on the next account
  cr -p \"summarize this repo\"          # one-shot, picked by policy
  cr --dangerously-skip-permissions    # any claude flag is forwarded as-is
  cr@work -p \"draft the PR\"            # force the 'work' subscription
  cr@deepseek --model flash -p \"…\"     # use a backend (DeepSeek), explicit only
  cr policy usage-aware && cr usage    # route to whichever has the most headroom

Notes:
  • Plain 'cr' rotates over SUBSCRIPTION accounts only; backends are
    explicit-only (cr@<name>) and never auto-selected.
  • 'cr use <name>' pins an account; 'cr use --clear' returns to rotation.
  • The banner (which account ran) prints to stderr, so 'cr -p' stdout stays clean."
}

# ------------------------------------------------------------------------
# Dispatch
# ------------------------------------------------------------------------
main() {
  cr_require_deps

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
    usage)            shift; cr_cmd_usage "$@" ;;
    status)           shift; cr_cmd_status ;;
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
