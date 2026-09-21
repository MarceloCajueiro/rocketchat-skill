# Build this skill yourself

This repository ships a working Rocket.Chat skill. If you would rather have your agent build its own - adapted to your harness, your language, your conventions - paste the prompt below into a skill builder.

**In Claude Desktop or claude.ai:** Settings → Capabilities → Skills → **Create skill**, then paste it.
**In Claude Code:** run `/skill-creator` and paste it, or just paste it into a normal session and ask for a skill.

Everything below the line is the prompt. It describes *what* the skill must do and the API facts that are expensive to discover; it deliberately does not prescribe a language or a file layout, so the builder can choose what fits your environment.

The facts in it were measured against a live Rocket.Chat server, not read from documentation. Several contradict what the API appears to do at first glance.

---

## Build a Rocket.Chat skill

Build me an agent skill that lets me search and send Rocket.Chat messages from my terminal, driven by plain language. I want to ask "which channel has that message about the unified repos?" or "tell Jane the release slipped to Friday" and have it work.

Decide the implementation yourself - language, structure, how the credentials are stored. What follows is the behaviour I need and the things about this API that will cost you a day if you discover them the hard way.

### Capabilities

**1. Search messages.**
- Scoped to one person or one channel, which is fast and should be the default when a target is named.
- Across many rooms, when no target is named.
- A "which channel is it in" mode that covers every channel, group and discussion, so the answer can be definitive rather than "among the ones I happened to check".
- Each result needs: date, room, author, the text, and a URL that opens that exact message. That URL is the most useful part of the output - it is what turns an answer into something the reader can act on.

**2. Send a message** to a person or a channel, including long or multi-line text.

**3. Post a long announcement as a thread**: a short headline visible in the channel, with the full text inside the thread behind it. Pasting a long announcement directly into a channel floods everyone's screen; this is the shape people actually use.

**4. Look up a user** by first name or partial name, so "message Jane" can be resolved to a username.

**5. Store credentials once**, then work without further setup. A Rocket.Chat personal access token, the user id that comes with it, and the server URL.

### API facts, measured — these shape the design

**There is no global search.** `chat.search` requires a `roomId`. "Search everywhere" can only be a loop over the user's rooms, one request per room. This is the single most consequential fact: scanning is the expensive operation, and any claim of completeness is a claim about how many rooms you scanned.

**Search is OR, and unmatched terms are ignored.** Four candidate terms cost one request, not four, and one wrong term does not zero the result. It also means passing a user's whole sentence returns noise that looks like an answer - the skill should extract a few distinctive words instead.

**It stems, in English, whatever language the messages are in.** `deploy`, `deploys` and `deploying` return the same results, because they reduce to one root. So do `unification` and `unific`. But it is not prefix matching - `deplo` finds nothing - and the stemmer only knows English, so inflections of a word in another language are unrelated terms to it. If your team writes in Portuguese, `unificar` and `unificado` are two separate searches, and a key verb is worth trying in more than one form.

**Accents and case are ignored.** `migracao`, `migração` and `Migração` are the same query.

**Quoted phrases and exclusion work.** `"exact phrase"` narrows; `-word` excludes; `from:username` filters by author, combined with AND.

**A message URL depends on the room type.** Direct messages, public channels and private groups take different URL segments. Getting this from the `@`/`#` prefix the user typed is wrong - a private group looks like a channel. The room's own type is the only reliable source.

**Discussions and private groups often have a generated id as their name**, with the human-readable title in a separate field. Labelling a result with the raw name produces something unreadable.

**Resolving a person to a room must not create one.** The obvious call for "get me the DM with X" creates the conversation as a side effect. Searching someone you have never messaged should report that there is no room, not quietly open a conversation with them.

**Posting a thread is two calls, not one.** There is no atomic "post with a body". You post the title, then post the body as a reply carrying the title's id. This has a consequence you must design for - see below.

### Failure modes that matter more than the happy path

These are the ones that made the difference between a skill that works and one that lies.

**A stranded headline.** Because a thread is two calls, the title can post and the body fail, leaving a headline in a public channel with nothing behind it. Everyone sees it. The skill must detect this, report it, and name the title's message id so it can be deleted. Reporting a clean failure when a message is live in a channel is the worst possible outcome. Correspondingly: validate everything local - the body exists, is readable, is not empty - **before** the first call, because a problem found afterwards is a problem that has already gone public. And do not retry the whole operation: that posts a second headline.

**Silence that reads as absence.** If a scan covers 51 of 64 rooms because some requests failed, saying nothing turns "I could not check" into "it does not exist". State the coverage and name what failed. A slow, honest answer beats a fast, confident wrong one.

**An error page is not JSON.** A proxy in front of the server answers with HTML when something goes wrong. Any code that assumes every response parses as JSON will crash on it - and it crashes exactly when something has gone wrong, which is when the user most needs a usable message.

**A "successful" response with missing fields.** A success flag does not guarantee the payload you expect. If you read an id that is not there, many languages and tools will hand you a string like `"null"` and happily send it - producing a message attached to nothing.

**Concurrency makes it slower.** Scanning rooms in parallel is the obvious optimisation, and past a low limit the server starts refusing connections wholesale - every room fails for several seconds. Three at a time, with a brief pause between rooms, measured faster end to end than eight. Measure this yourself rather than trusting the number; the point is that more parallelism is not monotonically better.

### How the skill should behave

**Confirm before sending.** A message goes out in my name and cannot be recalled. Draft it, show me, wait. Never skip this. Searching needs no confirmation - it changes nothing.

**Write in my voice**, in my language, the way I'd message a colleague: informal, direct, no corporate greeting, no signature. When I dictate exact words in quotes, send exactly those.

**Answer the question, then show the evidence.** For "which channel is it in", the first line should be the answer with the link - not a list I have to read. Cap it at about five results and offer the rest; never paste raw output at me.

**A question is not a search term.** "Which channel has that message about the unified product repos" contains no word anyone typed. Pull out the distinctive nouns and add the jargon the team would actually use. And notice when a result is my own question rather than the answer to it.

**Never print the token**, not even in debug output. Never ask me to paste it into a chat, where it lands in a transcript - prompt for it with hidden input, or take it from the environment.

### What I want out of it

Working code, plus a test suite I can trust. Tests that exercise the failure paths above, not just the happy path, and a way to run them without touching a real server - so I can check they can actually fail rather than passing for the wrong reason.
