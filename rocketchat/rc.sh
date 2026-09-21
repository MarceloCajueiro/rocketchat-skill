#!/usr/bin/env bash
# Rocket.Chat REST helper for the `rocketchat` agent skill.
# Credentials: run `rc.sh setup`. They are stored in
# ${XDG_CONFIG_HOME:-~/.config}/rocketchat/config with mode 600.
# Environment variables of the same name always win over the config file.
set -euo pipefail

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/rocketchat"
CONFIG_FILE="$CONFIG_DIR/config"
CONTACTS_FILE="$CONFIG_DIR/contacts.md"

# Env wins over the config file, as CLI convention requires. Without snapshotting
# first, `ROCKETCHAT_URL=... rc.sh` would be silently overwritten by the file.
_rc_env_url="${ROCKETCHAT_URL:-}"
_rc_env_uid="${ROCKETCHAT_USER_ID:-}"
_rc_env_tok="${ROCKETCHAT_AUTH_TOKEN:-}"

if [ -f "$CONFIG_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  set +a
fi

ROCKETCHAT_URL="${_rc_env_url:-${ROCKETCHAT_URL:-}}"
ROCKETCHAT_USER_ID="${_rc_env_uid:-${ROCKETCHAT_USER_ID:-}}"
ROCKETCHAT_AUTH_TOKEN="${_rc_env_tok:-${ROCKETCHAT_AUTH_TOKEN:-}}"
unset _rc_env_url _rc_env_uid _rc_env_tok

# Dependencies, checked once with an actionable message instead of a cryptic failure.
for _rc_dep in curl jq; do
  command -v "$_rc_dep" >/dev/null 2>&1 || {
    echo "ERROR: '$_rc_dep' is required but was not found in PATH." >&2
    exit 1
  }
done
unset _rc_dep

# Parallel scanning uses `wait -n`, which needs bash >= 4.3. macOS ships bash 3.2,
# where the throttle would silently do nothing and fire every request at once.
RC_CAN_PARALLEL=0
if [ "${BASH_VERSINFO[0]:-0}" -gt 4 ] ||
   { [ "${BASH_VERSINFO[0]:-0}" -eq 4 ] && [ "${BASH_VERSINFO[1]:-0}" -ge 3 ]; }; then
  RC_CAN_PARALLEL=1
fi

cmd_setup() {
  local url="" uid="" token=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --url)     url="${2:-}"; shift 2 ;;
      --user-id) uid="${2:-}"; shift 2 ;;
      --token)   token="${2:-}"; shift 2 ;;
      -h|--help)
        echo "usage: rc.sh setup [--url URL --user-id ID --token TOKEN]"
        echo "with no flags, prompts interactively."
        return 0 ;;
      *) echo "unknown option: $1" >&2; return 1 ;;
    esac
  done

  if [ -z "$url" ] || [ -z "$uid" ] || [ -z "$token" ]; then
    # Only a terminal gets the prompts; a pipe feeding three lines still works.
    # On stdin that never delivers - an agent's inherited descriptor - the read
    # times out instead of hanging until the caller's own timeout.
    local rc_read_opts=()
    if [ -t 0 ]; then
      echo "Rocket.Chat setup. Create a Personal Access Token at:"
      echo "  Avatar > My Account > Personal Access Tokens"
      echo "  Tick 'Ignore Two Factor Authentication', or every call will need a TOTP code."
      echo
    else
      rc_read_opts=(-t "${RC_SETUP_READ_TIMEOUT:-10}")
    fi

    rc_prompt() {  # rc_prompt <var-name> <label> [hidden]
      local __var="$1" __label="$2" __hidden="${3:-}" __value=""
      [ -t 0 ] && printf '%s' "$__label"
      if [ -n "$__hidden" ] && [ -t 0 ]; then
        # read -s keeps the token off the screen and out of the shell history.
        read -rs "${rc_read_opts[@]}" __value || __value=""
        echo
      else
        read -r "${rc_read_opts[@]}" __value || __value=""
      fi
      printf -v "$__var" '%s' "$__value"
    }

    [ -z "$url" ]   && rc_prompt url   'Server URL (e.g. https://chat.example.com): '
    [ -z "$uid" ]   && rc_prompt uid   'User ID: '
    [ -z "$token" ] && rc_prompt token 'Auth token (input hidden): ' hidden

    if [ -z "$url" ] || [ -z "$uid" ] || [ -z "$token" ]; then
      echo "ERROR: setup needs a terminal, three piped lines (url, user id, token), or the --url, --user-id and --token flags." >&2
      return 1
    fi
  fi

  url="${url%/}"
  [ -n "$url" ] && [ -n "$uid" ] && [ -n "$token" ] || {
    echo "ERROR: url, user id and token are all required." >&2
    return 1
  }

  mkdir -p "$CONFIG_DIR"
  umask 077
  cat > "$CONFIG_FILE" <<EOF
ROCKETCHAT_URL=$url
ROCKETCHAT_USER_ID=$uid
ROCKETCHAT_AUTH_TOKEN=$token
EOF
  chmod 600 "$CONFIG_FILE"

  ROCKETCHAT_URL="$url"
  ROCKETCHAT_USER_ID="$uid"
  ROCKETCHAT_AUTH_TOKEN="$token"
  BASE="$url"

  echo "Saved to $CONFIG_FILE"
  printf 'Checking credentials... '
  cmd_whoami
}

# Credentials are required by every command except setup itself, which creates them.
# The check runs here so an unconfigured install fails with one clear line.
if [ "${1:-}" != "setup" ] &&
   { [ -z "${ROCKETCHAT_URL:-}" ] || [ -z "${ROCKETCHAT_USER_ID:-}" ] || [ -z "${ROCKETCHAT_AUTH_TOKEN:-}" ]; }; then
  echo "ERROR: no credentials. Run 'rc.sh setup' (or set ROCKETCHAT_URL, ROCKETCHAT_USER_ID and ROCKETCHAT_AUTH_TOKEN)." >&2
  exit 1
fi

BASE="${ROCKETCHAT_URL:-}"
BASE="${BASE%/}"

rc_curl() {
  local method="$1" path="$2"
  shift 2
  local body
  # A network failure must not surface as an empty response: empty would become "NONE"
  # downstream, and a future session would read "the chat is down" as "no such message".
  if ! body=$(curl -sS --max-time "${RC_HTTP_TIMEOUT:-20}" --retry 2 --retry-connrefused -X "$method" "$BASE$path" \
    -H "X-Auth-Token: $ROCKETCHAT_AUTH_TOKEN" \
    -H "X-User-Id: $ROCKETCHAT_USER_ID" \
    -H "Content-Type: application/json" \
    "$@" 2>/dev/null); then
    echo '{"success":false,"error":"network failure talking to Rocket.Chat"}'
    return 0
  fi
  if [ -z "$body" ]; then
    echo '{"success":false,"error":"empty response from Rocket.Chat"}'
    return 0
  fi
  printf '%s' "$body"
}

# Extracts a human reason from a failed response, whatever shape it has.
# A proxy can answer with an HTML error page, so jq must never be allowed to
# abort the caller: on any unparsable body this still prints a usable sentence.
rc_failure_reason() {
  local body="$1" reason=""
  reason=$(printf '%s' "$body" | jq -r '(.error // .message // .errorType // empty) | select(type == "string")' 2>/dev/null || true)
  [ -n "$reason" ] || reason="unreadable response from Rocket.Chat"
  printf '%s' "$reason"
}

cmd_whoami() {
  rc_curl GET "/api/v1/me" | jq -r 'if .success == false then "ERROR: \(.error // .message)" else "\(.name) (@\(.username))" end'
}

# find <term> - look users up by name or username
cmd_find() {
  local term="${1:?usage: rc.sh find <term>}"
  local selector
  selector=$(jq -rn --arg t "$term" '{term:$t}|@uri')
  rc_curl GET "/api/v1/users.autocomplete?selector=$selector" \
    | jq -r 'if .success == false then "ERROR: \(.error // .message)"
             else (.items // [] | if length == 0 then "NONE"
             else .[] | "\(.name // "?")\t@\(.username)\t\(.status // "?")" end) end'
}

# send <@user|#channel> <text>
cmd_send() {
  local target="${1:?usage: rc.sh send <@user|#channel> <text>}"
  local text="${2:?usage: rc.sh send <@user|#channel> <text>}"
  local payload
  payload=$(jq -n --arg c "$target" --arg t "$text" '{channel:$c, text:$t}')
  rc_curl POST "/api/v1/chat.postMessage" -d "$payload" \
    | jq -r 'if .success then "OK: sent to \(.message.rid)" else "ERROR: \(.error // .message)" end'
}

# send-file <@user|#channel> <file> - reads the text from a file, for long messages
cmd_send_file() {
  local target="${1:?usage: rc.sh send-file <@user|#channel> <file>}"
  local file="${2:?usage: rc.sh send-file <@user|#channel> <file>}"
  local payload
  payload=$(jq -n --arg c "$target" --rawfile t "$file" '{channel:$c, text:$t}')
  rc_curl POST "/api/v1/chat.postMessage" -d "$payload" \
    | jq -r 'if .success then "OK: sent to \(.message.rid)" else "ERROR: \(.error // .message)" end'
}

# send-thread <@user|#channel> <title> <body-file>
# Posts the title as a normal message, then the body as a reply inside its thread.
# The channel shows one short line; the long text lives behind it, unfolded only
# by whoever opens the thread. This is the announcement shape: a headline that
# does not flood the room, with the detail one click away.
cmd_send_thread() {
  local target="${1:?usage: rc.sh send-thread <@user|#channel> <title> <body-file>}"
  local title="${2:?usage: rc.sh send-thread <@user|#channel> <title> <body-file>}"
  local file="${3:?usage: rc.sh send-thread <@user|#channel> <title> <body-file>}"

  # Every local precondition is checked, and the body is read into the payload,
  # BEFORE the title goes out. Posting the title is irreversible: a problem
  # discovered afterwards leaves a headline in the room with nothing behind it.
  [ -e "$file" ] || { echo "ERROR: body file not found: $file"; return 1; }
  [ -r "$file" ] || { echo "ERROR: body file is not readable: $file"; return 1; }
  [ -s "$file" ] || { echo "ERROR: body file is empty: $file"; return 1; }

  local body_text
  body_text=$(cat "$file") || { echo "ERROR: could not read the body file: $file"; return 1; }

  local root_payload root_body root_id room_id
  root_payload=$(jq -n --arg c "$target" --arg t "$title" '{channel:$c, text:$t}')
  root_body=$(rc_curl POST "/api/v1/chat.postMessage" -d "$root_payload")

  if ! printf '%s' "$root_body" | jq -e '.success == true' >/dev/null 2>&1; then
    echo "ERROR: could not post the thread title: $(rc_failure_reason "$root_body")"
    return 0
  fi

  # A success response without usable ids cannot be threaded onto: `jq -r` would
  # render a missing field as the string "null" and the reply would be posted
  # with tmid "null", detaching it from the title instead of failing.
  root_id=$(printf '%s' "$root_body" | jq -r '.message._id // empty' 2>/dev/null || true)
  room_id=$(printf '%s' "$root_body" | jq -r '.message.rid // empty' 2>/dev/null || true)
  if [ -z "$root_id" ] || [ -z "$room_id" ]; then
    echo "ERROR: the title may have been posted, but the server did not return its id, so the body was not sent. Check $target and add the body by hand."
    return 0
  fi

  # tmid attaches this message to the title's thread. The title is already
  # posted, so a failure here leaves a bare headline in the room: say exactly
  # that, with the id, instead of reporting a clean failure.
  local reply_payload reply_body
  reply_payload=$(jq -n --arg r "$room_id" --arg m "$root_id" --arg t "$body_text" \
    '{roomId:$r, tmid:$m, text:$t}')
  reply_body=$(rc_curl POST "/api/v1/chat.postMessage" -d "$reply_payload")

  if printf '%s' "$reply_body" | jq -e '.success == true' >/dev/null 2>&1; then
    echo "OK: thread posted to $room_id (title $root_id)"
  else
    echo "ERROR: the title was posted ($root_id) but the body failed: $(rc_failure_reason "$reply_body"). Delete it or add the body by hand."
  fi
}

# Subscriptions: every room the user belongs to, with rid, type and name.
# One call, reused by `room` and by the global search.
rc_subscriptions() {
  rc_curl GET "/api/v1/subscriptions.get"
}

# Internal: resolves a target to `roomId<TAB>type`. Never creates a room.
# chat.search requires a roomId; the API does not accept a room name.
# The type is what tells a private group (p) from a channel (c), which the
# message URL depends on. `cmd_room` prints only the id, as the CLI documents.
rc_room_lookup() {
  local target="$1"
  local kind name
  case "$target" in
    @*) kind=d; name="${target#@}" ;;
    \#*) kind=c; name="${target#\#}" ;;
    *)  kind=any; name="$target" ;;
  esac
  rc_subscriptions | jq -r --arg k "$kind" --arg n "$name" '
    if .success == false then "ERROR: \(.error // .message)"
    else
      ([.update[] | select(($k == "any" or (if $k == "c" then .t != "d" else .t == $k end)) and .name == $n)]
       | if length == 0 then "NONE" else "\(.[0].rid)\t\(.[0].t)" end)
    end'
}

# room <@user|#channel> - prints the roomId alone, as documented in the README.
cmd_room() {
  local target="${1:?usage: rc.sh room <@user|#channel>}"
  local found
  found=$(rc_room_lookup "$target")
  case "$found" in
    NONE|ERROR:*) printf '%s\n' "$found" ;;
    *) printf '%s\n' "${found%%$'\t'*}" ;;
  esac
}

# Internal: labels a room id, emitting `label<TAB>type` the way rc_room_lookup does.
# A permalink carries the rid for a DM and a name elsewhere, so the label comes
# from the subscription list rather than from the URL the caller pasted.
# A room the user has left is not in the list: the bare rid is still a truthful
# label, and the message itself was fetched, so this never fails the command.
rc_room_label() {
  local rid="$1"
  rc_subscriptions | jq -r --arg rid "$rid" '
    if .success == false then "\($rid)\t?"
    else
      ([.update[] | select(.rid == $rid)]
       | if length == 0 then "\($rid)\t?"
         elif .[0].t == "d" then "@\(.[0].name)\td"
         else "#\(.[0].name)\t\(.[0].t)" end)
    end'
}

# get <permalink|msgId> - one message by its id, in the TSV shape search emits.
# chat.search cannot reach a message by id, and a pasted permalink names the room
# by id, which no search target accepts. The text is NOT truncated: reading one
# whole message is the point, and its attachments are listed after it.
cmd_get() {
  local arg="${1:?usage: rc.sh get <message-link|message-id>}"
  local id="$arg"
  # A permalink is .../direct/<rid>?msg=<id>; anything else is already an id.
  case "$arg" in
    *[?\&]msg=*) id="${arg##*[?&]msg=}"; id="${id%%&*}" ;;
  esac

  local body
  body=$(rc_curl GET "/api/v1/chat.getMessage?msgId=$(jq -rn --arg i "$id" '$i|@uri')")
  if printf '%s' "$body" | jq -e '.success == false' >/dev/null 2>&1; then
    # A wrong id and a message in a room this account cannot read are the same
    # answer - the server sends a bare {"success":false} with no reason at all.
    # Naming both keeps a caller from reporting "it does not exist" for a
    # message that does exist and is simply out of reach.
    local reason
    reason=$(rc_failure_reason "$body")
    case "$reason" in
      *unreadable*|*"no reason"*|"")
        reason="no such message, or it is in a room this account cannot read" ;;
    esac
    echo "ERROR: $reason"
    return 0
  fi

  local rid
  rid=$(printf '%s' "$body" | jq -r '.message.rid // ""')
  [ -z "$rid" ] && { echo "ERROR: response carried no message"; return 0; }

  local found label rtype path=""
  found=$(rc_room_label "$rid")
  label="${found%%$'\t'*}"
  rtype="${found##*$'\t'}"
  # The room type decides the URL segment: a private group is /group/, not /channel/.
  case "$rtype" in
    d) path="$BASE/direct/$rid" ;;
    p) path="$BASE/group/${label#\#}" ;;
    c) path="$BASE/channel/${label#\#}" ;;
  esac

  printf '%s' "$body" | jq -r --arg label "$label" --arg path "$path" '
    .message
    | [(.ts | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601 | strflocaltime("%Y-%m-%d %H:%M")),
       $label,
       "@\(.u.username // "?")",
       (((.msg // "") | gsub("[\n\t]+"; " "))
        + ((.attachments // [])
           | map(select(.title != null) | " [file: \(.title)]") | join(""))),
       (if $path == "" then "" else "\($path)?msg=\(._id)" end)]
    | @tsv'
}

# Searches ONE already-resolved room.
# Emits TSV: date<TAB>room<TAB>@author<TAB>text<TAB>link
rc_search_room() {
  local rid="$1" term="$2" count="$3" label="$4" path="${5:-}"
  local body query
  query="/api/v1/chat.search?roomId=$rid&searchText=$(jq -rn --arg t "$term" '$t|@uri')&count=$count"
  body=$(rc_curl GET "$query")
  # A one-off connection refusal must not punch a hole in coverage: a second attempt
  # after a short pause recovers the room instead of reporting a gap.
  # jq: `.success // true` yields true when success IS false, because // treats
  # false as absent. It has to be `jq -e '.success == false'`.
  if printf '%s' "$body" | jq -e '.success == false' >/dev/null 2>&1; then
    sleep "${RC_RETRY_DELAY:-0.6}"
    body=$(rc_curl GET "$query")
  fi
  printf '%s' "$body" \
    | jq -r --arg label "$label" --arg path "$path" '
        if .success == false then "ERROR: \(.error // .message // "search refused") in \($label)" else
        (.messages // [])[]
        | select(.msg != null and .msg != "")
        | [(.ts | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601 | strflocaltime("%Y-%m-%d %H:%M")),
           $label,
           "@\(.u.username // "?")",
           (.msg | gsub("[\n\t]+"; " ")
                 | if length > 300 then .[0:300] + " [...]" else . end),
           (if $path == "" then "" else "\($path)?msg=\(._id)" end)]
        | @tsv
        end'
}

# search <term> [target] [count]
# With a target: searches that room only. Without: scans the most recently active open rooms.
# There is no global search in the REST API - chat.search is always per room.
cmd_search() {
  local term="${1:?usage: rc.sh search <term> [@user|#channel] [count]}"
  local target="${2:-}"
  local count="${3:-20}"

  # search <term> <count> with no target: a number in the target slot is the count.
  if [[ "$target" =~ ^[0-9]+$ ]]; then
    count="$target"
    target=""
  fi

  if [ -n "$target" ]; then
    local found rid rtype
    found=$(rc_room_lookup "$target")
    case "$found" in
      NONE) echo "ERROR: room not found: $target"; return 0 ;;
      ERROR:*) echo "$found"; return 0 ;;
    esac
    rid="${found%%$'\t'*}"
    rtype="${found##*$'\t'}"
    local out path
    # The room type decides the URL segment: a private group is /group/, not /channel/.
    case "$rtype" in
      d) path="$BASE/direct/${target#@}" ;;
      p) path="$BASE/group/${target#\#}" ;;
      *) path="$BASE/channel/${target#\#}" ;;
    esac
    out=$(rc_search_room "$rid" "$term" "$count" "$target" "$path")
    [ -n "$out" ] && printf '%s\n' "$out" || echo "NONE"
    return 0
  fi

  # Global: open rooms, most recently active first. One request per room, so a
  # large account (hundreds of subscriptions) is expensive to scan in full.
  # RC_SEARCH_KIND=channels scans channels and groups only, for "which channel"
  # questions - that way the answer covers all of them, not just the most recent ones.
  local scan="${RC_SEARCH_ROOMS:-40}"
  [ "${RC_SEARCH_KIND:-}" = "channels" ] && scan="${RC_SEARCH_ROOMS:-200}"
  local subs
  subs=$(rc_subscriptions)
  # No .update means there is nothing to scan: network failure, API error or an unexpected body.
  if [ "$(printf '%s' "$subs" | jq -r 'if (.success == false) or (.update | type) != "array" then "bad" else "ok" end' 2>/dev/null)" != "ok" ]; then
    printf '%s' "$subs" | jq -r '"ERROR: \(.error // .message // "unexpected response while listing rooms")"' 2>/dev/null \
      || echo "ERROR: unreadable response while listing rooms"
    return 0
  fi

  # A per-room error must not vanish in the sort/head of results: it is printed separately, first.
  local raw results errs rooms
  rooms=$(printf '%s' "$subs" \
    | jq -r --argjson n "$scan" --arg kind "${RC_SEARCH_KIND:-all}" --arg base "$BASE" '
        [.update[] | select(.open == true and ($kind != "channels" or .t != "d"))]
        | sort_by(._updatedAt) | reverse | .[0:$n][]
        # Discussions (they carry prid) and private groups have name = generated id;
        # the readable title lives in fname. The link always uses name, which is how the server routes.
        | . as $s
        | (if .t == "d" then "@\(.name)"
           elif .prid then "discussion:\(.fname // .name)"
           elif (.name | test("^[A-Za-z0-9]{17,}$")) and (.fname // "") != "" then "#\(.fname)"
           else "#\(.name)" end) as $label
        | (if .t == "d" then "\($base)/direct/\(.name)"
           elif .t == "p" then "\($base)/group/\(.name)"
           else "\($base)/channel/\(.name)" end) as $path
        | "\($s.rid)\t\($label)\t\($path)"')

  raw=$(printf '%s\n' "$rooms" | grep . \
    | { while IFS=$'\t' read -r rid label path; do
          if [ "$RC_CAN_PARALLEL" -eq 1 ]; then
            # In parallel: scanning dozens of rooms serially is slow, and one slow room stalls everything.
            rc_search_room "$rid" "$term" "$count" "$label" "$path" &
            # High concurrency makes the server refuse connections wholesale (http 000 across
            # every room for several seconds). Three at a time was stable on the tested server.
            while [ "$(jobs -rp | wc -l)" -ge "${RC_SEARCH_JOBS:-3}" ]; do wait -n 2>/dev/null || break; done
          else
            # bash < 4.3 (stock macOS) has no `wait -n`, so the throttle cannot work.
            # Serial is slower but never floods the server into refusing every connection.
            rc_search_room "$rid" "$term" "$count" "$label" "$path"
          fi
          # Back-to-back scans accumulate refusals; a short pause between rooms keeps
          # coverage complete at no noticeable cost to the total.
          sleep "${RC_SEARCH_DELAY:-0.08}"
        done
        wait; })

  errs=$(printf '%s\n' "$raw" | grep '^ERROR:' | sort -u || true)
  results=$(printf '%s\n' "$raw" | grep -v '^ERROR:' | grep . | sort -r | head -n "$count" || true)

  # Explicit coverage: without it a failed room becomes silence, and the answer
  # "it is in no channel" goes out with confidence the scan never earned.
  local total failed
  total=$(printf '%s\n' "$rooms" | grep -c . || true)
  failed=$(printf '%s\n' "$errs" | grep -c . || true)
  if [ "$failed" -gt 0 ]; then
    echo "WARNING: scanned $((total - failed)) of $total rooms; $failed failed, coverage is incomplete"
    printf '%s\n' "$errs"
  fi

  if [ -n "$results" ]; then
    printf '%s\n' "$results"
  elif [ "$failed" -eq 0 ]; then
    echo "NONE"
  fi
}

case "${1:-}" in
  setup)     shift; cmd_setup "$@" ;;
  whoami)    shift; cmd_whoami "$@" ;;
  find)      shift; cmd_find "$@" ;;
  room)      shift; cmd_room "$@" ;;
  get)       shift; cmd_get "$@" ;;
  search)    shift; cmd_search "$@" ;;
  send)      shift; cmd_send "$@" ;;
  send-file) shift; cmd_send_file "$@" ;;
  send-thread) shift; cmd_send_thread "$@" ;;
  *) echo "usage: rc.sh {setup|whoami|find <term>|room <target>|get <link|id>|search <term> [target] [count]|send <target> <text>|send-file <target> <file>|send-thread <target> <title> <body-file>}" >&2; exit 1 ;;
esac
