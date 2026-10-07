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

# --- get: one message by permalink or id ------------------------------------

@test "get accepts a permalink and asks for the id it carries" {
  rc get 'https://chat.example.com/direct/RIDDM?msg=MSGID1'
  [ "$status" -eq 0 ]
  grep -q 'chat.getMessage?msgId=MSGID1' "$CURL_LOG"
}

@test "get accepts a bare message id" {
  rc get MSGID1
  [ "$status" -eq 0 ]
  grep -q 'chat.getMessage?msgId=MSGID1' "$CURL_LOG"
}

@test "get emits the same five TSV fields as search" {
  rc get MSGID1
  [ "$(printf '%s' "$output" | awk -F'\t' 'END{print NF}')" -eq 5 ]
}

@test "get labels the room from the subscription, not from the link" {
  rc get 'https://chat.example.com/direct/RIDDM?msg=MSGID1'
  [ "$(printf '%s' "$output" | awk -F'\t' '{print $2}')" = "@john.roe" ]
}

@test "get keeps the whole text on one line and lists the attachment" {
  rc get MSGID1
  local text
  text="$(printf '%s' "$output" | awk -F'\t' '{print $4}')"
  [[ "$text" == *"any data we have access to:"* ]]
  [[ "$text" == *"[file: Clipboard.png]"* ]]
}

@test "get links a private group as /group/, not /channel/" {
  cp -R "$FIXTURES" "$TMP/fxpg"
  jq '.message.rid = "RIDPG"' "$FIXTURES/chat.getMessage.json" \
    > "$TMP/fxpg/chat.getMessage.json"
  FIXTURES="$TMP/fxpg" rc get MSGID1
  [ "$(printf '%s' "$output" | awk -F'\t' '{print $2}')" = "#leads" ]
  [[ "$(printf '%s' "$output" | awk -F'\t' '{print $5}')" == *"/group/leads?msg=MSGID1" ]]
}

@test "get reports a message it cannot read as an error, not as empty output" {
  CURL_MSG_NOT_FOUND=1 rc get MSGID1
  [[ "$output" == ERROR:* ]]
}

@test "get names both causes when the server refuses without a reason" {
  # The real server answers a wrong id with a bare {"success":false}: an id that
  # does not exist and one this account cannot read are indistinguishable.
  CURL_MSG_BARE_FALSE=1 rc get MSGID1
  [[ "$output" == ERROR:* ]]
  [[ "$output" == *"cannot read"* ]]
}

@test "get labels a room the user has left with the bare rid and no link" {
  cp -R "$FIXTURES" "$TMP/fxleft"
  jq '.message.rid = "RIDGONE"' "$FIXTURES/chat.getMessage.json" \
    > "$TMP/fxleft/chat.getMessage.json"
  FIXTURES="$TMP/fxleft" rc get MSGID1
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | awk -F'\t' '{print $2}')" = "RIDGONE" ]
  [ -z "$(printf '%s' "$output" | awk -F'\t' '{print $5}')" ]
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

@test "send-thread posts the title, then the body inside its thread" {
  printf 'Long body.\n\nSecond paragraph with *markdown*.\n' > "$TMP/body.md"
  rc send-thread '#general' "Headline goes here" "$TMP/body.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK: thread posted"* ]]

  local first second
  first="$(ls "$CURL_BODY_DIR"/body.*.json | sed -n 1p)"
  second="$(ls "$CURL_BODY_DIR"/body.*.json | sed -n 2p)"

  # The title goes to the channel as an ordinary message, with no tmid.
  [ "$(jq -r .text "$first")" = "Headline goes here" ]
  [ "$(jq -r '.tmid // "none"' "$first")" = "none" ]

  # The body is a reply carrying tmid, so it lands inside the title's thread.
  [ "$(jq -r .tmid "$second")" = "MSGNEW" ]
  [ "$(jq -r .text "$second")" = "$(cat "$TMP/body.md")" ]
}

@test "send-thread refuses an unusable body file before posting anything" {
  # Every local problem must be caught before the title goes out: posting it is
  # irreversible, so a late failure strands a headline in a public channel.
  : > "$TMP/empty.md"
  printf 'x\n' > "$TMP/noperm.md"; chmod 000 "$TMP/noperm.md"

  local f
  for f in "$TMP/does-not-exist.md" "$TMP/empty.md" "$TMP/noperm.md"; do
    : > "$CURL_LOG"
    rc send-thread '#general' "Headline" "$f"
    [ "$status" -ne 0 ]
    [[ "$output" == *"body file"* ]]
    ! grep -q 'chat.postMessage' "$CURL_LOG"
  done
  chmod 644 "$TMP/noperm.md"
}

@test "send-thread does not attempt the body when the title fails" {
  printf 'body\n' > "$TMP/body.md"
  CURL_TITLE_FAILS=1 rc send-thread '#general' "Headline" "$TMP/body.md"
  [[ "$output" == *"ERROR"* ]]
  [[ "$output" == *"could not post the thread title"* ]]
  # Exactly one POST: retrying the body against a title that does not exist
  # would post an orphan message into the channel.
  [ "$(grep -c 'chat.postMessage' "$CURL_LOG")" -eq 1 ]
}

@test "send-thread survives a non-JSON response and still names the stranded title" {
  # A proxy answering the reply with an HTML error page must not kill the
  # script: that is precisely when the operator needs the title's id.
  printf 'body\n' > "$TMP/body.md"
  CURL_REPLY_HTML=1 rc send-thread '#general' "Headline" "$TMP/body.md"
  [ "$status" -eq 0 ]
  [[ "$output" != *"parse error"* ]]
  [[ "$output" == *"title was posted"* ]]
  [[ "$output" == *"MSGNEW"* ]]
}

@test "send-thread refuses to thread onto a response with no message id" {
  # success:true with no .message._id would otherwise post the body with
  # tmid "null", detaching it from the title instead of failing.
  printf 'body\n' > "$TMP/body.md"
  CURL_TITLE_NO_ID=1 rc send-thread '#general' "Headline" "$TMP/body.md"
  [[ "$output" == *"ERROR"* ]]
  [[ "$output" != *"null"* ]]
  [ "$(grep -c 'chat.postMessage' "$CURL_LOG")" -eq 1 ]
}

@test "send-thread reports a dangling title when the body fails" {
  printf 'body\n' > "$TMP/body.md"
  # The title succeeds; the reply is refused. The room is left with a headline
  # and no content, and the operator has to be told exactly that.
  CURL_FAIL_ONCE="" CURL_REPLY_FAILS=1 rc send-thread '#general' "Headline" "$TMP/body.md"
  [[ "$output" == *"ERROR"* ]]
  [[ "$output" == *"title was posted"* ]]
  [[ "$output" == *"MSGNEW"* ]]
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
