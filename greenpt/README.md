# greenpt

A maki plugin that adds the [GreenPT](https://greenpt.ai) API as a provider.
GreenPT is an OpenAI-compatible endpoint with no API for model metadata, so a
curated model table is the catalogue and `list_models` only drops an id the
API no longer lists.

## What it adds

- The `greenpt` provider: its models become `greenpt/<model_id>` in `/model`
  and the picker.
- Curated rows for glm-5.3, glm-5.3-flash, kimi-k3, deepseek-v4.1-flash and
  minimax-m2.5, with prices (GreenPT's list in EUR per 1M tokens, stored in
  maki's dollar fields as-is), context windows, and vision and thinking
  support.
- GreenPT bills no cache write, so `cache_write` is 0.0. It enables reasoning
  by default, so every row spells its own `thinking_fields` ladder: off sends
  `reasoning_effort = "none"`, each named level sends itself, and a mode the
  row leaves out sends no field at all, leaving GreenPT's own default in
  charge. minimax-m2.5 reasons whether asked or not and accepts no `"none"`,
  so off clamps to minimal, the lowest rung of its ladder.

## Keeping the table current

The curated table covers GreenPT's recommended catalogue. Check these when
GreenPT announces models or price changes:

- Model list, prices, context windows and limits:
  https://docs.greenpt.ai/model-cards
- Every release, price change and deprecation: the "Model changes" list at
  the bottom of the same page
- What `GET /v1/models` answers: https://docs.greenpt.ai/models
- Which `reasoning_effort` values each model accepts, and which reject
  `"none"`: https://docs.greenpt.ai/reasoning
- Token pricing overview: https://docs.greenpt.ai/pricing

The "Model changes" list is the place to start: newest first, it tracks every
release, price change and status change. A "New model" line there without a
model card or a `/v1/models` listing has nothing to curate yet, so wait for
the card. The `metis` entry of 30 September 2026 is exactly that: no model
card, no `/v1/models` listing, no changelog mention - the model does not
exist, so it stays out of the table. Status changes mean different things:

- A deprecated id stops answering (`400 Unsupported model`) and drops out of
  `/v1/models`, so the picker loses it through `list_models` on its own - but
  remove its row anyway, or the table keeps claiming a price for it.
- A "not recommended" id still answers and still bills. The table
  deliberately carries only the recommended catalogue, so leave those out
  unless GreenPT moves one back.

Whatever the table does not list, `list_models` filters out, which is also how
the embedding, speech and rerank ids stay out of the picker.

Prices are the EU endpoint's list, in EUR per 1M tokens, stored as-is in
maki's dollar fields. The US endpoint (`api.us.greenpt.ai`) serves a subset
at its own prices, so do not mix the two: the plugin targets the EU default.

When adding a model, copy the ladder straight off the `/reasoning` page and
spare a thought for the trap the table layout exists to avoid: never declare
an `openai.thinking` dialect. A declared dialect replaces the per-row
`thinking_fields` wholesale, and the `standard` one omits the field on off,
which leaves a reason-by-default model thinking after the user asked for
off. The rows are the only spelling maki sees, and that is the point.

## Install

Requires maki 0.5.7 or newer.

```lua
maki.pack.add({ "https://github.com/<owner>/maki-greenpt" })
```

Or copy this directory into your config dir (e.g.
`~/.config/maki/pack/greenpt/`).

## Usage

Set `GREENPT_API_KEY` in your environment. The plugin sends it as a bearer
token. Point the slug elsewhere with `GREENPT_BASE_URL` or `providers.toml`.

## Permissions

- `net`: calls `https://api.greenpt.ai/v1`.
- `env`: reads `GREENPT_API_KEY`.
- `net_hosts`: `api.greenpt.ai`, `api.us.greenpt.ai`.
