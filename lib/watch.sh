#!/usr/bin/env bash
# watch.sh — supervised launch for cr: stay alive, watch usage in the
# background, and hand the session off to a fresher account before the current
# one hits its limit.  Requires common.sh + usage.sh to be sourced first.
# Bash 3.2 compatible (macOS stock bash).

# --- Config readers -------------------------------------------------------

cr_watch_at()        { cr_config_read | jq -r '.watchAtPct // 90'; }
cr_watch_interval()  { cr_config_read | jq -r '.watchIntervalSeconds // 120'; }
cr_watch_idle_secs() { cr_config_read | jq -r '.watchIdleSeconds // 30'; }

# --- Portable mtime -------------------------------------------------------

# Echo file mtime in epoch seconds. Returns nonzero if neither stat variant works.
cr_mtime() {
  local path="$1" t
  t="$(stat -f %m "$path" 2>/dev/null)" && { printf '%s' "$t"; return 0; }
  t="$(stat -c %Y "$path" 2>/dev/null)" && { printf '%s' "$t"; return 0; }
  return 1
}

# --- CWD munging ----------------------------------------------------------

# Echo the current directory with every non-[A-Za-z0-9] char replaced by '-'.
cr_munged_cwd() {
  pwd | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g'
}

# --- Session discovery ----------------------------------------------------

# Echo "sid<TAB>path" of the newest real (non-symlink) transcript for the
# current working directory across all subscription accounts.  If marker_path
# is non-empty and exists, only files whose mtime >= marker mtime are considered.
# Returns 1 if nothing is found.
cr_watch_latest_session() {
  local marker_path="${1:-}"
  local marker_mtime=0
  if [[ -n "$marker_path" && -f "$marker_path" ]]; then
    local m
    m="$(cr_mtime "$marker_path" 2>/dev/null || true)"
    [[ -n "$m" ]] && marker_mtime="$m"
  fi

  local munged; munged="$(cr_munged_cwd)"
  local best_mtime=0 best_sid="" best_path=""

  local name
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    local base
    base="$(cr_account_dir "$name" 2>/dev/null || true)"
    [[ -z "$base" ]] && base="$HOME/.claude"

    local f
    for f in "${base}/projects/${munged}"/*.jsonl; do
      # Must be a real regular file, not a symlink.
      [[ -f "$f" && ! -L "$f" ]] || continue
      local mt
      mt="$(cr_mtime "$f" 2>/dev/null || true)"
      [[ -z "$mt" ]] && continue
      # Skip files older than the marker (if marker filter is active).
      if [[ "$marker_mtime" -gt 0 ]]; then
        if ! awk -v mt="$mt" -v mm="$marker_mtime" 'BEGIN{exit !(mt >= mm)}'; then
          continue
        fi
      fi
      if awk -v mt="$mt" -v bm="$best_mtime" 'BEGIN{exit !(mt > bm)}'; then
        best_mtime="$mt"
        best_sid="$(basename "$f" .jsonl)"
        best_path="$f"
      fi
    done
  done < <(cr_config_read | jq -r '.accounts[]|select((.kind//"subscription")=="subscription")|.name')

  if [[ -z "$best_sid" ]]; then
    return 1
  fi
  printf '%s\t%s' "$best_sid" "$best_path"
}

# --- Idle detection -------------------------------------------------------

# Return 0 (idle) if:
#   - path is empty or missing, OR
#   - (now - mtime(path)) >= idle_secs
# Return 1 (active / not idle).
cr_watch_idle() {
  local transcript_path="${1:-}" idle_secs="${2:-30}"
  if [[ -z "$transcript_path" || ! -f "$transcript_path" ]]; then
    return 0
  fi
  local mt now
  mt="$(cr_mtime "$transcript_path" 2>/dev/null || true)"
  if [[ -z "$mt" ]]; then
    return 0
  fi
  now="$(date +%s)"
  awk -v now="$now" -v mt="$mt" -v idle="$idle_secs" 'BEGIN{exit !((now - mt) >= idle)}'
}

# --- Candidate picker -----------------------------------------------------

# Echo the name of the best handoff candidate (an enabled subscription account
# other than current_account with usagePct < at_pct), or nothing if none qualifies.
cr_watch_pick_next() {
  local current_account="$1" at_pct="$2"
  cr_config_read | jq -r --arg cur "$current_account" --argjson at "$at_pct" '
    [.accounts[]
     | select(.enabled != false)
     | select((.kind // "subscription") == "subscription")
     | select(.name != $cur)
     | select((.usagePct == null) or (.usagePct < $at))]
    | sort_by(.usagePct // 100.5)
    | .[0].name // empty'
}

# --- Strip resume args ----------------------------------------------------

# Rebuild args minus any --continue, -c, --resume, --resume=X, and the value
# following a bare --resume (when the next token doesn't start with -).
# Result is stored in the global array CR_WATCH_ARGS.
cr_watch_strip_resume() {
  CR_WATCH_ARGS=()
  while (($#)); do
    case "$1" in
      --continue|-c)
        shift ;;
      --resume=*)
        shift ;;
      --resume)
        # Drop the following session id too — but only when it isn't another
        # flag (mirrors cr_args_resume_kind's parse).
        if [[ -n "${2:-}" && "${2:-}" != -* ]]; then shift 2; else shift; fi ;;
      *)
        CR_WATCH_ARGS+=("$1"); shift ;;
    esac
  done
}

# --- Background watcher ---------------------------------------------------

# cr_watch_watcher <account> <child_pid> <flag_file> <at> <interval> <idle> <marker>
# Polls usage in the background. When usage >= at and a suitable next account
# exists and the session is idle, writes the next account to flag_file and
# sends SIGTERM to child_pid.
cr_watch_watcher() {
  local account="$1" child="$2" flag="$3" at="$4" interval="$5" idle="$6" marker="$7"

  while sleep "$interval"; do
    # Exit if child is gone.
    kill -0 "$child" 2>/dev/null || exit 0

    # Poll the current account's usage (best-effort).
    if [[ -z "${CR_NO_USAGE_POLL:-}" ]]; then
      cr_poll_account "$account" >/dev/null 2>&1 || true
    fi

    # Read current usagePct.
    local pct
    pct="$(cr_config_read | jq -r --arg n "$account" \
      '.accounts[]|select(.name==$n)|.usagePct // empty')"
    [[ -z "$pct" ]] && continue

    # Continue if below threshold (not yet time to hand off).
    if awk -v p="$pct" -v a="$at" 'BEGIN{exit !(p >= a)}'; then
      : # at or above threshold — fall through
    else
      continue
    fi

    # Poll all other enabled subscription accounts (best-effort).
    if [[ -z "${CR_NO_USAGE_POLL:-}" ]]; then
      local other
      while IFS= read -r other; do
        [[ -z "$other" || "$other" == "$account" ]] && continue
        cr_poll_account "$other" >/dev/null 2>&1 || true
      done < <(cr_config_read | jq -r '.accounts[]
        | select(.enabled != false)
        | select((.kind//"subscription")=="subscription")
        | .name')
    fi

    # Find the best next account.
    local next
    next="$(cr_watch_pick_next "$account" "$at")"
    [[ -z "$next" ]] && continue

    # Find the latest session transcript.
    local latest path
    latest="$(cr_watch_latest_session "$marker" || true)"
    path="${latest#*	}"                      # strip everything up to first tab
    [[ "$latest" == "$path" ]] && path=""   # no tab means no result

    # Don't interrupt mid-turn — wait for idle.
    cr_watch_idle "$path" "$idle" || continue

    # Re-check liveness right before committing — claude may have exited
    # naturally while we were polling (avoids a spurious relaunch).
    kill -0 "$child" 2>/dev/null || exit 0

    # Signal handoff: write the next account name and SIGTERM the child.
    printf '%s' "$next" > "$flag"
    kill -TERM "$child" 2>/dev/null || true

    # Escalate: wait up to 5 seconds (50 × 0.1s), then SIGKILL.
    local i
    for i in $(seq 1 50); do
      kill -0 "$child" 2>/dev/null || break
      sleep 0.1
    done
    kill -KILL "$child" 2>/dev/null || true

    exit 0
  done
}

# --- Supervisor -----------------------------------------------------------

# cr_watch_run <account> <policy> <args…>
# The supervised launch loop. Never returns; exits with claude's final exit code.
cr_watch_run() {
  local account="$1" _policy="$2"; shift 2
  local at interval idle
  at="$(cr_watch_at)"
  interval="$(cr_watch_interval)"
  idle="$(cr_watch_idle_secs)"

  local tmpdir
  tmpdir="$(mktemp -d)"
  local flag="$tmpdir/handoff" marker="$tmpdir/marker"
  touch "$marker"

  # Remember any explicit --resume <id> passed by the user, as a fallback when
  # session discovery finds nothing.
  local orig_sid="" rkind
  rkind="$(cr_args_resume_kind "$@" || true)"
  if [[ "$rkind" == "resume "* ]]; then
    orig_sid="${rkind#resume }"
  fi

  local -a args=("$@")
  local child="" watcher="" rc=0

  # Cleanup trap: kill watcher + child + remove tmpdir.
  # IMPORTANT: use ' ' (no-op) for INT so it is not inherited by child claude
  # processes (an empty-string trap SIG_IGN would be inherited and break Ctrl-C).
  trap 'kill "$watcher" 2>/dev/null || true; kill "$child" 2>/dev/null || true; rm -rf "$tmpdir"' EXIT
  trap ' ' INT
  trap 'kill -TERM "$child" 2>/dev/null || true' TERM

  while :; do
    rm -f "$flag"

    # Set CLAUDE_CONFIG_DIR for this account.
    local dir
    dir="$(cr_account_dir "$account" || true)"
    if [[ -n "$dir" ]]; then
      export CLAUDE_CONFIG_DIR="$dir"
    else
      unset CLAUDE_CONFIG_DIR
    fi

    # Launch claude in background so we can supervise it.
    cr_build_exec
    if [[ -t 0 ]]; then
      "${CR_EXEC[@]}" ${args[@]+"${args[@]}"} </dev/tty &
    else
      "${CR_EXEC[@]}" ${args[@]+"${args[@]}"} &
    fi
    child=$!

    # Start the background usage watcher.
    cr_watch_watcher "$account" "$child" "$flag" "$at" "$interval" "$idle" "$marker" &
    watcher=$!

    # Wait for claude to finish.
    rc=0
    wait "$child" 2>/dev/null || rc=$?
    # Drain any re-queued signals (bash re-enters wait if a signal fires).
    while kill -0 "$child" 2>/dev/null; do
      rc=0
      wait "$child" 2>/dev/null || rc=$?
    done

    # Reap the watcher.
    kill "$watcher" 2>/dev/null || true
    wait "$watcher" 2>/dev/null || true

    # If no handoff was requested, we're done.
    [[ -f "$flag" ]] || break
    local next
    next="$(cat "$flag")"
    [[ -z "$next" ]] && break

    # Discover the session to carry over to the next account.
    local sid="" latest
    latest="$(cr_watch_latest_session "$marker" || true)"
    if [[ -n "$latest" && "$latest" == *"	"* ]]; then
      sid="${latest%%	*}"
    fi
    # Fall back to the original explicit --resume id if discovery found nothing.
    [[ -z "$sid" ]] && sid="$orig_sid"

    # Strip any existing --resume / --continue from args and re-add the new one.
    cr_watch_strip_resume ${args[@]+"${args[@]}"}
    args=(${CR_WATCH_ARGS[@]+"${CR_WATCH_ARGS[@]}"})
    if [[ -n "$sid" ]]; then
      cr_link_session "$sid" "$next" >/dev/null 2>&1 || true
      args+=(--resume "$sid")
    fi

    # Defensive terminal reset between children.
    [[ -t 0 ]] && { stty sane </dev/tty 2>/dev/null || true; }

    # Banner: show the handoff transition.
    local oldpct
    oldpct="$(cr_config_read | jq -r --arg n "$account" \
      '.accounts[]|select(.name==$n)|.usagePct // "?"')"
    printf '%s↻%s %s%s%s at %s%% \xe2\x80\x94 continuing on %s%s%s%s\n' \
      "$C_YELLOW" "$C_RESET" \
      "$C_BOLD" "$account" "$C_RESET" \
      "$oldpct" \
      "$C_ACCENT$C_BOLD" "$next" "$C_RESET" \
      "${sid:+ (resuming ${sid:0:8}…)}" >&2

    cr_mark_used "$next"

    # Re-print the ◆ banner for the new account.
    local email plan
    email="$(cr_config_read | jq -r --arg n "$next" '.accounts[]|select(.name==$n)|.email // "?"')"
    plan="$(cr_config_read  | jq -r --arg n "$next" '.accounts[]|select(.name==$n)|.plan  // "?"')"
    printf '%s\xe2\x97\x86%s %s%s%s %s%s%s %s(%s)%s %s\xc2\xb7 watch%s\n' \
      "$C_ACCENT" "$C_RESET" \
      "$C_BOLD" "$next" "$C_RESET" \
      "$C_GREY" "$email" "$C_RESET" \
      "$C_GREY" "$plan" "$C_RESET" \
      "$C_DIM" "$C_RESET" >&2

    printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$next" "watch-handoff" \
      >> "$CR_LOG" 2>/dev/null || true

    account="$next"
  done

  exit "$rc"
}
