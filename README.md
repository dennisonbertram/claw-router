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
| `cr add-backend <name> …` | register an alt-model endpoint (e.g. DeepSeek); see Backends below |
| `cr register-default [name]` | register the existing `~/.claude` login (no dir move) |
| `cr login <name>` / `cr logout <name>` | (re)auth / sign out an account |
| `cr remove <name>` | unregister (prints how to delete its dir + keychain item) |
| `cr list` (`accounts`, `ls`) | table of accounts: email, plan, last used, usage%, enabled |
| `cr use <name>` | pin the account a plain `cr` uses (overrides rotation) |
| `cr use --clear` (`cr unuse`) | un-pin; go back to the rotation policy |
| `cr policy <p>` | `round-robin` \| `lru` \| `random` \| `usage-aware` |
| `cr usage [name]` | show usage meters per window (`--plain` for one-line text) |
| `cr status` | which account would run next, and why |
| `cr doctor [name]` | verify each account's dir + keychain credential |

## Selection policies

- **round-robin** (default) — even spread across enabled accounts.
- **lru** — least-recently-used first.
- **random** — uniform random.
- **usage-aware** — route to the account with the most headroom, using the
  numbers from `cr usage`. Run `cr usage` periodically (or wire it to a cron) to
  refresh the cached figures; falls back to `lru` if usage data is unavailable.

Tip: `cr usage` draws a meter of how much is left in each window (5-hour session,
7-day total, and per-model 7-day) with reset countdowns, so you can see at a
glance which subscription to lean on:

```
usage left per window  (█ = available)

  default  you@work.com
    5h session  █████████░░░░░░░░░░░░░  42% left   resets in 1h17m
    7d total    ███████████████████░░░  88% left   resets in 2d13h

  personal  you@gmail.com
    5h session  ██████████████████████ 100% left   resets in 4h47m
    7d total    ██████████████████████ 100% left   resets in 4d22h
```

Bars are colored green/yellow/red by headroom. `cr usage --plain` prints a
single line per account instead.

## Backends (alternate models, e.g. DeepSeek)

Besides your Anthropic subscriptions, `cr` can route Claude Code to an
Anthropic-compatible endpoint like DeepSeek. These are registered as **backend**
accounts and behave differently from subscriptions in one deliberate way:

> **Backends are explicit-only. They are never in the rotation.** A plain `cr`
> (round-robin / lru / usage-aware) only ever picks your subscriptions. You reach
> a backend by naming it: `cr@deepseek …` or `cr --account deepseek …`. This keeps
> an inferior fallback model out of your normal flow until you ask for it.

Register one (seeding the key from an existing `deep-claude` Keychain item):

```sh
cr add-backend deepseek --seed-from-deep-claude
# or supply the key interactively:
cr add-backend deepseek
# customize endpoint / model / aliases:
cr add-backend myllm --base-url https://host/anthropic --model some-model \
  --alias fast=some-fast-model
```

Use it:

```sh
cr@deepseek -p "quick scratch task"      # default model
cr@deepseek --model flash -p "…"         # alias → deepseek-v4-flash
```

A backend launch sets `ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN` /
`ANTHROPIC_MODEL`, leaves `CLAUDE_CONFIG_DIR` and **`HOME` untouched** (so `gh`
and keychain tools keep working), and stores its API key under cr's own Keychain
item (`claude-router-backend` / `<name>`). It's effectively `deep-claude` folded
into `cr`.

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
