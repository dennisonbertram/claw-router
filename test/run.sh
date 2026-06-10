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

echo
PASS=$(wc -c < "$SBX/.pass" | tr -d ' '); FAIL=$(wc -c < "$SBX/.fail" | tr -d ' ')
echo "== $PASS passed, $FAIL failed =="
[[ "$FAIL" -eq 0 ]]
