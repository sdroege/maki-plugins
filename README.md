# maki-plugins

A collection of plugins for [maki](https://maki.sh), an AI coding agent for the
terminal. Each top-level directory is a self-contained maki package: an entry
file under `plugin/`, modules under `lua/` where needed, a `plugin.toml`
manifest, and its own README.

## Plugins

| Plugin | What it adds | Requires |
| --- | --- | --- |
| [`bash-filter`](bash-filter/) | Rejects patch-printing `git diff` calls that omit `--no-ext-diff`, and auto-allows whitelisted read-only `sed` print commands. | maki 0.5.0 |
| [`greenpt`](greenpt/) | The `greenpt` provider, with a curated model table for GreenPT's OpenAI-compatible API. | maki 0.6.0 |
| [`history`](history/) | A `history` tool that lets the model read its own transcript, including archived pre-compaction windows and subagent transcripts. | maki `dev` |
| [`inference-coop`](inference-coop/) | The `inference-coop` provider, a member-governed gateway in front of Tinfoil, GreenPT and Regolo. | maki 0.6.0 |
| [`notes`](notes/) | A session-scoped `notes` tool plus a `/notes` picker, with reminders as the context window fills and a read-back after compaction. | maki `dev` |
| [`strata`](strata/) | The `strata` provider for a local Strata server, listing whatever model the server reports. | maki 0.6.0 |

`history` and `notes` need maki changes that are not merged upstream yet.
Build maki from the [`dev` branch](https://github.com/sdroege/maki/tree/dev)
for those two.

### bash-filter

A safety and convenience layer. It hooks maki's bash input slot and rejects a
`git diff` that would print a full external-diff patch, pointing at the same
command with `--no-ext-diff`. It also hooks the permission prompt and
auto-accepts `sed` invocations whose script only prints (`[addr[,addr]]p`),
provided the shell cannot rewrite the script on the way to `sed`.

### greenpt

Adds GreenPT as a provider. GreenPT has no model metadata API, so the plugin
ships a curated table of the recommended catalogue: models, prices, context
windows, vision and thinking support. `list_models` only drops ids the API no
longer lists. Set `GREENPT_API_KEY` to use it.

### history

Exposes the session's own transcript as a tool with `list_windows`,
`list_items`, `read_item` and `search`. It covers the current context window,
archived windows dropped by compaction, and subagent transcripts, with stable
ids and byte-sliced reads. Prompt hints tell the model when to reach for it,
and an `agent.compact.before` layer attaches the read-back reminder to every
compaction so dropped turns are read instead of redone.

### inference-coop

Adds the Inference Cooperative gateway as a provider. Model ids are
`<provider>/<model>`, so a spec reads `inference-coop/greenpt/glm-5.3`. The
plugin carries a curated table for the co-op's chat models with context
windows, vision support and the co-op's recorded costs. Set
`INFERENCE_COOP_API_KEY` to use it.

### notes

Session-scoped notes that survive compaction and session resume. The `notes`
tool supports `list`, `read`, `search`, `append` and `write`; `/notes` opens a
picker over the current session's notes. The plugin also nudges the model to
save state at configurable fractions of the context window, holds an automatic
compaction for a turn so the save lands, and names the surviving notes when the
compaction runs. For cross-session notes, use maki's built-in `memory` tool.

### strata

Adds a local Strata server as a provider. Strata serves one model at a time on
`127.0.0.1:8080`, so the plugin lists exactly what `GET /v1/models` reports,
including the live context window and vision support. Pricing is a real zero
and no API key is needed. maki's private-address guard must allow
`127.0.0.1:8080` for the live model list; see the
[plugin README](strata/README.md).

## Install

Maki loads hand-placed packages from a Neovim-style package directory:

```
<maki-data>/site/pack/<group>/start/<name>/
```

On Linux `<maki-data>` is `~/.local/share/maki`, so the usual location is
`~/.local/share/maki/site/pack/local/start/`. Clone this repository and
symlink the plugins you want:

```sh
git clone https://github.com/sdroege/maki-plugins.git ~/src/maki-plugins
ln -s ~/src/maki-plugins/notes ~/.local/share/maki/site/pack/local/start/notes
```

Copying a directory works the same way. `maki.pack.add` installs the root of a
Git repository, not a subdirectory, so it does not work with this monorepo;
use a symlink or a copy for the individual plugins.

Restart maki or run `/reload` after adding a package. A hand-placed package is
trusted like your own `init.lua` and receives exactly the permissions its
`plugin.toml` requests, with no approval prompt. Read that file before
installing.

Provider plugins also need their API key or endpoint configured. See the
individual README for the environment variables, `net_hosts` and any extra
maki setup.

## Development

A package entry point is `plugin/main.lua` (or any sorted `plugin/*.lua`), and
modules live under `lua/`. Edit a plugin in place and run `/reload` in maki to
pick up the change. Logs go to maki's log directory, and `MAKI_LOG=debug`
keeps debug output.

Tests use luajit, maki's host dialect:

```sh
sh history/tests/run.sh
sh notes/tests/run.sh
sh bash-filter/tests/run.sh
```

`bash-filter` tests parse real shell commands with the tree-sitter bash
grammar. If `bash-filter/tests/lib/libtree-sitter-bash.so` is missing, build
it first with `sh bash-filter/tests/lib/build.sh`; that needs the
`tree-sitter-bash` crate in the cargo registry and the system
`libtree-sitter`. The provider plugins have no automated tests.
