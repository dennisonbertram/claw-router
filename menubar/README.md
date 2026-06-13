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

3. Start the background refresh agent (see below).

4. In SwiftBar, click Refresh All (or wait for the next tick).

The `.30s.` in the filename controls how often SwiftBar re-renders the menu.
Rename to `.1m.` for 60 seconds, `.5m.` for 5 minutes, etc. The agent
controls how often the *usage data* is polled — these are independent.

## Background refresh agent (required for live data)

The plugin itself **never** calls `cr status --refresh` — doing so would trigger
a macOS Keychain authorization dialog for each account every time the menu
renders. Instead, a lightweight launchd LaunchAgent polls usage on a schedule
and writes the result to the cache. The plugin reads only the cache: instant,
no prompts, no network.

After installing the plugin, start the agent:

```sh
cr menubar install           # installs + loads the agent (polls every 5 min)
cr menubar install 120       # custom interval: poll every 2 minutes
```

Or call the script directly:

```sh
bash menubar/agent.sh install
bash menubar/agent.sh install 120
```

### One-time Keychain authorization

The first time the agent runs, macOS will show an authorization dialog for each
Claude account's Keychain credential. **Click "Always Allow"** — this grants
the agent permanent read access and the dialog never appears again.

Why does this happen? Claude Code stores your OAuth credentials in your macOS
Keychain, keyed by config directory. The launchd agent is a separate process
from the terminal that logged in, so macOS asks for explicit permission. Once
you click "Always Allow", launchd is authorized forever and polls silently in
the background.

### Managing the agent

```sh
cr menubar status      # print agent state, interval, and last log lines
cr menubar refresh     # trigger an immediate poll (alias: kick)
cr menubar uninstall   # stop and remove the agent
```

The agent log is at `~/.claw-router/logs/refresh-agent.log`.

## How the menu bar works

- **The plugin never polls.** It reads `cr status --json` (cache-only, no network, no Keychain) on every SwiftBar tick.
- **"Refresh now"** nudges the already-authorized agent to poll immediately — no new Keychain prompts.
- **When the agent is not installed**, the "Refresh now" item becomes "Enable background refresh…" which opens a terminal to run `cr menubar install` so you can click "Always Allow" interactively.
- **Stale-data hint:** if any subscription's cache is stale and the agent is not running, a `⚠ Usage is stale` line appears at the top of the dropdown.

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
- **Actions**: Refresh now (or Enable background refresh), set policy, pin an account, or open the project site.
- **Notifications**: a one-shot macOS notification fires when an in-rotation account first crosses the exhaustion threshold. It clears when usage drops back.

## Troubleshooting

**Blank menu or `🦞 ⚠`**: `cr` or `jq` is not on SwiftBar's PATH. Set `CLAWROUTER_CR` to the absolute path via Plugin Settings. Find it with `command -v cr` in a terminal.

**`🦞 —` with "no data" hint**: No cached usage yet. Start the agent (`cr menubar install`) and click "Always Allow" when prompted, or run `cr status --refresh` once in a terminal to prime the cache.

**Usage is always stale / numbers don't update**: The background agent is not running or not authorized. Run `cr menubar status` to check, then `cr menubar install` to reinstall. If the Keychain dialog keeps appearing, it means "Allow" was clicked instead of "Always Allow" — uninstall and reinstall the agent, and click "Always Allow" at each prompt.

**Notifications keep firing**: Check that your `exhaustedAtPct` threshold (`cr config exhausted-at`) is set appropriately. Notifications fire once per crossing; they silence when usage drops below the threshold.

## Security

The plugin only calls `cr status --json` and `jq`. It never reads credential files or touches your Keychain directly. The background agent calls `cr status --refresh`, which reads Keychain credentials — that is why macOS asks for authorization once.
