#!/usr/bin/env bash
# <xbar.title>Claw Router</xbar.title>
# <xbar.version>v1.0.0</xbar.version>
# <xbar.author>Dennison Bertram</xbar.author>
# <xbar.author.github>dennisonbertram</xbar.author.github>
# <xbar.desc>Menu-bar watcher for Claude or Codex account headroom via Claw Router (cr). Shows binding-constraint usage, per-window bars, and provider-scoped policy/pin actions.</xbar.desc>
# <xbar.dependencies>cr,jq</xbar.dependencies>
# <xbar.var>string(CLAWROUTER_CR=cr): Path/name of the cr binary. Override when cr is not on SwiftBar's PATH.</xbar.var>
# <xbar.var>string(CLAWROUTER_JQ=jq): Path/name of the jq binary.</xbar.var>
# <xbar.var>string(CLAWROUTER_PROVIDER=claude): Provider dashboard to show: claude or codex.</xbar.var>
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
PROVIDER="${CLAWROUTER_PROVIDER:-claude}"
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
case "$PROVIDER" in
  claude)
    # Keep the legacy invocation for schema-1 routers and existing installs.
    data="$("$CR_BIN" status --json 2>/dev/null)" || data="" ;;
  codex)
    data="$("$CR_BIN" --provider codex status --json 2>/dev/null)" || data="" ;;
  *)
    printf '🦞 ⚠\n---\nUnknown provider: %s (use claude or codex).\n' "$PROVIDER"
    exit 0 ;;
esac

# Validate JSON.
if [[ -z "$data" ]] || ! printf '%s' "$data" | "$JQ_BIN" -e . >/dev/null 2>&1; then
  printf '🦞 —\n'
  echo '---'
  printf 'No data yet — open a terminal and run: cr status --refresh\n'
  exit 0
fi

# --- Compute title ---------------------------------------------------------
# Binding constraint = minimum leftPct across all windows of in-rotation accounts.
# Rolled-over windows are frozen pre-reset numbers, not current headroom — exclude
# them so a just-reset window can't force the title to '🦞 0%'. `!= true` (not
# `== false`) so older cached JSON lacking the field still counts as live.
min_left="$(printf '%s' "$data" | "$JQ_BIN" -r '
  [.accounts[] | select(.inRotation == true) | .windows[] | select(.rolledOver != true) | .leftPct]
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

# --- Helper: compact "ago" delta for a PAST ISO-8601 timestamp --------------
# Empty output when the timestamp is in the future, unparseable, or python3 is
# missing — callers degrade to text without a time.
fmt_ago() {
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
s = int((now - t).total_seconds())
if s < 0:
    sys.exit(0)
d, r = divmod(s, 86400); h, r = divmod(r, 3600); m, _ = divmod(r, 60)
print(f"{d}d{h:02d}h" if d else (f"{h}h{m:02d}m" if h else f"{m}m"))
PY
}

# --- Header: policy + next pick -------------------------------------------
policy="$(printf '%s' "$data" | "$JQ_BIN" -r '.policy')" || policy="round-robin"
pinned="$(printf '%s' "$data" | "$JQ_BIN" -r '.pinned // ""')" || pinned=""
next_name="$(printf '%s' "$data" | "$JQ_BIN" -r '.next.name // ""')" || next_name=""
next_note="$(printf '%s' "$data" | "$JQ_BIN" -r '.next.note // ""')" || next_note=""
selected_provider="$(printf '%s' "$data" | "$JQ_BIN" -r --arg p "$PROVIDER" '.provider // $p')" || selected_provider="$PROVIDER"

header_line="Provider: ${selected_provider}  Policy: ${policy}"
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
stale_inrotation="$(printf '%s' "$data" | "$JQ_BIN" -r '[.accounts[] | select(.inRotation==true and .stale==true and ((.windows // []) | length) > 0)] | length')" || stale_inrotation=0
if [[ "${stale_inrotation:-0}" -gt 0 && "$agent_loaded" -eq 0 ]]; then
  printf '%s\n' '⚠ Usage is stale — turn on "Enable background refresh" below | color=#c8821a font=Menlo size=12'
fi

# --- Per-account rows: in-rotation first, then non-rotating ---------------
# Read all accounts as JSON lines; sort inRotation=true first.
acct_json_list="$(printf '%s' "$data" | "$JQ_BIN" -c '[.accounts[] | {name,provider:(.provider // "claude"),kind,email,inRotation,usagePct,exhausted,stale,windows,enabled}] | sort_by(.inRotation | not)')" || acct_json_list="[]"

# Track whether we have printed the separator between rotating and non-rotating.
prev_in_rotation=-1  # -1 = not started

acct_count="$(printf '%s' "$acct_json_list" | "$JQ_BIN" 'length')" || acct_count=0

for ((i=0; i<acct_count; i++)); do
  acct="$(printf '%s' "$acct_json_list" | "$JQ_BIN" -c ".[$i]")" || continue
  aname="$(printf '%s' "$acct" | "$JQ_BIN" -r '.name')" || aname="?"
  aprovider="$(printf '%s' "$acct" | "$JQ_BIN" -r '.provider // "claude"')" || aprovider="claude"
  aemail="$(printf '%s' "$acct" | "$JQ_BIN" -r '.email // ""')" || aemail=""
  ain="$(printf '%s' "$acct" | "$JQ_BIN" -r '.inRotation')" || ain="false"
  aexhausted="$(printf '%s' "$acct" | "$JQ_BIN" -r '.exhausted')" || aexhausted="false"
  astale="$(printf '%s' "$acct" | "$JQ_BIN" -r '.stale')" || astale="false"
  awindows="$(printf '%s' "$acct" | "$JQ_BIN" -c '.windows')" || awindows="[]"
  awin_count="$(printf '%s' "$awindows" | "$JQ_BIN" 'length')" || awin_count=0

  # Thin separator between in-rotation and non-rotating groups.
  if [[ "$prev_in_rotation" -eq 1 && "$ain" == "false" ]]; then
    echo '---'
  fi
  prev_in_rotation="$([ "$ain" == "true" ] && echo 1 || echo 0)"

  # Build account name line.
  name_label="◆ ${aname}  [${aprovider}]"
  [[ -n "$aemail" ]] && name_label="${name_label}  ${aemail}"
  [[ "$aexhausted" == "true" ]] && name_label="${name_label}  · exhausted"
  # Stale but not exhausted: the numbers below are frozen (couldn't refresh —
  # often an expired login), not a live reading. Say so instead of implying live.
  [[ "$aexhausted" != "true" && "$astale" == "true" && "$awin_count" -gt 0 ]] && name_label="${name_label}  · stale"
  [[ "$ain" == "false" ]] && name_label="${name_label}  · explicit-only"

  name_params="font=Menlo"
  [[ "$aexhausted" == "true" ]] && name_params="${name_params} color=#c0392b"
  [[ "$aexhausted" != "true" && "$astale" == "true" && "$awin_count" -gt 0 ]] && name_params="${name_params} color=#c8821a"
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
      wrolled="$(printf '%s' "$win" | "$JQ_BIN" -r '.rolledOver // false')" || wrolled="false"

      wbar="$(make_bar "$wleft")"
      wcolor="$(left_color_param "$wleft")"

      # Compact label, kept UNIQUE so the three 7d windows don't all read "7d".
      # Pre-padded to a fixed display width (4 cols) here, since · is multibyte
      # and would confuse printf %-Ns padding.
      case "$wlabel" in
        "5h session") short_label="5h  " ;;
        "7d total")   short_label="7d  " ;;
        "7d Opus")    short_label="7dO " ;;
        "7d Sonnet")  short_label="7dS " ;;
        "7d Haiku")   short_label="7dH " ;;
        *)            short_label="$(printf '%-4s' "$(printf '%s' "$wlabel" | awk '{print $1}')")" ;;
      esac

      # The cached numbers predate the window reset; drawing them as a live red
      # 0% bar would contradict exhausted=false. Say so — with WHEN it rolled
      # over, so the line isn't vague — and move on.
      if [[ "$wrolled" == "true" ]]; then
        rolled_ago="$(fmt_ago "$wresets")"
        if [[ -n "$rolled_ago" ]]; then
          printf '  %s rolled over %s ago — awaiting refresh | font=Menlo size=12 color=#888888\n' "$short_label" "$rolled_ago"
        else
          printf '  %s rolled over — awaiting refresh | font=Menlo size=12 color=#888888\n' "$short_label"
        fi
        continue
      fi

      # Reset countdown.
      reset_str=""
      if [[ -n "$wresets" && "$wresets" != "null" ]]; then
        rdelta="$(fmt_reset "$wresets")"
        [[ -n "$rdelta" ]] && reset_str=" · ${rdelta}"
      fi

      printf '  %s %s %s%%%s | font=Menlo size=12 %s\n' \
        "$short_label" "$wbar" "$wleft" "$reset_str" "$wcolor"
    done
  fi
done

# --- Actions section -------------------------------------------------------
echo '---'
# ACTION-LINE FORMAT: SwiftBar parses ONE "|" and then space-separated key=value
# params. Extra " | " separators between params corrupt the keys ("param1"
# parses as "| param1"), which silently drops BOTH terminal=false and the args —
# the click then opens a Terminal window running the bare command. So: exactly
# one pipe per action line, and quote path values (quotes are parsed + stripped)
# so spaced install dirs survive.
# "Refresh now" delegates to the background agent (no Keychain prompts in the plugin).
# If the agent is not loaded, offer to install it instead.
if [[ "$agent_loaded" -eq 1 ]]; then
  # kick-wait BLOCKS until the forced poll writes a fresh snapshot, so the
  # refresh=true re-render below shows real data. A bare `kickstart` returns
  # instantly and the menu would redraw the pre-kick (stale) cache — which reads
  # as "Refresh did nothing". SwiftBar/xbar shows a running indicator meanwhile.
  printf 'Refresh now | shell="%s" param1=kick-wait terminal=false refresh=true\n' \
    "$AGENT_SH"
else
  printf 'Enable background refresh… | shell="%s" param1=install terminal=true refresh=true\n' "$AGENT_SH"
fi
# Action clicks exec under SwiftBar's own minimal GUI PATH — this plugin's
# PATH fix-up above doesn't apply to them — so a bare "cr" won't resolve there.
# Hand actions the absolute path instead.
CR_ACTION_BIN="$(command -v "$CR_BIN" 2>/dev/null || printf '%s' "$CR_BIN")"
printf '%s\n' 'Policy'
for p in round-robin lru random usage-aware; do
  if [[ "$selected_provider" == "claude" ]]; then
    printf -- '--%s | shell="%s" param1=policy param2=%s terminal=false refresh=true\n' "$p" "$CR_ACTION_BIN" "$p"
  else
    printf -- '--%s | shell="%s" param1=--provider param2="%s" param3=policy param4=%s terminal=false refresh=true\n' \
      "$p" "$CR_ACTION_BIN" "$selected_provider" "$p"
  fi
done
printf '%s\n' 'Pin account'
# The status contract owns provider-specific eligibility through inRotation.
pin_names="$(printf '%s' "$data" | "$JQ_BIN" -r '.accounts[] | select(.inRotation == true) | .name')" || pin_names=""
while IFS= read -r pname; do
  [[ -z "$pname" ]] && continue
  if [[ "$selected_provider" == "claude" ]]; then
    printf -- '--%s | shell="%s" param1=use param2="%s" terminal=false refresh=true\n' "$pname" "$CR_ACTION_BIN" "$pname"
  else
    printf -- '--%s | shell="%s" param1=--provider param2="%s" param3=use param4="%s" terminal=false refresh=true\n' \
      "$pname" "$CR_ACTION_BIN" "$selected_provider" "$pname"
  fi
done <<< "$pin_names"
if [[ "$selected_provider" == "claude" ]]; then
  printf -- '--Clear pin | shell="%s" param1=use param2=--clear terminal=false refresh=true\n' "$CR_ACTION_BIN"
else
  printf -- '--Clear pin | shell="%s" param1=--provider param2="%s" param3=use param4=--clear terminal=false refresh=true\n' \
    "$CR_ACTION_BIN" "$selected_provider"
fi
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
