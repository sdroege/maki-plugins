-- GreenPT, an OpenAI-compatible endpoint with no API for model metadata, so
-- the curated table is the catalogue and `list_models` only drops an id the
-- API no longer lists. Model list, prices, context windows and limits come
-- from https://docs.greenpt.ai/model-cards (the "Model changes" list there
-- tracks every release, price change and deprecation) and
-- https://docs.greenpt.ai/models for what `GET /v1/models` answers. Keep the
-- table in sync with the recommended catalogue when those pages change. A
-- "New model" line in the Model changes list is only curatable once a model
-- card backs it and /v1/models lists the id as a chat model: the metis entry
-- of 30 September 2026 now has a card, but it is a decision model called
-- through POST /v1/systemone rather than chat completions, and /v1/models
-- does not list it, so it stays out. Nor is a listing a guarantee: /v1/models
-- still answers minimax-m2.5, the row this table carried until October 2026,
-- although its card is gone and no changelog line records its removal, and
-- without a card there is no rate, context window or effort ladder to curate.

local parse = require("maki.provider_parse")

local MODELS_PATH = "/models"
local API_KEY_ENV = "GREENPT_API_KEY"

-- Prices are GreenPT's list in EUR per 1M tokens, from the model cards page;
-- the factor below turns them into maki's dollars. GreenPT bills no cache
-- write, so cache_write is 0.0. It enables reasoning by default: omitting the
-- effort field leaves thinking on. No built-in effort dialect matches that shape
-- (off must send "none" and the levels run minimal..high, while "standard"
-- omits the field on off and every other dialect misses levels or adds ones
-- GreenPT rejects), so no dialect is declared and each row spells its own
-- ladder: a level the row names is sent as a reasoning_effort of the same
-- name, "off" sends "none", and a mode the row leaves out sends no field at
-- all, leaving GreenPT's own default in charge. Which `reasoning_effort`
-- values each model accepts, and which reject `"none"`, is documented at
-- https://docs.greenpt.ai/reasoning; the rows' ladders follow it.
local function efforts(...)
  local fields = {}
  for _, name in ipairs({ ... }) do
    fields[name] = { reasoning_effort = name == "off" and "none" or name }
  end
  return fields
end

-- The one place GreenPT's EUR becomes maki's dollars, so a rate review is one
-- edit and never means recomputing a row by hand. 1.0975 is the European Central
-- Bank's daily euro reference rate of 26 November 2026; GreenPT bills in EUR and
-- publishes no USD list, so that series is the one to follow. Refresh it on a
-- table sync, where the cost lines make a drift visible.
-- https://data-api.ecb.europa.eu/service/data/EXR/D.USD.EUR.SP00.A
local EUR_TO_USD = 1.0975

-- Rounds to 6 decimals, because plain multiplication leaves binary tails:
-- 0.11 * 1.0975 is 0.12072499999999999, not 0.120725. The rounding shifts a
-- rate by under half a millionth of a dollar per 1M tokens, which no cost line
-- can show.
local function dollars(pricing)
  local function convert(amount)
    return math.floor(amount * EUR_TO_USD * 1e6 + 0.5) / 1e6
  end
  return {
    input = convert(pricing.input),
    output = convert(pricing.output),
    cache_write = convert(pricing.cache_write),
    cache_read = convert(pricing.cache_read),
  }
end

-- Rows carry GreenPT's published EUR rates verbatim and stay readable against
-- their model cards. The registered CATALOGUE at the bottom is the converted
-- copy, and is the only table maki ever sees.
local MODELS = {
  {
    prefixes = { "glm-5.3" },
    tier = "strong",
    context_window = 1000000,
    supports_thinking = true,
    pricing = { input = 1.10, output = 4.40, cache_write = 0.0, cache_read = 0.275 },
    thinking_fields = efforts("off", "minimal", "low", "medium", "high"),
  },
  {
    -- Added 2026-11-05. GreenPT moved the kimi-k3 id out of the recommended
    -- catalogue on 2026-11-14 in favour of it, at the same rate.
    prefixes = { "kimi-k3.1-pro" },
    tier = "strong",
    context_window = 1000000,
    max_output_tokens = 65536,
    supports_thinking = true,
    supports_vision = true,
    pricing = { input = 3.30, output = 16.50, cache_write = 0.0, cache_read = 0.825 },
    thinking_fields = efforts("off", "minimal", "low", "medium", "high"),
  },
  {
    -- The recommended DeepSeek row since GreenPT moved the version-free
    -- deepseek-v4.1-flash id out of the catalogue on 2026-11-14.
    prefixes = { "deepseek-v4.1-flash-1017" },
    tier = "medium",
    context_window = 1000000,
    supports_thinking = true,
    supports_vision = true,
    pricing = { input = 0.36, output = 1.45, cache_write = 0.0, cache_read = 0.04 },
    thinking_fields = efforts("off", "minimal", "low", "medium", "high"),
  },
  {
    prefixes = { "glm-5.3-flash" },
    tier = "medium",
    context_window = 1000000,
    supports_thinking = true,
    supports_vision = true,
    pricing = { input = 0.11, output = 0.44, cache_write = 0.0, cache_read = 0.022 },
    thinking_fields = efforts("off", "minimal", "low", "medium", "high"),
  },
  {
    prefixes = { "minimax-m3" },
    tier = "medium",
    context_window = 1000000,
    max_output_tokens = 65536,
    supports_thinking = true,
    supports_vision = true,
    pricing = { input = 0.44, output = 2.20, cache_write = 0.0, cache_read = 0.11 },
    thinking_fields = efforts("off", "minimal", "low", "medium", "high"),
  },
}

local KNOWN = {}
for _, row in ipairs(MODELS) do
  KNOWN[row.prefixes[1]] = true
end

-- maki wants a copy with the factor applied, so MODELS itself stays in
-- GreenPT's currency.
local CATALOGUE = {}
for i, row in ipairs(MODELS) do
  local priced = {}
  for key, value in pairs(row) do
    priced[key] = value
  end
  priced.pricing = dollars(row.pricing)
  CATALOGUE[i] = priced
end

maki.provider.register({
  slug = "greenpt",
  display_name = "GreenPT",
  codec = "openai",
  base_url = "https://api.greenpt.ai/v1",
  api_key_env = API_KEY_ENV,
  -- No provider-wide output cap: a row that states none sends no
  -- max_tokens and the API's own limit applies. minimax-m3 and kimi-k3.1-pro
  -- keep the 65536 their model cards declare.
  max_output_tokens = false,
  models = CATALOGUE,

  -- /models also lists embedding, speech and rerank model ids. Anything the
  -- table does not list is filtered out as we can't know from the models list
  -- what kind of model is behind the id.
  list_models = function(ctx)
    local body, err = ctx.get_json(MODELS_PATH)
    if err then
      return nil, err
    end
    return parse.models(body, function(m)
      if type(m) ~= "table" or type(m.id) ~= "string" or KNOWN[m.id] == nil then
        return nil
      end
      return { id = m.id }
    end)
  end,
})
