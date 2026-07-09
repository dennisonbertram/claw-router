#!/usr/bin/env bash
# Codex provider adapter. Requires lib/common.sh. This file never reads
# CODEX_HOME/auth.json; authentication is delegated to official Codex commands
# and account metadata comes from the supported app-server protocol.

cr_find_codex() {
  local self_dir="$CR_DIR" d IFS=:
  for d in $PATH; do
    [[ "$d" == "$self_dir" ]] && continue
    if [[ -x "$d/codex" ]]; then printf '%s' "$d/codex"; return 0; fi
  done
  return 1
}

# Apply the selected Codex home while removing every auth override that could
# silently defeat the account selection. Also remove Claude-specific state so
# provider launches cannot bleed into each other.
cr_codex_prepare_env() {
  local dir="$1"
  unset OPENAI_API_KEY CODEX_API_KEY CODEX_ACCESS_TOKEN
  unset CLAUDE_CONFIG_DIR ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
  unset CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_BASE_URL ANTHROPIC_MODEL
  if [[ -n "$dir" ]]; then export CODEX_HOME="$dir"; else unset CODEX_HOME; fi
}

# Ensure the credential store is explicitly file-based for isolated homes.
# The key is top-level TOML; prepend it when absent so an existing trailing
# section cannot accidentally capture it. Unrelated content is preserved.
cr_codex_ensure_file_store() {
  local dir="$1" cfg tmp
  [[ -n "$dir" ]] || return 0
  mkdir -p "$dir"
  chmod 700 "$dir" 2>/dev/null || true
  cfg="$dir/config.toml"
  [[ -f "$cfg" ]] || : > "$cfg"
  tmp="$(mktemp "${cfg}.XXXXXX")" || return 1
  awk '
    BEGIN { in_table=0; found=0 }
    /^[[:space:]]*\[/ { in_table=1 }
    !in_table && /^[[:space:]]*cli_auth_credentials_store[[:space:]]*=/ {
      if (!found) print "cli_auth_credentials_store = \"file\""
      found=1
      next
    }
    { lines[NR]=$0 }
    END {
      if (!found) print "cli_auth_credentials_store = \"file\""
      for (i=1; i<=NR; i++) if (i in lines) print lines[i]
    }
  ' "$cfg" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$cfg"
}

# Query one stable app-server account method over a fully handshaken stdio
# connection. Bash 3.2 has no coproc, so use bidirectional FIFOs. Each read is
# bounded and the child is always killed/reaped; callers receive only .result.
cr_codex_app_server_request() {
  local dir="$1" method="$2" codex tmp in_fifo out_fifo pid="" line="" init="" response=""
  codex="$(cr_find_codex)" || return 2
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/cr-codex-rpc.XXXXXX")" || return 1
  in_fifo="$tmp/in"; out_fifo="$tmp/out"
  mkfifo "$in_fifo" "$out_fifo" || { rm -rf "$tmp"; return 1; }

  # Opening a FIFO read/write avoids startup deadlock while the child attaches.
  exec 8<>"$in_fifo"
  exec 9<>"$out_fifo"
  (
    cr_codex_prepare_env "$dir"
    exec "$codex" app-server --stdio <&8 >&9 2>/dev/null
  ) &
  pid=$!

  printf '%s\n' '{"method":"initialize","id":0,"params":{"clientInfo":{"name":"claw-router","title":"Claw Router","version":"1"},"capabilities":{"experimentalApi":true}}}' >&8

  local tries=0
  while (( tries < 40 )); do
    if IFS= read -r -t 0.25 line <&9; then
      if [[ "$(printf '%s' "$line" | jq -r 'select(.id==0) | .id' 2>/dev/null)" == "0" ]]; then
        init="$line"; break
      fi
    fi
    kill -0 "$pid" 2>/dev/null || break
    tries=$(( tries + 1 ))
  done

  if [[ -n "$init" && "$(printf '%s' "$init" | jq -r '.error // empty' 2>/dev/null)" == "" ]]; then
    printf '%s\n' '{"method":"initialized","params":{}}' >&8
    if [[ "$method" == "account/read" ]]; then
      printf '%s\n' '{"method":"account/read","id":1,"params":{"refreshToken":false}}' >&8
    else
      printf '{"method":"%s","id":1}\n' "$method" >&8
    fi

    tries=0
    while (( tries < 40 )); do
      if IFS= read -r -t 0.25 line <&9; then
        if [[ "$(printf '%s' "$line" | jq -r 'select(.id==1) | .id' 2>/dev/null)" == "1" ]]; then
          response="$line"; break
        fi
      fi
      kill -0 "$pid" 2>/dev/null || break
      tries=$(( tries + 1 ))
    done
  fi

  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  exec 8>&- 8<&- 9>&- 9<&-
  rm -rf "$tmp"

  [[ -n "$response" ]] || return 1
  printf '%s' "$response" | jq -e '.result' 2>/dev/null
}

cr_codex_read_account() {
  cr_codex_app_server_request "$1" "account/read"
}

cr_codex_read_rate_limits() {
  cr_codex_app_server_request "$1" "account/rateLimits/read"
}

# Refresh cached public identity metadata after login. API-key accounts have no
# email/plan; ChatGPT accounts expose both through account/read.
cr_codex_cache_identity() {
  local name="$1" dir result email plan auth_type
  dir="$(cr_account_dir "$name")" || return 1
  result="$(cr_codex_read_account "$dir")" || return 1
  email="$(printf '%s' "$result" | jq -r '.account.email // empty')"
  plan="$(printf '%s' "$result" | jq -r '.account.planType // empty')"
  auth_type="$(printf '%s' "$result" | jq -r '.account.type // empty')"
  cr_config_update '
    (.accounts[] | select(.name==$n) | .email) = (if $e=="" then null else $e end)
    | (.accounts[] | select(.name==$n) | .plan) = (if $pl=="" then $old else $pl end)
    | (.accounts[] | select(.name==$n) | .authType) = (if $at=="" then null else $at end)' \
    --arg n "$name" --arg e "$email" --arg pl "$plan" --arg at "$auth_type" \
    --arg old "$(cr_config_read | jq -r --arg n "$name" '.accounts[]|select(.name==$n)|.plan // "unknown"')" >/dev/null
}

