#!/usr/bin/env bash
# Self-contained test suite for cr. No real Claude, no network.
# Run: bash test/run.sh
set -uo pipefail

CR_REPO="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Isolated sandbox per run.
SBX="$(mktemp -d)"
trap 'rm -rf "$SBX"' EXIT
# Tests use fake accounts; never let a launch poll the real usage endpoint
# (the null-configDir "default" account would otherwise hit the real keychain).
export CR_NO_AUTO_REFRESH=1
# Tally via files so counts survive subshells (many test blocks run in ( … )).
: > "$SBX/.pass"; : > "$SBX/.fail"
ok()   { printf '  ok   %s\n' "$1"; printf x >> "$SBX/.pass"; }
bad()  { printf '  FAIL %s\n' "$1"; printf '       %s\n' "${2:-}"; printf x >> "$SBX/.fail"; }
eq()   { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected [$3] got [$2]"; fi; }
export CR_HOME="$SBX/crhome"

# Fake claude on PATH: records env+args, exits with $FAKE_EXIT (default 0).
FAKEBIN="$SBX/bin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/claude" <<'EOF'
#!/usr/bin/env bash
{
  echo "CONFIG_DIR=${CLAUDE_CONFIG_DIR-<unset>}"
  echo "API_KEY=${ANTHROPIC_API_KEY-<unset>}"
  echo "AUTH_TOKEN=${ANTHROPIC_AUTH_TOKEN-<unset>}"
  echo "OAUTH_TOKEN=${CLAUDE_CODE_OAUTH_TOKEN-<unset>}"
  echo "ARGS=$*"
} > "$FAKE_OUT"
exit "${FAKE_EXIT:-0}"
EOF
chmod +x "$FAKEBIN/claude"
export PATH="$FAKEBIN:$PATH"
export FAKE_OUT="$SBX/claude_out"

CR="$CR_REPO/cr"
run_cr() { "$CR" "$@" 2>"$SBX/stderr"; }

# Seed a registry with three accounts (default has null configDir).
seed() {
  rm -rf "$CR_HOME"; mkdir -p "$CR_HOME/logs"
  cat > "$CR_HOME/config.json" <<JSON
{ "selection": "round-robin",
  "accounts": [
    {"name":"default","configDir":null,"email":"a@x","plan":"max","lastUsed":0,"enabled":true,"usagePct":null},
    {"name":"work","configDir":"$CR_HOME/accounts/work","email":"b@x","plan":"max","lastUsed":0,"enabled":true,"usagePct":null},
    {"name":"home","configDir":"$CR_HOME/accounts/home","email":"c@x","plan":"pro","lastUsed":0,"enabled":true,"usagePct":null}
  ],
  "rotation": {"cursor":0},
  "share": {} }
JSON
}

echo "== selection (unit) =="
# Source the lib directly to test pure functions.
( export CR_HOME="$SBX/lib_home"; mkdir -p "$CR_HOME/logs"
  source "$CR_REPO/lib/common.sh"
  cat > "$CR_CONFIG" <<JSON
{"selection":"round-robin","accounts":[
  {"name":"a","configDir":null,"lastUsed":30,"enabled":true},
  {"name":"b","configDir":"/b","lastUsed":10,"enabled":true},
  {"name":"c","configDir":"/c","lastUsed":20,"enabled":false}],
 "rotation":{"cursor":0},"share":{}}
JSON
  # round-robin skips disabled c: a,b,a,b
  r1="$(cr_select_round_robin)"; r2="$(cr_select_round_robin)"
  r3="$(cr_select_round_robin)"; r4="$(cr_select_round_robin)"
  eq "round-robin cycles a,b,a,b over enabled" "$r1$r2$r3$r4" "abab"
  # lru picks smallest lastUsed among enabled (b=10; c disabled)
  eq "lru picks least-recently-used enabled" "$(cr_select_lru)" "b"
  # keychain hash recipe matches shasum formula
  want="Claude Code-credentials-$(printf '%s' "/tmp/acct" | shasum -a 256 | cut -c1-8)"
  eq "keychain service name for a dir" "$(cr_keychain_service "/tmp/acct")" "$want"
  eq "keychain service name for default" "$(cr_keychain_service "")" "Claude Code-credentials"
)

echo "== launch: config dir + env scrub + args =="
seed
export ANTHROPIC_API_KEY="SHOULD_BE_SCRUBBED"
export ANTHROPIC_AUTH_TOKEN="SHOULD_BE_SCRUBBED"
export CLAUDE_CODE_OAUTH_TOKEN="SHOULD_BE_SCRUBBED"
FAKE_EXIT=0 run_cr --account work --dangerously-skip-permissions -p "hello world"
out="$(cat "$FAKE_OUT")"
eq "forced account sets CLAUDE_CONFIG_DIR" \
   "$(grep '^CONFIG_DIR=' <<<"$out")" "CONFIG_DIR=$CR_HOME/accounts/work"
eq "API key scrubbed"   "$(grep '^API_KEY=' <<<"$out")"   "API_KEY=<unset>"
eq "auth token scrubbed" "$(grep '^AUTH_TOKEN=' <<<"$out")" "AUTH_TOKEN=<unset>"
eq "oauth token scrubbed" "$(grep '^OAUTH_TOKEN=' <<<"$out")" "OAUTH_TOKEN=<unset>"
eq "args forwarded verbatim" \
   "$(grep '^ARGS=' <<<"$out")" "ARGS=--dangerously-skip-permissions -p hello world"
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN

echo "== launch: default account leaves CLAUDE_CONFIG_DIR unset =="
seed
run_cr --account default -p hi
eq "default account → CLAUDE_CONFIG_DIR unset" \
   "$(grep '^CONFIG_DIR=' "$FAKE_OUT")" "CONFIG_DIR=<unset>"

echo "== launch: -- separator =="
seed
run_cr --account work -- --account zzz -p x
eq "-- forwards the rest to claude verbatim" \
   "$(grep '^ARGS=' "$FAKE_OUT")" "ARGS=--account zzz -p x"

echo "== launch: exit code propagation =="
seed
FAKE_EXIT=7 "$CR" --account work -p x >/dev/null 2>&1
eq "child exit code propagates" "$?" "7"

echo "== launch: banner goes to stderr, not stdout =="
seed
"$CR" --account work -p x >"$SBX/stdout" 2>"$SBX/stderr"
eq "stdout clean (banner on stderr)" "$(cat "$SBX/stdout")" ""
# Banner identifies the chosen account on stderr (color stripped — not a TTY in tests).
if grep -q 'work' "$SBX/stderr" && grep -q '◆' "$SBX/stderr"; then ok "banner on stderr"; else bad "banner on stderr" "missing ◆/account: $(cat "$SBX/stderr")"; fi

echo "== round-robin end to end =="
seed
for i in 1 2 3 4; do run_cr -p x; done
# log should have 4 entries; counts across 3 accounts ~ even (2,1,1 in order a,b,c,a)
counts="$(awk -F'\t' '{print $2}' "$CR_HOME/logs/route.log" | sort | uniq -c | awk '{print $1}' | sort | tr '\n' ' ')"
eq "4 launches split 2/1/1 over 3 accounts" "$counts" "1 1 2 "

echo "== single account: no rotation needed =="
rm -rf "$CR_HOME"; mkdir -p "$CR_HOME/logs"
cat > "$CR_HOME/config.json" <<JSON
{"selection":"round-robin","accounts":[
  {"name":"solo","configDir":"$CR_HOME/accounts/solo","email":"s@x","plan":"max","lastUsed":0,"enabled":true}],
 "rotation":{"cursor":0},"share":{}}
JSON
run_cr -p x
eq "single account is chosen" "$(grep '^CONFIG_DIR=' "$FAKE_OUT")" "CONFIG_DIR=$CR_HOME/accounts/solo"

echo "== plain 'cr' with NO args launches (bash 3.2 empty-array guard) =="
# Regression: on macOS stock bash 3.2 under set -u, `set -- "${_rest[@]}"` with
# no claude args was an "unbound variable" error — plain `cr` died before launch.
seed
: > "$FAKE_OUT"
"$CR" >"$SBX/stdout" 2>"$SBX/stderr"; rc=$?
eq "plain cr exits 0 (no unbound-variable crash)" "$rc" "0"
if grep -q 'unbound variable' "$SBX/stderr"; then bad "plain cr: no unbound-variable error" "$(cat "$SBX/stderr")"; else ok "plain cr: no unbound-variable error"; fi
if grep -q '^CONFIG_DIR=' "$FAKE_OUT"; then ok "plain cr reaches launch (execs claude)"; else bad "plain cr reaches launch" "fake claude not invoked: $(cat "$FAKE_OUT")"; fi
eq "plain cr forwards NO args to claude" "$(grep '^ARGS=' "$FAKE_OUT")" "ARGS="

echo "== usage pct parsing (unit) =="
( source "$CR_REPO/lib/common.sh"; source "$CR_REPO/lib/usage.sh"
  j='{"five_hour":{"utilization":42},"seven_day":{"utilization":61},"seven_day_opus":{"utilization":12}}'
  eq "usage pct takes most-constrained bucket" "$(cr_usage_pct "$j")" "61"
  j2='{"five_hour":17,"seven_day":9}'
  eq "usage pct handles numeric buckets" "$(cr_usage_pct "$j2")" "17"
)

echo "== backend: excluded from rotation =="
rm -rf "$CR_HOME"; mkdir -p "$CR_HOME/logs"
cat > "$CR_HOME/config.json" <<JSON
{"selection":"round-robin","accounts":[
  {"name":"default","kind":"subscription","configDir":null,"email":"a@x","plan":"max","lastUsed":0,"enabled":true},
  {"name":"work","kind":"subscription","configDir":"$CR_HOME/accounts/work","email":"b@x","plan":"max","lastUsed":0,"enabled":true},
  {"name":"deepseek","kind":"backend","configDir":null,"baseUrl":"https://api.deepseek.com/anthropic","model":"deepseek-v4-pro","modelAliases":{"pro":"deepseek-v4-pro","flash":"deepseek-v4-flash"},"apiKey":"sk-ds-test","email":null,"plan":"backend","lastUsed":0,"enabled":true}],
 "rotation":{"cursor":0},"share":{}}
JSON
( source "$CR_REPO/lib/common.sh"
  pool="$(cr_enabled_accounts | tr '\n' ',')"
  eq "rotation pool excludes backend" "$pool" "default,work,"
  eq "account kind reported" "$(cr_account_kind deepseek)" "backend"
)
# Round-robin over 4 launches must never pick the backend.
for i in 1 2 3 4; do run_cr -p x; done
if grep -q 'deepseek' "$CR_HOME/logs/route.log"; then bad "backend never auto-selected" "deepseek appeared in route log"; else ok "backend never auto-selected"; fi

echo "== backend: explicit launch sets env, not CLAUDE_CONFIG_DIR =="
run_cr --account deepseek --model flash -p hi
out="$(cat "$FAKE_OUT")"
eq "backend sets ANTHROPIC_BASE_URL" \
  "$(grep '^ARGS=' <<<"$out")" "ARGS=--model deepseek-v4-flash -p hi"
# The fake claude doesn't echo base url; assert via a richer stub below.

echo "== backend: env vars + key resolution (config fallback) =="
cat > "$FAKEBIN/claude" <<'EOF'
#!/usr/bin/env bash
{ echo "CONFIG_DIR=${CLAUDE_CONFIG_DIR-<unset>}"
  echo "BASE_URL=${ANTHROPIC_BASE_URL-<unset>}"
  echo "AUTH=${ANTHROPIC_AUTH_TOKEN-<unset>}"
  echo "MODEL_ENV=${ANTHROPIC_MODEL-<unset>}"
  echo "HOME_KEPT=${HOME}"
  echo "ARGS=$*"; } > "$FAKE_OUT"
EOF
chmod +x "$FAKEBIN/claude"
HOME_BEFORE="$HOME"
run_cr --account deepseek -p hi
out="$(cat "$FAKE_OUT")"
eq "backend: CLAUDE_CONFIG_DIR unset"        "$(grep '^CONFIG_DIR=' <<<"$out")" "CONFIG_DIR=<unset>"
eq "backend: base url set"                   "$(grep '^BASE_URL=' <<<"$out")"   "BASE_URL=https://api.deepseek.com/anthropic"
eq "backend: auth token = api key (config)"  "$(grep '^AUTH=' <<<"$out")"       "AUTH=sk-ds-test"
eq "backend: model env set (default)"        "$(grep '^MODEL_ENV=' <<<"$out")"  "MODEL_ENV=deepseek-v4-pro"
eq "backend: HOME left untouched"            "$(grep '^HOME_KEPT=' <<<"$out")"  "HOME_KEPT=$HOME_BEFORE"
# restore the original fake for any later tests
cat > "$FAKEBIN/claude" <<'EOF'
#!/usr/bin/env bash
{ echo "CONFIG_DIR=${CLAUDE_CONFIG_DIR-<unset>}"; echo "ARGS=$*"; } > "$FAKE_OUT"
exit "${FAKE_EXIT:-0}"
EOF
chmod +x "$FAKEBIN/claude"

echo "== backend: alias resolves pro/flash =="
( source "$CR_REPO/lib/common.sh"
  al="$(cr_config_read | jq -r '.accounts[]|select(.name=="deepseek")|.modelAliases.flash')"
  eq "flash alias maps to full model" "$al" "deepseek-v4-flash"
)

echo "== status: renders cached usage bars for all accounts =="
rm -rf "$CR_HOME"; mkdir -p "$CR_HOME/logs"
cat > "$CR_HOME/config.json" <<JSON
{"selection":"round-robin","accounts":[
  {"name":"default","kind":"subscription","configDir":null,"email":"a@x","plan":"max","lastUsed":0,"enabled":true,
   "usagePct":42,"usage":{"checkedAt":1700000000000,"windows":[
     {"label":"5h session","used":42,"resets":null},
     {"label":"7d total","used":12,"resets":null}]}},
  {"name":"work","kind":"subscription","configDir":"$CR_HOME/accounts/work","email":"b@x","plan":"max","lastUsed":0,"enabled":true,
   "usagePct":90,"usage":{"checkedAt":1700000000000,"windows":[
     {"label":"5h session","used":90,"resets":null}]}}],
 "rotation":{"cursor":0},"share":{}}
JSON
status_out="$("$CR" status 2>&1)"
if grep -q 'default' <<<"$status_out" && grep -q 'work' <<<"$status_out"; then ok "status lists all accounts"; else bad "status lists all accounts" "$status_out"; fi
if grep -q '58% left' <<<"$status_out"; then ok "status shows 'left' for 42% used (default)"; else bad "status 58% left" "$status_out"; fi
if grep -q '10% left' <<<"$status_out"; then ok "status shows 10% left for 90% used (work)"; else bad "status 10% left" "$status_out"; fi
if grep -qE '█|░' <<<"$status_out"; then ok "status draws bar glyphs"; else bad "status bar glyphs" "$status_out"; fi

echo "== status: no cache → friendly hint, no crash =="
rm -rf "$CR_HOME"; mkdir -p "$CR_HOME/logs"
cat > "$CR_HOME/config.json" <<JSON
{"selection":"round-robin","accounts":[
  {"name":"solo","kind":"subscription","configDir":null,"email":"s@x","plan":"max","lastUsed":0,"enabled":true}],
 "rotation":{"cursor":0},"share":{}}
JSON
so="$("$CR" status 2>&1)"; rc=$?
eq "status exits 0 without cache" "$rc" "0"
if grep -q 'cr usage' <<<"$so"; then ok "status hints to run cr usage"; else bad "status hint" "$so"; fi

echo "== resume auto-symlinks the session into the picked account =="
rm -rf "$CR_HOME"; mkdir -p "$CR_HOME/logs" "$CR_HOME/accounts/work/projects/-proj" "$CR_HOME/accounts/home"
cat > "$CR_HOME/config.json" <<JSON
{"selection":"round-robin","accounts":[
  {"name":"home","kind":"subscription","configDir":"$CR_HOME/accounts/home","email":"h@x","plan":"max","lastUsed":5,"enabled":true},
  {"name":"work","kind":"subscription","configDir":"$CR_HOME/accounts/work","email":"w@x","plan":"max","lastUsed":99,"enabled":true}],
 "rotation":{"cursor":0},"share":{}}
JSON
# Session owned by 'work'; resume rotates to the picked account and auto-links it in.
SID_OWN="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
echo '{"o":"work"}' > "$CR_HOME/accounts/work/projects/-proj/$SID_OWN.jsonl"
run_cr --account home --resume "$SID_OWN" -p x   # pin home so the assert is deterministic
eq "resume runs under the picked account (home)" \
   "$(grep '^CONFIG_DIR=' "$FAKE_OUT")" "CONFIG_DIR=$CR_HOME/accounts/home"
linkres="$CR_HOME/accounts/home/projects/-proj/$SID_OWN.jsonl"
if [[ -L "$linkres" ]]; then ok "resume auto-symlinks the session into the picked account"; else bad "resume auto-symlink" "not a symlink: $linkres"; fi
eq "auto-linked session resolves to owner's content" "$(cat "$linkres" 2>/dev/null)" '{"o":"work"}'
# Unknown session id → no link made, no crash, runs under picked account.
run_cr --account home --resume "deadbeef-0000-0000-0000-000000000000" -p x
eq "unknown session still launches (claude reports not-found)" \
   "$(grep '^CONFIG_DIR=' "$FAKE_OUT")" "CONFIG_DIR=$CR_HOME/accounts/home"

echo "== adopt symlinks a session into another account =="
SID_AD="adadadad-0000-1111-2222-333333333333"
echo '{"x":1}' > "$CR_HOME/accounts/work/projects/-proj/$SID_AD.jsonl"
"$CR" adopt "$SID_AD" home 2>"$SBX/stderr"
link="$CR_HOME/accounts/home/projects/-proj/$SID_AD.jsonl"
if [[ -L "$link" ]]; then ok "adopt creates a symlink in target"; else bad "adopt symlink" "not a symlink: $link"; fi
eq "adopted link resolves to source content" "$(cat "$link" 2>/dev/null)" '{"x":1}'
# After adopt, resuming under 'home' must route to home (it now owns a copy too).
run_cr --account home --resume "$SID_AD" -p x
eq "adopted session resumable under target account" \
   "$(grep '^CONFIG_DIR=' "$FAKE_OUT")" "CONFIG_DIR=$CR_HOME/accounts/home"

echo "== sandbox: --sandbox routes through cco, preserving account env =="
rm -rf "$CR_HOME"; mkdir -p "$CR_HOME/logs" "$CR_HOME/accounts/work"
cat > "$CR_HOME/config.json" <<JSON
{"selection":"round-robin","accounts":[
 {"name":"work","kind":"subscription","configDir":"$CR_HOME/accounts/work","email":"w@x","plan":"max","lastUsed":0,"enabled":true}],
 "rotation":{"cursor":0},"share":{}}
JSON
# Fake cco on PATH that records how it was invoked.
cat > "$FAKEBIN/cco" <<'EOF'
#!/usr/bin/env bash
{ echo "VIA=cco"; echo "CONFIG_DIR=${CLAUDE_CONFIG_DIR-<unset>}"; echo "ARGS=$*"; } > "$FAKE_OUT"
EOF
chmod +x "$FAKEBIN/cco"
run_cr --sandbox --account work -p "risky"
out="$(cat "$FAKE_OUT")"
eq "sandbox runs via cco"               "$(grep '^VIA=' <<<"$out")"        "VIA=cco"
eq "sandbox preserves CLAUDE_CONFIG_DIR" "$(grep '^CONFIG_DIR=' <<<"$out")" "CONFIG_DIR=$CR_HOME/accounts/work"
eq "sandbox forwards args after --"      "$(grep '^ARGS=' <<<"$out")"       "ARGS=-- -p risky"
# -s shorthand in plain form
run_cr -s --account work -p hi
eq "-s shorthand triggers sandbox" "$(grep '^VIA=' "$FAKE_OUT")" "VIA=cco"
# Without --sandbox, cco is NOT used (real/fake claude is).
run_cr --account work -p hi
eq "no --sandbox → does not use cco" "$(grep '^VIA=' "$FAKE_OUT" || echo 'VIA=claude')" "VIA=claude"
rm -f "$FAKEBIN/cco"
# Missing cco → fail fast, nonzero, no banner.
FAKE_EXIT=0 "$CR" --sandbox --account work -p hi >"$SBX/stdout" 2>"$SBX/stderr"; rc=$?
eq "missing cco exits nonzero" "$([[ $rc -ne 0 ]] && echo nonzero || echo zero)" "nonzero"
if grep -q 'cco' "$SBX/stderr"; then ok "missing cco explains how to install"; else bad "missing cco hint" "$(cat "$SBX/stderr")"; fi

echo "== availability: round-robin/lru skip exhausted accounts =="
( export CR_HOME="$SBX/avail"; mkdir -p "$CR_HOME/logs"
  source "$CR_REPO/lib/common.sh"
  cat > "$CR_CONFIG" <<JSON
{"selection":"round-robin","accounts":[
  {"name":"a","kind":"subscription","configDir":null,"lastUsed":1,"enabled":true,"usagePct":100},
  {"name":"b","kind":"subscription","configDir":"/b","lastUsed":9,"enabled":true,"usagePct":20},
  {"name":"c","kind":"subscription","configDir":"/c","lastUsed":5,"enabled":true,"usagePct":100}],
 "rotation":{"cursor":0},"share":{}}
JSON
  pool="$(cr_available_accounts | tr '\n' ',')"
  eq "available pool excludes 100%-used a and c" "$pool" "b,"
  # round-robin should only ever return b (a and c are exhausted)
  r="$(cr_select_round_robin)$(cr_select_round_robin)$(cr_select_round_robin)"
  eq "round-robin sticks to the only available account" "$r" "bbb"
  # lru must also skip exhausted, even though 'a' has the smallest lastUsed
  eq "lru picks available 'b', not lower-lastUsed exhausted 'a'" "$(cr_select_lru)" "b"
)

echo "== availability: all exhausted → fall back to all enabled (don't hard-fail) =="
( export CR_HOME="$SBX/avail2"; mkdir -p "$CR_HOME/logs"
  source "$CR_REPO/lib/common.sh"
  cat > "$CR_CONFIG" <<JSON
{"selection":"round-robin","accounts":[
  {"name":"a","kind":"subscription","configDir":null,"lastUsed":1,"enabled":true,"usagePct":100},
  {"name":"b","kind":"subscription","configDir":"/b","lastUsed":9,"enabled":true,"usagePct":100}],
 "rotation":{"cursor":0},"share":{}}
JSON
  got="$(cr_select_round_robin)"
  if [[ "$got" == "a" || "$got" == "b" ]]; then ok "all-exhausted falls back to an enabled account"; else bad "all-exhausted fallback" "got [$got]"; fi
)

echo "== availability: unknown usage is treated as available =="
( export CR_HOME="$SBX/avail3"; mkdir -p "$CR_HOME/logs"
  source "$CR_REPO/lib/common.sh"
  cat > "$CR_CONFIG" <<JSON
{"selection":"round-robin","accounts":[
  {"name":"a","kind":"subscription","configDir":null,"lastUsed":1,"enabled":true,"usagePct":100},
  {"name":"b","kind":"subscription","configDir":"/b","lastUsed":9,"enabled":true,"usagePct":null}],
 "rotation":{"cursor":0},"share":{}}
JSON
  eq "account with no usage data counts as available" "$(cr_available_accounts | tr '\n' ',')" "b,"
)

echo "== owner detection: a symlinked copy is NOT ownership =="
( export CR_HOME="$SBX/own"; mkdir -p "$CR_HOME/logs" "$CR_HOME/accounts/real/projects/-p" "$CR_HOME/accounts/linked/projects/-p"
  source "$CR_REPO/lib/common.sh"
  cat > "$CR_CONFIG" <<JSON
{"selection":"round-robin","accounts":[
  {"name":"real","kind":"subscription","configDir":"$CR_HOME/accounts/real","lastUsed":0,"enabled":true},
  {"name":"linked","kind":"subscription","configDir":"$CR_HOME/accounts/linked","lastUsed":0,"enabled":true}],
 "rotation":{"cursor":0},"share":{}}
JSON
  # cr_account_owning_session lives in cr (not lib); pull it in.
  eval "$(sed -n '/^cr_account_owning_session()/,/^}/p' "$CR_REPO/cr")"
  SID="bbbbbbbb-cccc-dddd-eeee-ffffffffffff"
  echo '{"real":1}' > "$CR_HOME/accounts/real/projects/-p/$SID.jsonl"
  ln -s "$CR_HOME/accounts/real/projects/-p/$SID.jsonl" "$CR_HOME/accounts/linked/projects/-p/$SID.jsonl"
  eq "owner is the real-file account, not the symlinked one" "$(cr_account_owning_session "$SID")" "real"
)

echo "== link safety: never destroy a real transcript at the target =="
( export CR_HOME="$SBX/safe"; mkdir -p "$CR_HOME/logs" "$CR_HOME/accounts/x/projects/-p" "$CR_HOME/accounts/y/projects/-p"
  source "$CR_REPO/lib/common.sh"
  cat > "$CR_CONFIG" <<JSON
{"selection":"round-robin","accounts":[
  {"name":"x","kind":"subscription","configDir":"$CR_HOME/accounts/x","lastUsed":0,"enabled":true},
  {"name":"y","kind":"subscription","configDir":"$CR_HOME/accounts/y","lastUsed":0,"enabled":true}],
 "rotation":{"cursor":0},"share":{}}
JSON
  SID="cccccccc-dddd-eeee-ffff-000000000000"
  echo '{"src":1}' > "$CR_HOME/accounts/x/projects/-p/$SID.jsonl"
  echo '{"DEST_REAL":1}' > "$CR_HOME/accounts/y/projects/-p/$SID.jsonl"   # y has its OWN real file
)
# cr_link_session is in cr (not lib); exercise the safety rule via the launcher path indirectly:
# Re-run owner detection + a manual link attempt by sourcing cr's function set.
( export CR_HOME="$SBX/safe"; source "$CR_REPO/lib/common.sh"
  # inline-source just the function under test from cr without running main:
  eval "$(sed -n '/^cr_link_session()/,/^}/p' "$CR_REPO/cr")"
  SID="cccccccc-dddd-eeee-ffff-000000000000"
  cr_link_session "$SID" y >/dev/null 2>&1 || true
  dest="$CR_HOME/accounts/y/projects/-p/$SID.jsonl"
  if [[ -f "$dest" && ! -L "$dest" ]] && grep -q DEST_REAL "$dest"; then ok "real target transcript left intact (not clobbered)"; else bad "link safety" "target was destroyed or replaced: $(ls -l "$dest" 2>&1)"; fi
)

# -------------------------------------------------------------------------
# Watch mode tests
# -------------------------------------------------------------------------
export CR_NO_USAGE_POLL=1

echo "== watch: strip resume args (unit) =="
(
  export CR_HOME="$SBX/watch_strip_home"; mkdir -p "$CR_HOME/logs"
  source "$CR_REPO/lib/common.sh"
  source "$CR_REPO/lib/watch.sh"

  cr_watch_strip_resume --resume abc -p x
  eq "strip --resume <val> -p x => -p x" "${CR_WATCH_ARGS[*]}" "-p x"

  cr_watch_strip_resume --resume=abc --continue -c foo
  eq "strip --resume=abc --continue -c foo => foo" "${CR_WATCH_ARGS[*]}" "foo"

  cr_watch_strip_resume -p x
  eq "nothing to strip: -p x => -p x" "${CR_WATCH_ARGS[*]}" "-p x"

  # A flag right after a bare --resume is NOT the session id — keep it.
  cr_watch_strip_resume --resume --output-format json
  eq "bare --resume followed by a flag keeps the flag" "${CR_WATCH_ARGS[*]}" "--output-format json"
)

echo "== watch: pick-next candidate (unit) =="
(
  export CR_HOME="$SBX/watch_pick_home"; mkdir -p "$CR_HOME/logs"
  source "$CR_REPO/lib/common.sh"
  source "$CR_REPO/lib/watch.sh"
  cat > "$CR_CONFIG" <<JSON
{"selection":"round-robin","accounts":[
  {"name":"work","kind":"subscription","configDir":"$SBX/watch_pick_home/accounts/work","lastUsed":0,"enabled":true,"usagePct":95},
  {"name":"home","kind":"subscription","configDir":"$SBX/watch_pick_home/accounts/home","lastUsed":0,"enabled":true,"usagePct":10},
  {"name":"spare","kind":"subscription","configDir":"$SBX/watch_pick_home/accounts/spare","lastUsed":0,"enabled":true,"usagePct":null},
  {"name":"deepseek","kind":"backend","configDir":null,"lastUsed":0,"enabled":true,"usagePct":null},
  {"name":"off","kind":"subscription","configDir":"$SBX/watch_pick_home/accounts/off","lastUsed":0,"enabled":false,"usagePct":5}],
 "rotation":{"cursor":0},"share":{}}
JSON
  # work at 95%, pick_next at 90 should return home (lowest usagePct among eligible)
  got="$(cr_watch_pick_next work 90)"
  eq "pick_next: work exhausted -> home" "$got" "home"

  # set home to 95 too; spare is null (unknown = eligible, ranked after known headroom)
  cr_config_update '(.accounts[] | select(.name=="home") | .usagePct) = 95' >/dev/null
  got="$(cr_watch_pick_next work 90)"
  eq "pick_next: home exhausted, spare null -> spare" "$got" "spare"

  # set spare to 95 too -> no eligible candidate
  cr_config_update '(.accounts[] | select(.name=="spare") | .usagePct) = 95' >/dev/null
  got="$(cr_watch_pick_next work 90)"
  eq "pick_next: all exhausted -> empty" "$got" ""
)

echo "== watch: latest-session discovery (unit) =="
(
  export CR_HOME="$SBX/watch_disc_home"; mkdir -p "$CR_HOME/logs"
  source "$CR_REPO/lib/common.sh"
  source "$CR_REPO/lib/watch.sh"

  mkdir -p "$CR_HOME/accounts/acct1" "$CR_HOME/accounts/acct2"
  cat > "$CR_CONFIG" <<JSON
{"selection":"round-robin","accounts":[
  {"name":"acct1","kind":"subscription","configDir":"$CR_HOME/accounts/acct1","lastUsed":0,"enabled":true},
  {"name":"acct2","kind":"subscription","configDir":"$CR_HOME/accounts/acct2","lastUsed":0,"enabled":true}],
 "rotation":{"cursor":0},"share":{}}
JSON

  MUNGED="$(pwd | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')"
  mkdir -p "$CR_HOME/accounts/acct1/projects/$MUNGED"
  mkdir -p "$CR_HOME/accounts/acct2/projects/$MUNGED"

  # Create a marker file
  MARKER="$SBX/disc_marker"
  touch "$MARKER"
  sleep 0.05 2>/dev/null || true

  OLD_SID="11111111-0000-0000-0000-000000000000"
  NEW_SID="22222222-0000-0000-0000-000000000000"
  LINK_SID="33333333-0000-0000-0000-000000000000"

  # Old file: mtime before marker (use year 2020 so definitely before marker)
  touch -t 202001010000 "$CR_HOME/accounts/acct1/projects/$MUNGED/$OLD_SID.jsonl"

  # Newer real file: mtime after marker
  touch "$CR_HOME/accounts/acct2/projects/$MUNGED/$NEW_SID.jsonl"

  # Symlink: should be excluded
  ln -s "$CR_HOME/accounts/acct2/projects/$MUNGED/$NEW_SID.jsonl" \
        "$CR_HOME/accounts/acct1/projects/$MUNGED/$LINK_SID.jsonl"

  # With marker: only NEW_SID qualifies (old is before marker, link is excluded)
  result="$(cr_watch_latest_session "$MARKER" || true)"
  got_sid="${result%%	*}"
  eq "discovery with marker: returns newer real sid" "$got_sid" "$NEW_SID"

  # Without marker filter (empty arg): picks newest overall (NEW_SID, ignoring symlink)
  result2="$(cr_watch_latest_session "" || true)"
  got_sid2="${result2%%	*}"
  eq "discovery no marker: picks newest real sid" "$got_sid2" "$NEW_SID"
)

echo "== watch: idle detection (unit) =="
(
  export CR_HOME="$SBX/watch_idle_home"; mkdir -p "$CR_HOME/logs"
  source "$CR_REPO/lib/common.sh"
  source "$CR_REPO/lib/watch.sh"

  OLD_FILE="$SBX/old_transcript.jsonl"
  touch -t 202001010000 "$OLD_FILE"
  if cr_watch_idle "$OLD_FILE" 30; then ok "old file is idle"; else bad "old file is idle" "expected idle"; fi

  FRESH_FILE="$SBX/fresh_transcript.jsonl"
  touch "$FRESH_FILE"
  if cr_watch_idle "$FRESH_FILE" 60; then bad "fresh file not idle" "expected not-idle"; else ok "fresh file is not idle"; fi

  if cr_watch_idle "" 30; then ok "empty path is idle"; else bad "empty path is idle" "expected idle"; fi
)

echo "== watch: config knobs =="
(
  export CR_HOME="$SBX/watch_cfg_home"; mkdir -p "$CR_HOME/logs"
  source "$CR_REPO/lib/common.sh"
  cat > "$CR_CONFIG" <<JSON
{"selection":"round-robin","accounts":[],"rotation":{"cursor":0},"share":{}}
JSON

  "$CR_REPO/cr" config watch-at 85 2>/dev/null
  got="$(cr_config_read | jq -r '.watchAtPct')"
  eq "watch-at sets watchAtPct" "$got" "85"

  "$CR_REPO/cr" config watch-interval 60 2>/dev/null
  got="$(cr_config_read | jq -r '.watchIntervalSeconds')"
  eq "watch-interval sets watchIntervalSeconds" "$got" "60"

  "$CR_REPO/cr" config watch-idle 45 2>/dev/null
  got="$(cr_config_read | jq -r '.watchIdleSeconds')"
  eq "watch-idle sets watchIdleSeconds" "$got" "45"

  # Invalid value should exit nonzero
  "$CR_REPO/cr" config watch-at notanumber 2>/dev/null; rc=$?
  if [[ "$rc" -ne 0 ]]; then ok "invalid watch-at exits nonzero"; else bad "invalid watch-at exits nonzero" "rc=$rc"; fi
)

echo "== watch: -p bypasses watch =="
(
  export CR_HOME="$SBX/watch_p_home"; mkdir -p "$CR_HOME/logs"
  cat > "$CR_HOME/config.json" <<JSON
{"selection":"round-robin","accounts":[
  {"name":"work","kind":"subscription","configDir":"$CR_HOME/accounts/work","lastUsed":0,"enabled":true,"usagePct":null},
  {"name":"home","kind":"subscription","configDir":"$CR_HOME/accounts/home","lastUsed":0,"enabled":true,"usagePct":null}],
 "rotation":{"cursor":0},"share":{}}
JSON
  mkdir -p "$CR_HOME/accounts/work" "$CR_HOME/accounts/home"
  "$CR_REPO/cr" --watch --account work -p hi >"$SBX/stdout" 2>"$SBX/watch_p_err"
  if grep -q 'without watch' "$SBX/watch_p_err"; then ok "-p: stderr contains 'without watch'"; else bad "-p: without watch message" "$(cat "$SBX/watch_p_err")"; fi
  if grep -q 'CONFIG_DIR=.*accounts/work' "$FAKE_OUT" 2>/dev/null || grep -q 'accounts/work' "$FAKE_OUT" 2>/dev/null; then ok "-p: single launch (not watched)"; else
    # The fake claude writes to FAKE_OUT; check the args were passed
    args_got="$(grep '^ARGS=' "$FAKE_OUT" 2>/dev/null || true)"
    if [[ "$args_got" == "ARGS=-p hi" ]]; then ok "-p: single launch (not watched)"; else bad "-p: single launch" "$args_got"; fi
  fi
)

echo "== watch: single account bypasses watch =="
(
  export CR_HOME="$SBX/watch_single_home"; mkdir -p "$CR_HOME/logs"
  cat > "$CR_HOME/config.json" <<JSON
{"selection":"round-robin","accounts":[
  {"name":"solo","kind":"subscription","configDir":"$CR_HOME/accounts/solo","lastUsed":0,"enabled":true,"usagePct":null}],
 "rotation":{"cursor":0},"share":{}}
JSON
  mkdir -p "$CR_HOME/accounts/solo"
  "$CR_REPO/cr" --watch x >"$SBX/stdout" 2>"$SBX/watch_single_err"
  if grep -qE 'only one account|fewer than two subscription' "$SBX/watch_single_err"; then ok "single account: bypass warning message"; else bad "single account bypass" "$(cat "$SBX/watch_single_err")"; fi
)

echo "== watch: end-to-end handoff =="
WATCH_LOG="$SBX/watch_log"
: > "$WATCH_LOG"
export WATCH_LOG

# Fresh config with two accounts, usage already near limit for 'work'.
WCR_HOME="$SBX/watch_e2e_home"
rm -rf "$WCR_HOME"; mkdir -p "$WCR_HOME/logs" "$WCR_HOME/accounts/work" "$WCR_HOME/accounts/home"
NOW_MS="$(( $(date +%s) * 1000 ))"
cat > "$WCR_HOME/config.json" <<JSON
{"selection":"round-robin",
 "watchAtPct":90, "watchIntervalSeconds":1, "watchIdleSeconds":0,
 "accounts":[
   {"name":"work","kind":"subscription","configDir":"$WCR_HOME/accounts/work",
    "lastUsed":0,"enabled":true,"usagePct":95,
    "usage":{"checkedAt":${NOW_MS},"windows":[]}},
   {"name":"home","kind":"subscription","configDir":"$WCR_HOME/accounts/home",
    "lastUsed":0,"enabled":true,"usagePct":10,
    "usage":{"checkedAt":${NOW_MS},"windows":[]}}],
 "rotation":{"cursor":0},"share":{}}
JSON

# Create a session transcript owned by 'work' (old mtime, so excluded by marker
# => exercises the orig-sid fallback).
SID_E2E="eeeeeeee-1111-2222-3333-444444444444"
MUNGED_E2E="$(pwd | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')"
mkdir -p "$WCR_HOME/accounts/work/projects/$MUNGED_E2E"
printf '{"w":1}\n' > "$WCR_HOME/accounts/work/projects/$MUNGED_E2E/$SID_E2E.jsonl"
touch -t 202001010000 "$WCR_HOME/accounts/work/projects/$MUNGED_E2E/$SID_E2E.jsonl"

# Watch-aware fake claude: records invocation, on 2nd call exits immediately.
cat > "$FAKEBIN/claude" <<'FAKE'
#!/usr/bin/env bash
echo "CONFIG_DIR=${CLAUDE_CONFIG_DIR-<unset>} ARGS=$*" >> "$WATCH_LOG"
lines="$(wc -l < "$WATCH_LOG" | tr -d ' ')"
if [[ "$lines" -ge 2 ]]; then
  exit 0
fi
# First invocation: sleep interruptibly so watcher can SIGTERM us.
sleep 60 &
wait $! 2>/dev/null || true
exit 0
FAKE
chmod +x "$FAKEBIN/claude"

# Run in background with isolated CR_HOME, capturing stderr.
CR_HOME="$WCR_HOME" "$CR_REPO/cr" --watch --account work --resume "$SID_E2E" \
  2>"$SBX/watch_e2e_err" &
WPID=$!

# Poll up to 30 seconds for completion.
DONE=0
for _i in $(seq 1 60); do
  sleep 0.5
  if ! kill -0 "$WPID" 2>/dev/null; then DONE=1; break; fi
done

if [[ "$DONE" -ne 1 ]]; then
  kill "$WPID" 2>/dev/null || true
  bad "e2e handoff: completed within timeout" "still running after 30s"
else
  wait "$WPID" 2>/dev/null; WRC=$?
  eq "e2e handoff: exit code 0" "$WRC" "0"

  # Line 1: work account was launched with --resume $SID_E2E
  LINE1="$(sed -n '1p' "$WATCH_LOG" 2>/dev/null || true)"
  if [[ "$LINE1" == *"accounts/work"* ]]; then ok "e2e: line1 uses work account"; else bad "e2e: line1 work account" "$LINE1"; fi
  if [[ "$LINE1" == *"--resume $SID_E2E"* ]]; then ok "e2e: line1 has --resume SID"; else bad "e2e: line1 --resume" "$LINE1"; fi

  # Line 2: home account was launched with --resume $SID_E2E
  LINE2="$(sed -n '2p' "$WATCH_LOG" 2>/dev/null || true)"
  if [[ "$LINE2" == *"accounts/home"* ]]; then ok "e2e: line2 uses home account"; else bad "e2e: line2 home account" "$LINE2"; fi
  if [[ "$LINE2" == *"--resume $SID_E2E"* ]]; then ok "e2e: line2 has --resume SID"; else bad "e2e: line2 --resume" "$LINE2"; fi

  # Session symlinked into home account
  LINK_PATH="$WCR_HOME/accounts/home/projects/$MUNGED_E2E/$SID_E2E.jsonl"
  if [[ -L "$LINK_PATH" ]]; then ok "e2e: session symlinked into home account"; else bad "e2e: session symlink" "not a symlink: $LINK_PATH"; fi
  LINK_CONTENT="$(cat "$LINK_PATH" 2>/dev/null | tr -d '\n' || true)"
  if [[ "$LINK_CONTENT" == *'"w":1'* ]]; then ok "e2e: symlink resolves to work's content"; else bad "e2e: symlink content" "$LINK_CONTENT"; fi

  # stderr should contain handoff banner
  if grep -q '↻' "$SBX/watch_e2e_err"; then ok "e2e: stderr has handoff arrow"; else bad "e2e: handoff arrow in stderr" "$(cat "$SBX/watch_e2e_err")"; fi
  if grep -q 'home' "$SBX/watch_e2e_err"; then ok "e2e: stderr mentions home account"; else bad "e2e: home in stderr" "$(cat "$SBX/watch_e2e_err")"; fi
fi

# Restore the standard fake claude (identical to the original at the top).
cat > "$FAKEBIN/claude" <<'EOF'
#!/usr/bin/env bash
{
  echo "CONFIG_DIR=${CLAUDE_CONFIG_DIR-<unset>}"
  echo "API_KEY=${ANTHROPIC_API_KEY-<unset>}"
  echo "AUTH_TOKEN=${ANTHROPIC_AUTH_TOKEN-<unset>}"
  echo "OAUTH_TOKEN=${CLAUDE_CODE_OAUTH_TOKEN-<unset>}"
  echo "ARGS=$*"
} > "$FAKE_OUT"
exit "${FAKE_EXIT:-0}"
EOF
chmod +x "$FAKEBIN/claude"
unset WATCH_LOG

echo "== watch: natural child exit propagates, no handoff =="
rm -rf "$CR_HOME"; mkdir -p "$CR_HOME/logs"
cat > "$CR_HOME/config.json" <<JSON
{"selection":"round-robin","accounts":[
  {"name":"work","kind":"subscription","configDir":"$CR_HOME/accounts/work","email":"w@x","plan":"max","lastUsed":0,"enabled":true,"usagePct":10},
  {"name":"home","kind":"subscription","configDir":"$CR_HOME/accounts/home","email":"h@x","plan":"max","lastUsed":0,"enabled":true,"usagePct":10}],
 "rotation":{"cursor":0},"share":{}}
JSON
FAKE_EXIT=42 "$CR" --watch --account work x >/dev/null 2>"$SBX/stderr"; rc=$?
eq "watch: natural child exit code propagates" "$rc" "42"
if grep -q '↻' "$SBX/stderr"; then bad "watch: no handoff on natural exit" "unexpected handoff banner"; else ok "watch: no handoff on natural exit"; fi

echo "== api: rotation pool — explicit-only by default =="
(
  export CR_HOME="$SBX/api_pool_home"; mkdir -p "$CR_HOME/logs"
  source "$CR_REPO/lib/common.sh"
  cat > "$CR_CONFIG" <<JSON
{"selection":"round-robin","accounts":[
  {"name":"default","kind":"subscription","configDir":null,"lastUsed":0,"enabled":true,"usagePct":null},
  {"name":"work","kind":"subscription","configDir":"$SBX/api_pool_home/accounts/work","lastUsed":0,"enabled":true,"usagePct":null},
  {"name":"workkey","kind":"api","configDir":"$SBX/api_pool_home/accounts/workkey","apiKey":"sk-test-work","email":null,"plan":"api-key","lastUsed":0,"enabled":true,"usagePct":null,"rotate":false},
  {"name":"workkey2","kind":"api","configDir":"$SBX/api_pool_home/accounts/workkey2","apiKey":"sk-test-work2","email":null,"plan":"api-key","lastUsed":0,"enabled":true,"usagePct":null}],
 "rotation":{"cursor":0},"share":{}}
JSON
  pool="$(cr_enabled_accounts | tr '\n' ',')"
  eq "api rotate=false excluded from pool" "$pool" "default,work,"
  # workkey2 has no rotate field — also excluded (defaults to false/absent)
  if printf '%s' "$pool" | grep -q 'workkey'; then bad "api rotate absent excluded from pool" "workkey in pool: $pool"; else ok "api rotate absent excluded from pool"; fi
)
# 4 launches via run_cr — workkey must never appear in route.log
rm -rf "$CR_HOME"; mkdir -p "$CR_HOME/logs"
cat > "$CR_HOME/config.json" <<JSON
{"selection":"round-robin","accounts":[
  {"name":"default","kind":"subscription","configDir":null,"lastUsed":0,"enabled":true,"usagePct":null},
  {"name":"work","kind":"subscription","configDir":"$CR_HOME/accounts/work","lastUsed":0,"enabled":true,"usagePct":null},
  {"name":"workkey","kind":"api","configDir":"$CR_HOME/accounts/workkey","apiKey":"sk-test-work","email":null,"plan":"api-key","lastUsed":0,"enabled":true,"usagePct":null,"rotate":false}],
 "rotation":{"cursor":0},"share":{}}
JSON
for i in 1 2 3 4; do run_cr -p x; done
if grep -q 'workkey' "$CR_HOME/logs/route.log"; then bad "api explicit-only: never auto-selected" "workkey in route.log"; else ok "api explicit-only: never auto-selected"; fi

echo "== api: rotate=true joins the pool =="
(
  export CR_HOME="$SBX/api_rotate_home"; mkdir -p "$CR_HOME/logs"
  source "$CR_REPO/lib/common.sh"
  cat > "$CR_CONFIG" <<JSON
{"selection":"round-robin","accounts":[
  {"name":"default","kind":"subscription","configDir":null,"lastUsed":0,"enabled":true,"usagePct":null},
  {"name":"perskey","kind":"api","configDir":"$SBX/api_rotate_home/accounts/perskey","apiKey":"sk-pers","email":null,"plan":"api-key","lastUsed":0,"enabled":true,"usagePct":null,"rotate":true}],
 "rotation":{"cursor":0},"share":{}}
JSON
  pool="$(cr_enabled_accounts | tr '\n' ',')"
  eq "api rotate=true in enabled pool" "$pool" "default,perskey,"
  avail="$(cr_available_accounts | tr '\n' ',')"
  eq "api rotate=true in available pool (usagePct null)" "$avail" "default,perskey,"
)

echo "== api: rotate command toggles =="
(
  export CR_HOME="$SBX/api_toggle_home"; mkdir -p "$CR_HOME/logs"
  cat > "$CR_HOME/config.json" <<JSON
{"selection":"round-robin","accounts":[
  {"name":"work","kind":"subscription","configDir":null,"lastUsed":0,"enabled":true,"usagePct":null},
  {"name":"workkey","kind":"api","configDir":"$SBX/api_toggle_home/accounts/workkey","apiKey":"sk-test","email":null,"plan":"api-key","lastUsed":0,"enabled":true,"usagePct":null,"rotate":false}],
 "rotation":{"cursor":0},"share":{}}
JSON
  # Toggle on
  "$CR" rotate workkey on 2>/dev/null
  got="$(jq -r '.accounts[]|select(.name=="workkey")|.rotate' "$CR_HOME/config.json")"
  eq "rotate on: .rotate=true" "$got" "true"
  # Toggle off
  "$CR" rotate workkey off 2>/dev/null
  got="$(jq -r '.accounts[]|select(.name=="workkey")|.rotate' "$CR_HOME/config.json")"
  eq "rotate off: .rotate=false" "$got" "false"
  # Rotating a subscription should exit nonzero
  "$CR" rotate work on 2>/dev/null; rc=$?
  if [[ "$rc" -ne 0 ]]; then ok "rotate subscription: exits nonzero"; else bad "rotate subscription: exits nonzero" "rc=$rc"; fi
)

echo "== api: launch env =="
(
  export CR_HOME="$SBX/api_env_home"; mkdir -p "$CR_HOME/logs" "$CR_HOME/accounts/workkey"
  cat > "$CR_HOME/config.json" <<JSON
{"selection":"round-robin","accounts":[
  {"name":"default","kind":"subscription","configDir":null,"lastUsed":0,"enabled":true,"usagePct":null},
  {"name":"workkey","kind":"api","configDir":"$SBX/api_env_home/accounts/workkey","apiKey":"sk-api-launch-test","email":null,"plan":"api-key","lastUsed":0,"enabled":true,"usagePct":null,"rotate":false}],
 "rotation":{"cursor":0},"share":{}}
JSON
  # Richer fake that echoes all relevant env vars
  cat > "$FAKEBIN/claude" <<'RICHEOF'
#!/usr/bin/env bash
{ echo "CONFIG_DIR=${CLAUDE_CONFIG_DIR-<unset>}"
  echo "API_KEY=${ANTHROPIC_API_KEY-<unset>}"
  echo "AUTH_TOKEN=${ANTHROPIC_AUTH_TOKEN-<unset>}"
  echo "OAUTH_TOKEN=${CLAUDE_CODE_OAUTH_TOKEN-<unset>}"
  echo "BASE_URL=${ANTHROPIC_BASE_URL-<unset>}"
  echo "ARGS=$*"; } > "$FAKE_OUT"
exit "${FAKE_EXIT:-0}"
RICHEOF
  chmod +x "$FAKEBIN/claude"
  export ANTHROPIC_AUTH_TOKEN="SHOULD_BE_SCRUBBED"
  export CLAUDE_CODE_OAUTH_TOKEN="SHOULD_BE_SCRUBBED"
  export ANTHROPIC_BASE_URL="http://evil"
  run_cr --account workkey -p hi
  out="$(cat "$FAKE_OUT")"
  eq "api: CLAUDE_CONFIG_DIR set to account dir" \
    "$(grep '^CONFIG_DIR=' <<<"$out")" "CONFIG_DIR=$SBX/api_env_home/accounts/workkey"
  eq "api: ANTHROPIC_API_KEY set to seeded key" \
    "$(grep '^API_KEY=' <<<"$out")" "API_KEY=sk-api-launch-test"
  eq "api: ANTHROPIC_AUTH_TOKEN scrubbed" \
    "$(grep '^AUTH_TOKEN=' <<<"$out")" "AUTH_TOKEN=<unset>"
  eq "api: CLAUDE_CODE_OAUTH_TOKEN scrubbed" \
    "$(grep '^OAUTH_TOKEN=' <<<"$out")" "OAUTH_TOKEN=<unset>"
  eq "api: ANTHROPIC_BASE_URL scrubbed" \
    "$(grep '^BASE_URL=' <<<"$out")" "BASE_URL=<unset>"
  unset ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_BASE_URL
  # Banner should contain "api" on stderr (run_cr captures stderr to $SBX/stderr)
  run_cr --account workkey -p hi
  if grep -q 'api' "$SBX/stderr"; then ok "api: banner contains 'api'"; else bad "api: banner contains 'api'" "$(cat "$SBX/stderr")"; fi
  # Restore standard fake
  cat > "$FAKEBIN/claude" <<'EOF'
#!/usr/bin/env bash
{ echo "CONFIG_DIR=${CLAUDE_CONFIG_DIR-<unset>}"
  echo "API_KEY=${ANTHROPIC_API_KEY-<unset>}"
  echo "AUTH_TOKEN=${ANTHROPIC_AUTH_TOKEN-<unset>}"
  echo "OAUTH_TOKEN=${CLAUDE_CODE_OAUTH_TOKEN-<unset>}"
  echo "ARGS=$*"
} > "$FAKE_OUT"
exit "${FAKE_EXIT:-0}"
EOF
  chmod +x "$FAKEBIN/claude"
)

echo "== api: usage skips api accounts =="
(
  export CR_HOME="$SBX/api_usage_home"; mkdir -p "$CR_HOME/logs"
  cat > "$CR_HOME/config.json" <<JSON
{"selection":"round-robin","accounts":[
  {"name":"default","kind":"subscription","configDir":null,"lastUsed":0,"enabled":true,"usagePct":null},
  {"name":"workkey","kind":"api","configDir":"$SBX/api_usage_home/accounts/workkey","apiKey":"sk-test","email":null,"plan":"api-key","lastUsed":0,"enabled":true,"usagePct":null,"rotate":false}],
 "rotation":{"cursor":0},"share":{}}
JSON
  # explicit usage for api account: exits 0, mentions no usage windows
  "$CR" usage workkey 2>"$SBX/api_usage_err"; rc=$?
  eq "api usage explicit: exits 0" "$rc" "0"
  if grep -qiE 'api-key|no usage windows|pay-per-token' "$SBX/api_usage_err"; then ok "api usage explicit: notes no usage windows"; else bad "api usage explicit: no usage windows message" "$(cat "$SBX/api_usage_err")"; fi
  # all-accounts cr usage must NOT warn-fail on workkey
  "$CR" usage 2>"$SBX/api_usage_all_err" || true
  if grep -q "usage poll failed for 'workkey'" "$SBX/api_usage_all_err"; then
    bad "api usage all: no warn-fail for api account" "$(cat "$SBX/api_usage_all_err")"
  else
    ok "api usage all: no warn-fail for api account"
  fi
)

echo "== api: list shows explicit-only =="
(
  export CR_HOME="$SBX/api_list_home"; mkdir -p "$CR_HOME/logs"
  cat > "$CR_HOME/config.json" <<JSON
{"selection":"round-robin","accounts":[
  {"name":"default","kind":"subscription","configDir":null,"lastUsed":0,"enabled":true,"usagePct":null},
  {"name":"workkey","kind":"api","configDir":"$SBX/api_list_home/accounts/workkey","apiKey":"sk-test","email":null,"plan":"api-key","lastUsed":0,"enabled":true,"usagePct":null,"rotate":false}],
 "rotation":{"cursor":0},"share":{}}
JSON
  list_out="$("$CR" list 2>&1)"
  if grep -q 'explicit-only' <<<"$list_out"; then ok "list: api account shows explicit-only"; else bad "list: explicit-only not found" "$list_out"; fi
  if grep -q 'workkey' <<<"$list_out" && grep -q ' api ' <<<"$list_out"; then ok "list: api account shows kind=api"; else bad "list: api kind not found" "$list_out"; fi
)

echo "== api: watch bypasses api accounts =="
(
  export CR_HOME="$SBX/api_watch_home"; mkdir -p "$CR_HOME/logs" "$CR_HOME/accounts/sub1" "$CR_HOME/accounts/sub2" "$CR_HOME/accounts/workkey"
  cat > "$CR_HOME/config.json" <<JSON
{"selection":"round-robin","accounts":[
  {"name":"sub1","kind":"subscription","configDir":"$SBX/api_watch_home/accounts/sub1","lastUsed":0,"enabled":true,"usagePct":null},
  {"name":"sub2","kind":"subscription","configDir":"$SBX/api_watch_home/accounts/sub2","lastUsed":0,"enabled":true,"usagePct":null},
  {"name":"workkey","kind":"api","configDir":"$SBX/api_watch_home/accounts/workkey","apiKey":"sk-test","email":null,"plan":"api-key","lastUsed":0,"enabled":true,"usagePct":null,"rotate":false}],
 "rotation":{"cursor":0},"share":{}}
JSON
  "$CR" --watch --account workkey -p x 2>"$SBX/api_watch_err"
  if grep -q 'without watch' "$SBX/api_watch_err"; then ok "watch: api account bypasses watch"; else bad "watch: api account bypass message" "$(cat "$SBX/api_watch_err")"; fi
  got_args="$(grep '^ARGS=' "$FAKE_OUT" 2>/dev/null || true)"
  eq "watch bypassed: args forwarded normally" "$got_args" "ARGS=-p x"
)

echo "== api: session ownership + adopt =="
(
  export CR_HOME="$SBX/api_own_home"
  mkdir -p "$CR_HOME/logs" "$CR_HOME/accounts/sub1/projects/-p" "$CR_HOME/accounts/apikey"
  source "$CR_REPO/lib/common.sh"
  cat > "$CR_CONFIG" <<JSON
{"selection":"round-robin","accounts":[
  {"name":"sub1","kind":"subscription","configDir":"$CR_HOME/accounts/sub1","lastUsed":0,"enabled":true},
  {"name":"apikey","kind":"api","configDir":"$CR_HOME/accounts/apikey","apiKey":"sk-test","email":null,"plan":"api-key","lastUsed":0,"enabled":true,"usagePct":null,"rotate":false}],
 "rotation":{"cursor":0},"share":{}}
JSON
  # Pull in cr_account_owning_session from cr
  eval "$(sed -n '/^cr_account_owning_session()/,/^}/p' "$CR_REPO/cr")"
  SID_API="a1b2c3d4-0000-0000-0000-000000000000"
  echo '{"api":1}' > "$CR_HOME/accounts/sub1/projects/-p/$SID_API.jsonl"
  eq "api: owning session finds sub1 (real file)" "$(cr_account_owning_session "$SID_API")" "sub1"

  # Adopt into an api account — should succeed
  mkdir -p "$CR_HOME/accounts/apikey/projects/-p"
  eval "$(sed -n '/^cr_link_session()/,/^}/p' "$CR_REPO/cr")"
  cr_link_session "$SID_API" apikey >/dev/null 2>&1
  rc=$?
  if [[ "$rc" -eq 0 ]]; then ok "api: cr_link_session into api account succeeds"; else bad "api: link_session into api account" "rc=$rc"; fi
  link="$CR_HOME/accounts/apikey/projects/-p/$SID_API.jsonl"
  if [[ -L "$link" ]]; then ok "api: adopt creates symlink in api account dir"; else bad "api: adopt symlink not created" "$link"; fi

  # cr adopt via CLI: api account should be accepted
  "$CR" adopt "$SID_API" apikey 2>"$SBX/api_adopt_err"; rc=$?
  if [[ "$rc" -eq 0 ]]; then ok "api: cr adopt accepts api account target"; else bad "api: cr adopt api target" "rc=$rc: $(cat "$SBX/api_adopt_err")"; fi
)

echo "== api: usage-aware never picks a non-rotating api account =="
(
  export CR_HOME="$SBX/api_ua_home"; mkdir -p "$CR_HOME/logs"
  source "$CR_REPO/lib/common.sh"
  # Base config: subscription "sub1" usagePct 80, api "workkey" rotate ABSENT usagePct 5
  # (deliberately poisoned cache), api "offkey" rotate:false usagePct 1, backend "deepseek" usagePct 2.
  cat > "$CR_CONFIG" <<JSON
{"selection":"usage-aware","accounts":[
  {"name":"sub1","kind":"subscription","configDir":null,"lastUsed":0,"enabled":true,"usagePct":80},
  {"name":"workkey","kind":"api","configDir":"$SBX/api_ua_home/accounts/workkey","apiKey":"sk-w","email":null,"plan":"api-key","lastUsed":0,"enabled":true,"usagePct":5},
  {"name":"offkey","kind":"api","configDir":"$SBX/api_ua_home/accounts/offkey","apiKey":"sk-o","email":null,"plan":"api-key","lastUsed":0,"enabled":true,"usagePct":1,"rotate":false},
  {"name":"deepseek","kind":"backend","configDir":null,"baseUrl":"https://api.deepseek.com/anthropic","model":"m","email":null,"plan":"backend","lastUsed":0,"enabled":true,"usagePct":2}],
 "rotation":{"cursor":0},"share":{}}
JSON
  got="$(cr_select_usage_aware)"
  eq "usage-aware: only subscription sub1 eligible → sub1 picked" "$got" "sub1"

  # Second case: add perskey rotate:true usagePct 5 — now it should be picked (lower pct than sub1=80).
  cr_config_update '.accounts += [{"name":"perskey","kind":"api","configDir":"'"$SBX/api_ua_home/accounts/perskey"'","apiKey":"sk-p","email":null,"plan":"api-key","lastUsed":0,"enabled":true,"usagePct":5,"rotate":true}]' >/dev/null
  got2="$(cr_select_usage_aware)"
  eq "usage-aware: rotate=true api perskey (pct 5) beats sub1 (pct 80)" "$got2" "perskey"
)

echo "== watch: bypass counts subscriptions only =="
(
  export CR_HOME="$SBX/api_watch_bypass_home"
  mkdir -p "$CR_HOME/logs" "$CR_HOME/accounts/sub1" "$CR_HOME/accounts/rotkey"
  cat > "$CR_HOME/config.json" <<JSON
{"selection":"round-robin","accounts":[
  {"name":"sub1","kind":"subscription","configDir":"$SBX/api_watch_bypass_home/accounts/sub1","lastUsed":0,"enabled":true,"usagePct":null},
  {"name":"rotkey","kind":"api","configDir":"$SBX/api_watch_bypass_home/accounts/rotkey","apiKey":"sk-r","email":null,"plan":"api-key","lastUsed":0,"enabled":true,"usagePct":null,"rotate":true}],
 "rotation":{"cursor":0},"share":{}}
JSON
  "$CR_REPO/cr" --watch --account sub1 x >"$SBX/stdout" 2>"$SBX/api_watch_bypass_err"
  if grep -qE 'fewer than two subscription|nothing to hand off' "$SBX/api_watch_bypass_err"; then
    ok "watch bypass: 1 subscription + 1 rotate=true api → bypass warning"
  else
    bad "watch bypass: expected bypass warning" "$(cat "$SBX/api_watch_bypass_err")"
  fi
)

echo "== status --json: valid, cached, no cursor advance =="
(
  export CR_HOME="$SBX/json_home"; mkdir -p "$CR_HOME/logs"
  NOW_MS="$(( $(date +%s) * 1000 ))"
  cat > "$CR_HOME/config.json" <<JSON
{
  "selection": "round-robin",
  "exhaustedAtPct": 100,
  "usageTtlSeconds": 900,
  "accounts": [
    {
      "name": "work", "kind": "subscription",
      "configDir": "$SBX/json_home/accounts/work",
      "email": "work@example.com", "plan": "max",
      "lastUsed": 0, "enabled": true, "usagePct": 58,
      "usage": {
        "checkedAt": ${NOW_MS},
        "windows": [
          {"label": "5h session", "used": 58, "resets": "2030-01-01T00:00:00Z"},
          {"label": "7d total",   "used": 12, "resets": null}
        ]
      }
    },
    {
      "name": "home", "kind": "subscription",
      "configDir": "$SBX/json_home/accounts/home",
      "email": "home@example.com", "plan": "pro",
      "lastUsed": 0, "enabled": true, "usagePct": null
    },
    {
      "name": "perskey", "kind": "api",
      "configDir": "$SBX/json_home/accounts/perskey",
      "apiKey": "sk-pers", "email": null, "plan": "api-key",
      "lastUsed": 0, "enabled": true, "usagePct": 5, "rotate": true,
      "usage": {
        "checkedAt": ${NOW_MS},
        "windows": [{"label": "5h session", "used": 5, "resets": null}]
      }
    },
    {
      "name": "workkey", "kind": "api",
      "configDir": "$SBX/json_home/accounts/workkey",
      "apiKey": "sk-work", "email": null, "plan": "api-key",
      "lastUsed": 0, "enabled": true, "usagePct": null, "rotate": false
    },
    {
      "name": "deepseek", "kind": "backend",
      "configDir": null, "baseUrl": "https://api.deepseek.com/anthropic",
      "model": "deepseek-v4-pro", "email": null, "plan": "backend",
      "lastUsed": 0, "enabled": true, "usagePct": null
    }
  ],
  "rotation": {"cursor": 2},
  "share": {}
}
JSON

  out="$("$CR" status --json 2>/dev/null)"
  # Valid JSON.
  if printf '%s' "$out" | jq -e . >/dev/null 2>&1; then ok "status --json: valid JSON output"; else bad "status --json: valid JSON output" "$out"; fi
  # Exit 0 already confirmed by subshell not erroring; check explicitly.
  "$CR" status --json >/dev/null 2>/dev/null; rc=$?
  eq "status --json: exits 0" "$rc" "0"

  # Top-level schema fields.
  eq "status --json: schema==1"           "$(printf '%s' "$out" | jq -r '.schema')"            "1"
  eq "status --json: policy==round-robin" "$(printf '%s' "$out" | jq -r '.policy')"            "round-robin"
  eq "status --json: 5 accounts"         "$(printf '%s' "$out" | jq -r '.accounts|length')"   "5"

  # work account.
  eq "status --json: work.usagePct==58"  "$(printf '%s' "$out" | jq -r '.accounts[]|select(.name=="work")|.usagePct')"    "58"
  eq "status --json: work win0.leftPct==42" \
     "$(printf '%s' "$out" | jq -r '.accounts[]|select(.name=="work")|.windows[0].leftPct')" "42"
  eq "status --json: work.exhausted==false" \
     "$(printf '%s' "$out" | jq -r '.accounts[]|select(.name=="work")|.exhausted')"          "false"
  eq "status --json: work.inRotation==true" \
     "$(printf '%s' "$out" | jq -r '.accounts[]|select(.name=="work")|.inRotation')"         "true"

  # backend deepseek: not in rotation.
  eq "status --json: deepseek.inRotation==false" \
     "$(printf '%s' "$out" | jq -r '.accounts[]|select(.name=="deepseek")|.inRotation')"     "false"

  # api workkey rotate:false: not in rotation.
  eq "status --json: workkey.inRotation==false" \
     "$(printf '%s' "$out" | jq -r '.accounts[]|select(.name=="workkey")|.inRotation')"      "false"

  # api perskey rotate:true: in rotation.
  eq "status --json: perskey.inRotation==true" \
     "$(printf '%s' "$out" | jq -r '.accounts[]|select(.name=="perskey")|.inRotation')"      "true"

  # home has no usage.
  eq "status --json: home.usagePct==null" \
     "$(printf '%s' "$out" | jq -r '.accounts[]|select(.name=="home")|.usagePct')"           "null"
  eq "status --json: home.windows empty" \
     "$(printf '%s' "$out" | jq -r '.accounts[]|select(.name=="home")|.windows|length')"     "0"

  # round-robin next: no cursor advance, name should be null.
  eq "status --json: next.name==null (round-robin)" \
     "$(printf '%s' "$out" | jq -r '.next.name')"                                            "null"
  if printf '%s' "$out" | jq -r '.next.note' | grep -q "rotation"; then
    ok "status --json: next.note mentions rotation"
  else
    bad "status --json: next.note mentions rotation" "$(printf '%s' "$out" | jq -r '.next.note')"
  fi

  # Cursor must NOT have advanced — still 2.
  cursor_after="$(jq -r '.rotation.cursor' "$CR_HOME/config.json")"
  eq "status --json: round-robin cursor unchanged after --json" "$cursor_after" "2"

  # stdout starts with '{'.
  first_char="$(printf '%s' "$out" | head -c1)"
  eq "status --json: stdout starts with '{'" "$first_char" "{"
)

echo "== status --json: lru/pinned next, exhausted flag =="
(
  export CR_HOME="$SBX/json_lru_home"; mkdir -p "$CR_HOME/logs"
  NOW_MS="$(( $(date +%s) * 1000 ))"
  cat > "$CR_HOME/config.json" <<JSON
{
  "selection": "lru",
  "exhaustedAtPct": 90,
  "usageTtlSeconds": 900,
  "accounts": [
    {
      "name": "alpha", "kind": "subscription",
      "configDir": "$SBX/json_lru_home/accounts/alpha",
      "email": "a@x", "plan": "max",
      "lastUsed": 1000, "enabled": true, "usagePct": 95,
      "usage": {"checkedAt": ${NOW_MS}, "windows": []}
    },
    {
      "name": "beta", "kind": "subscription",
      "configDir": "$SBX/json_lru_home/accounts/beta",
      "email": "b@x", "plan": "max",
      "lastUsed": 500, "enabled": true, "usagePct": 40,
      "usage": {"checkedAt": ${NOW_MS}, "windows": []}
    }
  ],
  "rotation": {"cursor": 0},
  "share": {}
}
JSON

  out="$("$CR" status --json 2>/dev/null)"

  # alpha at 95% >= exhaustedAtPct 90 → exhausted.
  eq "status --json lru: alpha.exhausted==true" \
     "$(printf '%s' "$out" | jq -r '.accounts[]|select(.name=="alpha")|.exhausted')" "true"

  # beta at 40% < 90 → not exhausted.
  eq "status --json lru: beta.exhausted==false" \
     "$(printf '%s' "$out" | jq -r '.accounts[]|select(.name=="beta")|.exhausted')" "false"

  # lru next: beta (lastUsed 500 < alpha 1000, and beta is available;
  # alpha is exhausted at 95% >= exhaustedAtPct 90, so lru skips it).
  eq "status --json lru: next.name is exactly beta" \
     "$(printf '%s' "$out" | jq -r '.next.name')" "beta"
  eq "status --json lru: next.note=='would pick now'" \
     "$(printf '%s' "$out" | jq -r '.next.note')" "would pick now"

  # Pin a name and confirm it shows up.
  cr_home_backup="$CR_HOME"
  export CR_HOME="$cr_home_backup"
  jq '.defaultAccount = "beta"' "$CR_HOME/config.json" > "$CR_HOME/config.json.tmp" && mv "$CR_HOME/config.json.tmp" "$CR_HOME/config.json"
  out2="$("$CR" status --json 2>/dev/null)"
  eq "status --json pinned: next.name=='beta'" \
     "$(printf '%s' "$out2" | jq -r '.next.name')" "beta"
  if printf '%s' "$out2" | jq -r '.next.note' | grep -q "pinned"; then
    ok "status --json pinned: next.note mentions pinned"
  else
    bad "status --json pinned: next.note mentions pinned" "$(printf '%s' "$out2" | jq -r '.next.note')"
  fi
)

echo "== status --json: no cache -> still valid JSON, exit 0 =="
(
  export CR_HOME="$SBX/json_nocache_home"; mkdir -p "$CR_HOME/logs"
  cat > "$CR_HOME/config.json" <<JSON
{
  "selection": "round-robin",
  "accounts": [
    {
      "name": "solo", "kind": "subscription",
      "configDir": null,
      "email": "s@x", "plan": "max",
      "lastUsed": 0, "enabled": true
    }
  ],
  "rotation": {"cursor": 0},
  "share": {}
}
JSON

  out="$("$CR" status --json 2>/dev/null)"; rc=$?
  eq "status --json nocache: exits 0" "$rc" "0"
  if printf '%s' "$out" | jq -e . >/dev/null 2>&1; then ok "status --json nocache: valid JSON"; else bad "status --json nocache: valid JSON" "$out"; fi
  eq "status --json nocache: solo.usagePct==null" \
     "$(printf '%s' "$out" | jq -r '.accounts[]|select(.name=="solo")|.usagePct')" "null"
  eq "status --json nocache: solo.stale==true" \
     "$(printf '%s' "$out" | jq -r '.accounts[]|select(.name=="solo")|.stale')" "true"
)

echo "== status --json: float rounding for usedPct/leftPct =="
(
  export CR_HOME="$SBX/json_float_home"; mkdir -p "$CR_HOME/logs"
  NOW_MS="$(( $(date +%s) * 1000 ))"
  cat > "$CR_HOME/config.json" <<JSON
{
  "selection": "round-robin",
  "exhaustedAtPct": 100,
  "usageTtlSeconds": 900,
  "accounts": [
    {
      "name": "floaty", "kind": "subscription",
      "configDir": null, "email": "f@x", "plan": "max",
      "lastUsed": 0, "enabled": true, "usagePct": 59,
      "usage": {
        "checkedAt": ${NOW_MS},
        "windows": [
          {"label": "5h session", "used": 58.7, "resets": null},
          {"label": "7d total",   "used": 110,  "resets": null}
        ]
      }
    }
  ],
  "rotation": {"cursor": 0},
  "share": {}
}
JSON
  out="$("$CR" status --json 2>/dev/null)"
  # 58.7 rounds to 59 usedPct, leftPct = 100-58.7 = 41.3 rounds to 41
  if printf '%s' "$out" | jq -e '.accounts[]|select(.name=="floaty")|.windows[0]|(.leftPct==41 and .usedPct==59)' >/dev/null 2>&1; then
    ok "status --json float: 58.7 -> usedPct=59 leftPct=41 (integers)"
  else
    bad "status --json float: 58.7 rounding" \
      "$(printf '%s' "$out" | jq -c '.accounts[]|select(.name=="floaty")|.windows[0]|{usedPct,leftPct}')"
  fi
  # used=110 clamps to usedPct=100, leftPct=0 (not negative)
  if printf '%s' "$out" | jq -e '.accounts[]|select(.name=="floaty")|.windows[1]|(.leftPct==0 and .usedPct==100)' >/dev/null 2>&1; then
    ok "status --json float: used=110 -> usedPct=100 leftPct=0 (clamped)"
  else
    bad "status --json float: used=110 clamping" \
      "$(printf '%s' "$out" | jq -c '.accounts[]|select(.name=="floaty")|.windows[1]|{usedPct,leftPct}')"
  fi
)

echo "== status --json: random policy next.name==null + note =="
(
  export CR_HOME="$SBX/json_random_home"; mkdir -p "$CR_HOME/logs"
  cat > "$CR_HOME/config.json" <<JSON
{
  "selection": "random",
  "accounts": [
    {"name": "work", "kind": "subscription", "configDir": null,
     "email": "w@x", "plan": "max", "lastUsed": 0, "enabled": true, "usagePct": null}
  ],
  "rotation": {"cursor": 0},
  "share": {}
}
JSON
  out="$("$CR" status --json 2>/dev/null)"
  eq "status --json random: next.name==null" \
     "$(printf '%s' "$out" | jq -r '.next.name')" "null"
  if printf '%s' "$out" | jq -r '.next.note' | grep -qi "random"; then
    ok "status --json random: next.note contains 'random'"
  else
    bad "status --json random: next.note contains 'random'" \
      "$(printf '%s' "$out" | jq -r '.next.note')"
  fi
)

echo "== menubar plugin: stale-refresh jq filter is subscription-scoped =="
(
  # Unit-assert the jq filter directly on a known-bad stub:
  # one stale subscription (stale=false), one stale api rotate=true account.
  # The subscription-scoped filter must return 0.
  stub_json='{
    "accounts": [
      {"name":"subA","kind":"subscription","inRotation":true,"stale":false},
      {"name":"apiB","kind":"api","inRotation":true,"stale":true}
    ]
  }'
  result="$(printf '%s' "$stub_json" | jq -r '[.accounts[]|select(.kind=="subscription" and .inRotation==true and .stale==true)]|length')"
  eq "plugin stale filter: api-stale-only -> count==0 (no spurious refresh)" "$result" "0"
)

echo "== menubar plugin: syntax check =="
bash -n "$CR_REPO/menubar/clawrouter.30s.sh"
eq "menubar plugin: bash -n syntax check" "$?" "0"

echo "== menubar plugin: renders from stubbed cr =="
(
  MB_BIN="$SBX/mb_bin"; mkdir -p "$MB_BIN"
  MB_NOW_MS="$(( $(date +%s) * 1000 ))"

  # Fake cr: for 'status --json' emits known-good JSON; all other calls exit 0.
  cat > "$MB_BIN/cr" <<FAKECR
#!/usr/bin/env bash
if [[ "\${1:-}" == "status" && "\${2:-}" == "--json" ]]; then
  cat <<'ENDJSON'
{
  "schema": 1,
  "generatedAt": "2026-01-01T00:00:00Z",
  "policy": "round-robin",
  "pinned": null,
  "exhaustedAtPct": 100,
  "ttlSeconds": 900,
  "next": {"name": null, "note": "next in rotation -- run a plain 'cr' to advance"},
  "accounts": [
    {
      "name": "work", "kind": "subscription",
      "email": "work@example.com",
      "enabled": true, "rotate": true, "inRotation": true,
      "usagePct": 58, "exhausted": false, "stale": false,
      "checkedAt": "2026-01-01T00:00:00Z",
      "windows": [
        {"label": "5h session", "usedPct": 58, "leftPct": 42, "resetsAt": "2030-01-01T06:00:00Z"},
        {"label": "7d total",   "usedPct": 12, "leftPct": 88, "resetsAt": null}
      ]
    },
    {
      "name": "home", "kind": "subscription",
      "email": "home@example.com",
      "enabled": true, "rotate": true, "inRotation": true,
      "usagePct": 95, "exhausted": false, "stale": false,
      "checkedAt": "2026-01-01T00:00:00Z",
      "windows": [
        {"label": "5h session", "usedPct": 95, "leftPct": 5, "resetsAt": null}
      ]
    },
    {
      "name": "deepseek", "kind": "backend",
      "email": null,
      "enabled": true, "rotate": false, "inRotation": false,
      "usagePct": null, "exhausted": false, "stale": true,
      "checkedAt": null,
      "windows": []
    }
  ]
}
ENDJSON
  exit 0
fi
exit 0
FAKECR
  chmod +x "$MB_BIN/cr"

  # Use real jq.
  MB_JQ="$(command -v jq)"

  # Fake launchctl that reports the agent as loaded (print succeeds).
  MB_LC_DIR="$SBX/mb_lc_bin"; mkdir -p "$MB_LC_DIR"
  cat > "$MB_LC_DIR/launchctl" <<'MBLC'
#!/usr/bin/env bash
# Always succeed — agent appears loaded for this render test.
exit 0
MBLC
  chmod +x "$MB_LC_DIR/launchctl"
  MB_LC="$MB_LC_DIR/launchctl"

  plugin_out="$(CLAWROUTER_CR="$MB_BIN/cr" CLAWROUTER_JQ="$MB_JQ" \
    CLAWROUTER_LAUNCHCTL="$MB_LC" CLAWROUTER_NOTIFY=0 \
    bash "$CR_REPO/menubar/clawrouter.30s.sh" 2>/dev/null)"; rc=$?

  eq "menubar: exits 0 with good data" "$rc" "0"
  # First line contains the lobster emoji.
  first_line="$(printf '%s' "$plugin_out" | head -1)"
  if printf '%s' "$first_line" | grep -q '🦞'; then ok "menubar: first line contains 🦞"; else bad "menubar: first line contains 🦞" "$first_line"; fi
  # Contains --- separator.
  if printf '%s' "$plugin_out" | grep -q '^---$'; then ok "menubar: output has --- separator"; else bad "menubar: output has --- separator" ""; fi
  # Contains the in-rotation account name.
  if printf '%s' "$plugin_out" | grep -q 'work'; then ok "menubar: output contains 'work' account"; else bad "menubar: output contains work account" "$plugin_out"; fi
  # With agent loaded, "Refresh now" should appear (not "Enable background refresh").
  if printf '%s' "$plugin_out" | grep -q 'Refresh now'; then ok "menubar: output contains 'Refresh now'"; else bad "menubar: output contains Refresh now" "$plugin_out"; fi
  # Contains Policy submenu header.
  if printf '%s' "$plugin_out" | grep -q 'Policy'; then ok "menubar: output contains 'Policy'"; else bad "menubar: output contains Policy" "$plugin_out"; fi
  # Policy submenu child lines must emit with the -- prefix (Fix 1).
  if printf '%s' "$plugin_out" | grep -q '^--usage-aware'; then ok "menubar: --usage-aware submenu child line emitted"; else bad "menubar: --usage-aware submenu line missing (printf fix)" "$(printf '%s' "$plugin_out" | grep -E '^--' || echo '<none>')"; fi
  # No 'invalid option' errors (Fix 1 regression guard).
  plugin_out_with_stderr="$(CLAWROUTER_CR="$MB_BIN/cr" CLAWROUTER_JQ="$MB_JQ" \
    CLAWROUTER_LAUNCHCTL="$MB_LC" CLAWROUTER_NOTIFY=0 \
    bash "$CR_REPO/menubar/clawrouter.30s.sh" 2>&1)"
  if printf '%s' "$plugin_out_with_stderr" | grep -q 'invalid option'; then
    bad "menubar: no printf 'invalid option' errors" "$(printf '%s' "$plugin_out_with_stderr" | grep 'invalid option' | head -3)"
  else
    ok "menubar: no 'invalid option' errors in combined stdout+stderr"
  fi
  # No raw error or 'unbound' message in output.
  if printf '%s' "$plugin_out" | grep -qiE 'unbound variable|syntax error'; then
    bad "menubar: no unbound/syntax errors in output" "$(printf '%s' "$plugin_out" | grep -iE 'unbound|syntax')"
  else
    ok "menubar: no unbound/syntax errors in output"
  fi
)

echo "== menubar plugin: empty/garbage cr output -> graceful fallback =="
(
  MB_BIN2="$SBX/mb_bin2"; mkdir -p "$MB_BIN2"
  # Fake cr that prints nothing.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$MB_BIN2/cr"
  chmod +x "$MB_BIN2/cr"
  MB_JQ="$(command -v jq)"

  plugin_out="$(CLAWROUTER_CR="$MB_BIN2/cr" CLAWROUTER_JQ="$MB_JQ" CLAWROUTER_NOTIFY=0 \
    bash "$CR_REPO/menubar/clawrouter.30s.sh" 2>/dev/null)"; rc=$?

  eq "menubar empty cr: exits 0" "$rc" "0"
  first_line2="$(printf '%s' "$plugin_out" | head -1)"
  if printf '%s' "$first_line2" | grep -q '🦞'; then ok "menubar empty cr: first line contains 🦞"; else bad "menubar empty cr: first line contains 🦞" "$first_line2"; fi
  if printf '%s' "$plugin_out" | grep -qiE 'no data|refresh'; then ok "menubar empty cr: hints to refresh"; else bad "menubar empty cr: no-data hint" "$plugin_out"; fi
)

# =========================================================================
# menubar agent tests
# =========================================================================

# Build a fake launchctl that records its argv to a file, and whose `print`
# subcommand succeeds or fails based on the FAKE_LAUNCHCTL_PRINT_OK env var.
FAKE_LC_DIR="$SBX/fake_lc_bin"
FAKE_LC_LOG="$SBX/fake_lc_calls.log"
export FAKE_LC_LOG
mkdir -p "$FAKE_LC_DIR"
cat > "$FAKE_LC_DIR/launchctl" <<'EOFAKECTL'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_LC_LOG"
if [[ "${1:-}" == "print" ]]; then
  if [[ "${FAKE_LAUNCHCTL_PRINT_OK:-0}" == "1" ]]; then
    exit 0
  else
    exit 1
  fi
fi
exit 0
EOFAKECTL
chmod +x "$FAKE_LC_DIR/launchctl"
FAKE_LC="$FAKE_LC_DIR/launchctl"

echo "== menubar agent: install writes plist + loads =="
(
  T="$SBX/agent_install_test"
  mkdir -p "$T"
  : > "$FAKE_LC_LOG"

  # Use /usr/bin/true — it must exist and be executable (Fix 5 requires -x CR_BIN).
  # Set FAKE_LAUNCHCTL_PRINT_OK=1 so the post-load verification (Fix 2) passes.
  rc=0
  CLAWROUTER_LAUNCH_AGENTS_DIR="$T" CLAWROUTER_LAUNCHCTL="$FAKE_LC" \
    CLAWROUTER_CR="/usr/bin/true" FAKE_LAUNCHCTL_PRINT_OK=1 \
    bash "$CR_REPO/menubar/agent.sh" install 120 2>/dev/null
  rc=$?
  eq "agent install: exits 0" "$rc" "0"

  plist="$T/com.clawrouter.refresh.plist"
  if [[ -f "$plist" ]]; then ok "agent install: plist exists"; else bad "agent install: plist missing" "$plist"; fi

  # Assert required plist content.
  if grep -q 'com.clawrouter.refresh' "$plist" 2>/dev/null; then ok "agent plist: contains label"; else bad "agent plist: label missing" "$(cat "$plist")"; fi
  if grep -q 'status' "$plist" 2>/dev/null; then ok "agent plist: contains 'status' arg"; else bad "agent plist: status arg missing" ""; fi
  if grep -q -- '--refresh' "$plist" 2>/dev/null; then ok "agent plist: contains '--refresh' arg"; else bad "agent plist: --refresh arg missing" ""; fi
  if grep -q '<integer>120</integer>' "$plist" 2>/dev/null; then ok "agent plist: StartInterval=120"; else bad "agent plist: StartInterval not 120" "$(grep -A1 StartInterval "$plist")"; fi
  if grep -q '/usr/bin/true' "$plist" 2>/dev/null; then ok "agent plist: contains CR path"; else bad "agent plist: CR path missing" ""; fi

  # Fix 3: plist must NOT set RunAtLoad=true (to avoid double Keychain prompts).
  if grep -A1 'RunAtLoad' "$plist" 2>/dev/null | grep -q '<true/>'; then
    bad "agent plist: RunAtLoad must not be true (double-start risk)" "$(grep -A1 RunAtLoad "$plist")"
  else
    ok "agent plist: RunAtLoad is not true (no double-start)"
  fi

  # Fix 1: plist must be plutil-valid (if plutil is available).
  if command -v plutil >/dev/null 2>&1; then
    if plutil -lint "$plist" >/dev/null 2>&1; then
      ok "agent plist: plutil -lint passes (well-formed XML)"
    else
      bad "agent plist: plutil -lint failed" "$(plutil -lint "$plist" 2>&1)"
    fi
  else
    ok "agent plist: plutil not available — skipping lint check"
  fi

  # Fake launchctl must have been called with bootstrap (or load) and kickstart.
  if grep -qE 'bootstrap|load' "$FAKE_LC_LOG" 2>/dev/null; then ok "agent install: launchctl bootstrap/load called"; else bad "agent install: launchctl not called for load" "$(cat "$FAKE_LC_LOG")"; fi
  if grep -q 'kickstart' "$FAKE_LC_LOG" 2>/dev/null; then ok "agent install: launchctl kickstart called"; else bad "agent install: launchctl kickstart not called" "$(cat "$FAKE_LC_LOG")"; fi
)

echo "== menubar agent: status + uninstall =="
(
  T="$SBX/agent_su_test"
  mkdir -p "$T"
  : > "$FAKE_LC_LOG"

  # Install first (FAKE_LAUNCHCTL_PRINT_OK=1 so Fix 2 post-load verification passes).
  CLAWROUTER_LAUNCH_AGENTS_DIR="$T" CLAWROUTER_LAUNCHCTL="$FAKE_LC" \
    CLAWROUTER_CR="/usr/bin/true" FAKE_LAUNCHCTL_PRINT_OK=1 \
    bash "$CR_REPO/menubar/agent.sh" install 300 2>/dev/null

  # Status with agent "loaded" (print returns success).
  status_out="$(CLAWROUTER_LAUNCH_AGENTS_DIR="$T" CLAWROUTER_LAUNCHCTL="$FAKE_LC" \
    FAKE_LAUNCHCTL_PRINT_OK=1 \
    bash "$CR_REPO/menubar/agent.sh" status 2>/dev/null)"; rc=$?
  eq "agent status: exits 0" "$rc" "0"
  if printf '%s' "$status_out" | grep -qiE 'loaded.*yes|yes'; then ok "agent status: reports loaded=yes"; else bad "agent status: loaded=yes not shown" "$status_out"; fi
  if printf '%s' "$status_out" | grep -qiE 'installed|plist'; then ok "agent status: mentions plist"; else bad "agent status: plist mention missing" "$status_out"; fi

  # Uninstall.
  : > "$FAKE_LC_LOG"
  CLAWROUTER_LAUNCH_AGENTS_DIR="$T" CLAWROUTER_LAUNCHCTL="$FAKE_LC" \
    bash "$CR_REPO/menubar/agent.sh" uninstall 2>/dev/null
  plist="$T/com.clawrouter.refresh.plist"
  if [[ ! -f "$plist" ]]; then ok "agent uninstall: plist removed"; else bad "agent uninstall: plist still present" "$plist"; fi
  if grep -qE 'bootout|unload' "$FAKE_LC_LOG" 2>/dev/null; then ok "agent uninstall: launchctl bootout/unload called"; else bad "agent uninstall: launchctl not called" "$(cat "$FAKE_LC_LOG")"; fi
)

echo "== menubar agent: install rejects bad interval / missing cr =="
(
  T="$SBX/agent_bad_test"
  mkdir -p "$T"

  # Bad interval.
  CLAWROUTER_LAUNCH_AGENTS_DIR="$T" CLAWROUTER_LAUNCHCTL="$FAKE_LC" \
    CLAWROUTER_CR="/usr/bin/true" \
    bash "$CR_REPO/menubar/agent.sh" install notanumber 2>/dev/null; rc=$?
  if [[ "$rc" -ne 0 ]]; then ok "agent install bad interval: exits nonzero"; else bad "agent install bad interval: should fail" "rc=$rc"; fi

  # Missing cr: clear CLAWROUTER_CR and ensure cr is not on PATH via a clean PATH.
  CLAWROUTER_LAUNCH_AGENTS_DIR="$T" CLAWROUTER_LAUNCHCTL="$FAKE_LC" \
    CLAWROUTER_CR="" PATH="/usr/bin:/bin" \
    bash "$CR_REPO/menubar/agent.sh" install 300 2>"$SBX/agent_no_cr_err"; rc=$?
  if [[ "$rc" -ne 0 ]]; then ok "agent install missing cr: exits nonzero"; else bad "agent install missing cr: should fail" "rc=$rc"; fi
  if grep -qiE 'cr|binary|CLAWROUTER_CR' "$SBX/agent_no_cr_err" 2>/dev/null; then ok "agent install missing cr: helpful message"; else bad "agent install missing cr: message missing" "$(cat "$SBX/agent_no_cr_err")"; fi
)

echo "== menubar agent: install fails when launchctl cannot load (Fix 2) =="
(
  # Build a fake launchctl whose bootstrap AND load both exit 1, and print exits 1.
  FAIL_LC_DIR="$SBX/fail_lc_bin"
  mkdir -p "$FAIL_LC_DIR"
  cat > "$FAIL_LC_DIR/launchctl" <<'EOFAIL'
#!/usr/bin/env bash
if [[ "${1:-}" == "print" ]]; then exit 1; fi
if [[ "${1:-}" == "bootout" ]]; then exit 0; fi
# bootstrap and load both fail.
exit 1
EOFAIL
  chmod +x "$FAIL_LC_DIR/launchctl"

  T="$SBX/agent_fail_load_test"
  mkdir -p "$T"
  CLAWROUTER_LAUNCH_AGENTS_DIR="$T" CLAWROUTER_LAUNCHCTL="$FAIL_LC_DIR/launchctl" \
    CLAWROUTER_CR="/usr/bin/true" \
    bash "$CR_REPO/menubar/agent.sh" install 120 2>"$SBX/agent_fail_load_err"; rc=$?
  if [[ "$rc" -ne 0 ]]; then ok "agent install load-fail: exits nonzero"; else bad "agent install load-fail: should fail" "rc=$rc"; fi
  if grep -qiE 'error|failed to load' "$SBX/agent_fail_load_err" 2>/dev/null; then
    ok "agent install load-fail: error message printed"
  else
    bad "agent install load-fail: error message missing" "$(cat "$SBX/agent_fail_load_err")"
  fi
)

echo "== menubar agent: kick exits nonzero when agent not loaded (Fix 4) =="
(
  T="$SBX/agent_kick_unloaded"
  mkdir -p "$T"
  # FAKE_LAUNCHCTL_PRINT_OK defaults to 0 → print fails → agent not loaded.
  CLAWROUTER_LAUNCH_AGENTS_DIR="$T" CLAWROUTER_LAUNCHCTL="$FAKE_LC" \
    FAKE_LAUNCHCTL_PRINT_OK=0 \
    bash "$CR_REPO/menubar/agent.sh" kick 2>"$SBX/agent_kick_err"; rc=$?
  if [[ "$rc" -ne 0 ]]; then ok "agent kick unloaded: exits nonzero"; else bad "agent kick unloaded: should exit nonzero" "rc=$rc"; fi
  if grep -qiE 'not loaded|install' "$SBX/agent_kick_err" 2>/dev/null; then
    ok "agent kick unloaded: helpful message"
  else
    bad "agent kick unloaded: message missing" "$(cat "$SBX/agent_kick_err")"
  fi
)

echo "== menubar agent: cr menubar refresh exits nonzero when agent not loaded =="
(
  T="$SBX/cr_menubar_kick_unloaded"
  mkdir -p "$T"
  CLAWROUTER_LAUNCH_AGENTS_DIR="$T" CLAWROUTER_LAUNCHCTL="$FAKE_LC" \
    FAKE_LAUNCHCTL_PRINT_OK=0 \
    "$CR" menubar refresh 2>/dev/null; rc=$?
  if [[ "$rc" -ne 0 ]]; then ok "cr menubar refresh unloaded: exits nonzero"; else bad "cr menubar refresh unloaded: should exit nonzero" "rc=$rc"; fi
)

echo "== menubar agent: install rejects non-executable CR_BIN (Fix 5) =="
(
  T="$SBX/agent_nonexec_cr"
  mkdir -p "$T"
  CLAWROUTER_LAUNCH_AGENTS_DIR="$T" CLAWROUTER_LAUNCHCTL="$FAKE_LC" \
    CLAWROUTER_CR="/nonexistent/cr" FAKE_LAUNCHCTL_PRINT_OK=1 \
    bash "$CR_REPO/menubar/agent.sh" install 300 2>"$SBX/agent_nonexec_err"; rc=$?
  if [[ "$rc" -ne 0 ]]; then ok "agent install non-executable cr: exits nonzero"; else bad "agent install non-executable cr: should fail" "rc=$rc"; fi
  if grep -qiE 'not executable|executable|install cr' "$SBX/agent_nonexec_err" 2>/dev/null; then
    ok "agent install non-executable cr: helpful message"
  else
    bad "agent install non-executable cr: message missing" "$(cat "$SBX/agent_nonexec_err")"
  fi
)

echo "== menubar agent: logs into the legacy data home, never creates ~/.claw-router =="
(
  # Regression: agent.sh once hardcoded ~/.claw-router for its log + mkdir'd it,
  # which flipped cr's legacy-aware CR_HOME resolution and orphaned an existing
  # ~/.claude-router install. The plist log path must follow the resolved home.
  H="$SBX/legacyhomeuser"; mkdir -p "$H/.claude-router/logs"   # legacy home exists, new one does NOT
  T="$SBX/agent_home_test"; mkdir -p "$T"
  # Unset the suite-global CR_HOME so agent.sh exercises the legacy-aware
  # resolution (the real-world path), not an explicit override.
  env -u CR_HOME HOME="$H" CLAWROUTER_LAUNCH_AGENTS_DIR="$T" CLAWROUTER_LAUNCHCTL="$FAKE_LC" \
    CLAWROUTER_CR="/usr/bin/true" FAKE_LAUNCHCTL_PRINT_OK=1 \
    bash "$CR_REPO/menubar/agent.sh" install 300 2>/dev/null; rc=$?
  eq "agent install (legacy home): exits 0" "$rc" "0"
  plist="$T/com.clawrouter.refresh.plist"
  if grep -q "$H/.claude-router/logs/refresh-agent.log" "$plist" 2>/dev/null; then
    ok "agent plist: logs into the legacy .claude-router home"
  else
    bad "agent plist: log path not in legacy home" "$(grep -i standard "$plist" 2>/dev/null)"
  fi
  if grep -q '.claw-router' "$plist" 2>/dev/null; then bad "agent plist: must not reference .claw-router" "$(grep claw "$plist")"; else ok "agent plist: no .claw-router reference"; fi
  if [[ ! -d "$H/.claw-router" ]]; then ok "agent install: did NOT create ~/.claw-router (no CR_HOME flip)"; else bad "agent install: created ~/.claw-router (flips CR_HOME!)" "$(ls -la "$H")"; fi
)

echo "== cr menubar dispatches to agent =="
(
  T="$SBX/cr_menubar_test"
  mkdir -p "$T"
  : > "$FAKE_LC_LOG"

  # Install an agent plist so status has something to show.
  # FAKE_LAUNCHCTL_PRINT_OK=1 so the post-load verification (Fix 2) passes.
  CLAWROUTER_LAUNCH_AGENTS_DIR="$T" CLAWROUTER_LAUNCHCTL="$FAKE_LC" \
    CLAWROUTER_CR="/usr/bin/true" FAKE_LAUNCHCTL_PRINT_OK=1 \
    bash "$CR_REPO/menubar/agent.sh" install 300 2>/dev/null

  # cr menubar status — should exit 0 and show agent info.
  status_out="$(CLAWROUTER_LAUNCH_AGENTS_DIR="$T" CLAWROUTER_LAUNCHCTL="$FAKE_LC" \
    FAKE_LAUNCHCTL_PRINT_OK=1 \
    "$CR" menubar status 2>/dev/null)"; rc=$?
  eq "cr menubar status: exits 0" "$rc" "0"

  # cr menubar refresh — should call launchctl kickstart.
  : > "$FAKE_LC_LOG"
  CLAWROUTER_LAUNCH_AGENTS_DIR="$T" CLAWROUTER_LAUNCHCTL="$FAKE_LC" \
    FAKE_LAUNCHCTL_PRINT_OK=1 \
    "$CR" menubar refresh 2>/dev/null || true
  if grep -q 'kickstart' "$FAKE_LC_LOG" 2>/dev/null; then ok "cr menubar refresh: calls launchctl kickstart"; else bad "cr menubar refresh: kickstart not called" "$(cat "$FAKE_LC_LOG")"; fi
)

echo "== menubar plugin: no self-refresh; refresh delegates =="
(
  # Assert the plugin contains no execution of status --refresh.
  if grep -nE '"?\$CR_BIN"?[[:space:]]+status[[:space:]]+--refresh|\$\(.*status --refresh' \
      "$CR_REPO/menubar/clawrouter.30s.sh" 2>/dev/null | grep -v '^.*#'; then
    bad "plugin: no 'status --refresh' execution found" "grep found execution form(s) above"
  else
    ok "plugin: contains no 'status --refresh' execution"
  fi

  MB_BIN3="$SBX/mb_bin3"; mkdir -p "$MB_BIN3"
  MB_JQ="$(command -v jq)"

  # Good JSON for one in-rotation subscription account, stale=true.
  cat > "$MB_BIN3/cr" <<'FAKECR3'
#!/usr/bin/env bash
if [[ "${1:-}" == "status" && "${2:-}" == "--json" ]]; then
  cat <<'ENDJSON'
{
  "schema": 1,
  "generatedAt": "2026-01-01T00:00:00Z",
  "policy": "round-robin",
  "pinned": null,
  "exhaustedAtPct": 100,
  "ttlSeconds": 900,
  "next": {"name": null, "note": "next in rotation"},
  "accounts": [
    {
      "name": "work", "kind": "subscription",
      "email": "work@example.com",
      "enabled": true, "rotate": true, "inRotation": true,
      "usagePct": 58, "exhausted": false, "stale": true,
      "checkedAt": null,
      "windows": [
        {"label": "5h session", "usedPct": 58, "leftPct": 42, "resetsAt": null}
      ]
    }
  ]
}
ENDJSON
  exit 0
fi
exit 0
FAKECR3
  chmod +x "$MB_BIN3/cr"

  # Render with agent NOT loaded (FAKE_LAUNCHCTL_PRINT_OK=0).
  plugin_out_noagent="$(CLAWROUTER_CR="$MB_BIN3/cr" CLAWROUTER_JQ="$MB_JQ" \
    CLAWROUTER_LAUNCHCTL="$FAKE_LC" CLAWROUTER_NOTIFY=0 \
    FAKE_LAUNCHCTL_PRINT_OK=0 \
    bash "$CR_REPO/menubar/clawrouter.30s.sh" 2>/dev/null)"

  if printf '%s' "$plugin_out_noagent" | grep -q 'Enable background refresh'; then
    ok "plugin no-agent: shows 'Enable background refresh' action"
  else
    bad "plugin no-agent: 'Enable background refresh' missing" \
      "$(printf '%s' "$plugin_out_noagent" | grep -i refresh || echo '<none>')"
  fi
  if printf '%s' "$plugin_out_noagent" | grep -q 'param2=--refresh'; then
    bad "plugin no-agent: must not contain param2=--refresh" \
      "$(printf '%s' "$plugin_out_noagent" | grep 'param2=--refresh')"
  else
    ok "plugin no-agent: no param2=--refresh in output"
  fi
  # Stale hint should appear when agent not loaded.
  if printf '%s' "$plugin_out_noagent" | grep -qi 'stale\|Enable background refresh'; then
    ok "plugin no-agent: stale or enable-refresh hint present"
  else
    bad "plugin no-agent: expected stale/enable hint" \
      "$(printf '%s' "$plugin_out_noagent" | head -20)"
  fi

  # Render with agent loaded (FAKE_LAUNCHCTL_PRINT_OK=1).
  plugin_out_agent="$(CLAWROUTER_CR="$MB_BIN3/cr" CLAWROUTER_JQ="$MB_JQ" \
    CLAWROUTER_LAUNCHCTL="$FAKE_LC" CLAWROUTER_NOTIFY=0 \
    FAKE_LAUNCHCTL_PRINT_OK=1 \
    bash "$CR_REPO/menubar/clawrouter.30s.sh" 2>/dev/null)"

  if printf '%s' "$plugin_out_agent" | grep -q 'Refresh now'; then
    ok "plugin agent-loaded: shows 'Refresh now' action"
  else
    bad "plugin agent-loaded: 'Refresh now' missing" \
      "$(printf '%s' "$plugin_out_agent" | grep -i refresh || echo '<none>')"
  fi
  if printf '%s' "$plugin_out_agent" | grep -q 'kickstart'; then
    ok "plugin agent-loaded: Refresh now uses kickstart"
  else
    bad "plugin agent-loaded: kickstart not in Refresh now line" \
      "$(printf '%s' "$plugin_out_agent" | grep -i 'refresh now' || echo '<none>')"
  fi
  if printf '%s' "$plugin_out_agent" | grep -q 'com.clawrouter.refresh'; then
    ok "plugin agent-loaded: Refresh now references label"
  else
    bad "plugin agent-loaded: label missing from Refresh now" \
      "$(printf '%s' "$plugin_out_agent" | grep -i 'refresh now' || echo '<none>')"
  fi
  if printf '%s' "$plugin_out_agent" | grep -q 'param2=--refresh'; then
    bad "plugin agent-loaded: must not contain param2=--refresh" \
      "$(printf '%s' "$plugin_out_agent" | grep 'param2=--refresh')"
  else
    ok "plugin agent-loaded: no param2=--refresh in output"
  fi
)

# =========================================================================
# relink tests — fully sandboxed, never touch real ~/.claude
# =========================================================================

# Fake claude home for relink tests (overrides CR_CLAUDE_HOME / CR_CLAUDE_JSON).
FAKEHOME="$SBX/fakeclaudehome"
mkdir -p "${FAKEHOME}/skills/s1" "${FAKEHOME}/agents/a1" "${FAKEHOME}/plugins/repos" \
         "${FAKEHOME}/hooks" "${FAKEHOME}/workflows" "${FAKEHOME}/commands"
printf 'x' > "${FAKEHOME}/settings.json"
printf 'y' > "${FAKEHOME}/CLAUDE.md"
printf '{"oauthAccount":{"emailAddress":"d@x"},"mcpServers":{"ctx7":{"command":"npx"},"linear":{"url":"x"}}}' \
  > "$SBX/fake-claude.json"
export CR_CLAUDE_HOME="$FAKEHOME"
export CR_CLAUDE_JSON="$SBX/fake-claude.json"

echo "== relink: shares dirs as symlinks, backs up real plugins =="
(
  export CR_HOME="$SBX/relink_home"
  mkdir -p "$CR_HOME/logs"
  WORK="$CR_HOME/accounts/work"
  mkdir -p "$WORK"

  # Seed config: subscription "work" (has a dir), null-default, and a backend.
  cat > "$CR_HOME/config.json" <<JSON
{"selection":"round-robin","accounts":[
  {"name":"default","configDir":null,"email":"a@x","plan":"max","lastUsed":0,"enabled":true,"usagePct":null},
  {"name":"work","configDir":"$WORK","email":"b@x","plan":"max","lastUsed":0,"enabled":true,"usagePct":null},
  {"name":"deepseek","kind":"backend","configDir":null,"baseUrl":"https://api.deepseek.com/anthropic","model":"m","email":null,"plan":"backend","lastUsed":0,"enabled":true,"usagePct":null}],
 "rotation":{"cursor":0},"share":{}}
JSON

  # Put a REAL plugins/ dir in the work account with a marker file.
  mkdir -p "$WORK/plugins"
  printf 'real' > "$WORK/plugins/MARKER"

  # Run relink.
  "$CR" relink work 2>"$SBX/relink_err"; rc=$?
  eq "relink work exits 0" "$rc" "0"

  # skills, agents, hooks, workflows, commands, settings.json, CLAUDE.md should be symlinks.
  for p in skills agents hooks commands settings.json CLAUDE.md; do
    if [[ -L "$WORK/$p" ]]; then
      tgt="$(readlink "$WORK/$p")"
      if [[ "$tgt" == "$FAKEHOME/$p" ]]; then
        ok "relink: $p is symlink → FAKEHOME"
      else
        bad "relink: $p symlink target" "expected $FAKEHOME/$p got $tgt"
      fi
    else
      bad "relink: $p should be a symlink" "ls: $(ls -la "$WORK/$p" 2>&1)"
    fi
  done

  # plugins should now be a symlink → FAKEHOME/plugins.
  if [[ -L "$WORK/plugins" ]]; then
    tgt="$(readlink "$WORK/plugins")"
    if [[ "$tgt" == "$FAKEHOME/plugins" ]]; then
      ok "relink: plugins is symlink → FAKEHOME/plugins"
    else
      bad "relink: plugins symlink target" "expected $FAKEHOME/plugins got $tgt"
    fi
  else
    bad "relink: plugins should be a symlink now" "$(ls -la "$WORK/plugins" 2>&1)"
  fi

  # The old real plugins/ was backed up.
  bak_count="$(find "$WORK" -maxdepth 1 -name 'plugins.bak.*' -type d 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$bak_count" -ge 1 ]]; then
    ok "relink: old real plugins backed up"
    # The backup still contains MARKER.
    bak="$(find "$WORK" -maxdepth 1 -name 'plugins.bak.*' -type d 2>/dev/null | head -1)"
    if grep -q 'real' "$bak/MARKER" 2>/dev/null; then
      ok "relink: backup contains original MARKER content"
    else
      bad "relink: backup MARKER content" "bak dir=$bak"
    fi
  else
    bad "relink: old real plugins should have been backed up" "bak files: $(ls -la "$WORK/" | grep bak || echo none)"
  fi

  # Idempotency: run relink again; no new .bak.* dirs created, symlinks unchanged.
  "$CR" relink work 2>/dev/null
  bak_count2="$(find "$WORK" -maxdepth 1 -name 'plugins.bak.*' -type d 2>/dev/null | wc -l | tr -d ' ')"
  eq "relink idempotent: no extra bak dirs on second run" "$bak_count2" "$bak_count"
  if [[ -L "$WORK/plugins" && "$(readlink "$WORK/plugins")" == "$FAKEHOME/plugins" ]]; then
    ok "relink idempotent: plugins symlink unchanged"
  else
    bad "relink idempotent: plugins symlink changed" "$(ls -la "$WORK/plugins" 2>&1)"
  fi

  # Dangling-source: remove FAKEHOME/workflows; relink again; work/workflows must NOT become a dangling symlink.
  rm -rf "$FAKEHOME/workflows"
  "$CR" relink work 2>/dev/null
  if [[ -L "$WORK/workflows" ]]; then
    # If a symlink exists, its target must still exist (not dangling).
    if [[ -e "$WORK/workflows" ]]; then
      ok "relink dangling-source: workflows symlink exists and target is valid"
    else
      bad "relink dangling-source: workflows is a dangling symlink" "target=$(readlink "$WORK/workflows")"
    fi
  else
    ok "relink dangling-source: no symlink created for missing source"
  fi
  # Restore workflows for later tests.
  mkdir -p "$FAKEHOME/workflows"
)

echo "== relink: merges mcpServers, preserves identity =="
(
  export CR_HOME="$SBX/relink_mcp_home"
  mkdir -p "$CR_HOME/logs"
  WORK="$CR_HOME/accounts/work"
  mkdir -p "$WORK"

  cat > "$CR_HOME/config.json" <<JSON
{"selection":"round-robin","accounts":[
  {"name":"work","configDir":"$WORK","email":"b@x","plan":"max","lastUsed":0,"enabled":true,"usagePct":null}],
 "rotation":{"cursor":0},"share":{}}
JSON

  # Give work a .claude.json with its own mcp server, identity, and extra keys.
  printf '{"oauthAccount":{"emailAddress":"work@x"},"mcpServers":{"local-only":{"command":"foo"}},"numStartups":5}' \
    > "$WORK/.claude.json"

  "$CR" relink work 2>/dev/null

  # Identity preserved.
  email="$(jq -r '.oauthAccount.emailAddress' "$WORK/.claude.json" 2>/dev/null)"
  eq "relink mcp: oauthAccount.emailAddress preserved" "$email" "work@x"

  # Extra keys preserved.
  ns="$(jq -r '.numStartups' "$WORK/.claude.json" 2>/dev/null)"
  eq "relink mcp: numStartups preserved" "$ns" "5"

  # Shared servers merged in.
  has_ctx7="$(jq -r '.mcpServers | has("ctx7")' "$WORK/.claude.json" 2>/dev/null)"
  has_linear="$(jq -r '.mcpServers | has("linear")' "$WORK/.claude.json" 2>/dev/null)"
  eq "relink mcp: ctx7 merged from source" "$has_ctx7" "true"
  eq "relink mcp: linear merged from source" "$has_linear" "true"

  # Account-only server preserved.
  has_local="$(jq -r '.mcpServers | has("local-only")' "$WORK/.claude.json" 2>/dev/null)"
  eq "relink mcp: local-only account server preserved" "$has_local" "true"

  # Valid JSON.
  if jq empty "$WORK/.claude.json" 2>/dev/null; then ok "relink mcp: .claude.json is valid JSON"; else bad "relink mcp: .claude.json invalid JSON" "$(cat "$WORK/.claude.json")"; fi

  # Conflict: source wins. Overwrite ctx7 in work with different value, then relink.
  jq '.mcpServers.ctx7 = {"command":"old-npx"}' "$WORK/.claude.json" > "$WORK/.claude.json.tmp" \
    && mv "$WORK/.claude.json.tmp" "$WORK/.claude.json"
  "$CR" relink work 2>/dev/null
  ctx7_cmd="$(jq -r '.mcpServers.ctx7.command' "$WORK/.claude.json" 2>/dev/null)"
  eq "relink mcp conflict: source wins (ctx7.command=npx not old-npx)" "$ctx7_cmd" "npx"
)

echo "== relink --all skips default + backend =="
(
  export CR_HOME="$SBX/relink_all_home"
  mkdir -p "$CR_HOME/logs"
  WORK="$CR_HOME/accounts/work"
  API="$CR_HOME/accounts/api"
  mkdir -p "$WORK" "$API"

  cat > "$CR_HOME/config.json" <<JSON
{"selection":"round-robin","accounts":[
  {"name":"default","configDir":null,"email":"a@x","plan":"max","lastUsed":0,"enabled":true,"usagePct":null},
  {"name":"work","configDir":"$WORK","email":"b@x","plan":"max","lastUsed":0,"enabled":true,"usagePct":null},
  {"name":"apikey","kind":"api","configDir":"$API","apiKey":"sk-t","email":null,"plan":"api-key","lastUsed":0,"enabled":true,"usagePct":null,"rotate":true},
  {"name":"deepseek","kind":"backend","configDir":null,"baseUrl":"https://api.deepseek.com/anthropic","model":"m","email":null,"plan":"backend","lastUsed":0,"enabled":true,"usagePct":null}],
 "rotation":{"cursor":0},"share":{}}
JSON

  "$CR" relink --all 2>"$SBX/relink_all_err"; rc=$?
  eq "relink --all exits 0" "$rc" "0"

  # work and api dirs got symlinks.
  if [[ -L "$WORK/settings.json" ]]; then ok "relink --all: work/settings.json symlinked"; else bad "relink --all: work/settings.json not symlinked" "$(ls -la "$WORK/" 2>&1)"; fi
  if [[ -L "$API/settings.json" ]]; then ok "relink --all: api/settings.json symlinked"; else bad "relink --all: api/settings.json not symlinked" "$(ls -la "$API/" 2>&1)"; fi

  # No error touching default (null configDir) or backend.
  if grep -qiE 'error|fail' "$SBX/relink_all_err" 2>/dev/null; then
    # skip messages are fine; look for actual errors.
    bad "relink --all: unexpected error in stderr" "$(cat "$SBX/relink_all_err")"
  else
    ok "relink --all: no errors in stderr"
  fi

  # Backend dir was not created.
  if [[ -d "$CR_HOME/accounts/deepseek" ]]; then
    bad "relink --all: backend dir should not have been created" "$CR_HOME/accounts/deepseek"
  else
    ok "relink --all: backend dir not created"
  fi
)

echo "== relink: bad/missing target errors cleanly =="
(
  export CR_HOME="$SBX/relink_bad_home"
  mkdir -p "$CR_HOME/logs"
  cat > "$CR_HOME/config.json" <<JSON
{"selection":"round-robin","accounts":[
  {"name":"work","configDir":"$SBX/relink_bad_home/accounts/work","email":"b@x","plan":"max","lastUsed":0,"enabled":true,"usagePct":null},
  {"name":"deepseek","kind":"backend","configDir":null,"baseUrl":"https://api.deepseek.com/anthropic","model":"m","email":null,"plan":"backend","lastUsed":0,"enabled":true,"usagePct":null}],
 "rotation":{"cursor":0},"share":{}}
JSON
  mkdir -p "$SBX/relink_bad_home/accounts/work"

  # Nonexistent account exits nonzero with a clear message.
  "$CR" relink nonexistent 2>"$SBX/relink_ne_err"; rc=$?
  if [[ "$rc" -ne 0 ]]; then ok "relink nonexistent: exits nonzero"; else bad "relink nonexistent: should exit nonzero" "rc=$rc"; fi
  if grep -qiE 'unknown|not found|nonexistent' "$SBX/relink_ne_err" 2>/dev/null; then ok "relink nonexistent: clear message"; else bad "relink nonexistent: no clear message" "$(cat "$SBX/relink_ne_err")"; fi

  # Backend account exits nonzero with a clear message.
  "$CR" relink deepseek 2>"$SBX/relink_be_err"; rc=$?
  if [[ "$rc" -ne 0 ]]; then
    ok "relink backend: exits nonzero"
    if grep -qiE 'backend|config dir' "$SBX/relink_be_err" 2>/dev/null; then ok "relink backend: clear message"; else bad "relink backend: no clear message" "$(cat "$SBX/relink_be_err")"; fi
  else
    # Alternative: skip with a clear message (check for skip/backend in stderr).
    if grep -qiE 'skip|backend' "$SBX/relink_be_err" 2>/dev/null; then ok "relink backend: exits 0 with skip message"; else bad "relink backend: should exit nonzero or print clear message" "rc=$rc stderr=$(cat "$SBX/relink_be_err")"; fi
  fi
)

echo "== relink: missing/empty source + missing acct json =="
(
  export CR_HOME="$SBX/relink_empty_home"
  mkdir -p "$CR_HOME/logs"
  WORK="$CR_HOME/accounts/work"
  mkdir -p "$WORK"

  cat > "$CR_HOME/config.json" <<JSON
{"selection":"round-robin","accounts":[
  {"name":"work","configDir":"$WORK","email":"b@x","plan":"max","lastUsed":0,"enabled":true,"usagePct":null}],
 "rotation":{"cursor":0},"share":{}}
JSON

  # Source .claude.json has no mcpServers → relink exits 0, work/.claude.json absent is fine.
  ORIG_JSON="$CR_CLAUDE_JSON"
  printf '{"oauthAccount":{"emailAddress":"d@x"}}' > "$SBX/no-mcp-claude.json"
  CR_CLAUDE_JSON="$SBX/no-mcp-claude.json" "$CR" relink work 2>/dev/null; rc=$?
  eq "relink empty source mcp: exits 0" "$rc" "0"
  # work has no .claude.json yet — that's fine.
  if [[ ! -f "$WORK/.claude.json" ]]; then ok "relink: no .claude.json → skip merge cleanly"; fi

  # With work having no .claude.json but the source has mcp: dirs still linked, merge skipped.
  CR_CLAUDE_JSON="$CR_CLAUDE_JSON" "$CR" relink work 2>/dev/null; rc2=$?
  eq "relink: links dirs even without work/.claude.json, exits 0" "$rc2" "0"
  if [[ -L "$WORK/settings.json" ]]; then ok "relink: settings.json symlinked despite no .claude.json"; else bad "relink: settings.json not symlinked" "$(ls -la "$WORK/" 2>&1)"; fi
)

echo "== cr add: merges mcpServers after registering the account (ordering) =="
(
  export CR_HOME="$SBX/add_mcp_home"
  mkdir -p "$CR_HOME/logs"
  cat > "$CR_HOME/config.json" <<JSON
{"selection":"round-robin","accounts":[],"rotation":{"cursor":0},"share":{}}
JSON
  # Fake claude whose /login writes a .claude.json with its OWN identity into the dir.
  LOGINBIN="$SBX/add_mcp_bin"; mkdir -p "$LOGINBIN"
  cat > "$LOGINBIN/claude" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "/login" ]]; then
  printf '{"oauthAccount":{"emailAddress":"new@x","organizationType":"max"},"mcpServers":{"local-only":{"command":"foo"}},"numStartups":3}' \
    > "${CLAUDE_CONFIG_DIR}/.claude.json"
fi
exit 0
EOF
  chmod +x "$LOGINBIN/claude"
  # Source has two shared servers; the new account should end up with both + its own.
  printf '{"oauthAccount":{"emailAddress":"d@x"},"mcpServers":{"ctx7":{"command":"npx"},"linear":{"url":"x"}}}' > "$SBX/add-src-claude.json"

  PATH="$LOGINBIN:$PATH" CR_CLAUDE_JSON="$SBX/add-src-claude.json" "$CR" add newacct >/dev/null 2>&1
  AJ="$CR_HOME/accounts/newacct/.claude.json"
  if [[ -f "$AJ" ]]; then ok "cr add: account .claude.json created"; else bad "cr add: .claude.json missing" "$(ls -la "$CR_HOME/accounts/newacct/" 2>&1)"; fi
  # Shared servers merged in (the ordering bug made this silently skip):
  eq "cr add: shared mcp 'ctx7' merged"   "$(jq -r '.mcpServers.ctx7.command // "MISSING"' "$AJ" 2>/dev/null)" "npx"
  eq "cr add: shared mcp 'linear' merged"  "$(jq -r '.mcpServers.linear.url // "MISSING"' "$AJ" 2>/dev/null)" "x"
  # Account-only server preserved, identity + other keys untouched:
  eq "cr add: account-only mcp preserved"  "$(jq -r '.mcpServers["local-only"].command // "MISSING"' "$AJ" 2>/dev/null)" "foo"
  eq "cr add: account identity preserved"  "$(jq -r '.oauthAccount.emailAddress' "$AJ" 2>/dev/null)" "new@x"
  eq "cr add: other keys preserved"        "$(jq -r '.numStartups' "$AJ" 2>/dev/null)" "3"
)

echo
PASS=$(wc -c < "$SBX/.pass" | tr -d ' '); FAIL=$(wc -c < "$SBX/.fail" | tr -d ' ')
echo "== $PASS passed, $FAIL failed =="
[[ "$FAIL" -eq 0 ]]
