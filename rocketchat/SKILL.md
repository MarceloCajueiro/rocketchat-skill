---
name: rocketchat
description: Search and send Rocket.Chat messages from the terminal via the REST API. Use when the user wants to find something said in chat ("what did X say about Y", "which channel has that message about Z", "search the chat", "find that thread"), or to send a message to a person or channel ("message X", "tell the team", "ask X about Y", "post this in #channel"), including posting a long announcement as a thread - a headline in the room with the detail behind it.
---

# Rocket.Chat from the terminal

All access goes through `rc.sh`, in this skill's directory.
**Use the path of the directory this file was loaded from** - it is already known, and it is always correct.

If you need to locate it anyway, check the known install paths in order and take the first that exists.
Never use `find ~`: it takes almost a minute on a real home directory and can return an unrelated or outdated copy.
Do not use `ls` for this either - it sorts its arguments, so the first path listed is not the one you get back.

```bash
RC=
for p in "$HOME"/.claude/skills/rocketchat/rc.sh \
         "$HOME"/.agents/skills/rocketchat/rc.sh \
         "$HOME"/.codex/skills/rocketchat/rc.sh \
         "$HOME"/mnt/.skills/rocketchat/rc.sh \
         .agents/skills/rocketchat/rc.sh \
         .claude/skills/rocketchat/rc.sh; do
  [ -f "$p" ] && { RC=$p; break; }
done
[ -n "$RC" ] || { echo "ERROR: rc.sh not found; install with 'npx skills add MarceloCajueiro/rocketchat-skill'" >&2; exit 1; }
```

```bash
rc.sh setup                          # one-time: stores credentials
rc.sh whoami                         # verify credentials, prints "Name (@username)"
rc.sh find jane                      # look up users: name<TAB>@username<TAB>status
rc.sh search "deploy" @jane.doe      # search one DM
rc.sh search "release" "#general" 10 # search a channel, 10 results
rc.sh search "postgres upgrade"      # search recently active rooms
rc.sh send @jane.doe "text"          # send a DM (creates the conversation if needed)
rc.sh send "#general" "text"         # send to a channel
rc.sh send-file @jane.doe draft.txt  # long or multi-line message, read from a file
rc.sh send-thread "#general" "Headline" body.md   # headline in the room, detail in its thread
```

Output is TSV, one line per message: `date<TAB>room<TAB>@author<TAB>text<TAB>link`.
The link opens that exact message. Rooms appear as `@user`, `#channel` or `discussion:<title>`.
`NONE` when there is no result, `ERROR: <reason>` when a call fails.
Text longer than 300 characters is truncated with ` [...]`.

If any command answers `ERROR: no credentials`, tell the user to run `rc.sh setup`.

**First check whether the credentials merely sit somewhere else.** In a sandbox that generates a `$HOME` per session (Claude Desktop's Cowork, for instance) the config file exists under the real user's home, reachable through a mount, and running setup again would write a copy that dies with the session.

You are in that situation when `$HOME` looks generated rather than personal - a path like `/sessions/<name>` instead of `/Users/<name>` or `/home/<name>`. When it does, look for the real config before asking for anything:

```bash
# The mount directory can be a dotted name, which `*` does not match.
find /mnt -maxdepth 6 -type d -path '*/shared/*/.config/rocketchat' 2>/dev/null | head -1
```

If that finds a directory, export `XDG_CONFIG_HOME` to its parent and retry. If it finds nothing, fall back to asking the user to run setup.
Never ask them to paste a token into the chat - the setup prompt hides the input, a chat message would land in the transcript.

---

# Searching

## 1. A question is not a search term

The request is almost never the literal wording of the message.
"Which channel has that message about the unified product repos" contains no word anyone actually typed.

**Never pass the user's sentence to `search`.**
Search is OR, so the full sentence matches anything containing a common word and returns noise that looks like an answer.

1. **Extract 2 to 4 distinctive nouns.** Drop articles, prepositions and filler (`that`, `about`, `the`, `thing`, `message`).
2. **Add the jargon the team would actually type**, even if it is absent from the request. This is the step that finds the message: for "unified repositories", the terms that work may be `monorepo` or `umbrella`.
3. **Put them in a single term.** Since search is OR and ignores non-matching words, 4 candidates cost one request, not four: `"monorepo umbrella unified repositories"`.
4. **Ask for a `count` of 20 to 30.** The cap of 5 applies to your reply, not to the search - you need material to judge relevance.
5. **Discard the question itself.** A hit that echoes the request's wording, or is authored by whoever asked, is the question and not the answer. Its date is an upper bound: the message being sought predates it.

If OR brings too much noise, narrow with a quoted phrase or `-word`. See the table below.

## 2. Pick the scope

**A person or channel is named: search scoped.** One request, well under a second.

Resolve the target in this order:

- Explicit username (contains a dot, or the user said the username): use directly.
- Known nickname: check the contacts file, `${XDG_CONFIG_HOME:-~/.config}/rocketchat/contacts.md`, if it exists.
- First name only: run `rc.sh find <name>`. With 2 or more results, ask the user which one - never pick on their behalf.

**"Which channel", "where", "in what group" → scan every channel** with `RC_SEARCH_KIND=channels`.
This covers all channels, groups and discussions, so the answer is definitive rather than "among the ones I looked at".
On an account with a few dozen channels it takes roughly ten seconds.

**No person, no channel, no question of place → global.** Scans the most recently active open rooms (40 by default, `RC_SEARCH_ROOMS` to change).

**If the output contains `WARNING: ... coverage is incomplete`, say so in your reply.**
Each `ERROR:` line names the room that failed.
Never conclude "it is in no channel" while that warning is on screen: state how many rooms were scanned and offer to retry the failed ones scoped.
Back-to-back scans make the server refuse connections; if failures pile up, wait about a minute before retrying.

## 3. Write the term

The server uses MongoDB text search. Measured behavior:

| Rule | What it means in practice |
|---|---|
| Multiple terms are **OR**, and a term with no match is ignored | 4 candidates cost one request; one wrong term does not zero the search |
| **Stems in English**, whatever language the messages are in | `deploy`, `deploys` and `deploying` return the same results. So do `unification` and `unific` |
| Not prefix matching | `deplo` finds nothing. A fragment only works when it happens to be the English stem |
| The stemmer knows only English | In a Portuguese team, `unificar` and `unificado` are separate searches - try more than one form of a key verb |
| **Ignores accents and case** | `migracao` = `migração` = `Migração` |
| `"in quotes"` = exact phrase | The precision tool when OR brings noise |
| `-word` excludes | `deploy -staging` returns deploys that are not about staging |
| `from:username` filters by author | Combines with AND: `from:x` plus a rare term returns `NONE` easily. When investigating, keep only the `from:` |

## 4. Present the result

**Answer the question first, in one line, with the link.**
Only then list what supports it. Never paste raw TSV.

For "which channel":

```
It is in #engineering, Sep 16, from @jane.doe:
https://chat.example.com/channel/engineering?msg=abc123

> We opened the AI agent instruction base in both umbrella repos [...]
```

For "what was said about X", one line per message, newest first:

```
Sep 21 09:13  #general  @jane.doe: the release goes out around noon
```

**At most 5 messages in the reply**, even when the search found more - say how many remain and offer to show the rest.
When every hit is a DM and the question was about a channel, say so: "not in any channel, only in DMs with @x and @y" is a valid, honest answer.

## API limit worth knowing

There is no global search in Rocket.Chat: `chat.search` requires a `roomId`.
The global mode here is a loop over rooms, not a server-side call.
That is why it sees only the rooms it scanned, and a message in an archived or long-idle room may not appear - search scoped in that case.

---

# Sending

## Required flow

1. **Resolve the recipient** (same order as searching, above).
2. **Draft the message.**
3. **Show the draft and wait for approval.**
4. **Send and report.**

**Never skip step 3.**
A message to a colleague is irreversible and goes out in the user's name.

## Drafting

The user describes the subject; they do not dictate the text.
Write in the user's language, in their voice: informal peer tone, straight to the point.
No corporate greeting, no "hope you're well", no signature.

Rocket.Chat markdown works: `*bold*`, `_italic_`, `` `code` ``, and triple-backtick blocks.

If the user dictates exact wording in quotes, send exactly that.

## Confirming and sending

Show the recipient and the full text, and ask whether to send.
If they ask for changes, redo it and show again.

One-line text: `rc.sh send @user "text"`.
Long, multi-line or punctuation-heavy text: write it to a temporary file and use `rc.sh send-file`.
That avoids shell escaping problems.

Output is `OK: sent to <roomId>` or `ERROR: <reason>`. Report what actually happened.

## Announcing something long in a channel: use a thread

A long announcement pasted straight into a channel floods everyone's screen.
The shape people actually use is a **headline in the room, with the detail inside its thread**: one short line everybody sees, and the full text unfolded only by whoever opens it.

```bash
rc.sh send-thread "#general" "🚀 *Feature X is live* - details in the thread" body.md
```

The title is posted as a normal message; the body file becomes the first reply inside its thread.

**Use this instead of `send-file` whenever the message is long and goes to a channel** - an announcement, a release note, an instruction set, anything with paragraphs or a list. A direct message to one person rarely needs it.

Write the title so it stands alone: what happened, and who needs to act. "Details in the thread" at the end tells the reader where the rest is.

Confirm before sending, exactly as with any other message, and show **both** parts: the title as the room will see it, and the body.

Output is `OK: thread posted to <roomId> (title <id>)`.

Every local problem - a missing, unreadable or empty body file - is refused before anything is posted, so a bad path cannot strand a headline.

What cannot be prevented is the server accepting the title and then refusing the body. The output says so and names the title's id:

```
ERROR: the title was posted (abc123) but the body failed: <reason>. Delete it or add the body by hand.
```

The room is left showing a headline with nothing behind it. Report that plainly, quote the id, and offer to delete it or post the body by hand. Do not describe it as a clean failure, and **do not simply re-run the command** - that would post a second headline.

When the user confirms a nickname you had to resolve, append a line to the contacts file so the next session skips the lookup.

---

# Common errors

- `ERROR: no credentials` → run `rc.sh setup`.
- `unauthorized` or `You must be logged in` → invalid or expired token. Create a new Personal Access Token and run `rc.sh setup` again.
- `totp-required` → the token was created without ticking "Ignore Two Factor Authentication". Create another one with that box checked.
- `ERROR: room not found` → wrong username or channel, **or** a real person the user has never exchanged a DM with. The skill does not create a conversation just to search. Run `rc.sh find` to check the user exists.
- `NONE` on a global search → the room may be outside the scanned window. Raise `RC_SEARCH_ROOMS`, use `RC_SEARCH_KIND=channels`, or search scoped.
- `WARNING: coverage is incomplete` → the server refused some connections. This is not "it does not exist": wait about a minute and retry, or search the named rooms scoped.

Tuning, when needed: `RC_SEARCH_JOBS` (parallelism, default 3 - raising it triggers wholesale refusals), `RC_SEARCH_DELAY`, `RC_SEARCH_ROOMS`, `RC_HTTP_TIMEOUT`.

Never print the token value, not even in debug output.
