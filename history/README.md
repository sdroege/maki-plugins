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
- An `agent.compact.before` layer that attaches the same reminder to
  every compaction, so the model reads dropped turns back with `history`
  instead of redoing work.

## Install

Requires maki 0.6.0 or newer.

> **Note:** this plugin needs maki changes that are not merged upstream yet.
> Build maki from the [`dev` branch](https://github.com/sdroege/maki/tree/dev)
> for now. It uses `maki.session.transcript` and compact prompt hints, which
> are not in upstream maki yet.

Clone the repository and symlink this plugin into maki's package directory:

```sh
git clone https://github.com/sdroege/maki-plugins.git ~/src/maki-plugins
ln -s ~/src/maki-plugins/history ~/.local/share/maki/site/pack/local/start/history
```

Copying the directory works the same way. `maki.pack.add` installs the root of
a Git repository, not a subdirectory, so it does not work with this monorepo.
See the [repository README](../README.md#install) for other platforms and
details.

## Permissions

The manifest asks for every permission, because the `agent.compact.before`
layer steers what the agent does next and every `agent.*` slot costs all
of them: a plugin missing one gets its layer skipped. What the plugin
actually uses is narrower: `session_read`, to read the transcript through
`maki.session.transcript` (and to receive the event subscriptions whole),
and `agent`, for the slot itself.

## Tests

`sh tests/run.sh` (luajit only).
