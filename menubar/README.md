# Claw Router — menu-bar plugin

A [SwiftBar](https://github.com/swiftbar/SwiftBar) / [xbar](https://xbarapp.com) plugin that watches your Claude subscription headroom in the macOS menu bar, reading live data from `cr status --json`.

```
🦞 42% ▾
─────────────────────────────────────
Policy: round-robin  Next: work
◆ work  you@work.com
  5h   ████████░░ 42% · 1h17m
  7d   ██████████ 88%
◆ home  you@home.com
  5h   ██████████ 98%
  7d   █████░░░░░ 48%
─────────────────────────────────────
◆ deepseek  · explicit-only
  no usage data
─────────────────────────────────────
Refresh now
Policy ▶  round-robin / lru / random / usage-aware
Pin account ▶  work / home / Clear pin
Open Claw Router ↗
```

## Requirements

- macOS (notifications via `osascript`; date parsing via `python3`)
- [SwiftBar](https://github.com/swiftbar/SwiftBar) — `brew install swiftbar` — or [xbar](https://xbarapp.com)
- `jq` — `brew install jq`
- `cr` on PATH (install: see the [Claw Router README](../README.md))

## Install

1. Copy or symlink the plugin into your SwiftBar Plugins folder:

   ```sh
   # symlink (stays in sync with updates)
   ln -s "$(pwd)/menubar/clawrouter.30s.sh" ~/Library/Application\ Support/SwiftBar/Plugins/

   # or copy
   cp menubar/clawrouter.30s.sh ~/Library/Application\ Support/SwiftBar/Plugins/
   ```

2. Ensure the file is executable: `chmod +x clawrouter.30s.sh`

3. In SwiftBar, click Refresh All (or wait for the next tick).

The `.30s.` in the filename controls the refresh interval. Rename to `.1m.` for 60 seconds, `.5m.` for 5 minutes, etc.

## Configuration

Set environment variables via SwiftBar's Plugin Settings (right-click the icon → Plugin Settings):

| Variable | Default | Purpose |
|---|---|---|
| `CLAWROUTER_CR` | `cr` | Absolute path to the `cr` binary — needed when `cr` is not on SwiftBar's PATH |
| `CLAWROUTER_JQ` | `jq` | Absolute path to `jq` |
| `CLAWROUTER_NOTIFY` | `1` | Set to `0` or `false` to disable exhaustion notifications |

To find the absolute path of `cr`: `command -v cr`

## What it shows

- **Menu-bar title**: `🦞 NN%` where NN is the binding constraint — the minimum `leftPct` across all windows of in-rotation accounts. Color: green ≥50%, orange ≥20%, red <20%.
- **Per-account rows**: in-rotation accounts first, then non-rotating (dimmed, labeled `explicit-only`). Each account shows a 10-cell Unicode bar per usage window with a compact reset countdown (`1h17m`, `3d04h`, etc.).
- **Policy and next pick**: shown at the top of the dropdown.
- **Actions**: Refresh now, set policy, pin an account, or open the project site.
- **Notifications**: a one-shot macOS notification fires when an in-rotation account first crosses the exhaustion threshold. It clears when usage drops back.

## How it stays cheap

The plugin renders from `cr`'s cached snapshot — no network calls at render time. If any in-rotation account's cache is stale (older than `cr config ttl`, default 15 min), a background refresh is kicked off and the next 30-second tick shows fresh numbers.

## Optional: keep the cache warm with launchd

If you want `cr` to proactively refresh usage in the background (rather than waiting for the plugin to notice staleness), add a launchd agent:

```xml
<!-- ~/Library/LaunchAgents/com.clawrouter.refresh.plist -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>             <string>com.clawrouter.refresh</string>
  <key>ProgramArguments</key>
  <array>
    <string>/opt/homebrew/bin/cr</string>
    <string>status</string>
    <string>--refresh</string>
  </array>
  <key>StartInterval</key>     <integer>600</integer>  <!-- every 10 minutes -->
  <key>StandardOutPath</key>   <string>/dev/null</string>
  <key>StandardErrorPath</key> <string>/dev/null</string>
</dict>
</plist>
```

Load it with: `launchctl load ~/Library/LaunchAgents/com.clawrouter.refresh.plist`

## Troubleshooting

**Blank menu or `🦞 ⚠`**: `cr` or `jq` is not on SwiftBar's PATH. Set `CLAWROUTER_CR` to the absolute path via Plugin Settings. Find it with `command -v cr` in a terminal.

**`🦞 —` with "no data" hint**: No cached usage yet. Open a terminal and run `cr status --refresh` once to prime the cache.

**Notifications keep firing**: Check that your `exhaustedAtPct` threshold (`cr config exhausted-at`) is set appropriately. Notifications fire once per crossing; they silence when usage drops below the threshold.

## Security

The plugin only calls `cr` and `jq`. It never reads credential files or touches your keychain directly.
