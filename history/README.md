# history

A `history` tool for maki that lets the model read the session's own
transcript: the current context window, the archived pre-compaction windows,
and subagent transcripts, without touching the session files on disk.

## What it adds

- `history` tool:
  - `list_windows`: id, item count, total chars, and creation time per
    window, current first.
  - `list_items`: one line per item with a `window/item` id the model chains
    into `read_item`; filter by `role` and `sub` (`"main"` or a subagent
    name, the task description that spawned it).
  - `read_item`: full render of one item - text, thinking, tool_use (name
    and input), tool_result, images as `[image omitted]` - with
    `offset_chars`/`limit_chars` slicing.
  - `search`: literal case-sensitive substring across windows, with snippets
    around each match and a per-item match count when an item matches more
    than once.
- Main-thread items are numbered by position in the window's log, subagent
  items by spawn slot and position within their transcript (`s2/3`), so ids
  stay valid as the transcript grows. Archives are immutable. Unknown ids
  answer a clean not-found. Limit-like arguments are clamped, never
  rejected, and output goes through maki's per-tool output limits.
- Prompt hints: a system-prompt nudge with the everyday triggers (exact
  earlier wording, subagent findings) and a compact-prompt hint that the
  transcript stays readable, while the summary itself must still stand on
  its own.
- A `CompactionDone` listener that notifies the session right after a
  compaction that the dropped turns remain readable with `history`, instead
  of redoing work.

## Install

Requires maki 0.6.0 or newer.

```lua
maki.pack.add({ "https://github.com/<owner>/maki-history" })
```

Or copy this directory into your config dir (e.g.
`~/.config/maki/pack/history/`).

## Permissions

None: it reads the transcript through `maki.session.messages`, which is not
gated.

## Tests

`sh tests/run.sh` (luajit only).
