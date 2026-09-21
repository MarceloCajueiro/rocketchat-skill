# rocketchat-skill

An agent skill that lets your coding agent search and send Rocket.Chat messages from the terminal.

Ask in plain language and the agent does the rest:

> which channel has that message about the unified product repos?

> what did Jane say about the postgres upgrade?

> message Jane that the release is delayed to Friday

It works with any agent that supports skills - Claude Code, Codex, Cursor, OpenCode and others.

**Using Claude Desktop?** It is not one runtime but three, and the answer differs for each. See [Claude Desktop](#claude-desktop) below before installing.

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

# or three lines on stdin, in this order:
printf '%s\n' "https://chat.example.com" "YOUR_ID" "YOUR_TOKEN" | rc.sh setup
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

## Claude Desktop

Claude Desktop is a single app containing three runtimes, and this skill's verdict differs for each. *Checked 2026-09-21 against Claude Desktop 2.2553.1 on macOS; this area moves fast.*

| Where you are typing | Does this skill work? |
|---|---|
| **Claude Code tab** | **Yes, as-is.** `npx skills add` is the whole recipe |
| **Cowork** (local VM) | **Probably, with one environment variable** - untested, see below |
| **Chat window** (Customize → Skills) | **No, and no fix exists.** Use an MCP server instead |

### The chat window cannot run this skill

Skills in the chat window execute in a sandbox, and a sandbox is the wrong place for this skill twice over: `rc.sh` cannot reach your Rocket.Chat server, and it cannot read your credentials at `~/.config/rocketchat/config`. Either blocker is fatal on its own.

Anthropic documents the sandbox running code for the API as having **no outbound network access and full isolation from the host** ([code execution tool docs](https://platform.claude.com/docs/en/agents-and-tools/tool-use/code-execution-tool)). That page covers the API, not the Desktop chat window specifically, so the restriction here is reasoned by analogy rather than quoted from a page about Skills. Nobody has published a way to reach a private server from a chat-window skill, and the mechanism would have to change for one to exist.

This is not a plan limitation - custom skills are available on every tier, including Free. No upgrade changes it. A bash script that talks to a private server is simply the wrong shape for that sandbox.

**The route that does work there is a local MCP server**, which Claude Desktop runs as a normal process on your machine, with your filesystem and your network. That server does not exist yet - see [#3](https://github.com/MarceloCajueiro/rocketchat-skill/issues/3).

### Cowork: one environment variable, and three things nobody has checked yet

Cowork runs a local Ubuntu VM that *does* have network access and *does* mount your home directory. But `$HOME` inside the VM is a generated per-session path, not yours, so the credentials written by `rc.sh setup` are not where the script looks.

Point it at your real config directory:

```bash
export XDG_CONFIG_HOME=/mnt/.virtiofs-root/shared/Users/<you>/.config
```

Setting the three credential variables directly also works - environment always wins over the config file - but then the token lives in a launch environment instead of the `600`-mode file it already sits in.

Running `rc.sh setup` inside the VM is the wrong move: `$HOME` is regenerated each session, so those credentials die with it.

**This path is reasoned from logs, not executed.** Three things are unconfirmed, and any one of them would break it:

- **`jq`.** The image is Ubuntu 22.04, which ships `curl` but not `jq`, and the script hard-fails without it. Likely fix: `sudo apt-get install -y jq`.
- **The mount path** above is what the host logs show. Whether a skill process sees that exact path, and whether it survives Desktop updates, is unknown.
- **Whether Cowork runs a skill's scripts at all**, rather than only reading `SKILL.md` as prose.

One command settles all three. In a Cowork session, with `XDG_CONFIG_HOME` set:

```bash
rc.sh whoami
```

Your name and handle means it works. `jq: command not found` means install it. A path or credentials error means the mount path is wrong. **If you try this, please report the result in an issue** - it turns this section from reasoning into fact.

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

## Tests

```bash
brew install bats-core      # or your platform's package
bats tests/rc.bats
RC_BASH=/bin/bash bats tests/rc.bats    # exercise the bash 3.2 path
```

The suite never touches the network: `tests/bin/curl` shadows `curl` on `PATH` and answers from fixtures, which also lets a test inject a per-room failure and assert on the resulting call log.

It is checked against the commit whose defects it covers - `RC=<old rc.sh> SKILL_MD=<old SKILL.md> bats tests/rc.bats` must go red. A test that cannot fail proves nothing, so CI asserts that too.

The documented install-path lookup in `SKILL.md` is extracted from the file and executed, so the instructions the agent follows cannot silently drift from what actually works.

## Design notes

**There is no global search in the Rocket.Chat REST API.** `chat.search` requires a `roomId`, so "search everywhere" is a loop over your rooms, one request each. That shapes everything else: scanning is the expensive part, and coverage is a real property worth reporting.

**Coverage is stated, never assumed.** If some rooms fail, the output says `WARNING: scanned 51 of 64 rooms` and names each failure. Silence about a failed room would turn into "that message does not exist", which is worse than a slow answer.

**Searching never creates anything.** Resolving `@someone` reads your subscriptions rather than calling `im.create`, so searching a person you have never messaged reports "room not found" instead of quietly opening a conversation with them.

## License

MIT
