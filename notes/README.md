# notes

Session-scoped notes for maki: a `notes` tool the model uses to save
session state that must survive compaction, plus a `/notes` picker for the
user.

Notes live under `<state>/sessions/notes/<session-id>/`, so they survive
compaction and session resume, and are deleted together with the session.
For cross-session, project-scoped notes use the built-in `memory` tool.

## What it adds

- `notes` tool: `list`, `read` (with line ranges), `search`, `append`,
  `write`. Strongly consistent local files, capped at 1 MiB per note.
  Limit-like arguments are clamped, never rejected. No model-facing delete.
- A `ToolDone` listener that nudges the model to save important state to
  `notes` as the context window fills, at 40%, 60%, and 80% of the window
  (configurable), with hysteresis: each step fires once per crossing, one
  nudge per event even when a jump crosses several steps.
- Prompt hints: a system-prompt nudge to save/read notes around compaction,
  and a compact-prompt hint listing the session's note filenames so the
  compaction summary tells the model what to read back.
- A `CompactionDone` listener that wakes the session with an observation
  naming the surviving notes and telling the model to read them before
  doing any work. The summary alone is passive text the model can skim
  past; the woken observation is what makes the read-back actually happen.
- `/notes`: a picker over the current session's notes. Enter opens a file
  in `$EDITOR`, Ctrl+D deletes.

## Install

Requires maki 0.6.0 or newer.

```lua
maki.pack.add({ "https://github.com/<owner>/maki-notes" })
```

Or copy this directory into your config dir (e.g.
`~/.config/maki/pack/notes/`).

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

`fs_read` and `fs_write`, used only for the session's own notes dir and
the `/notes` picker.

## Tests

`sh tests/run.sh` (luajit only).
