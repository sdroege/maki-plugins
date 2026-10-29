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
- Curated rows for the 8 chat models, with context windows, vision support
  and prices from the co-op's published model list.
- Thinking uses the standard `reasoning_effort` spelling, with each row
  spelling its own `thinking_fields` ladder: off sends `reasoning_effort =
  "none"` where the model accepts it, each named level sends itself, and a
  mode the row leaves out sends no field at all. glm-5.3, glm-5.3-flash and
  deepseek-v4.1-flash can switch thinking off. gpt-oss-120b reasons whether
  asked or not and accepts no `none`, so off clamps to `low`, the lowest rung
  of its ladder.

## Install

Requires maki 0.6.0 or newer.

```lua
maki.pack.add({ "https://github.com/<owner>/maki-inference-coop" })
```

Or copy this directory into your config dir (e.g.
`~/.config/maki/pack/inference-coop/`).

## Usage

Set `INFERENCE_COOP_API_KEY` to a member key from the
[dashboard](https://dashboard.inference.coop). The plugin sends it as a
bearer token. Point the slug elsewhere with `INFERENCE_COOP_BASE_URL` or
`providers.toml`.

API usage draws from the same monthly allowance as the co-op's chat. The
recorded prices are what the co-op pays the provider, not what you pay, so
maki's cost sums track co-op spend rather than a bill.

## Keeping the table current

The curated table covers the co-op's chat models. Check these when the co-op
adds models or rates change:

- Member-facing model list, context windows, vision support:
  https://git.inference.coop/co-op/docs/src/branch/main/models.md
- Authoritative pricing, including the cached-input rates:
  https://git.inference.coop/code/litellm/src/branch/main/config.yaml
- Regolo's own catalogue and rates, for the pricing of regolo/* rows:
  https://regolo.ai/models (announcements: https://regolo.ai/pricing-update/)
- API usage and auth: https://git.inference.coop/co-op/docs/src/branch/main/api-access.md

The docs state the two stay in sync: the LiteLLM config holds the numbers,
models.md mirrors them. In practice they disagree, and each in its own way,
so read both before touching a row:

- models.md can state a model is not served while the config is silent about
  it (it says the co-op does not serve the Tinfoil version of the full
  GLM-5.3, which the config never lists).
- The config's comments record removals models.md no longer shows
  (greenpt/green-r and green-l, removed 2026-10 once GreenPT marked them
  "not recommended").

A row needs both sources behind it: drop it when either drops the model.

A dash for cached input is not always a rate that does not exist, and the
same goes for any other price that disagrees: for a greenpt/* or regolo/*
row, the provider's own price list has priority over the co-op's sources,
because the co-op pays the provider's list price directly - the co-op's
pages are a mirror that can lag or have gaps. Check the upstream provider's
own pricing before recording 0.0.

GreenPT's list is https://docs.greenpt.ai/model-cards; the rule came from
cached input on greenpt/glm-5.3, where the config listed no cached rate and
models.md showed a dash while GreenPT billed 0.275 (both co-op sources list
the rate now and agree with the row). Regolo's is the per-token catalogue
embedded in https://regolo.ai/models, plus its rate announcements at
https://regolo.ai/pricing-update/: the co-op's sources carry Regolo's EUR
list converted to dollars at 1.16, and the rows record the list itself
(apertus-70b 0.40/2.10, qwen3.5-122b 1.00/4.20). Regolo has announced new
rates effective 2026-11-01 (apertus-70b EUR 1.00/3.40, qwen3.5-122b EUR
0.60/3.40), so re-sync both rows once they are live.

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
