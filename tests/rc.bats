#!/usr/bin/env bats
#
# The suite runs against a `curl` shim on PATH (tests/bin/curl), so no test
# touches the network or a real server.
#
# RC and SKILL_MD can point at another revision, which is how the suite is
# checked against the commit whose defects it covers: a test that cannot fail
# proves nothing.
#
# RC_BASH selects the interpreter, so the same tests run under bash 3.2
# (stock macOS, serial scan branch) and modern bash.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  RC="${RC:-$REPO_ROOT/rocketchat/rc.sh}"
  SKILL_MD="${SKILL_MD:-$REPO_ROOT/rocketchat/SKILL.md}"
  RC_BASH="${RC_BASH:-bash}"

  export FIXTURES="$REPO_ROOT/tests/fixtures"
  export PATH="$REPO_ROOT/tests/bin:$PATH"
  export TZ=UTC
  export RC_SEARCH_DELAY=0 RC_RETRY_DELAY=0

  TMP="$(mktemp -d)"
  export CURL_LOG="$TMP/curl.log"; : > "$CURL_LOG"
  export CURL_BODY_DIR="$TMP/bodies"; mkdir -p "$CURL_BODY_DIR"
  export CURL_FAIL_DIR="$TMP/fail"; mkdir -p "$CURL_FAIL_DIR"
  export XDG_CONFIG_HOME="$TMP/config"
  mkdir -p "$XDG_CONFIG_HOME/rocketchat"
  cat > "$XDG_CONFIG_HOME/rocketchat/config" <<EOF
ROCKETCHAT_URL=https://chat.example.com
ROCKETCHAT_USER_ID=FAKEUID
ROCKETCHAT_AUTH_TOKEN=FAKETOKEN
EOF
  chmod 600 "$XDG_CONFIG_HOME/rocketchat/config"

  unset ROCKETCHAT_URL ROCKETCHAT_USER_ID ROCKETCHAT_AUTH_TOKEN
}

teardown() {
  [ -n "${TMP:-}" ] && rm -rf "$TMP"
}

rc() {
  run "$RC_BASH" "$RC" "$@"
}

# Extracts the shell block containing the install-path lookup from SKILL.md,
# so the documented snippet is tested rather than a copy that can drift.
lookup_snippet() {
  awk '/^```bash$/{buf=""; inb=1; next} /^```$/{if (inb && buf ~ /for p in/) {printf "%s", buf; exit} inb=0} inb{buf = buf $0 "\n"}' "$SKILL_MD"
}

# --- credentials ------------------------------------------------------------

@test "fails with a clear message when no credentials are configured" {
  rm -rf "$XDG_CONFIG_HOME/rocketchat"
  rc whoami
  [ "$status" -ne 0 ]
  [[ "$output" == *"no credentials"* ]]
  [[ "$output" == *"rc.sh setup"* ]]
}

@test "setup stores credentials from flags with mode 600" {
  rm -rf "$XDG_CONFIG_HOME/rocketchat"
  rc setup --url https://chat.example.com/ --user-id U1 --token T1
  [ "$status" -eq 0 ]
  local cfg="$XDG_CONFIG_HOME/rocketchat/config"
  [ -f "$cfg" ]
  # GNU stat uses -c, BSD stat uses -f. On Linux `stat -f` is valid but reports
  # the filesystem, so it succeeds with the wrong answer instead of failing:
  # pick by what the platform's stat actually supports.
  local mode
  if stat -c '%a' "$cfg" >/dev/null 2>&1; then
    mode="$(stat -c '%a' "$cfg")"
  else
    mode="$(stat -f '%Lp' "$cfg")"
  fi
  [ "$mode" = "600" ]
  grep -q '^ROCKETCHAT_URL=https://chat.example.com$' "$cfg"   # trailing slash stripped
}

@test "setup accepts three piped lines (provisioning scripts)" {
  rm -rf "$XDG_CONFIG_HOME/rocketchat"
  run "$RC_BASH" -c "printf '%s\n' https://chat.example.com U2 T2 | '$RC' setup"
  [ "$status" -eq 0 ]
  grep -q '^ROCKETCHAT_USER_ID=U2$' "$XDG_CONFIG_HOME/rocketchat/config"
}

@test "setup fails fast on closed stdin instead of hanging" {
  rm -rf "$XDG_CONFIG_HOME/rocketchat"
  local start=$SECONDS
  run "$RC_BASH" -c "'$RC' setup < /dev/null"
  [ "$status" -ne 0 ]
  [[ "$output" == *"terminal"* ]] || [[ "$output" == *"flags"* ]]
  [ $((SECONDS - start)) -lt 5 ]
}

@test "setup times out on stdin that never delivers a line" {
  rm -rf "$XDG_CONFIG_HOME/rocketchat"
  local start=$SECONDS
  run env RC_SETUP_READ_TIMEOUT=1 "$RC_BASH" -c "'$RC' setup < /dev/zero"
  [ "$status" -ne 0 ]
  [ $((SECONDS - start)) -lt 15 ]
}

@test "environment variables win over the config file" {
  run env ROCKETCHAT_URL=https://other.example.com \
           ROCKETCHAT_USER_ID=ENVID ROCKETCHAT_AUTH_TOKEN=ENVTOK \
           "$RC_BASH" "$RC" whoami
  [ "$status" -eq 0 ]
  grep -q 'https://other.example.com' "$CURL_LOG"
  ! grep -q 'chat.example.com' "$CURL_LOG"
}

@test "the token never appears in output" {
  rc whoami
  [[ "$output" != *"FAKETOKEN"* ]]
  rc search deploy '#general' 5
  [[ "$output" != *"FAKETOKEN"* ]]
  rc room @john.roe
  [[ "$output" != *"FAKETOKEN"* ]]
}

# --- room: the public contract ---------------------------------------------

@test "room prints a bare roomId with no TAB, for every room type" {
  for target in @john.roe '#general' '#leads'; do
    rc room "$target"
    [ "$status" -eq 0 ]
    [[ "$output" != *$'\t'* ]]
  done
}

@test "room resolves each room type to its id" {
  rc room @john.roe;  [ "$output" = "RIDDM" ]
  rc room '#general'; [ "$output" = "RIDCH" ]
  rc room '#leads';   [ "$output" = "RIDPG" ]
}

@test "room reports NONE for an unknown target" {
  rc room @nobody.here
  [ "$output" = "NONE" ]
}

@test "searching never creates a room" {
  rc search deploy @john.roe 5
  ! grep -q 'im.create' "$CURL_LOG"
}

# --- search: output contract ------------------------------------------------

@test "scoped search emits five TSV fields" {
  rc search deploy @john.roe 5
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | awk -F'\t' 'END{print NF}')" -eq 5 ]
}

@test "message link uses the URL segment matching the room type" {
  rc search deploy @john.roe 5
  [[ "$output" == *"/direct/john.roe?msg=MSGDM"* ]]
  rc search deploy '#general' 5
  [[ "$output" == *"/channel/general?msg=MSGCH"* ]]
  rc search deploy '#leads' 5
  [[ "$output" == *"/group/leads?msg=MSGPG"* ]]
}

@test "search reports NONE when a room has no match" {
  rc search nothingmatches '#general' 5
  [ "$output" = "NONE" ]
}

@test "search reports an unknown target as an error, not as NONE" {
  rc search deploy @nobody.here 5
  [[ "$output" == *"ERROR: room not found"* ]]
}

@test "long messages are truncated to 300 characters" {
  # A private FIXTURES copy: a test must never mutate a versioned fixture,
  # or a failure part-way through leaves the suite corrupted for later tests.
  cp -R "$FIXTURES" "$TMP/fx"
  cp "$TMP/fx/chat.search.RIDLONG.json" "$TMP/fx/chat.search.RIDDM.json"
  FIXTURES="$TMP/fx" rc search deploy @john.roe 5
  local text
  text="$(printf '%s' "$output" | awk -F'\t' '{print $4}')"
  [[ "$text" == *" [...]" ]]
  [ "${#text}" -lt 320 ]
}

@test "a numeric second argument is the count, not a target" {
  rc search deploy 2
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | grep -c .)" -le 2 ]
}

# --- global scan: coverage and labels --------------------------------------

@test "global scan labels a discussion distinctly from a channel" {
  rc search deploy 20
  [[ "$output" == *"discussion:Quarterly planning"* ]]
}

@test "global scan skips closed rooms" {
  rc search deploy 20
  ! grep -q 'roomId=RIDCLOSED' "$CURL_LOG"
}

@test "channels mode excludes direct messages" {
  RC_SEARCH_KIND=channels rc search deploy 20
  ! grep -q 'roomId=RIDDM' "$CURL_LOG"
  grep -q 'roomId=RIDCH' "$CURL_LOG"
}

@test "a failing room is named and coverage is declared incomplete" {
  CURL_FAIL_URLS="roomId=RIDCH" rc search deploy 20
  [[ "$output" == *"WARNING:"* ]]
  [[ "$output" == *"coverage is incomplete"* ]]
  [[ "$output" == *"#general"* ]]
}

@test "a network failure surfaces as ERROR, never as NONE" {
  CURL_FAIL_URLS="chat.search" rc search deploy @john.roe 5
  [[ "$output" == *"ERROR"* ]]
  [[ "$output" != "NONE" ]]
}

@test "a one-off refusal is retried and recovered" {
  CURL_FAIL_ONCE="roomId=RIDDM" rc search deploy @john.roe 5
  [ "$(grep -c 'roomId=RIDDM' "$CURL_LOG")" -eq 2 ]
  [[ "$output" != *"ERROR"* ]]
  [[ "$output" == *"MSGDM"* ]]
}

# --- send -------------------------------------------------------------------

@test "send posts the channel and text as JSON" {
  rc send @john.roe "hello there"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK: sent to"* ]]
  local body
  body="$(ls "$CURL_BODY_DIR"/body.*.json | head -1)"
  [ "$(jq -r .channel "$body")" = "@john.roe" ]
  [ "$(jq -r .text "$body")" = "hello there" ]
}

@test "send-file preserves the file's exact multi-line content" {
  printf 'line one\nline "two"\n\tindented\n' > "$TMP/msg.txt"
  rc send-file '#general' "$TMP/msg.txt"
  [ "$status" -eq 0 ]
  local body
  body="$(ls "$CURL_BODY_DIR"/body.*.json | head -1)"
  [ "$(jq -r .text "$body")" = "$(cat "$TMP/msg.txt")" ]
}

# --- find -------------------------------------------------------------------

@test "find returns name, username and status" {
  rc find john
  [ "$status" -eq 0 ]
  [[ "$output" == *"John Roe"* ]]
  [[ "$output" == *"@john.roe"* ]]
}

# --- the lookup snippet documented in SKILL.md ------------------------------

@test "SKILL.md still documents a lookup snippet" {
  [ -n "$(lookup_snippet)" ]
}

@test "documented lookup honours path priority over alphabetical order" {
  local h="$TMP/home" w="$TMP/work"
  mkdir -p "$h/.claude/skills/rocketchat" "$h/.agents/skills/rocketchat" "$w/.agents/skills/rocketchat"
  echo CLAUDE > "$h/.claude/skills/rocketchat/rc.sh"
  echo AGENTS > "$h/.agents/skills/rocketchat/rc.sh"
  echo CWD    > "$w/.agents/skills/rocketchat/rc.sh"
  run env HOME="$h" "$RC_BASH" -c "cd '$w' || exit 1
$(lookup_snippet)
cat \"\$RC\""
  [ "$status" -eq 0 ]
  [ "$output" = "CLAUDE" ]
}

@test "documented lookup finds the sandbox mount path (Cowork)" {
  # A per-session $HOME, as Claude Desktop's Cowork generates: the skill is
  # mounted under $HOME/mnt/.skills, and none of the usual paths exist.
  local h="$TMP/sessionhome" w="$TMP/nowhere"
  mkdir -p "$h/mnt/.skills/rocketchat" "$w"
  echo MOUNTED > "$h/mnt/.skills/rocketchat/rc.sh"
  run env HOME="$h" "$RC_BASH" -c "cd '$w' || exit 1
$(lookup_snippet)
cat \"\$RC\""
  [ "$status" -eq 0 ]
  [ "$output" = "MOUNTED" ]
}

@test "documented lookup reports a missing install instead of dying silently" {
  local h="$TMP/emptyhome" w="$TMP/neutral"
  mkdir -p "$h" "$w"
  run env HOME="$h" "$RC_BASH" -c "cd '$w' || exit 1
set -euo pipefail
$(lookup_snippet)
echo SHOULD_NOT_REACH"
  [ "$status" -ne 0 ]
  [[ "$output" != *"SHOULD_NOT_REACH"* ]]
  [ -n "$output" ]
}
