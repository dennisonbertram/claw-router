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

# --- Pretty meters -------------------------------------------------------

# Format an ISO-8601 reset time as a compact "in 2h11m" / "in 3d04h" delta.
cr_fmt_reset() {
  local iso="$1"
  [[ -z "$iso" || "$iso" == "null" ]] && return 0
  cr_have python3 || return 0
  python3 - "$iso" <<'PY' 2>/dev/null
import sys, datetime
iso = sys.argv[1].replace("Z", "+00:00")
try:
    t = datetime.datetime.fromisoformat(iso)
except Exception:
    sys.exit(0)
now = datetime.datetime.now(datetime.timezone.utc)
s = int((t - now).total_seconds())
if s <= 0:
    print("now"); sys.exit(0)
d, r = divmod(s, 86400); h, r = divmod(r, 3600); m, _ = divmod(r, 60)
print(f"{d}d{h:02d}h" if d else (f"{h}h{m:02d}m" if h else f"{m}m"))
PY
}

# Build a [████░░░░] bar for a "percent left" value (0-100) at a given width.
cr_bar() {
  local left="$1" width="${2:-22}" filled i out=""
  filled="$(awk -v l="$left" -v w="$width" 'BEGIN{f=int(l/100*w+0.5); if(f<0)f=0; if(f>w)f=w; print f}')"
  for ((i=0; i<filled; i++));      do out+="█"; done
  for ((i=filled; i<width; i++));  do out+="░"; done
  printf '%s' "$out"
}

# ANSI color code by how much is left (green / yellow / red). Empty if no TTY.
cr_bar_color() {
  [[ -t 2 ]] || { printf ''; return; }
  awk -v l="$1" 'BEGIN{ if (l>=50) print "32"; else if (l>=20) print "33"; else print "31" }'
}

# Render the usage meters for one account (to stderr) and cache its usagePct.
# Best-effort: warns and returns nonzero if usage can't be fetched.
cr_render_account_meters() {
  local name="$1" dir raw email pct
  dir="$(cr_account_dir "$name")" || { cr_warn "unknown account: $name"; return 1; }
  raw="$(cr_fetch_usage_raw "$dir")" || { cr_warn "usage unavailable for '$name' (try: cr login $name)"; return 1; }

  email="$(cr_config_read | jq -r --arg n "$name" '.accounts[]|select(.name==$n)|.email // ""')"
  pct="$(cr_usage_pct "$raw")"
  if [[ -n "$pct" ]]; then
    cr_config_update '(.accounts[] | select(.name==$n) | .usagePct) = ($p|tonumber)' \
      --arg n "$name" --arg p "$pct" >/dev/null
  fi

  printf '\n  \033[1m%s\033[0m  %s\n' "$name" "$email" >&2

  local lab util reset left bar color rh
  while IFS=$'\t' read -r lab util reset; do
    [[ -z "$lab" ]] && continue
    left="$(awk -v u="$util" 'BEGIN{printf "%.0f", 100-u}')"
    bar="$(cr_bar "$left" 22)"
    rh="$(cr_fmt_reset "$reset")"
    color="$(cr_bar_color "$left")"
    if [[ -n "$color" ]]; then
      printf '    %-11s \033[%sm%s\033[0m %3s%% left%s\n' \
        "$lab" "$color" "$bar" "$left" "${rh:+   resets in $rh}" >&2
    else
      printf '    %-11s %s %3s%% left%s\n' \
        "$lab" "$bar" "$left" "${rh:+   resets in $rh}" >&2
    fi
  done < <(printf '%s' "$raw" | jq -r '
    . as $r
    | [ {k:"five_hour",      lab:"5h session"},
        {k:"seven_day",      lab:"7d total"},
        {k:"seven_day_opus", lab:"7d Opus"},
        {k:"seven_day_sonnet",lab:"7d Sonnet"} ]
    | .[]
    | . as $e | ($r[$e.k]) | select(. != null)
    | "\($e.lab)\t\((.utilization // .))\t\(.resets_at // "")"')
}

# Render meters for one account or all enabled accounts.
cr_render_meters() {
  local name="${1:-}"
  cr_say "usage left per window  (█ = available)"
  if [[ -n "$name" ]]; then
    cr_render_account_meters "$name"
  else
    local a any=0
    while IFS= read -r a; do
      cr_render_account_meters "$a" && any=1 || true
    done < <(cr_enabled_accounts)
    [[ "$any" -eq 0 ]] && cr_warn "no usage data available"
  fi
  printf '\n' >&2
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
