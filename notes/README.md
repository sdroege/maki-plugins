# notes

Session-scoped notes for maki: a `notes` tool the model uses to save
session state that must survive compaction, plus a `/notes` picker for the
user.

Notes live under `<state>/sessions/data/<session-id>/notes/`, so they
survive compaction and session resume, and are deleted together with the
session.
For cross-session, project-scoped notes use the built-in `memory` tool.

## What it adds

- `notes` tool: `list`, `read` (with line ranges), `search`, `append`,
  `write`. Strongly consistent local files, capped at 1 MiB per note.
  Limit-like arguments are clamped, never rejected. No model-facing delete.
- A `compact` tool the model calls at a natural boundary to summarize the
  session itself, with the same free-form guidance input as `/compact`. A
  subagent calling it compacts its own conversation.
- A `context_usage` tool reporting the calling agent's own context: tokens in
  use, window size, percentage. A subagent sees its own window, never the
  parent's. Pairs with `compact`. Needs maki newer than 0.7.4, and is skipped
  silently on older hosts.
- A `TurnComplete` listener that nudges the model to save important state to
  `notes` as the context window fills, at 40%, 60%, and 80% of the window
  (configurable), with hysteresis: each step fires once per crossing, one
  nudge per event even when a jump crosses several steps. The last step,
  at 85%, trades the save ask for the compact ask. Subagents are
  nudged too, addressed by the task id their events carry, and their state
  dies with the session that opened them.
- Prompt hints: a system-prompt nudge to save/read notes around compaction,
  and one to check `context_usage` and, when it runs high, save what matters
  and call `compact` at a task end.
- An `agent.compact.before` layer that gives every automatic compaction one
  turn: the ask defers with a nudge to save notes, delivered as the model's
  next message, and the ask after that turn runs with a read-back naming the
  surviving notes attached to the message the agent resumes with. The same
  verdict adds the note filenames to the compaction summary's instructions,
  computed at the compaction moment so they are never stale. The host caps
  the defer to one per compaction, so the layer keeps no state. A manual
  `/compact` and an overflow recovery are obeyed at once, only read back. The
  summary alone is passive text the model can skim past. The read-back is a
  fresh message that names the files, which is what makes it actually happen.
  Subagent runs ride the same hook, so the save turn and read-back work
  without ever addressing them.
- `/notes`: a picker over the current session's notes. Enter opens a file
  in `$EDITOR`, Ctrl+D deletes.

## Install

Requires maki 0.7.2 or newer. The `context_usage` tool and its prompt
hint need maki newer than 0.7.4, the line that provides `ctx:context_usage()`
including its `0.7.5-dev` builds; older hosts load the plugin without
them.

> **Note:** the `defer` verdict of `agent.compact.before`, the `task`
> option of `maki.session.notify`, `maki.session.request_compact`, and
> `ctx:context_usage()` (maki 0.7.5) are not released upstream yet. Build
> maki from the [`dev` branch](https://github.com/sdroege/maki/tree/dev)
> for now. Everything else this plugin uses is upstream.

Clone the repository and symlink this plugin into maki's package directory:

```sh
git clone https://github.com/sdroege/maki-plugins.git ~/src/maki-plugins
ln -s ~/src/maki-plugins/notes ~/.local/share/maki/site/pack/local/start/notes
```

Copying the directory works the same way. `maki.pack.add` installs the root of
a Git repository, not a subdirectory, so it does not work with this monorepo.
See the [repository README](../README.md#install) for other platforms and
details.

## Configuration

Defaults need no configuration. To tune the reminders, call `setup` from
your `init.lua`:

```lua
require("notes_helpers").setup({
  remind_steps = { 0.4, 0.6, 0.8, 0.85 }, -- nudge as context passes each fraction, at least three
  -- reminder_text = "custom nudge text", -- overrides every step's text
})
```

Each step nudges once per crossing and re-arms when usage falls below it or a
compaction runs. The roles are positional: the first step asks to start a
note, the one below the last to save before compaction, and the last asks for
`compact` at the next task boundary instead of a save. Middle steps ask to
update your notes. `reminder_text` overrides every step's text, including the
compact ask.

## Permissions

`fs_read` and `fs_write` cover the session's own notes dir and the `/notes`
picker. `agent`, `session_read` and `session_write` are the price of the
`agent.compact.before` layer, and the reminders need them too: waking the
session with a `notify` observation and asking for a compaction both cost
the same.

## Tests

`sh tests/run.sh` (luajit only).
