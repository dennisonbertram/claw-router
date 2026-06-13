#!/usr/bin/env bash
# agent.sh — LaunchAgent manager for Claw Router background usage polling.
#
# The SwiftBar plugin reads only the cached snapshot and NEVER polls itself,
# so it never triggers macOS Keychain prompts. This agent is the sole poller:
# it runs `cr status --refresh` on a schedule, updating the cache silently.
# Because launchd owns the process, macOS prompts ("Allow" / "Always Allow")
# are shown once per account at agent launch — click **Always Allow** and they
# never appear again.
#
# Usage:
#   bash menubar/agent.sh install [interval_seconds]
#   bash menubar/agent.sh uninstall
#   bash menubar/agent.sh status
#   bash menubar/agent.sh kick
#   cr menubar install|uninstall|status|refresh
#
# Testability: override CLAWROUTER_LAUNCH_AGENTS_DIR, CLAWROUTER_LAUNCHCTL,
# and CLAWROUTER_CR to stub the environment in tests (no real launchd/Keychain).

set -euo pipefail

# --- Constants / overridable via env -----------------------------------------
LABEL="com.clawrouter.refresh"
AGENTS_DIR="${CLAWROUTER_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
PLIST="$AGENTS_DIR/$LABEL.plist"
LAUNCHCTL="${CLAWROUTER_LAUNCHCTL:-launchctl}"
# Fix 6: use || echo 0 fallback to match plugin consistency.
DOMAIN="gui/$(id -u 2>/dev/null || echo 0)"

# Data home — MUST match lib/common.sh's resolution so the agent logs into (and
# the polled `cr` reads) the SAME directory. Hardcoding ~/.claw-router here
# would CREATE it and flip cr's legacy-aware resolution, orphaning an existing
# ~/.claude-router install. Honor an explicit CR_HOME, else prefer the legacy
# dir when it exists and the new one does not.
if [[ -n "${CR_HOME:-}" ]]; then
  CR_DATA_HOME="$CR_HOME"
elif [[ -d "$HOME/.claude-router" && ! -d "$HOME/.claw-router" ]]; then
  CR_DATA_HOME="$HOME/.claude-router"
else
  CR_DATA_HOME="$HOME/.claw-router"
fi
LOG_PATH="$CR_DATA_HOME/logs/refresh-agent.log"

# Resolve the cr binary: explicit env > PATH search.
_resolve_cr_bin() {
  if [[ -n "${CLAWROUTER_CR:-}" ]]; then
    printf '%s' "$CLAWROUTER_CR"
    return 0
  fi
  local found
  found="$(command -v cr 2>/dev/null || true)"
  printf '%s' "$found"
}

CR_BIN="$(_resolve_cr_bin)"

# --- Helpers -----------------------------------------------------------------

# Fix 1: XML-escape helper — escape & < > " ' in plist string values.
_xml_escape() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"
}

# --- Subcommands -------------------------------------------------------------

_usage() {
  printf 'Usage: %s <install [interval_seconds]|uninstall|status|kick>\n' \
    "$(basename "$0")" >&2
  printf '\n' >&2
  printf '  install [interval]  Install and load the LaunchAgent (default: 300s)\n' >&2
  printf '  uninstall           Unload and remove the LaunchAgent plist\n' >&2
  printf '  status              Print agent state, interval, and recent log lines\n' >&2
  printf '  kick                Trigger an immediate poll (requires agent loaded)\n' >&2
  exit 0
}

_cmd_install() {
  local interval="${1:-300}"

  # Validate interval is a positive integer.
  case "$interval" in
    ''|*[!0-9]*)
      printf 'error: interval must be a positive integer (got: %s)\n' "$interval" >&2
      exit 1
      ;;
  esac
  if [[ "$interval" -le 0 ]]; then
    printf 'error: interval must be greater than 0 (got: %s)\n' "$interval" >&2
    exit 1
  fi

  # Require a resolved cr binary.
  if [[ -z "$CR_BIN" ]]; then
    printf 'error: cannot find the cr binary.\n' >&2
    printf '  Either install cr so it is on PATH, or set CLAWROUTER_CR=/path/to/cr\n' >&2
    exit 1
  fi

  # Fix 5: Require cr binary to be executable.
  if [[ ! -x "$CR_BIN" ]]; then
    printf 'error: cr is not executable: %s (install cr or set CLAWROUTER_CR)\n' "$CR_BIN" >&2
    exit 1
  fi

  # Create directories.
  mkdir -p "$AGENTS_DIR"
  mkdir -p "$(dirname "$LOG_PATH")"

  # Pre-escape dynamic values for XML (Fix 1).
  local cr_bin_escaped home_escaped log_escaped
  cr_bin_escaped="$(printf '%s' "$CR_BIN" | _xml_escape)"
  home_escaped="$(printf '%s' "$HOME" | _xml_escape)"
  log_escaped="$(printf '%s' "$LOG_PATH" | _xml_escape)"

  # Write the plist using printf (no eval, no shell expansion inside XML values).
  # Fix 3: RunAtLoad omitted — rely solely on post-install kickstart for first run
  # and StartInterval for the recurring schedule. This avoids two back-to-back
  # launches (and double Keychain prompts) on first install.
  printf '<?xml version="1.0" encoding="UTF-8"?>\n' > "$PLIST"
  printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"\n' >> "$PLIST"
  printf '  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n' >> "$PLIST"
  printf '<plist version="1.0">\n' >> "$PLIST"
  printf '<dict>\n' >> "$PLIST"
  printf '  <key>Label</key>\n' >> "$PLIST"
  printf '  <string>%s</string>\n' "$LABEL" >> "$PLIST"
  printf '  <key>ProgramArguments</key>\n' >> "$PLIST"
  printf '  <array>\n' >> "$PLIST"
  printf '    <string>%s</string>\n' "$cr_bin_escaped" >> "$PLIST"
  printf '    <string>status</string>\n' >> "$PLIST"
  printf '    <string>--refresh</string>\n' >> "$PLIST"
  printf '  </array>\n' >> "$PLIST"
  printf '  <key>StartInterval</key>\n' >> "$PLIST"
  printf '  <integer>%s</integer>\n' "$interval" >> "$PLIST"
  printf '  <key>EnvironmentVariables</key>\n' >> "$PLIST"
  printf '  <dict>\n' >> "$PLIST"
  printf '    <key>PATH</key>\n' >> "$PLIST"
  printf '    <string>/opt/homebrew/bin:/usr/local/bin:%s/.local/bin:/usr/bin:/bin</string>\n' "$home_escaped" >> "$PLIST"
  printf '  </dict>\n' >> "$PLIST"
  printf '  <key>StandardOutPath</key>\n' >> "$PLIST"
  printf '  <string>%s</string>\n' "$log_escaped" >> "$PLIST"
  printf '  <key>StandardErrorPath</key>\n' >> "$PLIST"
  printf '  <string>%s</string>\n' "$log_escaped" >> "$PLIST"
  printf '</dict>\n' >> "$PLIST"
  printf '</plist>\n' >> "$PLIST"

  # Fix 1: Validate plist XML before loading it.
  if command -v plutil >/dev/null 2>&1; then
    if ! plutil -lint "$PLIST" >/dev/null 2>&1; then
      rm -f "$PLIST"
      printf 'error: generated plist is invalid\n' >&2
      exit 1
    fi
  fi

  # Load idempotently: bootout any existing load, then bootstrap (prefer modern
  # launchctl interface; fall back to the legacy load for older macOS).
  "$LAUNCHCTL" bootout "$DOMAIN" "$PLIST" 2>/dev/null || true
  "$LAUNCHCTL" bootstrap "$DOMAIN" "$PLIST" 2>/dev/null \
    || "$LAUNCHCTL" load "$PLIST" 2>/dev/null \
    || true

  # Fix 2: Verify that the agent actually loaded; fail loudly if not.
  if ! "$LAUNCHCTL" print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
    printf 'error: the launch agent failed to load (see: %s)\n' "$LOG_PATH" >&2
    exit 1
  fi

  # Kick immediately so the user can see (and approve) the Keychain prompts now.
  "$LAUNCHCTL" kickstart -k "$DOMAIN/$LABEL" 2>/dev/null || true

  printf '\nClaw Router background refresh agent installed.\n' >&2
  printf '  Polls every %ss using: %s\n' "$interval" "$CR_BIN" >&2
  printf '  Log: %s\n' "$LOG_PATH" >&2
  printf '\n' >&2
  printf '*** IMPORTANT — one-time Keychain setup ***\n' >&2
  printf 'macOS will ask to allow access to each account'\''s Keychain credential\n' >&2
  printf 'the first time the agent runs. Click **Always Allow** so it never asks again.\n' >&2
  printf '(The credentials are owned by Claude Code; the agent needs read access.)\n' >&2
  printf '\n' >&2
  printf 'Manage with: cr menubar status | cr menubar refresh | cr menubar uninstall\n' >&2
}

_cmd_uninstall() {
  "$LAUNCHCTL" bootout "$DOMAIN" "$PLIST" 2>/dev/null \
    || "$LAUNCHCTL" unload "$PLIST" 2>/dev/null \
    || true
  rm -f "$PLIST"
  printf 'Claw Router background refresh agent uninstalled.\n' >&2
}

_cmd_status() {
  local plist_ok=0 loaded=0 interval=""

  if [[ -f "$PLIST" ]]; then
    plist_ok=1
  fi

  if "$LAUNCHCTL" print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
    loaded=1
  fi

  # Extract interval from plist if it exists.
  if [[ "$plist_ok" -eq 1 ]]; then
    # Read the integer value after the StartInterval key.
    interval="$(grep -A1 'StartInterval' "$PLIST" 2>/dev/null \
      | grep '<integer>' \
      | sed 's/.*<integer>\([0-9]*\)<\/integer>.*/\1/' || true)"
  fi

  printf 'Claw Router background refresh agent:\n'
  printf '  plist:    %s\n' "$([ "$plist_ok" -eq 1 ] && echo "installed ($PLIST)" || echo "not installed")"
  printf '  loaded:   %s\n' "$([ "$loaded" -eq 1 ] && echo "yes" || echo "no")"
  if [[ -n "$interval" ]]; then
    printf '  interval: %ss\n' "$interval"
  fi

  local log="$LOG_PATH"
  if [[ -f "$log" ]]; then
    printf '  log (last 3 lines):\n'
    tail -3 "$log" 2>/dev/null | sed 's/^/    /' || true
  fi

  return 0
}

_cmd_kick() {
  # Fix 4: exit nonzero when agent is not loaded; don't swallow kickstart failures.
  if ! "$LAUNCHCTL" print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
    printf 'error: agent is not loaded — run: cr menubar install\n' >&2
    exit 1
  fi
  "$LAUNCHCTL" kickstart -k "$DOMAIN/$LABEL"
  printf 'Kicked background refresh agent.\n' >&2
}

# --- Dispatch ----------------------------------------------------------------
case "${1:-}" in
  install)   shift; _cmd_install "${1:-300}" ;;
  uninstall) _cmd_uninstall ;;
  status)    _cmd_status ;;
  kick)      _cmd_kick ;;
  -h|--help|"") _usage ;;
  *) printf 'error: unknown subcommand: %s\n' "$1" >&2; _usage ;;
esac
