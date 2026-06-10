<p align="center">
  <img src="assets/banner.png" alt="Claw Router" width="100%">
</p>

<h1 align="center">Claw Router 🦞</h1>

<p align="center">
  <b>Effortlessly manage your Claude subscriptions.</b><br>
  One command. All your accounts. Used evenly, so they last.
</p>

<p align="center">
  <a href="#install">Install</a> ·
  <a href="#quick-start">Quick start</a> ·
  <a href="#commands">Commands</a> ·
  <a href="#selection-policies">Policies</a> ·
  <a href="#how-it-works">How it works</a>
</p>

<p align="center">
  <code>cr</code> is a tiny wrapper around <a href="https://claude.com/claude-code">Claude Code</a>.
  Type <code>cr</code> followed by any normal <code>claude</code> arguments and it
  picks one of your Claude accounts (round-robin by default), tells you which, and
  launches Claude Code under that account — spreading the load so no single
  subscription burns out first.
</p>

```console
$ cr -p "explain this repo"
◆ work  you@work.com  (claude_max) · round-robin
…claude runs normally…

$ cr -p "and the tests?"
◆ personal  you@gmail.com  (claude_max) · round-robin
…next call, next account…
```

If you keep two or three Claude Max plans around so you don't hit the 5-hour
limit mid-flow, this is for you: stop manually `/login`-swapping, and let `cr`
balance them — including a `usage-aware` mode that routes to whichever account
has the most headroom right now.

> **Your secrets never move.** `cr` flips one environment variable
> (`CLAUDE_CONFIG_DIR`) per launch; Claude Code reads the right macOS Keychain
> login and refreshes its own token. `cr` never reads, copies, or stores your
> credentials.

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
git clone https://github.com/dennisonbertram/claw-router.git
cd claw-router
./install.sh          # symlinks `cr` into ~/.local/bin
```

Make sure `~/.local/bin` is on your `PATH`. The only hard dependency is `jq`
(`brew install jq`); `curl` is needed for `cr usage`, and `security` / `shasum`
/ `python3` ship with macOS.

> **Platform:** macOS-first (it builds on the macOS Keychain). It runs on Linux
> too — credentials come from `CLAUDE_CONFIG_DIR/.credentials.json` instead — but
> the Keychain checks in `cr doctor` are skipped there.

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
| `cr --sandbox` / `-s [args…]` | run the session inside a [cco](https://github.com/nikvdp/cco) sandbox |
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
| `cr status [--refresh]` | dashboard: next pick + per-account usage bars (cached; `--refresh` polls live) |
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

## Sandbox mode

Add `--sandbox` (or `-s`) to run the session inside a container, so Claude Code
can't touch anything outside your project:

```sh
cr --sandbox -p "run the migration and tests"
cr@work -s                                   # sandboxed interactive session
```

This delegates isolation to [`cco`](https://github.com/nikvdp/cco) (“Claude
Container”). `cr` still does the account routing — it picks the account, sets
`CLAUDE_CONFIG_DIR`, then launches through `cco` instead of `claude`. Because
`cco` reads the same `CLAUDE_CONFIG_DIR` (for both config *and* the Keychain
login), the right account is used inside the box, and your normal policies,
pins, backends, and `--resume` all compose with `--sandbox` unchanged.

`cco` isn't bundled (it's a separate GPL-3.0 project). If it's missing, `cr`
tells you the one-line install:

```sh
curl -fsSL https://raw.githubusercontent.com/nikvdp/cco/master/install.sh | bash
```

## Sessions across accounts

Claude Code stores each conversation under the account that created it
(`<config-dir>/projects/<cwd>/<id>.jsonl`). `cr` handles this two ways:

- **`cr --resume <id>` just works.** Normal rotation (or your `--account` pin)
  picks the account, and `cr` transparently symlinks the session in from whatever
  account owns it — so you never see "No conversation found" from landing on the
  wrong account, and you don't have to think about where the session lives.
  (Subagent transcripts are linked too. The account you resume under is the one
  billed for new turns.)
- **`cr adopt <id> <account>`** does the same linking manually, if you want to
  prepare a session for another account ahead of time:

  ```sh
  cr adopt 5fe702a8-… personal     # link a session 'work' started into 'personal'
  cr@personal --resume 5fe702a8-…  # (or just `cr --resume` — it auto-links anyway)
  ```

  Linking is a symlink, so the accounts share one evolving transcript.

## Notes & limits

- **macOS-first.** Keychain isolation is the clean path on macOS. On Linux the
  same model works via `CLAUDE_CONFIG_DIR`/`.credentials.json` but the Keychain
  checks in `cr doctor` are skipped.
- **`--resume <id>`** auto-links the session into the picked account, so it
  resumes regardless of which account created it (see *Sessions across accounts*).
  A bare `--continue` has no id to match — it just runs under the picked account.
- **Shared settings.** `cr add` symlinks `settings.json`, `CLAUDE.md`,
  `commands/`, and `rules/` from `~/.claude` so your config isn't fragmented;
  per-account history/projects stay separate.
- The `/api/oauth/usage` endpoint is undocumented; `cr usage` is best-effort and
  degrades gracefully.

## Appearance

`cr` colorizes its banner, `list`, `status`, and `help` when stderr is a
terminal. It honors [`NO_COLOR`](https://no-color.org) and a `dumb` `$TERM`, and
strips all styling automatically when output is piped — so `cr -p …` stdout and
any captured output stay clean.

## Tests

```sh
bash test/run.sh
```

No real Claude or network calls — uses a fake `claude` and an isolated config
home. 30+ assertions cover account selection, env scrubbing, arg forwarding,
the Keychain naming scheme, backend isolation, usage rendering, and
cross-account session linking.

## License

MIT © Dennison Bertram

---

<p align="center"><i>Not affiliated with Anthropic. “Claude” and “Claude Code” are trademarks of Anthropic.</i></p>
