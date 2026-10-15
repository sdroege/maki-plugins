# strata

A maki plugin that adds a local Strata server as a provider. Strata serves one
quantised model behind an OpenAI-compatible API on `127.0.0.1:8080/v1`. It
runs on your own machine, so it needs no API key and pricing is free.

## What it adds

- The `strata` provider: its model becomes
  `strata/qwen3.8-flash-next-unsloth-ud-iq4_xs` in `/model` and the picker.
  The id is the quantised build the server loads, so a different quant gets a
  different id - update the row's `prefixes` when you swap the model file.
- The curated row carries what the API cannot say: the tier, the zero pricing
  (a real `$0`, so cost sums read zero), and the thinking ladder. Context
  window and vision support are read from `GET /v1/models` (`meta.n_ctx` and
  `architecture.input_modalities`), so a server started with another
  `--max-context`, or with a vision encoder loaded, is reported as it is.
- Thinking uses the standard `reasoning_effort` spelling, with the row
  spelling its own ladder: off sends `reasoning_effort = "none"`, each named
  level sends itself, and `high`/`xhigh`/`max` all mean the template's xhigh.
  The model thinks by default; a mode the row leaves out snaps to the
  nearest declared rung, so maki's `minimal` lands on `low` - never on the
  server's `minimal` alias, which means off.

## Install

Requires maki 0.5.7 or newer.

```lua
maki.pack.add({ "https://github.com/<owner>/maki-strata" })
```

Or copy this directory into a package directory (e.g.
`~/.local/share/maki/site/pack/plugins/start/strata/`).

## Usage

Start Strata so it listens on `127.0.0.1:8080`, then pick
`strata/qwen3.8-flash-next-unsloth-ud-iq4_xs` in `/model`. No key is needed.
Point the slug elsewhere with `STRATA_BASE_URL` or `providers.toml`. When the
server is down, the picker falls back to the curated row and requests fail
until it is back.

The model list is read from the running server with a plugin network call,
which maki's private-address guard blocks by default. Allow it once in your
global `init.lua` so the picker sees the live context window and vision
support:

```lua
maki.setup({
    net = {
        allowed_private_hosts = { "127.0.0.1:8080" },
    },
})
```

Chat requests go to the declared origin unguarded, so without this the model
still runs; only the live listing falls back to the curated row.

## Permissions

- `net`: calls `http://127.0.0.1:8080/v1`.
- `net_hosts`: `127.0.0.1:8080`.
