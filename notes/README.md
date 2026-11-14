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
- A `TurnComplete` listener that nudges the model to save important state to
  `notes` as the context window fills, at 40%, 60%, and 80% of the window
  (configurable), with hysteresis: each step fires once per crossing, one
  nudge per event even when a jump crosses several steps. Subagents are
  nudged too, addressed by the task id their events carry, and their state
  dies with the session that opened them.
- Prompt hints: a system-prompt nudge to save/read notes around compaction.
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

Requires maki 0.7.2 or newer.

> **Note:** the `defer` verdict of `agent.compact.before` and the `task`
> option of `maki.session.notify` are not merged upstream yet. Build maki from
> the [`dev` branch](https://github.com/sdroege/maki/tree/dev) for now.
> Everything else this plugin uses is upstream.

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
  remind_steps = { 0.4, 0.6, 0.8 }, -- nudge as context passes each fraction
  -- remind_at = 0.8, -- single-threshold shorthand for one step
  -- reminder_text = "custom nudge text", -- overrides every step's text
})
```

Each step nudges once per crossing and re-arms when usage falls below it or a
compaction runs. The texts escalate by step: the first asks to start a note,
the middle ones to update, the last to save before compaction.

## Permissions

The manifest asks for every permission, because the `agent.compact.before`
layer steers what the agent does next and every `agent.*` slot costs all
of them: a plugin missing one gets its layer skipped. What the plugin
actually uses is narrower: `fs_read` and `fs_write` for the session's own
notes dir and the `/notes` picker. `agent` and `session_write` let the
reminders wake the session with a `notify` observation, and `session_read`
keeps the `TurnComplete` subscription whole instead of stripped to its
metadata.

## Tests

`sh tests/run.sh` (luajit only).
