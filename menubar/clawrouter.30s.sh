#!/usr/bin/env bash
# <xbar.title>Claw Router</xbar.title>
# <xbar.version>v1.0.0</xbar.version>
# <xbar.author>Dennison Bertram</xbar.author>
# <xbar.author.github>dennisonbertram</xbar.author.github>
# <xbar.desc>Menu-bar watcher for Claude subscription headroom via Claw Router (cr). Shows binding-constraint usage, per-window bars, and policy/pin actions.</xbar.desc>
# <xbar.dependencies>cr,jq</xbar.dependencies>
# <xbar.var>string(CLAWROUTER_CR=cr): Path/name of the cr binary. Override when cr is not on SwiftBar's PATH.</xbar.var>
# <xbar.var>string(CLAWROUTER_JQ=jq): Path/name of the jq binary.</xbar.var>
# <xbar.var>string(CLAWROUTER_NOTIFY=1): Set to 0 or false to silence exhaust notifications.</xbar.var>
#
# The .30s. in the filename sets the refresh interval to 30 seconds.
# Rename to .1m. for a 60-second interval, etc.

# NOT -e: a plugin must never die mid-render and leave an empty menu.
set -uo pipefail

# --- Tool resolution -------------------------------------------------------
# SwiftBar runs with a minimal PATH. Prepend common locations so cr and jq resolve.
PATH="/opt/homebrew/bin:/usr/local/bin:${HOME}/.local/bin:${PATH}"

CR_BIN="${CLAWROUTER_CR:-cr}"
JQ_BIN="${CLAWROUTER_JQ:-jq}"
LAUNCHCTL="${CLAWROUTER_LAUNCHCTL:-launchctl}"
LABEL="com.clawrouter.refresh"
AGENT_DOMAIN="gui/$(id -u 2>/dev/null || echo 0)"

# Resolve this plugin's real directory (handles SwiftBar symlinks).
self="${BASH_SOURCE[0]}"
while [ -L "$self" ]; do
  d=$(cd -P "$(dirname "$self")" && pwd)
  self=$(readlink "$self")
  case "$self" in /*) ;; *) self="$d/$self" ;; esac
done
MENUBAR_DIR=$(cd -P "$(dirname "$self")" && pwd)
AGENT_SH="$MENUBAR_DIR/agent.sh"

# Detect whether the background refresh LaunchAgent is loaded.
agent_loaded=0
if command -v "$LAUNCHCTL" >/dev/null 2>&1; then
  "$LAUNCHCTL" print "$AGENT_DOMAIN/$LABEL" >/dev/null 2>&1 && agent_loaded=1 || true
fi

# Check for required tools before doing anything else.
if ! command -v "$CR_BIN" >/dev/null 2>&1 || ! command -v "$JQ_BIN" >/dev/null 2>&1; then
  printf '🦞 ⚠\n'
  echo '---'
  if ! command -v "$CR_BIN" >/dev/null 2>&1; then
    printf 'cr not found on PATH. Set CLAWROUTER_CR to the absolute path (e.g. %s).\n' "$(command -v cr 2>/dev/null || echo /opt/homebrew/bin/cr)"
  fi
  if ! command -v "$JQ_BIN" >/dev/null 2>&1; then
    printf 'jq not found on PATH. Set CLAWROUTER_JQ to the absolute path (e.g. %s).\n' "$(command -v jq 2>/dev/null || echo /opt/homebrew/bin/jq)"
  fi
  printf 'In SwiftBar: right-click the plugin → Plugin Settings to set env vars.\n'
  exit 0
fi

# --- Fetch cached data (fast, no network, no Keychain) ---------------------
data="$("$CR_BIN" status --json 2>/dev/null)" || data=""

# Validate JSON.
if [[ -z "$data" ]] || ! printf '%s' "$data" | "$JQ_BIN" -e . >/dev/null 2>&1; then
  printf '🦞 —\n'
  echo '---'
  printf 'No data yet — open a terminal and run: cr status --refresh\n'
  exit 0
fi

# --- Compute title ---------------------------------------------------------
# Binding constraint = minimum leftPct across all windows of in-rotation accounts.
min_left="$(printf '%s' "$data" | "$JQ_BIN" -r '
  [.accounts[] | select(.inRotation == true) | .windows[] | .leftPct]
  | if length > 0 then min else empty end
')" || min_left=""

if [[ -z "$min_left" ]]; then
  title_text="🦞 —"
  title_color=""
else
  title_text="🦞 ${min_left}%"
  # Color by headroom threshold.
  if [[ "$min_left" -ge 50 ]]; then
    title_color="color=#2e9e5b"
  elif [[ "$min_left" -ge 20 ]]; then
    title_color="color=#c8821a"
  else
    title_color="color=#c0392b"
  fi
fi

if [[ -n "$title_color" ]]; then
  printf '%s\n' "${title_text} | ${title_color}"
else
  printf '%s\n' "$title_text"
fi
echo '---'

# --- Helper: 10-cell unicode bar from leftPct ------------------------------
make_bar() {
  local left="$1" filled i bar=""
  # Round to nearest cell.
  filled="$(awk -v l="$left" 'BEGIN{ f=int(l/100*10+0.5); if(f<0)f=0; if(f>10)f=10; print f }')" || filled=0
  for ((i=0; i<filled; i++)); do bar="${bar}█"; done
  for ((i=filled; i<10; i++)); do bar="${bar}░"; done
  printf '%s' "$bar"
}

# --- Helper: color param string from leftPct --------------------------------
left_color_param() {
  local left="$1"
  if [[ "$left" -ge 50 ]]; then
    printf 'color=#2e9e5b'
  elif [[ "$left" -ge 20 ]]; then
    printf 'color=#c8821a'
  else
    printf 'color=#c0392b'
  fi
}

# --- Helper: compact "resets in" delta from ISO-8601 timestamp -------------
fmt_reset() {
  local iso="$1"
  [[ -z "$iso" || "$iso" == "null" ]] && return 0
  command -v python3 >/dev/null 2>&1 || return 0
  python3 - "$iso" <<'PY' 2>/dev/null || true
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

# --- Header: policy + next pick -------------------------------------------
policy="$(printf '%s' "$data" | "$JQ_BIN" -r '.policy')" || policy="round-robin"
pinned="$(printf '%s' "$data" | "$JQ_BIN" -r '.pinned // ""')" || pinned=""
next_name="$(printf '%s' "$data" | "$JQ_BIN" -r '.next.name // ""')" || next_name=""
next_note="$(printf '%s' "$data" | "$JQ_BIN" -r '.next.note // ""')" || next_note=""

header_line="Policy: ${policy}"
[[ -n "$pinned" ]] && header_line="${header_line}  · pinned: ${pinned}"

if [[ -n "$next_name" ]]; then
  header_line="${header_line}  Next: ${next_name}"
  [[ -n "$next_note" ]] && header_line="${header_line} (${next_note})"
else
  header_line="${header_line}  Next: ${next_note:-round-robin (run cr)}"
fi

printf '%s | font=Menlo size=12\n' "$header_line"
echo '---'

# --- Stale-data hint (shown only when agent is not loaded) -----------------
stale_inrotation="$(printf '%s' "$data" | "$JQ_BIN" -r '[.accounts[] | select(.kind=="subscription" and .inRotation==true and .stale==true)] | length')" || stale_inrotation=0
if [[ "${stale_inrotation:-0}" -gt 0 && "$agent_loaded" -eq 0 ]]; then
  printf '%s\n' '⚠ Usage is stale — turn on "Enable background refresh" below | color=#c8821a font=Menlo size=12'
fi

# --- Per-account rows: in-rotation first, then non-rotating ---------------
# Read all accounts as JSON lines; sort inRotation=true first.
acct_json_list="$(printf '%s' "$data" | "$JQ_BIN" -c '[.accounts[] | {name,kind,email,inRotation,usagePct,exhausted,stale,windows,enabled}] | sort_by(.inRotation | not)')" || acct_json_list="[]"

# Track whether we have printed the separator between rotating and non-rotating.
prev_in_rotation=-1  # -1 = not started

acct_count="$(printf '%s' "$acct_json_list" | "$JQ_BIN" 'length')" || acct_count=0

for ((i=0; i<acct_count; i++)); do
  acct="$(printf '%s' "$acct_json_list" | "$JQ_BIN" -c ".[$i]")" || continue
  aname="$(printf '%s' "$acct" | "$JQ_BIN" -r '.name')" || aname="?"
  aemail="$(printf '%s' "$acct" | "$JQ_BIN" -r '.email // ""')" || aemail=""
  ain="$(printf '%s' "$acct" | "$JQ_BIN" -r '.inRotation')" || ain="false"
  aexhausted="$(printf '%s' "$acct" | "$JQ_BIN" -r '.exhausted')" || aexhausted="false"
  awindows="$(printf '%s' "$acct" | "$JQ_BIN" -c '.windows')" || awindows="[]"
  awin_count="$(printf '%s' "$awindows" | "$JQ_BIN" 'length')" || awin_count=0

  # Thin separator between in-rotation and non-rotating groups.
  if [[ "$prev_in_rotation" -eq 1 && "$ain" == "false" ]]; then
    echo '---'
  fi
  prev_in_rotation="$([ "$ain" == "true" ] && echo 1 || echo 0)"

  # Build account name line.
  name_label="◆ ${aname}"
  [[ -n "$aemail" ]] && name_label="${name_label}  ${aemail}"
  [[ "$aexhausted" == "true" ]] && name_label="${name_label}  · exhausted"
  [[ "$ain" == "false" ]] && name_label="${name_label}  · explicit-only"

  name_params="font=Menlo"
  [[ "$aexhausted" == "true" ]] && name_params="${name_params} color=#c0392b"
  [[ "$ain" == "false" ]] && name_params="${name_params} color=#888888"

  printf '%s | %s\n' "$name_label" "$name_params"

  # Per-window sub-lines.
  if [[ "$awin_count" -eq 0 ]]; then
    printf '  no usage data | font=Menlo size=12 color=#888888\n'
  else
    for ((w=0; w<awin_count; w++)); do
      win="$(printf '%s' "$awindows" | "$JQ_BIN" -c ".[$w]")" || continue
      wlabel="$(printf '%s' "$win" | "$JQ_BIN" -r '.label')" || wlabel="?"
      wleft="$(printf '%s' "$win" | "$JQ_BIN" -r '.leftPct')" || wleft=0
      wresets="$(printf '%s' "$win" | "$JQ_BIN" -r '.resetsAt // ""')" || wresets=""

      wbar="$(make_bar "$wleft")"
      wcolor="$(left_color_param "$wleft")"

      # Compact label: shorten "5h session" → "5h", "7d total" → "7d", etc.
      short_label="$(printf '%s' "$wlabel" | awk '{print $1}')"

      # Reset countdown.
      reset_str=""
      if [[ -n "$wresets" && "$wresets" != "null" ]]; then
        rdelta="$(fmt_reset "$wresets")"
        [[ -n "$rdelta" ]] && reset_str=" · ${rdelta}"
      fi

      printf '  %-4s %s %s%%%s | font=Menlo size=12 %s\n' \
        "$short_label" "$wbar" "$wleft" "$reset_str" "$wcolor"
    done
  fi
done

# --- Actions section -------------------------------------------------------
echo '---'
# "Refresh now" delegates to the background agent (no Keychain prompts in the plugin).
# If the agent is not loaded, offer to install it instead.
if [[ "$agent_loaded" -eq 1 ]]; then
  printf 'Refresh now | shell=%s | param1=kickstart | param2=-k | param3=%s/%s | terminal=false | refresh=true\n' \
    "$LAUNCHCTL" "$AGENT_DOMAIN" "$LABEL"
else
  printf '%s\n' "Enable background refresh… | shell=${AGENT_SH} | param1=install | terminal=true | refresh=true"
fi
printf '%s\n' 'Policy'
for p in round-robin lru random usage-aware; do
  printf '%s\n' "--${p} | shell=${CR_BIN} | param1=policy | param2=${p} | terminal=false | refresh=true"
done
printf '%s\n' 'Pin account'
# Only subscription and rotating-api accounts can be pinned.
pin_names="$(printf '%s' "$data" | "$JQ_BIN" -r '.accounts[] | select(.kind == "subscription" or (.kind == "api" and .rotate == true)) | .name')" || pin_names=""
while IFS= read -r pname; do
  [[ -z "$pname" ]] && continue
  printf '%s\n' "--${pname} | shell=${CR_BIN} | param1=use | param2=${pname} | terminal=false | refresh=true"
done <<< "$pin_names"
printf '%s\n' "--Clear pin | shell=${CR_BIN} | param1=use | param2=--clear | terminal=false | refresh=true"
printf 'Open Claw Router ↗ | href=https://dennisonbertram.github.io/claw-router/\n'

# --- Notifications (throttled, opt-out) ------------------------------------
# Gate on CLAWROUTER_NOTIFY (default ON; set to 0 or false to disable).
notify_enabled="${CLAWROUTER_NOTIFY:-1}"
if [[ "$notify_enabled" != "0" && "$notify_enabled" != "false" ]]; then
  state_file="${TMPDIR:-/tmp}/clawrouter-menubar.exhausted"

  # Compute current set of exhausted in-rotation account names (sorted).
  new_exhausted="$(printf '%s' "$data" | "$JQ_BIN" -r '[.accounts[] | select(.inRotation == true and .exhausted == true) | .name] | sort | .[]')" || new_exhausted=""

  # Load previously known exhausted set.
  old_exhausted=""
  if [[ -f "$state_file" ]]; then
    old_exhausted="$(cat "$state_file" 2>/dev/null || true)"
  fi

  # For any name NEWLY exhausted, fire a notification.
  if command -v osascript >/dev/null 2>&1; then
    while IFS= read -r exname; do
      [[ -z "$exname" ]] && continue
      if ! grep -qx "$exname" <<< "$old_exhausted" 2>/dev/null; then
        # Get usagePct for the message.
        epct="$(printf '%s' "$data" | "$JQ_BIN" -r --arg n "$exname" '.accounts[] | select(.name == $n) | .usagePct // "?"')" || epct="?"
        osascript - "$exname" "$epct" >/dev/null 2>&1 <<'AS' || true
on run argv
  display notification ((item 1 of argv) & " is at " & (item 2 of argv) & "% — switch accounts") with title "Claw Router"
end run
AS
      fi
    done <<< "$new_exhausted"
  fi

  # Overwrite state file with the new exhausted set.
  printf '%s\n' "$new_exhausted" > "$state_file" 2>/dev/null || true
fi

exit 0
