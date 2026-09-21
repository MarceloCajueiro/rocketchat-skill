# rocketchat-skill

An agent skill that lets your coding agent search and send Rocket.Chat messages from the terminal.

Ask in plain language and the agent does the rest:

> which channel has that message about the unified product repos?

> what did Jane say about the postgres upgrade?

> message Jane that the release is delayed to Friday

It works with any agent that supports skills - Claude Code, Codex, Cursor, OpenCode and others.

## Install

```bash
npx skills add MarceloCajueiro/rocketchat-skill
```

The installer asks which agent to install into. Then set up credentials once:

```bash
# the path is printed by the installer; in Claude Code it is:
~/.claude/skills/rocketchat/rc.sh setup
```

It prompts for the server URL, your user id and a token, hiding the token as you type.
Non-interactive, for a dotfiles or provisioning script:

```bash
rc.sh setup --url https://chat.example.com --user-id YOUR_ID --token YOUR_TOKEN
```

Credentials are stored in `${XDG_CONFIG_HOME:-~/.config}/rocketchat/config` with mode `600`.
Environment variables of the same name (`ROCKETCHAT_URL`, `ROCKETCHAT_USER_ID`, `ROCKETCHAT_AUTH_TOKEN`) always take precedence, which is handy in CI.

Verify:

```bash
rc.sh whoami     # prints "Your Name (@your.username)"
```

## Getting a token

In Rocket.Chat, in the browser:

1. Click your avatar, top left.
2. **My Account** → **Personal Access Tokens**.
3. Name it (`agent`, for instance).
4. **Tick "Ignore Two Factor Authentication".** Without it every API call demands a TOTP code and the skill cannot work.
5. Click **Add**.
6. The screen shows the **token** and **your user id**. Copy both now - the token is never shown again.

## Requirements

- `bash`, `curl` and `jq`
- Rocket.Chat server with the REST API enabled (the default)

Parallel channel scanning needs bash ≥ 4.3. On stock macOS (bash 3.2) the skill automatically falls back to a serial scan, which is slower but safe. `brew install bash` if you want the faster path.

## What the agent can do

| Ask | What happens |
|---|---|
| "which channel has the message about X" | Scans every channel, group and discussion, and answers with a direct link |
| "what did Jane say about X" | Searches that DM and summarizes, newest first |
| "search the chat for X" | Scans the most recently active rooms |
| "message Jane that ..." | Drafts the message, **shows it to you, waits for approval**, then sends |

Sending always asks for confirmation first. A message goes out in your name and cannot be recalled.

## CLI reference

The agent drives this for you, but it is a normal script:

```bash
rc.sh setup                            # store credentials
rc.sh whoami                           # verify credentials
rc.sh find jane                        # look up users
rc.sh room @jane.doe                   # resolve a roomId
rc.sh search "deploy" @jane.doe        # search one DM
rc.sh search "release" "#general" 10   # search a channel
rc.sh search "postgres" 20             # search recently active rooms
rc.sh send @jane.doe "text"            # send a DM
rc.sh send "#general" "text"           # send to a channel
rc.sh send-file @jane.doe draft.txt    # send long text from a file
```

Search output is TSV: `date<TAB>room<TAB>@author<TAB>text<TAB>link`.

### Search syntax

The server uses MongoDB text search:

- Multiple words are **OR**, and a word with no match is ignored
- Matches **whole words**: `unific` will not find "unified"
- Accents and case are ignored
- `"in quotes"` is an exact phrase
- `-word` excludes
- `from:username` filters by author

### Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `RC_SEARCH_KIND` | `all` | `channels` scans only channels, groups and discussions |
| `RC_SEARCH_ROOMS` | `40` | How many rooms a global scan covers |
| `RC_SEARCH_JOBS` | `3` | Parallel requests. Raising it makes servers refuse connections |
| `RC_SEARCH_DELAY` | `0.08` | Pause between rooms, in seconds |
| `RC_HTTP_TIMEOUT` | `20` | Per-request timeout, in seconds |

## Design notes

**There is no global search in the Rocket.Chat REST API.** `chat.search` requires a `roomId`, so "search everywhere" is a loop over your rooms, one request each. That shapes everything else: scanning is the expensive part, and coverage is a real property worth reporting.

**Coverage is stated, never assumed.** If some rooms fail, the output says `WARNING: scanned 51 of 64 rooms` and names each failure. Silence about a failed room would turn into "that message does not exist", which is worse than a slow answer.

**Searching never creates anything.** Resolving `@someone` reads your subscriptions rather than calling `im.create`, so searching a person you have never messaged reports "room not found" instead of quietly opening a conversation with them.

## License

MIT
