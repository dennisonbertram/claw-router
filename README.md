<p align="center">
  <img src="assets/banner.png" alt="Claw Router" width="100%">
</p>

<h1 align="center">Claw Router 🦞</h1>

<p align="center">
  <b>Route Claude Code and OpenAI Codex accounts from one CLI.</b><br>
  Provider-aware login, selection, usage, and launch — without moving credentials.
</p>

<p align="center">
  <a href="https://dennisonbertram.github.io/claw-router/">Website</a> ·
  <a href="#install">Install</a> ·
  <a href="#quick-start">Quick start</a> ·
  <a href="#commands">Commands</a> ·
  <a href="#selection-policies">Policies</a> ·
  <a href="#how-it-works">How it works</a>
</p>

<p align="center">
  <code>cr</code> is a tiny account router for
  <a href="https://claude.com/claude-code">Claude Code</a> and
  <a href="https://developers.openai.com/codex/cli">OpenAI Codex CLI</a>.
  Plain <code>cr</code> remains the Claude-compatible default; add
  <code>--provider codex</code> to run Codex, or name an account and let the router
  infer its provider.
</p>

```console
$ cr -p "explain this repo"
◆ work  you@work.com  (claude_max) · round-robin
…claude runs normally…

$ cr -p "and the tests?"
◆ personal  you@gmail.com  (claude_max) · round-robin
…next call, next account…

$ cr --provider codex exec "explain this repo"
◆ openai-work  [codex]  · round-robin
…codex runs normally…
```

If you keep two or three Claude Max plans around so you don't hit the 5-hour
limit mid-flow, this is for you: stop manually `/login`-swapping, and let `cr`
balance them — including a `usage-aware` mode that routes to whichever account
has the most headroom right now.

> **Your secrets never move between accounts or providers.** Claude launches
> isolate accounts with `CLAUDE_CONFIG_DIR`; Codex launches use `CODEX_HOME` and
> Codex's official `login`, `logout`, and `login status` commands. Claw Router
> never reads Codex credentials. Claude usage polling retains its existing
> best-effort OAuth behavior and writes refreshed Claude tokens only to the same
> account store they came from.

## How it works

`cr` keeps provider and authentication type separate in its account registry.
Legacy accounts without a provider remain Claude accounts. On each launch it:

1. chooses Claude by default, the provider passed with `--provider`, or the
   provider recorded on a named `--account` / `@account`,
2. picks an account from that provider's policy pool,
3. sets the provider's isolated home (`CLAUDE_CONFIG_DIR` or `CODEX_HOME`),
4. prints a one-line banner to **stderr**, and
5. `exec`s the real `claude` or `codex`, forwarding that provider's native
   arguments, TTY, signals, and exit code.

Claude keeps its existing Keychain/config-directory isolation. Codex owns its
authentication cache under `CODEX_HOME`; the router invokes official Codex
commands rather than interpreting `auth.json` or OS credential-store entries.

Your existing `~/.claude` login is registered as the `default` account and is
never modified.

## Install

```sh
git clone https://github.com/dennisonbertram/claw-router.git
cd claw-router
./install.sh          # symlinks `cr` into ~/.local/bin
```

Make sure `~/.local/bin` is on your `PATH`. The only hard dependency is `jq`
(`brew install jq`). Install the provider CLIs you intend to route (`claude`
and/or `codex`). `curl` is needed for Claude usage polling; `security`, `shasum`,
and `python3` ship with macOS.

> **Platform:** macOS-first (it builds on the macOS Keychain). It runs on Linux
> too — credentials come from `CLAUDE_CONFIG_DIR/.credentials.json` instead — but
> the Keychain checks in `cr doctor` are skipped there.

## Quick start: Claude (default)

```sh
cr register-default       # adopt your current ~/.claude login as "default"
cr add work               # create + browser-login a second account
cr add personal           # …and a third
cr list                   # see them all
cr -p "hello"             # round-robins across them
```

## Quick start: OpenAI Codex

```sh
cr --provider codex add openai-work      # isolated CODEX_HOME + official codex login
cr --provider codex add openai-personal  # add another ChatGPT/Codex account
cr --provider codex add-api openai-api --from-env # optional API-key account
cr list                                  # all accounts, with a provider column
cr --provider codex                      # interactive Codex, routed by Codex policy
cr --provider codex exec "explain this repo"  # native non-interactive Codex command
cr @openai-work resume --last            # account name infers Codex
```

`cr --provider codex login <name>`, `logout <name>`, and `doctor [name]`
delegate to official Codex commands under that account's `CODEX_HOME`. Codex
`exec`, `resume`, `exec resume`, `--profile`, and `-s` / `--sandbox` are native
Codex arguments and are forwarded unchanged.

## Commands

Launch (provider-native arguments are forwarded verbatim):

| Command | Effect |
|---|---|
| `cr [args…]` | route by policy, then run `claude args…` |
| `cr --provider codex [args…]` | route within Codex accounts, then run `codex args…` |
| `cr --account <name> [args…]` | force an account and infer its provider |
| `cr @<name> [args…]` | spaced shorthand for `--account <name>` |
| `cr --sandbox` / `-s [args…]` | Claude: run through [cco](https://github.com/nikvdp/cco); Codex: forward its native sandbox flag |
| `cr --watch` / `-w [args…]` | Claude-only supervised handoff near the usage limit |
| `cr --account <name> -- [args…]` | `--` ends router flags; the rest belongs to the selected provider CLI |

Manage (handled by the router or the selected provider adapter):

| Command | Effect |
|---|---|
| `cr add <name>` | make an account dir, symlink shared settings, browser-login, cache identity |
| `cr --provider codex add <name>` | make an isolated `CODEX_HOME` and run official `codex login` |
| `cr --provider codex add-api <name> [--from-env] [--rotate]` | give an API key to `codex login --with-api-key`; explicit-only unless `--rotate` |
| `cr add-backend <name> …` | register an alt-model endpoint (e.g. DeepSeek); see Backends below |
| `cr add-api <name>` | register an Anthropic API key account (explicit-only by default) |
| `cr rotate <name> on\|off` | opt an api-key account in or out of rotation |
| `cr register-default [name]` | register the existing `~/.claude` login (no dir move) |
| `cr relink [--all\|<name>]` | re-apply `~/.claude` sharing to existing accounts (run once after upgrading) |
| `cr [--provider <p>] login <name>` / `logout <name>` | run the provider's official authentication command |
| `cr remove <name>` | unregister (prints how to delete its dir + keychain item) |
| `cr list` (`accounts`, `ls`) | all accounts, with provider, identity, last-used, usage, and rotation state |
| `cr use <name>` | pin the account a plain `cr` uses (overrides rotation) |
| `cr use --clear` (`cr unuse`) | un-pin; go back to the rotation policy |
| `cr [--provider <p>] policy <policy>` | provider-scoped `round-robin` \| `lru` \| `random` \| `usage-aware` |
| `cr [--provider <p>] usage [name]` | provider-scoped usage; no-data/API-key accounts degrade gracefully |
| `cr [--provider <p>] status [--refresh\|--json]` | provider-scoped dashboard or machine-readable JSON |
| `cr [--provider <p>] doctor [name]` | provider-aware health check; Codex uses `codex login status` |

## Provider-scoped selection policies

Claude and Codex keep independent policy, pin, and rotation state. Plain
management commands target Claude; prefix them with `--provider codex` for
Codex:

```sh
cr policy usage-aware
cr --provider codex policy lru
cr --provider codex use openai-work
cr --provider codex status --json
```

- **round-robin** (default) — even spread across enabled accounts.
- **lru** — least-recently-used first.
- **random** — uniform random.
- **usage-aware** — route to the account with the most headroom, using the
  numbers from `cr usage`. Run `cr usage` periodically (or wire it to a cron) to
  refresh the cached figures; falls back to `lru` if usage data is unavailable.

**All policies skip exhausted accounts when current usage is available.** Before routing, `cr` refreshes usage
when the cache is stale and drops any account at/above the exhaustion threshold
(default 100%) from the rotation — so a maxed-out subscription is never chosen.
If *every* account is exhausted, it falls back to the full set rather than
failing. An account with no usage data yet counts as available. Tune it:

```sh
cr config                       # show routing knobs
cr config exhausted-at 90       # treat ≥90% used as "out", leave headroom
cr config auto-refresh off      # don't auto-poll before routing (use cr usage)
cr config ttl 600               # consider cached usage stale after 10 min
```

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
single line per account instead. Codex ChatGPT usage, when available through the
official Codex app-server interface, is normalized into the same windows. Codex
API-key accounts and accounts with no returned usage data show a friendly
no-data state instead of failing routing.

## OpenAI Codex accounts

Codex accounts use an isolated `CODEX_HOME` and Codex's own authentication
commands. Claw Router never parses or copies Codex credentials.

```sh
cr --provider codex add openai-work
cr --provider codex login openai-work
cr --provider codex doctor openai-work
cr --provider codex logout openai-work
```

For an OpenAI API-key account, use a hidden prompt or `--from-env`:

```sh
cr --provider codex add-api openai-api
cr --provider codex add-api openai-ci --from-env # reads an existing OPENAI_API_KEY
cr --provider codex add-api openai-personal --rotate
```

The key is piped to `codex login --with-api-key`. Claw Router does not persist
or read it; Codex owns the resulting login under that account's `CODEX_HOME`.
Codex API-key accounts are explicit-only unless `--rotate` is supplied, and
they have no subscription usage windows.

Provider selection is explicit unless an account supplies it:

```sh
cr --provider codex                         # interactive TUI
cr --provider codex exec "run the tests"    # native non-interactive mode
cr --provider codex resume --last           # native interactive resume
cr --provider codex exec resume --last "continue" # native exec resume
cr @openai-work -s workspace-write          # account infers Codex; -s is Codex's flag
```

Codex limitations are deliberate:

- `--watch` and `cr adopt` are Claude-only; the router does not inspect or
  symlink Codex session storage.
- Codex `resume` is forwarded as a native subcommand. It is not translated into
  Claude's `--resume` form.
- `-s` / `--sandbox` is forwarded to Codex. The `cco` integration is Claude-only.
- Codex API-key accounts have no subscription usage windows. Other Codex usage
  may also be unavailable; status, routing, and the menu bar continue with a
  no-data state.

## API-key accounts

Run Claude Code billed directly to an Anthropic API key, with its own config dir and conversation history — completely separate from your subscription accounts.

> **API-key accounts are explicit-only by default. A plain `cr` will never auto-pick one.** This is intentional: if you have a work API key, it must not bleed into personal projects. You reach an api account by naming it directly, or by explicitly opting it into rotation.

Register one:

```sh
cr add-api work-key                   # prompt for key (hidden input)
cr add-api work-key --from-env        # copy from $ANTHROPIC_API_KEY
cr add-api personal-key --rotate      # opt into rotation at registration time
```

Opt an existing account in or out of rotation:

```sh
cr rotate personal-key on             # plain 'cr' may now pick it
cr rotate personal-key off            # back to explicit-only
cr rotate personal-key                # print current state
```

Use it:

```sh
cr @work-key -p "draft the proposal"  # always explicit — never auto-selected
cr @personal-key                      # interactive session under that key
```

How it works: `cr` exports `ANTHROPIC_API_KEY` and sets `CLAUDE_CONFIG_DIR` to the account's own directory (history, projects, and settings all live there). It scrubs `ANTHROPIC_AUTH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`, and `ANTHROPIC_BASE_URL` so no conflicting auth leaks through.

**No usage meters.** API-key accounts are pay-per-token; there are no usage windows to poll. `cr usage work-key` prints a short note instead of a meter, and the all-accounts `cr usage` silently skips api accounts. Watch-mode handoffs never target api accounts for the same reason.

## Backends (alternate models, e.g. DeepSeek)

Besides your Anthropic subscriptions, `cr` can route Claude Code to an
Anthropic-compatible endpoint like DeepSeek. These are registered as **backend**
accounts and behave differently from subscriptions in one deliberate way:

> **Backends are explicit-only. They are never in the rotation.** A plain `cr`
> (round-robin / lru / usage-aware) only ever picks your subscriptions. You reach
> a backend by naming it: `cr @deepseek …` or `cr --account deepseek …`. This keeps
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
cr @deepseek -p "quick scratch task"      # default model
cr @deepseek --model flash -p "…"         # alias → deepseek-v4-flash
```

A backend launch sets `ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN` /
`ANTHROPIC_MODEL`, leaves `CLAUDE_CONFIG_DIR` and **`HOME` untouched** (so `gh`
and keychain tools keep working), and stores its API key under cr's own Keychain
item (`claw-router-backend` / `<name>`). It's effectively `deep-claude` folded
into `cr`.

## Sandbox mode

For Claude, add `--sandbox` (or `-s`) to run the session inside a container, so Claude Code
can't touch anything outside your project:

```sh
cr --sandbox -p "run the migration and tests"
cr @work -s                                  # sandboxed interactive session
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

For Codex, `-s` / `--sandbox` is not a router flag. It is forwarded unchanged
to Codex, including its required sandbox value:

```sh
cr --provider codex -s workspace-write
cr @openai-work --sandbox read-only
```

## Watch mode (Claude only)

Add `--watch` (or `-w`) to stay in a Claude conversation past your account's usage
limit. Instead of `exec`-ing claude and stepping away, `cr` stays alive,
watches the current account's usage in the background every two minutes, and
when usage nears its limit gracefully restarts claude under a fresher account
with `--resume` — the conversation continues because the session transcript is
symlinked across accounts via the existing session-linking machinery.

```sh
cr --watch                           # interactive session, auto-handoff when near limit
cr -w --account work                 # force starting account
cr --watch --resume <id>             # pick up an existing session and keep watching
```

The handoff happens at a turn boundary: `cr` waits until the session transcript
has been idle for at least 30 seconds (configurable), so an in-flight reply is
never interrupted mid-stream. The restart takes only a few seconds.

Three knobs (all configurable via `cr config`):

```sh
cr config watch-at 90        # hand off when usage reaches 90% (default)
cr config watch-interval 120 # poll every 120s (default)
cr config watch-idle 30      # wait for 30s of session inactivity before handing off (default)
```

Bypasses (watch silently degrades and runs normally):

- `-p` / `--print` — one-shot; no session to watch.
- Backends (`cr @deepseek`) — no usage data to poll.
- Only one enabled subscription account — nowhere to hand off to.
- Codex accounts — use native `codex resume`; cross-account watch handoff is not supported.

For Claude, `--watch` composes with the `cco` `--sandbox` mode (best-effort: both flags are independent).

## Menu bar watcher

A small [SwiftBar](https://github.com/swiftbar/SwiftBar) (or xbar) plugin lives in
[`menubar/`](menubar/) — it sits in your macOS menu bar and shows, at a glance,
how much headroom each account has, so you know which one to lean on before
you even start a session.

```sh
brew install --cask swiftbar      # or: brew install --cask xbar
brew install jq                   # if you don't already have it
mkdir -p ~/.config/swiftbar
ln -s "$PWD/menubar/clawrouter.30s.sh" ~/.config/swiftbar/
# point SwiftBar at ~/.config/swiftbar on first launch, then enable the plugin
cr menubar install                # Claude dashboard + background refresh
CLAWROUTER_PROVIDER=codex cr menubar install  # Codex dashboard + refresh
```

Set `CLAWROUTER_PROVIDER` to `claude` (default) or `codex` in SwiftBar Plugin
Settings. The bar shows the binding constraint — the *least* headroom across your in-rotation
accounts (`🦞 58%`, colored by how much is left). The dropdown breaks it down per
provider-labeled account and per window with reset countdowns, and gives you one-click actions to
switch policy, pin an account, or trigger a refresh.

The plugin reads only the cached snapshot (`cr status --json`) — no network, no
credential access at render time. A small launchd LaunchAgent (`cr menubar install`)
refreshes the selected provider every 5 minutes in the background. Claude may ask for
one-time Keychain access; Codex refresh delegates to the official Codex interface,
and Claw Router never reads Codex credentials. When an in-rotation account crosses the
exhaustion threshold the plugin fires a single macOS notification.

The dropdown is honest about data quality. Numbers that couldn't be refreshed
(an expired login, say) are labeled `· stale` in amber instead of being passed
off as live. A window whose reset time has already passed is shown as *rolled
over — awaiting refresh* rather than as a red 0%-left bar, and it doesn't drag
the headline percentage down while it waits for the next poll. "Refresh now"
blocks until the fresh snapshot actually lands (bounded at ~15 s), so the menu
redraws with the new reading instead of the cache it just invalidated.

See [`menubar/README.md`](menubar/README.md) for agent management (`cr menubar
status`, `cr menubar refresh`, `cr menubar uninstall`), configuration
(`CLAWROUTER_CR`, `CLAWROUTER_NOTIFY`), and troubleshooting.

`cr status --json` is also useful on its own — a machine-readable usage snapshot
(policy, next pick, per-account/per-window headroom, exhaustion, staleness,
window rollover) you can pipe into your own tools:

```sh
cr status --json            # cached snapshot, instant, no network
cr status --json --refresh  # poll live first, then emit
```

## Sessions across accounts (Claude only)

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
  cr @personal --resume 5fe702a8-… # (or just `cr --resume` — it auto-links anyway)
  ```

  Linking is a symlink, so the accounts share one evolving transcript.

Codex sessions stay under Codex's ownership. Use native `codex resume` forms
through the router (`cr --provider codex resume …` or `cr @name resume …`); Claw
Router does not discover, adopt, or symlink Codex sessions between accounts.

## Notes & limits

- **macOS-first.** Keychain isolation is the clean path on macOS. On Linux the
  same model works via `CLAUDE_CONFIG_DIR`/`.credentials.json` but the Keychain
  checks in `cr doctor` are skipped.
- **`--resume <id>`** auto-links the session into the picked account, so it
  resumes regardless of which Claude account created it (see *Sessions across accounts*).
  A bare `--continue` has no id to match — it just runs under the picked account.
- **Codex is capability-gated.** Native `exec`, `resume`, `exec resume`, and
  sandbox flags pass through unchanged. Claude-only watch, sandbox-container,
  shared-session, and transcript-linking logic is not applied to Codex.
- **Shared settings.** `cr add` symlinks `settings.json`, `CLAUDE.md`,
  `commands/`, `rules/`, `skills/`, `agents/`, `hooks/`, `workflows/`, and
  `plugins/` from `~/.claude` so your full extension environment is available in
  every account — not just settings. User-scope MCP servers are also merged from
  `~/.claude.json` into each account's `.claude.json` (the shared source wins on
  key conflicts; `oauthAccount` identity and all other keys are left per-account).
  Per-account history/projects stay separate. To apply sharing to accounts created
  before this version, run `cr relink --all` once after upgrading.
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

No real provider CLI or network calls — uses fake `claude` / `codex` executables
and isolated homes. Assertions cover provider/account selection, environment isolation, arg forwarding,
the Keychain naming scheme, backend isolation, usage rendering, token-refresh
persistence, the menu-bar plugin and its background agent, and cross-account
session linking.

## License

MIT © Dennison Bertram

---

<p align="center"><i>Not affiliated with Anthropic or OpenAI. “Claude” and “Claude Code” are trademarks of Anthropic; “OpenAI” and “Codex” are trademarks of OpenAI.</i></p>
