# Claybrick — Claude as a developer inside Roblox Studio

*[Versão em português](README.md)*

A **plugin** gives Claude real tools inside Roblox Studio: read the hierarchy,
write scripts, **run them to test**, and build entire systems. A **local bridge
server** in Python talks to Claude through two backends:

| Backend | Authentication | Cost |
|---|---|---|
| **API** | Anthropic API key | Pay per token |
| **Subscription** | Claude Code signed into your Pro/Max account (Claude Agent SDK) | Subscription quota |

```
┌──────────────────┐     job queue       ┌───────────────────┐
│  Plugin (Luau)   │ ─── /session/* ───▶ │  Server (Python)  │
│  Roblox Studio   │ ◀── long-poll ───── │                   │
│  • chat          │                     │  backend=api ───────▶ Anthropic API
│  • permissions   │                     │  backend=sub ───────▶ Claude Code
│  • runs tools    │                     │                   │   (your subscription)
└──────────────────┘                     └───────────────────┘
```

Claude **requests** a tool; the server **queues** it; the plugin **asks for
permission** (depending on the mode), **runs** it in Studio and returns the result.

---

## Installation

Requirements: Windows, Roblox Studio and Python 3.10+.

In PowerShell:

```powershell
irm https://claybrick.online/install.ps1 | iex
```

The installer downloads Claybrick to `%LOCALAPPDATA%\Claybrick`, creates the
virtual environment and copies the plugin into Studio's Plugins folder. It writes
nothing outside those two folders.

### Configure a backend

Open `%LOCALAPPDATA%\Claybrick\server\.env`:

**API backend:** set `ANTHROPIC_API_KEY` and leave `DEFAULT_BACKEND=api`.

**Subscription backend:**
1. Keep `ANTHROPIC_API_KEY` **in `.env` only**, never as a system environment
   variable — otherwise Claude Code inherits it and bills the API instead of the
   subscription.
2. Sign into Claude Code once:
   ```powershell
   npm install -g @anthropic-ai/claude-code
   claude   # choose "Log in with Claude", not the API option
   ```
3. Set `DEFAULT_BACKEND=subscription` (you can switch inside the plugin).

> In subscription mode the agent is locked to the Roblox tools
> (`mcp__roblox__*`). Bash/Read/Write/Edit are blocked — it does **not** touch
> your filesystem or your terminal.
>
> The subscription has a quota per time window, and automated use burns through
> it quickly.

### Run

```powershell
cd "$env:LOCALAPPDATA\Claybrick\server"
.\run.ps1
```

It listens on `http://127.0.0.1:8787`. Check `http://127.0.0.1:8787/health` — it
shows the available backends and whether the Roblox API dump was indexed.

With the server up, open Studio: **Plugins** tab → **Claude Agent**. On the first
action, **allow** script/HTTP access.

The port is deliberately not 8000: that one is among the most contested there is,
and on Windows system services can hold it in a way that makes the bind fail with
"access denied". If you need to change it, edit `PORT` in `.env` **and** the URL
box in the plugin — both sides must match. If the port is taken, the server
doesn't fail silently: it tells you which port is free and what to change.

## Permissions

This is the important part. The button at the top cycles three modes:

| Mode | Read | Write | Execute (`run_code`, playtest) |
|---|---|---|---|
| **Ask** (default) | direct | asks | asks |
| **Accept edits** | direct | direct | asks |
| **No permissions** | direct | direct | direct |

Each request opens a card with the tool name and its arguments:
**Allow** · **Always allow** (remembers that tool) · **Deny**.

When denying you can give a reason — it goes back to Claude as an error result,
and it adapts instead of stalling or insisting. To forget the "always allow"
entries, use ⚙ → *Forget "always allow"*.

**Ctrl+Z undoes** writes — every tool call (and every `batch`) is an undo
waypoint. `run_code` and `run_playtest` are the exception: not everything they do
is reversible.

## Using it

- "List what's in the Workspace."
- "Create a red neon platform, 20x1x20, at (0, 10, 0)."
- "Build a collectible coin system: coins spin, disappear on touch, and score
  points per player. Test it before handing it to me."
- "Open the Main script in ServerScriptService and add error handling."

---

## How it knows what it's doing

- **The real Roblox API.** The server downloads and indexes the official
  `Full-API-Dump.json` for the installed Studio version (682 classes, 351 enums,
  cached in `server/.cache/`). The `lookup_api` tool answers with the properties,
  methods and events that actually exist — flagging the deprecated ones and the
  plugin-only ones.
- **An invented property never passes silently.** If it writes `part.Colour`, the
  write fails, comes back marked as an error, and the server appends the names
  that do exist (`Color`, `BrickColor`) straight from the API dump. The mistake
  becomes a correction in one round trip, instead of becoming a grey brick the
  user discovers later.
- **Static Luau analysis.** `check_syntax` doesn't just compile: it runs
  `luau-lsp` with the Roblox type definitions. It catches the field that doesn't
  exist, the wrong argument type and the wrong return — before anything runs.
  That is what makes the `--!strict` the guides ask for actually worth writing.
- **A ready-made model when one fits.** `search_assets` searches the Creator
  Store by keyword and returns name, ID, creator, votes and whether the model
  contains scripts; `insert_asset` inserts by the ID that came from it.
- **Curated guides** on modern Luau and client-server architecture go into the
  system prompt (`server/agent/knowledge/`).
- **Place context** is injected at the start of the session: name, instance and
  script counts per service, and which capabilities this Studio has.
- **Project memory** (`set_project_memory` / `get_project_memory`) lives in a
  StringValue under `ServerStorage`, inside the place itself — it survives
  restarts and travels with the file.

## How it tests

A ladder, cheapest first:

1. `check_syntax` — syntax **and types**, without running. Instant, no side
   effects.
2. `inspect_space` — measures what was built: real size, loose parts that will
   fall, parts intersecting parts, parts floating in mid-air. It's how an agent
   that cannot see checks its own work.
3. `run_code` with `require` + asserts — tests a ModuleScript **for real**, in
   edit mode, without dirtying the place. This is where most testing should live.
4. `get_output` — reads Studio's Output to see what happened. Each run returns a
   marker, so it can read only what that run produced.
5. `run_playtest` — only when runtime behavior is the thing under test. It is
   **destructive**: `RunService:Stop()` does not restore the place, so whatever
   physics knocked over and scripts created stays.

## Tools

31 in total.

**Read** (never asks) — `get_tree`, `get_place_info`, `get_selection`,
`set_selection`, `get_properties`, `find_instances`, `get_source`,
`search_source`, `lookup_api`, `check_syntax`, `get_output`, `inspect_space`,
`search_assets`, `get_project_memory`

**Write** (asks; undoable) — `create_instance`, `delete_instance`,
`set_property`, `set_source`, `patch_source`, `move_instance`, `rename_instance`,
`clone_instance`, `set_attribute`, `set_tags`, `batch`, `set_project_memory`,
`insert_asset`

**Modeling** (asks; undoable) — `solid_op` (union/subtract/intersect),
`terrain_fill` (real terrain, with `Air` to carve)

**Execute** (asks in nearly every mode) — `run_code`, `run_playtest`

`lookup_api`, `search_assets` and the type-checking half of `check_syntax`
resolve on the server, without a trip to Studio.

`batch` is what makes projects possible: many writes in a single transaction —
one undo, one permission prompt. It also accepts `solid_op`, `terrain_fill` and
`insert_asset`, and resolves `$id` references in any path argument — including
inside lists. So "create the wall, create the opening, subtract one from the
other" is a single transaction.

## Endpoints

| Endpoint | Use |
|---|---|
| `POST /session/message` | `{session_id, message, backend, place_context}` |
| `GET /session/poll?session_id=` | long-poll: `tool`/`text`/`thinking`/`usage`/`compaction`/`done`/`error`/`wait` |
| `POST /session/tool_result` | `{session_id, id, content, is_error}` |
| `POST /session/cancel` | stops the turn without losing the conversation |
| `POST /session/reset` | ends the session |
| `GET /tools` | tools and permission classes |
| `GET /health` | status, backends, API dump, Luau analyzer |

## Layout

```
server/
  app.py                    HTTP shell + session lifecycle
  agent/
    config.py               reads .env without polluting os.environ
    tools.py                the 32 tools + permission classes
    prompt.py               system prompt (identity, method, values)
    knowledge/*.md          Luau and architecture guides
    apidump.py              Full-API-Dump download/index
    assets.py               Creator Store search
    luau_check.py           static analysis (luau-lsp + Roblox types)
    session.py              sessions + tool bridge
    backends.py             api backend (streaming) and subscription
plugin/
  ClaudeStudio.luau         the plugin
  install.ps1               installs into the Plugins folder
```

## Long conversations

A whole project doesn't fit in one context window: every `run_code`, every
`get_tree` comes back as text in the history, and an agentic turn piles that up
fast.

- **Compaction.** Past `COMPACT_AT` tokens (default 150k, minimum 50k), the API
  itself summarizes the older conversation and continues from the summary — the
  chat says so when it happens. Without it the session would die with an error on
  a full context. Only on models that support it: Opus 4.6+, Sonnet 4.6+,
  Sonnet 5, Fable 5.
- **History caching.** A rolling breakpoint at the end of the conversation makes
  the already-seen prefix read at 0.1x the price instead of being reprocessed in
  full on every loop iteration. The counter at the top shows what came from cache.
- **Real cost.** Compaction is an extra model call, and the API's top-level
  `usage` doesn't include it — the number the plugin shows sums all iterations.

## Updating

The install command is also the update command:
`irm https://claybrick.online/install.ps1 | iex`. It replaces server and plugin in
place and **preserves your `.env`**. Then restart Studio — it reads the plugins
folder only at boot (its hot reload exists, but ships disabled), so until you
restart, the old plugin stays in memory.

Nobody has to keep checking for releases: the plugin shows a banner at the top
when there's something new. It distinguishes two cases, which need different
things:

| The banner says | What happened | What's left to do |
|---|---|---|
| *New version X available* | a new release shipped (checked at `claybrick.online/version.json`) | run the command |
| *Plugin out of date · restart Studio* | the installer already ran; disk is new, memory isn't | just restart Studio |

## Security

The bridge has **no password** — and doesn't need one, as long as only it and the
plugin can reach each other. Three things hold that up:

- **It only listens on `127.0.0.1`.** Nothing from outside the machine reaches
  it. If you change `HOST` to `0.0.0.0`, the server shouts at boot: with no
  password, that means anyone on your network can have Claude run code in your
  place.
- **No web page can talk to it.** The plugin isn't a browser — `HttpService`
  sends neither `Origin` nor `Sec-Fetch-*`. A request carrying those headers came
  from a website, and gets a 403. (CORS alone wouldn't be enough: CORS decides who
  *reads the response*, not who *sends the request* — the side effect would happen
  even with the browser throwing the response away.)
- **The key never leaves `.env`.** `.env` is not included in the distributed
  package, and the installer preserves yours on update.

In subscription mode the agent is still locked to `mcp__roblox__*`: Bash, Read,
Write and Edit are blocked, so it doesn't touch your filesystem.

What remains true: any program **already running on your machine** can talk to
the bridge. At that point the problem is no longer Claybrick.

## Notes and limits

- Conversation state lives in the server's memory; restarting clears sessions.
  **Project memory** doesn't — it lives in the place.
- The Luau analyzer (`luau-lsp`, ~17 MB) is downloaded on the first syntax check
  and kept in `server/.cache/`. With no network, `check_syntax` falls back to
  syntax only — and says so in its answer, instead of pretending it checked types.
- Paths use `.` as the separator — avoid object names containing `.`.
- Studio only (plugins don't run in a published game).
- `run_code` runs with plugin permissions. In **No permissions** mode it executes
  without asking; use it with judgment.

## License

See [LICENSE](LICENSE).
