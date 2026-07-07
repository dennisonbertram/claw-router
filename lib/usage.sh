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

# Exchange a refresh token for a fresh token set. Echoes the raw OAuth token
# response JSON ({access_token, refresh_token?, expires_in?, ...}) on stdout so
# the caller can persist the rotated refresh token too. Nonzero on failure or
# when the response carries no access token.
cr_refresh_token() {
  local refresh="$1" resp
  cr_have curl || return 2
  resp="$(curl -fsS --max-time 10 -X POST "$CR_TOKEN_URL" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg rt "$refresh" --arg cid "$CR_OAUTH_CLIENT_ID" \
          '{grant_type:"refresh_token", refresh_token:$rt, client_id:$cid}')" 2>/dev/null)" || return 1
  printf '%s' "$resp" | jq -e '.access_token' >/dev/null 2>&1 || return 1
  printf '%s' "$resp"
}

# Persist an updated credentials JSON blob for a config dir, mirroring exactly
# where cr_read_credentials reads from: macOS Keychain, else <dir>/.credentials.json.
# Best-effort: returns nonzero if it could not be written anywhere.
cr_write_credentials() {
  local dir="$1" blob="$2" svc file
  [[ -z "$blob" || "$blob" == "null" ]] && return 1
  if cr_have security; then
    svc="$(cr_keychain_service "$dir")"
    security add-generic-password -U -s "$svc" -a "${USER:-$(id -un)}" -w "$blob" 2>/dev/null && return 0
  fi
  if [[ -n "$dir" ]]; then file="${dir}/.credentials.json"; else file="${HOME}/.claude/.credentials.json"; fi
  [[ -e "$file" || -d "$(dirname "$file")" ]] || return 1
  ( umask 177; printf '%s' "$blob" > "$file" ) 2>/dev/null || return 1
  return 0
}

# Merge a fresh OAuth token response into the stored credentials blob and write
# it back. Anthropic ROTATES refresh tokens, so persisting both the new access
# token and any rotated refresh token is mandatory — otherwise the next poll
# re-uses the now-invalid stored tokens and auto-refresh breaks permanently
# (leaving usage frozen at the last snapshot). Best-effort; nonzero on failure.
cr_persist_refreshed_creds() {
  local dir="$1" creds="$2" resp="$3" merged now_ms
  now_ms="$(( $(date +%s) * 1000 ))"
  merged="$(jq -n --argjson creds "$creds" --argjson resp "$resp" --argjson now "$now_ms" '
    $creds
    | .claudeAiOauth.accessToken = $resp.access_token
    | (if ($resp.refresh_token // null) != null then .claudeAiOauth.refreshToken = $resp.refresh_token else . end)
    | (if ($resp.expires_in   // null) != null then .claudeAiOauth.expiresAt   = ($now + ($resp.expires_in * 1000)) else . end)
  ' 2>/dev/null)" || return 1
  cr_write_credentials "$dir" "$merged"
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
    local rtresp newtok
    rtresp="$(cr_refresh_token "$refresh")" || return 1
    newtok="$(printf '%s' "$rtresp" | jq -r '.access_token // empty')"
    [[ -z "$newtok" ]] && return 1
    # Persist refreshed + rotated tokens so the NEXT poll doesn't re-use the
    # expired/consumed ones. Best-effort — a write failure must not fail the poll.
    cr_persist_refreshed_creds "$dir" "$creds" "$rtresp" || true
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
  [[ -n "$pct" ]] && cr_cache_usage "$name" "$pct" "$raw"

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

# Render meters for one account or all enabled subscription accounts.
# api accounts are skipped in all-accounts mode (pay-per-token, no usage windows).
# If a specific api account is named explicitly, print a short note and return 0.
cr_render_meters() {
  local name="${1:-}"
  cr_say "usage left per window  (█ = available)"
  if [[ -n "$name" ]]; then
    local kind; kind="$(cr_account_kind "$name" 2>/dev/null || true)"
    if [[ "$kind" == "api" ]]; then
      cr_say "$name: api-key account — pay-per-token, no usage windows"
      printf '\n' >&2
      return 0
    fi
    cr_render_account_meters "$name"
  else
    local a any=0
    while IFS= read -r a; do
      cr_render_account_meters "$a" && any=1 || true
    done < <(cr_subscription_accounts)
    [[ "$any" -eq 0 ]] && cr_warn "no usage data available"
  fi
  printf '\n' >&2
}

# Cache usagePct + a compact per-window snapshot + a timestamp into the registry,
# so `cr status` can draw bars instantly without hitting the network.
# Stored shape:  .usagePct (number)  .usage = { checkedAt, windows: [{label,used,resets}] }
cr_cache_usage() {
  local name="$1" pct="$2" raw="$3" now_ms win_json
  now_ms="$(( $(date +%s) * 1000 ))"
  win_json="$(printf '%s' "$raw" | jq -c '
    . as $r
    | [ {k:"five_hour",lab:"5h session"}, {k:"seven_day",lab:"7d total"},
        {k:"seven_day_opus",lab:"7d Opus"}, {k:"seven_day_sonnet",lab:"7d Sonnet"} ]
    | map(. as $e | ($r[$e.k]) as $w | select($w != null)
          | {label:$e.lab, used:($w.utilization // $w), resets:($w.resets_at // null)})' 2>/dev/null)"
  [[ -z "$win_json" || "$win_json" == "null" ]] && win_json='[]'
  cr_config_update '
    (.accounts[] | select(.name==$n) | .usagePct) = ($p|tonumber)
    | (.accounts[] | select(.name==$n) | .usage) = {checkedAt:($t|tonumber), windows:$w}' \
    --arg n "$name" --arg p "$pct" --arg t "$now_ms" --argjson w "$win_json" >/dev/null
}

# Render cached usage bars for every enabled account to stderr — no network.
# Reads the .usage snapshot saved by the last `cr usage` / `--refresh`.
cr_render_cached_bars() {
  local rows; rows="$(cr_config_read)"
  local any=0 name email pct checked
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    email="$(printf '%s' "$rows" | jq -r --arg n "$name" '.accounts[]|select(.name==$n)|.email // ""')"
    pct="$(printf '%s' "$rows"   | jq -r --arg n "$name" '.accounts[]|select(.name==$n)|.usagePct // empty')"
    checked="$(printf '%s' "$rows" | jq -r --arg n "$name" '.accounts[]|select(.name==$n)|.usage.checkedAt // empty')"

    printf '  %s◆ %s%s  %s%s%s' "$C_ACCENT$C_BOLD" "$name" "$C_RESET" "$C_GREY" "$email" "$C_RESET" >&2
    if [[ -n "$checked" ]]; then
      printf '  %s%s%s\n' "$C_DIM" "($(cr_age_human "$checked") ago)" "$C_RESET" >&2
    else
      printf '\n' >&2
    fi

    local wins; wins="$(printf '%s' "$rows" | jq -c --arg n "$name" \
      '.accounts[]|select(.name==$n)|.usage.windows // []')"
    if [[ "$wins" == "[]" || -z "$wins" ]]; then
      printf '    %sno usage data — run %scr usage%s%s\n' "$C_DIM" "$C_CYAN" "$C_RESET$C_DIM" "$C_RESET" >&2
    else
      any=1
      local lab used resets left bar color rh suffix
      while IFS=$'\t' read -r lab used resets; do
        [[ -z "$lab" ]] && continue
        left="$(awk -v u="$used" 'BEGIN{printf "%.0f", 100-u}')"
        bar="$(cr_bar "$left" 20)"; color="$(cr_bar_color "$left")"; rh="$(cr_fmt_reset "$resets")"
        suffix=""
        [[ -n "$rh" ]] && suffix="   ${C_GREY}resets in ${rh}${C_RESET}"
        if [[ -n "$color" ]]; then
          printf '    %-11s \033[%sm%s\033[0m %3s%% left%s\n' "$lab" "$color" "$bar" "$left" "$suffix" >&2
        else
          printf '    %-11s %s %3s%% left%s\n' "$lab" "$bar" "$left" "$suffix" >&2
        fi
      done < <(printf '%s' "$wins" | jq -r '.[] | "\(.label)\t\(.used)\t\(.resets // "")"')
    fi
    printf '\n' >&2
  done < <(cr_subscription_accounts)
  return $(( any ? 0 : 1 ))
}

# Humanize a ms-epoch timestamp as "3m" / "2h" / "5d" elapsed.
cr_age_human() {
  local then_ms="$1" now_s then_s d
  now_s="$(date +%s)"; then_s=$(( then_ms / 1000 )); d=$(( now_s - then_s ))
  (( d < 0 )) && d=0
  if   (( d < 90 ));    then printf '%ds' "$d"
  elif (( d < 5400 ));  then printf '%dm' $(( (d+30)/60 ))
  elif (( d < 172800 ));then printf '%dh' $(( (d+1800)/3600 ))
  else printf '%dd' $(( (d+43200)/86400 )); fi
}

# Refresh cached usage for all enabled accounts IF the cache is stale, so the
# "skip exhausted accounts" routing has fresh numbers. Best-effort and bounded:
# - Skips entirely without curl, or when disabled via .autoRefreshUsage=false.
# - TTL from .usageTtlSeconds (default 900s = 15m).
# - Polls accounts whose snapshot is older than the TTL (or missing).
# This adds a little latency to a launch only when the cache has gone stale.
cr_refresh_usage_if_stale() {
  [[ -n "${CR_NO_AUTO_REFRESH:-}" ]] && return 0   # test/escape hatch
  cr_have curl || return 0
  [[ "$(cr_config_read | jq -r '.autoRefreshUsage // true')" == "false" ]] && return 0
  local ttl now_s; ttl="$(cr_config_read | jq -r '.usageTtlSeconds // 900')"
  now_s="$(date +%s)"
  local stale; stale="$(cr_config_read | jq -r --argjson now "$now_s" --argjson ttl "$ttl" '
    .accounts[]
    | select(.enabled != false)
    | select((.kind // "subscription") == "subscription")
    | select(((.usage.checkedAt // 0) / 1000) < ($now - $ttl))
    | .name')"
  [[ -z "$stale" ]] && return 0
  local a; while IFS= read -r a; do
    [[ -n "$a" ]] && cr_poll_account "$a" >/dev/null 2>&1 || true
  done <<< "$stale"
}

# Poll one account and cache its usagePct + a short summary into the registry.
# Echoes a human summary line. Best-effort.
cr_poll_account() {
  local name="$1" dir raw pct line
  dir="$(cr_account_dir "$name")" || { cr_warn "unknown account: $name"; return 1; }
  raw="$(cr_fetch_usage_raw "$dir")" || { cr_warn "usage poll failed for '$name'"; return 1; }
  pct="$(cr_usage_pct "$raw")"
  if [[ -n "$pct" ]]; then
    cr_cache_usage "$name" "$pct" "$raw"
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
