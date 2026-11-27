# inference-coop

A maki plugin that adds the [Inference Cooperative](https://inference.coop)
as a provider: a member-governed gateway in front of several providers
(Tinfoil, GreenPT, Regolo) behind one OpenAI-compatible endpoint.

Model ids are `<provider>/<model>`, so a maki spec reads
`inference-coop/greenpt/glm-5.3`. The same model behind two providers stays
two ids, which is the co-op's point: you pick privacy (Tinfoil enclaves),
renewable energy (GreenPT) or publicly developed sovereign models
(Regolo).

## What it adds

- The `inference-coop` provider: its models become
  `inference-coop/<provider>/<model>` in `/model` and the picker.
- Curated rows for the 10 chat models, with context windows, vision support
  and thinking ladders, and prices read live from the co-op's gateway
  (the rows' own rates are the fallback when it does not answer).
- `/usage` from the co-op's own meter: the allowance window you are in, what
  has been spent against it and when it resets, the same figures the member
  dashboard shows.
- Thinking uses the standard `reasoning_effort` spelling, with each row
  spelling its own `thinking_fields` ladder: off sends `reasoning_effort =
  "none"` where the model accepts it, each named level sends itself, and a
  mode the row leaves out sends no field at all. glm-5.3, glm-5.3-flash and
  deepseek-v4.1-flash can switch thinking off. gpt-oss-120b reasons whether
  asked or not and accepts no `none`, so off clamps to `low`, the lowest rung
  of its ladder.

## Install

Requires maki 0.6.0 or newer.

Clone the repository and symlink this plugin into maki's package directory:

```sh
git clone https://github.com/sdroege/maki-plugins.git ~/src/maki-plugins
ln -s ~/src/maki-plugins/inference-coop ~/.local/share/maki/site/pack/local/start/inference-coop
```

Copying the directory works the same way. `maki.pack.add` installs the root of
a Git repository, not a subdirectory, so it does not work with this monorepo.
See the [repository README](../README.md#install) for other platforms and
details.

## Usage

Set `INFERENCE_COOP_API_KEY` to a member key from the
[dashboard](https://dashboard.inference.coop). The plugin sends it as a
bearer token. Point the slug elsewhere with `INFERENCE_COOP_BASE_URL` or
`providers.toml`.

API usage draws from the same monthly allowance as the co-op's chat. The
recorded prices are what the co-op pays the provider, not what you pay, so
maki's cost sums track co-op spend rather than a bill.

### The co-op's meter behind `/usage`

`/usage` shows the co-op's own meter, the number the dashboard shows, read off
the gateway with the key you already set: `GET /key/info` names the budget team
behind the key, and `GET /team/info` on that team carries the spend and the cap.
Both are LiteLLM management routes at the host root, so they are fetched on the
gateway's origin rather than under `/v1`. Team spend counts the chat and every
API key at once, which is what the co-op meters; what a single key has spent is
lifetime for that key and says nothing about the allowance.

Three things the gateway cannot tell an API key:

- The split between the monthly allowance and any credit pack. The co-op keeps
  purchased credit in its portal database and pushes only the sum to the
  gateway, so a $15 allowance plus a $10 pack reads as one $25 cap. The dollar
  line is the one to read; the percentage is of the combined cap.
- The per-day and per-model history behind the dashboard's charts. `/spend/logs`
  answers to the co-op's master key, and the daily-activity routes refuse a
  member key outright, so `by_model_today` stays empty here.
- The allowance as a figure of its own. The window is the co-op's, 30 days
  pinned to your billing day, so the reset `/usage` reports is the gateway's,
  not a calendar month.

## Keeping the table current

Prices are not really kept here: `list_models` reads the live per-token
costs off the gateway's `/model/info` route (a LiteLLM route at the host
root, reachable with a member key but documented nowhere, so it could be
closed without notice) and maki lets a discovered price outrank a row's. The
gateway meters each call at exactly those figures, EUR-quoted providers
included at the ECB daily rate, so a session prices at real co-op spend.
What follows is therefore about the fallback rates: the last-committed
figures that stand in when the route answers nothing or the gateway is
unreachable. Keep them at the config's committed numbers so the fallback
stays honest.

The curated table covers the co-op's chat models. Check these when the co-op
adds models or rates change:

- Member-facing model list, context windows, vision support:
  https://git.inference.coop/co-op/docs/src/branch/main/guides/models.md
- Authoritative pricing and the EUR list behind it:
  https://git.inference.coop/code/litellm/src/branch/main/config.yaml and
  https://git.inference.coop/code/litellm/src/branch/main/eur_prices.json
- Regolo's own catalogue and rates, for the pricing of regolo/* rows:
  https://regolo.ai/models (announcements: https://regolo.ai/pricing-update/)
- API usage and auth: https://git.inference.coop/co-op/docs/src/branch/main/guides/api-access.md
  (it documents the chat and completion endpoints only: the usage routes above
  are LiteLLM's own, and the docs list no usage endpoint for members)

The docs state the two stay in sync: models.md mirrors the config, and the
config's `model_info` is generated from `eur_prices.json`, the EUR list
prices. In practice they disagree, and each in its own way,
so read both before touching a row:

- The config carries an operator-only model models.md never shows
  (`tinfoil/nomic-embed-text`, scoped to the admin team for the co-op's own
  docs RAG).
- The config's comments record removals models.md no longer shows
  (greenpt/green-r and green-l, removed 2026-10 once GreenPT marked them
  "not recommended").
- The config declares four short route aliases members can pin
  (`deepseek-flash-green`, `deepseek-flash-tee`, `glm-flash-green`, `glm-tee`)
  that models.md never mentions. They are the same four upstream routes at the
  same prices, so they are not rows and `list_models` filters them out.

A row needs both sources behind it: drop it when either drops the model.

A dash for cached input is not always a rate that does not exist, and the
same goes for any other price that disagrees: when a co-op source and a
provider's own price list disagree, the co-op's sources win, because the
rows record what the co-op pays in dollars and that is what its spend
records show. Check both before recording 0.0.

GreenPT's list is https://docs.greenpt.ai/model-cards. The rule came from
cached input on greenpt/glm-5.3, where the config listed no cached rate and
models.md showed a dash while GreenPT billed 0.275 (both co-op sources list
the rate now and agree with the row). GreenPT and Regolo quote EUR, and those
list prices live in the config repo's eur_prices.json - the only source of
those numbers. The config's dollar fields for them are generated: fx_sync.py
converts the EUR list at the ECB daily reference rate at every boot, and the
config carries a pinned generated figure as a fallback, named in its header
(FX_FALLBACK_USD, 1.0975 = ECB 2026-11-26). Before 2026-11-26 the co-op
instead converted at a fixed policy rate, FX 1.16, and a header that still
said so sat over numbers the boot sync had already moved. So greenpt/* and
regolo/* rows sit a little above the EUR figure on the provider's own page
(the EUR list for greenpt/glm-5.3 is 1.10/4.40/0.275, the row and the config
both say 1.20725/4.829/0.3018125, the pin times the list) and track the ECB
rate with some lag, the pin being the last generated figure committed.
Copying a provider's EUR numerals into a row under-states co-op spend by the
FX gap, which is the same mistake the co-op's own config header warns its
operators against. Tinfoil quotes dollars, so tinfoil/* rows match its list
directly. Regolo's own list is the per-token catalogue embedded
in https://regolo.ai/models (a `regolo_model_list` JSON blob in the page HTML,
mirrored by the visible pricing table), plus its rate announcements at
https://regolo.ai/pricing-update/.

The upstream lists settle prices only: which models are rows still comes
from the co-op's docs, since Regolo serves many models the co-op does not.
The tinfoil rows have no upstream list to fall back on, so for those the
co-op's sources are the last word.

Reasoning values come from the upstream provider's docs, not the co-op's:
GreenPT spells what each model accepts at
https://docs.greenpt.ai/reasoning, and the tinfoil rows mirror those values
for the same models, since Tinfoil publishes none of its own. And never
declare an `openai.thinking` dialect for the slug: a declared dialect
replaces the per-row `thinking_fields` wholesale, and the `standard` one
omits the field on off, which leaves a reason-by-default model thinking
after the user asked for off.

Ids outside the table stay hidden from the picker: `list_models` filters
anything the table does not list, which also keeps the whisper and voxtral
speech models out.

## Permissions

- `net`: calls `https://gateway.inference.coop/v1`.
- `env`: reads `INFERENCE_COOP_API_KEY`.
- `net_hosts`: `gateway.inference.coop`.
