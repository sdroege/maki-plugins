# strata

A maki plugin that adds a local Strata server as a provider. Strata serves one
model at a time behind an OpenAI-compatible API on `127.0.0.1:8080/v1`. It
runs on your own machine, so it needs no API key and pricing is free.

## What it adds

- The `strata` provider. Only the models the server reports are listed, so
  the picker follows whatever model is loaded and swapping a quant or
  changing `model_name` needs no plugin edit. The image model is dropped by
  its output modality, and an alias is skipped because the model it points
  at is listed under its own id. When the server is down, no Strata models
  are listed.
- Strata can serve Qwen3.8-Flash-Next (the original, Coder, Unsloth, Gyro,
  NVFP4, and Swift 1.5), Qwen3.6-35B-A3B, and DeepSeek-V4.1-Flash. The plugin
  lists whichever one the running server reports.
- The plugin adds what the API cannot say: the tier (Qwen3.6-35B-A3B weak,
  everything else medium), the zero pricing (a real `$0`, so cost sums read
  zero), and the thinking levels. Context window and vision support are read
  from `GET /v1/models` (`meta.n_ctx` and `architecture.input_modalities`), so
  a server started with another `--max-context`, or with a vision encoder
  loaded, is reported as it is.
- Thinking uses the standard `reasoning_effort` dialect plus a per-model
  level list: off sends `"none"`, each named level sends itself, and the
  server maps the levels its template does not take (Qwen's
  `high`/`xhigh`/`max` all mean xhigh, DeepSeek's `xhigh`/`max` mean max).
  `minimal` is not in the list, so maki snaps it down to `low` - never to
  the server's `minimal` alias, which means off.

## Install

Requires maki 0.6.0 or newer.

```lua
maki.pack.add({ "https://github.com/<owner>/maki-strata" })
```

Or copy this directory into a package directory (e.g.
`~/.local/share/maki/site/pack/plugins/start/strata/`).

## Usage

Start Strata so it listens on `127.0.0.1:8080`, then pick the id the server
reports (e.g. `strata/qwen3.8-flash-next-unsloth-ud-q4_k_xl`) in `/model`.
No key is needed. Point the slug elsewhere with `STRATA_BASE_URL` or
`providers.toml`. When the server is down, no Strata models are listed and
requests fail until it is back.

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
still runs; only the live listing is empty.

## Permissions

- `net`: calls `http://127.0.0.1:8080/v1`.
- `net_hosts`: `127.0.0.1:8080`.
