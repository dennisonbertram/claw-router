# Claude Router (`cr`) — Implementation & Test Plan

A convenience wrapper that lets you type `cr [any normal claude args]` and have it
automatically pick one of your several Claude subscriptions, announce which account
it's using, and then launch Claude Code normally under that account's credentials —
so load spreads evenly across accounts and your total usage lasts longer.

Scope: **Claude Code** (the CLI), macOS, multiple **subscription (OAuth) logins**.

---

## 1. How Claude Code authentication actually works (verified)

Findings below come from (a) the official docs and (b) reading the installed binary
`~/.local/share/claude/versions/2.1.170` and the live credential store on this machine.

### 1.1 Where credentials live

| OS | Storage |
|---|---|
| **macOS** | System **Keychain** (a generic-password item). The `.credentials.json` file is *not* the source of truth on macOS. |
| Linux/Windows | `~/.claude/.credentials.json`, mode `0600` (moves into `CLAUDE_CONFIG_DIR` if set). |

The Keychain item on this machine:

```
service (svce): "Claude Code-credentials"
account (acct): "dennison"          # = $USER
class:          genp (generic password)
```

The secret blob is JSON:

```json
{ "claudeAiOauth": {
    "accessToken":  "...",
    "refreshToken": "...",
    "expiresAt":    1780186069589,   # ms epoch; access tokens are short-lived
    "scopes":       ["user:inference","user:profile","user:sessions:claude_code", ...],
    "subscriptionType": "max",
    "rateLimitTier": "..."
} }
```

Account *identity* (email, org, plan, rate-limit tier) is cached separately, in plaintext,
in `~/.claude.json` under `oauthAccount`:

```json
"oauthAccount": {
  "emailAddress": "dennison@withtally.com",
  "organizationName": "Dennison Bertram",
  "organizationType": "claude_max",
  "organizationRateLimitTier": "default_claude_max_20x"
}
```

### 1.2 The key mechanism: `CLAUDE_CONFIG_DIR` namespaces the Keychain entry

From the binary, the Keychain **service name** is computed (de-minified):

```js
function keychainService(suffix = "") {                 // suffix is "-credentials" for creds
  const sec = process.env.CLAUDE_SECURESTORAGE_CONFIG_DIR;
  const useDefault = sec !== undefined ? !sec : !process.env.CLAUDE_CONFIG_DIR;
  const dir = sec !== undefined ? nfc(sec)
                                : (process.env.CLAUDE_CONFIG_DIR ?? `${home}/.claude`); // NFC-normalized
  const tag = useDefault ? "" : "-" + sha256(dir).slice(0, 8);   // 8 hex chars
  return `Claude Code${OAUTH_FILE_SUFFIX}${suffix}${tag}`;        // OAUTH_FILE_SUFFIX = "" in prod
}
// account name = process.env.USER (falls back to os.userInfo().username)
```

Consequences — these are the load-bearing facts the whole design rests on:

- **No `CLAUDE_CONFIG_DIR`** → service `Claude Code-credentials` (your current default account).
- **`CLAUDE_CONFIG_DIR=/path`** → service `Claude Code-credentials-<sha256(NFC(/path))[0:8]>`.
  Each distinct config dir therefore gets its **own** Keychain item, fully isolated.
  (Verified the hash recipe: `printf '%s' "$dir" | shasum -a 256 | cut -c1-8`.)
- `CLAUDE_SECURESTORAGE_CONFIG_DIR` can override *just* the Keychain keying without moving
  the rest of the config — but it leaves `oauthAccount` in `~/.claude.json` shared/stale,
  so we will **not** use it. One `CLAUDE_CONFIG_DIR` per account is the clean path.

So: **one directory per account = one isolated Keychain credential + its own config/state.**
A wrapper that sets `CLAUDE_CONFIG_DIR` before `exec claude` switches accounts with zero
credential juggling — Claude finds the right Keychain item by itself and auto-refreshes it.

### 1.3 Credential resolution precedence (highest → lowest)

1. Cloud provider creds (`CLAUDE_CODE_USE_BEDROCK` / `_VERTEX` / `_FOUNDRY`)
2. `ANTHROPIC_AUTH_TOKEN` (Bearer; gateways/proxies)
3. `ANTHROPIC_API_KEY` (`X-Api-Key`; once approved, sticky)
4. `apiKeyHelper` script (API keys only — **cannot** supply subscription OAuth)
5. `CLAUDE_CODE_OAUTH_TOKEN` (long-lived token from `claude setup-token`)
6. **Subscription OAuth from `/login`** (Keychain/`.credentials.json`) ← what we route

Implication for the wrapper: it must run with `ANTHROPIC_API_KEY` / `ANTHROPIC_AUTH_TOKEN`
**unset**, or they'll override the per-account subscription creds. `cr` will scrub those.

### 1.4 Token refresh & usage (for the smart, usage-aware mode)

- Refresh: `POST https://platform.claude.com/v1/oauth/token`
  body `grant_type=refresh_token`, `refresh_token`, `client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e`
  (the production Claude Code OAuth client id from the binary). Claude does this itself on
  launch, so for the launcher we don't need to — only for out-of-band usage polling.
- Usage: `GET https://api.anthropic.com/api/oauth/usage`
  headers `Authorization: Bearer <accessToken>`, `anthropic-beta: oauth-2025-04-20`.
  Response carries utilization buckets the `/usage` command uses:
  `five_hour` (the 5-hour session limit), `seven_day`, `seven_day_opus`,
  `seven_day_sonnet`, `seven_day_oauth_apps`. This is the data source for usage-aware
  selection. (Undocumented; treat as best-effort and degrade gracefully.)

### 1.5 `claude setup-token` (alternative, considered but not primary)

Produces a **1-year** OAuth token (`CLAUDE_CODE_OAUTH_TOKEN`), works on Pro/Max/Team/Enterprise,
inference-only (no Remote Control), and it does **not** persist the token — you capture it.
We could store one per account and switch via the env var. Downsides vs. `CLAUDE_CONFIG_DIR`:
the token sits in our files (less safe than Keychain), it's a separate credit/quota path on
subscription plans, and it bypasses Claude's own refresh. We'll keep it as a fallback for
headless/CI accounts, not the default.

---

## 2. Design

### 2.1 Model: one isolated account dir per subscription

```
~/.claude-router/
  config.json                 # registry + selection settings + rotation state
  accounts/
    default -> (uses ~/.claude, no CLAUDE_CONFIG_DIR)   # your existing login, untouched
    work/                     # CLAUDE_CONFIG_DIR for account "work"
    personal/                 # CLAUDE_CONFIG_DIR for account "personal"
  logs/route.log
```

`config.json`:

```json
{
  "selection": "round-robin",        // round-robin | lru | usage-aware | random
  "accounts": [
    { "name": "default",  "configDir": null,
      "email": "dennison@withtally.com", "plan": "claude_max",
      "lastUsed": 0, "enabled": true },
    { "name": "work",     "configDir": "~/.claude-router/accounts/work",
      "email": "...", "plan": "...", "lastUsed": 0, "enabled": true }
  ],
  "rotation": { "cursor": 0 },
  "share": { "settings": true, "memory": true, "commands": true }  // symlink shared bits
}
```

Identity (`email`/`plan`) is **cached into the registry at onboarding** so the launch hot
path never has to parse JSON or hit the network.

### 2.2 Why per-dir isolation (and the one tradeoff)

A separate `CLAUDE_CONFIG_DIR` isolates not just creds but also `settings.json`, MCP servers,
project history, todos, etc. That's usually fine, but you probably want **shared settings**.
Mitigation: at onboarding, symlink the bits you want shared from `~/.claude` into each account
dir (`settings.json`, `CLAUDE.md`, `commands/`, `rules/`, optionally `plugins/`). Per-account
state (`projects/`, `history.jsonl`, `.credentials.json`) stays separate. The `share` block in
config controls which paths get symlinked. (Rejected alternative: shared dir +
`CLAUDE_SECURESTORAGE_CONFIG_DIR` — it leaves `oauthAccount` identity mixed/stale.)

### 2.3 CLI surface

```
cr [claude args...]          # pick account per policy, announce, exec claude
cr --account <name> [args]   # force a specific account (alias: cr@<name>)
cr --account <name> --       # everything after -- is claude args, no ambiguity

cr accounts                  # table: name, email, plan, last used, (usage if available), enabled
cr add <name>                # create account dir, symlink shared bits, run `claude /login`, cache identity
cr login <name>              # (re)authenticate an existing account (claude /login under its dir)
cr logout <name>             # claude /logout under its dir (clears that Keychain item)
cr remove <name>             # unregister (optionally rm the dir / keychain item)
cr use <name>                # set/override default account for next plain `cr`
cr policy <round-robin|lru|usage-aware|random>
cr usage [<name>]            # poll /api/oauth/usage for one/all accounts (best-effort)
cr status                    # which account a plain `cr` would pick right now, and why
cr doctor                    # verify each account: dir exists, keychain item present, token decodes
```

Arg forwarding rule: anything `cr` doesn't recognize as its own subcommand/flag is passed
**verbatim** to `claude`, so `cr --dangerously-skip-permissions -p "..."` Just Works.
(Note: the real flag is `--dangerously-skip-permissions`, not `--dangerously-ignore-permissions`;
either way `cr` forwards whatever you type.) A literal `--` forces "everything after is claude's".

### 2.4 Launch hot path (the thing that runs every time)

```
1. parse cr-owned flags (stop at first unknown / at `--`)
2. choose account:
     round-robin: cursor = (cursor+1) % enabledCount; persist cursor
     lru:         pick min(lastUsed)
     usage-aware: pick max remaining headroom from cached/last usage poll (fallback → lru)
     forced:      --account / cr@name / `cr use` default
3. stamp lastUsed = now; persist registry (atomic write)
4. scrub overriding env: unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN
5. if account.configDir: export CLAUDE_CONFIG_DIR=<expanded absolute path>
   else: leave unset (default account → ~/.claude)
6. print banner to stderr:  "▶ claude-router → <name>  <email>  (<plan>)  [policy: round-robin]"
7. exec claude "$@"          # exec, not fork: zero overhead, signals/TTY/exit code pass through
```

`exec` matters: Claude Code is interactive (raw TTY, Ctrl-C, resize). The wrapper must hand
the terminal over and disappear, preserving the exit code.

### 2.5 Implementation language

**Bash** for the launcher (`cr`) — near-zero startup latency, no install step, `exec`-friendly,
and account selection (round-robin/lru) is a few lines. Dependencies, all present on this Mac:
`jq`, `curl`, `shasum`, `security`, `python3` (verified). Registry writes use a temp-file +
`mv` for atomicity. The optional **usage-aware** poller (HTTP + token refresh + JSON) is a
separate `cr-usage` helper shelling out to `curl`+`jq`, so the hot path never pays for it.

(If you'd rather have one typed codebase, a small Node/TS CLI works too — Node 24 is installed —
at the cost of ~100–200 ms startup on every launch. Recommendation: Bash launcher, optional
Node/Python only for the usage helper.)

### 2.6 Onboarding flow (`cr add <name>`)

```
1. mkdir -p ~/.claude-router/accounts/<name>
2. for each shared path in config.share: ln -s ~/.claude/<path> <accountdir>/<path>
3. CLAUDE_CONFIG_DIR=<accountdir> claude /login        # interactive browser OAuth
4. read <accountdir>/.claude.json -> oauthAccount; cache email/plan into registry
5. cr doctor <name>: confirm Keychain item "Claude Code-credentials-<hash>" now exists
```

The existing `~/.claude` login is registered as `default` with no dir move — nothing about
your current setup changes.

---

## 3. Risks & mitigations

| Risk | Mitigation |
|---|---|
| `ANTHROPIC_API_KEY` in env silently overrides subscription creds | `cr` unsets API-key/token env vars before exec |
| Per-dir isolation hides your settings/MCP/commands | Symlink shared bits at onboarding (`share` block) |
| Keychain item missing for a dir (never logged in) | `cr doctor` detects; `cr add`/`login` fixes; launch warns and offers login |
| Token expired at launch | Non-issue — Claude refreshes on its own using the refresh token in Keychain |
| `/api/oauth/usage` is undocumented and may change | usage-aware mode is best-effort; falls back to lru on any error |
| Rotation makes session/`--continue` land on the wrong account | `--continue`/`--resume` detected → reuse the account from that session's dir; or require explicit `--account` |
| macOS Keychain prompt on first access from a new binary path | first launch may prompt "always allow"; documented in onboarding |
| NFC normalization of the dir path | hash the NFC form (`python3 -c unicodedata.normalize('NFC',…)`); ASCII paths are unaffected |

---

## 4. Test plan

Goal: prove correctness **without burning real quota**. Layered, cheap → real.

### 4.1 Unit — selection logic (no Claude, no network)
- Round-robin over N enabled accounts cycles `0,1,...,N-1,0`; disabled accounts skipped.
- LRU always returns the min-`lastUsed`; ties broken deterministically.
- `--account`/`cr@name`/`cr use` override the policy.
- Registry writes are atomic (kill mid-write → file still valid JSON).
- Harness: `bats` (or plain shell asserts) against the pure selection function.

### 4.2 Launcher behavior — fake `claude` on PATH
- Put a stub `claude` earlier in PATH that prints `CLAUDE_CONFIG_DIR` and `"$@"` and exits 0.
- Assert: chosen account → correct `CLAUDE_CONFIG_DIR` (or unset for `default`).
- Assert: args forwarded **verbatim**, including `--dangerously-skip-permissions`, `-p "x"`,
  quoted args with spaces, and everything after `--`.
- Assert: `ANTHROPIC_API_KEY`/`ANTHROPIC_AUTH_TOKEN`/`CLAUDE_CODE_OAUTH_TOKEN` are unset in the
  child even if set in the parent.
- Assert: child exit code propagates (stub exits 7 → `cr` exits 7); banner goes to **stderr**
  (so `cr -p` stdout stays clean/pipeable).

### 4.3 Keychain naming — verify the hash recipe
- For a sample dir, compute `shasum -a 256` of the NFC path, take 8 chars, and assert it equals
  the suffix Claude actually used: after `cr add t`, `security find-generic-password
  -s "Claude Code-credentials-<hash>" -a "$USER"` returns 0.
- Confirms our isolation model matches the binary's real behavior.

### 4.4 Identity caching
- After `cr add`, registry `email`/`plan` match `<dir>/.claude.json` `oauthAccount`.
- `cr accounts` renders them with no network call and no JSON parse on the hot path.

### 4.5 Real auth round-trip (minimal quota)
- For each account: `CLAUDE_CONFIG_DIR=<dir> claude --version` then a one-shot
  `claude -p "reply with OK"` — confirms the credential resolves and the right account answers
  (cross-check via `cr usage` or the org/email). Cheapest possible real call.

### 4.6 Usage endpoint (best-effort mode)
- `cr usage <name>` returns parsed `five_hour`/`seven_day*` buckets for a live account.
- Force a 401 (corrupt token) → poller refreshes via `/v1/oauth/token` then retries; on hard
  failure, usage-aware selection falls back to lru without crashing the launch.

### 4.7 Resume safety
- `cr --continue` / `cr --resume <id>`: confirm it reattaches under the *originating* account's
  dir, not a rotated one (or errors clearly if it can't tell).

### 4.8 End-to-end smoke
- Two accounts registered; run `cr -p "hi"` four times; assert the route log shows an even
  2/2 split (round-robin) and each ran under the expected `CLAUDE_CONFIG_DIR`.

---

## 5. Build order (suggested)

1. Skeleton `cr` + registry read/write (atomic) + `cr add`/`accounts`/`doctor`.
2. Launch hot path: selection (round-robin + forced) + env scrub + `exec`. Tests 4.1–4.2.
3. Keychain/identity verification + onboarding symlinks. Tests 4.3–4.4.
4. Real round-trip + e2e smoke. Tests 4.5, 4.8.
5. LRU + `cr usage` + usage-aware policy + resume safety. Tests 4.6–4.7.
6. Install: symlink `cr` into `~/.local/bin`, shell completion, README.
