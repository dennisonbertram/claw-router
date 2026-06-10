# claude-router (`cr`)

Run Claude Code across several Claude subscriptions from one command. Type `cr`
followed by any normal `claude` arguments; `cr` picks an account (round-robin by
default), tells you which one it's using, and launches Claude Code under that
account's credentials — so your usage spreads out and lasts longer.

```
$ cr -p "explain this repo"
▶ claude-router → work  you@work.com  (claude_max)  [policy: round-robin]
…claude runs normally…
```

## How it works

Claude Code derives its macOS Keychain credential entry from the
`CLAUDE_CONFIG_DIR` environment variable: each distinct config dir gets its own
isolated login (`Claude Code-credentials-<hash>`). `cr` keeps one directory per
account, and on each launch it:

1. picks an account by policy (or your forced `--account`),
2. unsets `ANTHROPIC_API_KEY` / `ANTHROPIC_AUTH_TOKEN` / `CLAUDE_CODE_OAUTH_TOKEN`
   (these would otherwise override your subscription login),
3. sets `CLAUDE_CONFIG_DIR` to that account's directory,
4. prints a one-line banner to **stderr**, and
5. `exec`s the real `claude` — so the TTY, signals, and exit code pass straight
   through with zero overhead.

Claude Code itself reads the right Keychain credential and refreshes the token;
`cr` never copies or stores your secrets.

Your existing `~/.claude` login is registered as the `default` account and is
never modified.

## Install

```sh
git clone <this repo> ~/.claude-router-src   # or wherever
ln -s ~/.claude-router-src/cr ~/.local/bin/cr   # ensure ~/.local/bin is on PATH
```

Requires `jq` (and `curl` for `cr usage`). On macOS these plus `security`,
`shasum`, and `python3` are already present or one `brew install jq` away.

## Quick start

```sh
cr register-default       # adopt your current ~/.claude login as "default"
cr add work               # create + browser-login a second account
cr add personal           # …and a third
cr list                   # see them all
cr -p "hello"             # round-robins across them
```

## Commands

Launch (anything unrecognized is forwarded verbatim to `claude`):

| Command | Effect |
|---|---|
| `cr [args…]` | route by policy, then run `claude args…` |
| `cr --account <name> [args…]` | force an account |
| `cr@<name> [args…]` | shorthand for `--account <name>` |
| `cr --account <name> -- [args…]` | `--` ends cr's flags; the rest is claude's |

Manage (never forwarded to claude):

| Command | Effect |
|---|---|
| `cr add <name>` | make an account dir, symlink shared settings, browser-login, cache identity |
| `cr register-default [name]` | register the existing `~/.claude` login (no dir move) |
| `cr login <name>` / `cr logout <name>` | (re)auth / sign out an account |
| `cr remove <name>` | unregister (prints how to delete its dir + keychain item) |
| `cr list` (`accounts`, `ls`) | table of accounts: email, plan, last used, usage%, enabled |
| `cr use <name>` | pin the account a plain `cr` uses (overrides rotation) |
| `cr policy <p>` | `round-robin` \| `lru` \| `random` \| `usage-aware` |
| `cr usage [name]` | poll live usage and cache it (feeds `usage-aware`) |
| `cr status` | which account would run next, and why |
| `cr doctor [name]` | verify each account's dir + keychain credential |

## Selection policies

- **round-robin** (default) — even spread across enabled accounts.
- **lru** — least-recently-used first.
- **random** — uniform random.
- **usage-aware** — route to the account with the most headroom, using the
  numbers from `cr usage`. Run `cr usage` periodically (or wire it to a cron) to
  refresh the cached figures; falls back to `lru` if usage data is unavailable.

Tip: `cr usage` shows the 5-hour and 7-day windows with reset times, so you can
see at a glance which subscription to lean on.

## Notes & limits

- **macOS-first.** Keychain isolation is the clean path on macOS. On Linux the
  same model works via `CLAUDE_CONFIG_DIR`/`.credentials.json` but the Keychain
  checks in `cr doctor` are skipped.
- **`--continue` / `--resume`** route to the least-recently-used account and warn,
  since the session belongs to whichever account created it. Pin with
  `--account <name>` to be sure.
- **Shared settings.** `cr add` symlinks `settings.json`, `CLAUDE.md`,
  `commands/`, and `rules/` from `~/.claude` so your config isn't fragmented;
  per-account history/projects stay separate.
- The `/api/oauth/usage` endpoint is undocumented; `cr usage` is best-effort and
  degrades gracefully.

## Tests

```sh
bash test/run.sh
```

No real Claude or network calls — uses a fake `claude` and an isolated config
home.
