#!/usr/bin/env bash
# usage.sh — best-effort usage polling for an account, via Claude's own OAuth
# endpoints. Never fatal: any failure returns nonzero and the caller degrades.
# Requires common.sh to be sourced first.

# Read the credential JSON blob for a config dir.
# macOS: from Keychain. Linux/Windows: from <dir>/.credentials.json (or ~/.claude).
# Echoes the JSON on stdout, or returns nonzero.
cr_read_credentials() {
  local dir="$1" svc blob file
  if cr_have security; then
    svc="$(cr_keychain_service "$dir")"
    blob="$(security find-generic-password -s "$svc" -a "${USER:-$(id -un)}" -w 2>/dev/null)" || return 1
    [[ -n "$blob" ]] && { printf '%s' "$blob"; return 0; }
  fi
  if [[ -n "$dir" ]]; then file="${dir}/.credentials.json"; else file="${HOME}/.claude/.credentials.json"; fi
  [[ -f "$file" ]] && { cat "$file"; return 0; }
  return 1
}

# Refresh an access token given a refresh token. Echoes new access token.
cr_refresh_token() {
  local refresh="$1" resp
  cr_have curl || return 2
  resp="$(curl -fsS --max-time 10 -X POST "$CR_TOKEN_URL" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg rt "$refresh" --arg cid "$CR_OAUTH_CLIENT_ID" \
          '{grant_type:"refresh_token", refresh_token:$rt, client_id:$cid}')" 2>/dev/null)" || return 1
  printf '%s' "$resp" | jq -r '.access_token // empty'
}

# Fetch raw usage JSON for an account dir. Handles one 401 -> refresh -> retry.
# Echoes the usage JSON on success.
cr_fetch_usage_raw() {
  local dir="$1" creds access refresh code body
  cr_have curl || return 2
  creds="$(cr_read_credentials "$dir")" || return 1
  access="$(printf '%s' "$creds" | jq -r '.claudeAiOauth.accessToken // empty')"
  refresh="$(printf '%s' "$creds" | jq -r '.claudeAiOauth.refreshToken // empty')"
  [[ -z "$access" ]] && return 1

  _cr_usage_call() {
    curl -sS --max-time 10 -w '\n%{http_code}' "$CR_USAGE_URL" \
      -H "Authorization: Bearer $1" \
      -H "anthropic-beta: $CR_OAUTH_BETA" \
      -H 'Content-Type: application/json' 2>/dev/null
  }

  local out; out="$(_cr_usage_call "$access")" || return 1
  code="${out##*$'\n'}"; body="${out%$'\n'*}"
  if [[ "$code" == "401" && -n "$refresh" ]]; then
    local newtok; newtok="$(cr_refresh_token "$refresh")" || return 1
    [[ -z "$newtok" ]] && return 1
    out="$(_cr_usage_call "$newtok")" || return 1
    code="${out##*$'\n'}"; body="${out%$'\n'*}"
  fi
  [[ "$code" == "200" ]] || return 1
  printf '%s' "$body"
}

# Compute a single "percent used" number (0-100) from the usage JSON, taking
# the most-constrained bucket. Returns empty if it can't parse.
cr_usage_pct() {
  printf '%s' "$1" | jq -r '
    [ .five_hour, .seven_day, .seven_day_opus, .seven_day_sonnet ]
    | map(select(. != null))
    | map( if type=="object" then (.utilization // .used_pct // .percent // empty) else . end )
    | map(select(type=="number"))
    | if length>0 then (max) else empty end
  ' 2>/dev/null
}

# Poll one account and cache its usagePct + a short summary into the registry.
# Echoes a human summary line. Best-effort.
cr_poll_account() {
  local name="$1" dir raw pct line
  dir="$(cr_account_dir "$name")" || { cr_warn "unknown account: $name"; return 1; }
  raw="$(cr_fetch_usage_raw "$dir")" || { cr_warn "usage poll failed for '$name'"; return 1; }
  pct="$(cr_usage_pct "$raw")"
  if [[ -n "$pct" ]]; then
    cr_config_update '(.accounts[] | select(.name==$n) | .usagePct) = ($p|tonumber)' \
      --arg n "$name" --arg p "$pct" >/dev/null
    # Per-window breakdown (5h / 7d), with reset times when present.
    line="$(printf '%s' "$raw" | jq -r '
      def w(o): if o==null then empty
                else "\(o.utilization // o)%\(if o.resets_at then " →resets \(o.resets_at[0:16])" else "" end)" end;
      [ (if .five_hour != null then "5h " + w(.five_hour) else empty end),
        (if .seven_day != null then "7d " + w(.seven_day) else empty end) ]
      | join("   ")' 2>/dev/null)"
    printf '%s: %s%% used (most-constrained)   %s\n' "$name" "$pct" "$line"
  else
    printf '%s: usage returned but unparseable\n' "$name"
  fi
}
