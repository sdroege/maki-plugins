# greenpt

A maki plugin that adds the [GreenPT](https://greenpt.ai) API as a provider.
GreenPT is an OpenAI-compatible endpoint with no API for model metadata, so a
curated model table is the catalogue and `list_models` only drops an id the
API no longer lists.

## What it adds

- The `greenpt` provider: its models become `greenpt/<model_id>` in `/model`
  and the picker. GreenPT is in the models.dev catalog, so the plugin takes
  over the `greenpt` name (listed as `providers = ["greenpt"]` in
  `plugin.toml`, shown in the install approval prompt) and receives the key
  saved for it.
- Curated rows for glm-5.3, glm-5.3-flash, kimi-k3.1-pro,
  deepseek-v4.1-flash-1017 and minimax-m3, with GreenPT's own EUR rates per 1M
  tokens, context windows, the output caps their cards declare, and vision and
  thinking support.
- `/usage` from GreenPT's credit balance, the one usage figure an API key can
  read: what is left of your prepaid credits, in EUR with a USD approximation.
- GreenPT bills no cache write, so `cache_write` is 0.0. It enables reasoning
  by default, so every row spells its own `thinking_fields` ladder: off sends
  `reasoning_effort = "none"`, each named level sends itself, and a mode the
  row leaves out sends no field at all, leaving GreenPT's own default in
  charge.

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
the card - and a card alone is not enough when it is not a chat model: the
`metis` entry of 30 September 2026 now has a card, but it is a decision model
called through `POST /v1/systemone` rather than chat completions, and
`/v1/models` does not list it either, so it stays out of the table. A listing
is no guarantee either way: `/v1/models` still answers `minimax-m2.5`, the row
this table carried until October 2026, but its card is gone and no changelog
line records its removal, and without a card there is no rate, context window
or effort ladder to curate. Status changes mean different things:

- A deprecated id stops answering (`400 Unsupported model`) and drops out of
  `/v1/models`, so the picker loses it through `list_models` on its own - but
  remove its row anyway, or the table keeps claiming a price for it.
- A "not recommended" id still answers and still bills. The table
  deliberately carries only the recommended catalogue, so leave those out
  unless GreenPT moves one back.

Whatever the table does not list, `list_models` filters out, which is also how
the embedding, speech and rerank ids stay out of the picker.

Prices are GreenPT's EU endpoint list in EUR per 1M tokens - the US endpoint
(`api.us.greenpt.ai`) serves a subset at its own prices, so do not mix the two:
the plugin targets the EU default. GreenPT quotes and bills in EUR while maki
counts in dollars, so the rows hold GreenPT's EUR rates verbatim and a single
`EUR_TO_USD` factor converts them where the table is registered. Keep it that
way: writing dollars into a row makes it unreadable against its model card, and
two conversions (here and in the price) drift apart. The factor is the European
Central Bank's daily euro reference rate, and it takes one edit to refresh:

```sh
curl -s "https://data-api.ecb.europa.eu/service/data/EXR/D.USD.EUR.SP00.A?lastNObservations=1&format=csvdata" | tail -1
```

GreenPT's own list prices are the thing to keep exact; the rate only has to be
current enough that the cost lines mean something, so refreshing it on a table
sync is enough.

When adding a model, copy the ladder straight off the `/reasoning` page and
spare a thought for the trap the table layout exists to avoid: never declare
an `openai.thinking` dialect. A declared dialect replaces the per-row
`thinking_fields` wholesale, and the `standard` one omits the field on off,
which leaves a reason-by-default model thinking after the user asked for
off. The rows are the only spelling maki sees, and that is the point.

## Install

Requires maki 0.6.0 or newer.

Clone the repository and symlink this plugin into maki's package directory:

```sh
git clone https://github.com/sdroege/maki-plugins.git ~/src/maki-plugins
ln -s ~/src/maki-plugins/greenpt ~/.local/share/maki/site/pack/local/start/greenpt
```

Copying the directory works the same way. `maki.pack.add` installs the root of
a Git repository, not a subdirectory, so it does not work with this monorepo.
See the [repository README](../README.md#install) for other platforms and
details.

## Usage

Set `GREENPT_API_KEY` in your environment. The plugin sends it as a bearer
token. Point the slug elsewhere with `GREENPT_BASE_URL` or `providers.toml`.

### The credit balance behind `/usage`

GreenPT has no usage endpoint for API keys: the account portal's analytics sit
behind its login session and `/v1` answers 404 for `credits`, `usage` and
`balance` alike. What a key can read is the prepaid credit balance, which
GreenPT returns in the `X-Credits-Remaining` header of billed API responses -
but not of `GET /v1/models`, which omits it. The plugin reads it off the free
Mangrove discovery call `GET /v1/agents`, which carries the header, bills
nothing and keeps answering at a zero balance, so `/usage` still reports after
the credits run out.

That balance is all `/usage` can show, and only because there is nothing else
to ask for:

- No percentage: credits are a prepaid top-up that never expires, with no
  budget or window to divide by, so no reset is reported either.
- No spend, per-day or per-model history: those live in the portal's usage
  dashboard, which no key can reach.

The balance is EUR, GreenPT's billing currency; the USD figure in the detail
line uses the same `EUR_TO_USD` factor as the price rows.

## Permissions

- `net`: calls `https://api.greenpt.ai/v1`.
- `env`: reads `GREENPT_API_KEY`.
- `net_hosts`: `api.greenpt.ai`, `api.us.greenpt.ai`.
