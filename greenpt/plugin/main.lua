-- GreenPT, an OpenAI-compatible endpoint whose `GET /v1/models` lists ids
-- without any metadata, so the curated table is the catalogue and
-- `list_models` drops an id the API no longer lists and overlays the live
-- rates, context windows and output caps of `GET /v1/pricing` (documented at
-- https://docs.greenpt.ai/regions; per-endpoint figures, so the region of the
-- base URL decides what it answers). Everything no endpoint describes, the
-- tiers, vision and thinking ladders above all, comes from
-- https://docs.greenpt.ai/model-cards (the "Model changes" list there
-- tracks every release, price change and deprecation). Keep the table in
-- sync with the recommended catalogue when those pages change. A
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
local PRICING_PATH = "/pricing"
local AGENTS_PATH = "/agents"
local API_KEY_ENV = "GREENPT_API_KEY"

-- The key-free SDMX feed for the euro's daily reference rate in US dollars:
-- one series, one observation, asked for with lastNObservations=1.
local FX_URL =
  "https://data-api.ecb.europa.eu/service/data/EXR/D.USD.EUR.SP00.A?lastNObservations=1&format=jsondata"

-- The prices in the rows are GreenPT's list in EUR per 1M tokens, from the
-- model cards page, and serve as the offline fallback: `list_models`
-- overlays the live figures of `/pricing`, converted at the ECB rate the
-- listing fetched. GreenPT bills no cache write, so cache_write is 0.0. It
-- enables reasoning by default: omitting the
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

-- The one place GreenPT's EUR becomes maki's dollars, so a rate review never
-- means recomputing a row by hand. Listings convert at the ECB's daily euro
-- reference rate, which `live_rate` fetches fresh; GreenPT bills in EUR and
-- publishes no USD list, so that series is the one to follow. The pin below
-- is the fallback for a listing whose fetch did not answer, and what the
-- rows registered at startup carry. Refresh it on a table sync, where the
-- cost lines make a drift visible.
-- https://data-api.ecb.europa.eu/service/data/EXR/D.USD.EUR.SP00.A
local EUR_TO_USD = 1.0975

-- The rate rides the first value of the one observation of the one series the
-- query asks for. Nil on any surprise, so a chatty feed cannot crash a
-- listing or price it at zero.
local function ecb_rate(body)
  local sets = type(body) == "table" and body.dataSets
  local set = type(sets) == "table" and sets[1]
  local series = type(set) == "table" and set.series
  if type(series) ~= "table" then
    return nil
  end
  for _, entry in pairs(series) do
    local observations = type(entry) == "table" and entry.observations
    if type(observations) == "table" then
      for _, observation in pairs(observations) do
        local rate = type(observation) == "table" and parse.as_f64(observation[1])
        if rate and rate > 0 then
          return rate
        end
      end
    end
  end
  return nil
end

-- A fresh rate per call. It goes out through maki.net.request rather than
-- ctx.get_json because no GreenPT key belongs in an ECB request, and every
-- failure path lands on nil so the caller falls back to the pin.
local function live_rate()
  local res, err = maki.net.request(FX_URL)
  if err or not res or res.status >= 400 then
    return nil
  end
  local body, derr = maki.json.decode(res.body)
  if derr then
    return nil
  end
  return ecb_rate(body)
end

-- Rounds to 6 decimals, because plain multiplication leaves binary tails:
-- 0.11 * 1.0975 is 0.12072499999999999, not 0.120725. The rounding shifts a
-- rate by under half a millionth of a dollar per 1M tokens, which no cost line
-- can show. A nil `rate` is the pinned fallback.
local function dollars(pricing, rate)
  local factor = rate or EUR_TO_USD
  local function convert(amount)
    return math.floor(amount * factor * 1e6 + 0.5) / 1e6
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
    max_output_tokens = 64000,
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
    max_output_tokens = 64000,
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
  -- keep the 64000 their model cards and `/pricing` state.
  max_output_tokens = false,
  models = CATALOGUE,

  -- /models also lists embedding, speech and rerank model ids. Anything the
  -- table does not list is filtered out as we can't know from the models list
  -- what kind of model is behind the id. /pricing describes every id it
  -- knows with live EUR rates, a context window and an output cap, and also
  -- carries the ids off the recommended catalogue, so the KNOWN gate stays
  -- first and the figures only refresh the rows it lets through. A row
  -- /pricing prices only partly keeps its fallback rather than a half price,
  -- and when /pricing does not answer at all every row lists with its
  -- fallback untouched. The overlay converts at the ECB rate fetched for the
  -- listing; when that feed does not answer, the pinned factor does.
  list_models = function(ctx)
    local body, err = ctx.get_json(MODELS_PATH)
    if err then
      return nil, err
    end
    local rates = {}
    local priced, perr = ctx.get_json(PRICING_PATH)
    if not perr and type(priced) == "table" and type(priced.data) == "table" then
      for _, entry in ipairs(priced.data) do
        if type(entry) == "table" and entry.type == "LLM" and type(entry.id) == "string" then
          rates[entry.id] = entry
        end
      end
    end
    local fx = nil
    if next(rates) then
      fx = live_rate()
    end
    return parse.models(body, function(m)
      if type(m) ~= "table" or type(m.id) ~= "string" or KNOWN[m.id] == nil then
        return nil
      end
      local entry = rates[m.id]
      if not entry then
        return { id = m.id }
      end
      local p = type(entry.pricing) == "table" and entry.pricing or {}
      local input = parse.as_f64(p.promptToken)
      local output = parse.as_f64(p.completionToken)
      local pricing
      if input and output then
        pricing = dollars({
          input = input,
          output = output,
          cache_write = 0.0,
          cache_read = parse.as_f64(p.cachedPromptToken) or 0,
        }, fx)
      end
      return {
        id = m.id,
        pricing = pricing,
        context_window = parse.as_u32(entry.contextWindowTokens),
        max_output_tokens = parse.as_u32(entry.maxOutputTokens),
      }
    end)
  end,

  -- GreenPT gives an API key no usage endpoint: the account portal's analytics
  -- hide behind its login session and /v1 answers 404 for credits, usage and
  -- balance alike. What a key can read is the credit balance itself, which
  -- https://docs.greenpt.ai/credits promises in X-Credits-Remaining on every
  -- API response - every billed one though: /v1/models omits it (measured
  -- 2026-11-27). The free Mangrove discovery call GET /v1/agents answers with
  -- the header, bills nothing, and keeps working at a zero balance, so it is
  -- the carrier. Credits are a prepaid EUR balance that never expires and has
  -- no cap to divide by, and no spend history is key-readable, so this shows
  -- the balance and nothing else.
  fetch_usage = function(ctx)
    if not ctx.base_url then
      return nil, "no GreenPT origin to ask for the credit balance"
    end
    local res, err = maki.net.request(ctx.base_url .. AGENTS_PATH, { headers = ctx.headers })
    if err then
      return nil, err
    end
    if res.status >= 400 then
      return nil, maki.provider.http_error(res)
    end
    -- Header values are strings, so tonumber, not parse.as_f64.
    local credits = res.headers and tonumber(res.headers["x-credits-remaining"])
    if not credits then
      return nil, "GreenPT answered without a credit balance in X-Credits-Remaining"
    end
    -- The USD figure says "approximation" on purpose: it converts at the
    -- live ECB rate, and at the pin when the feed does not answer.
    local approx = credits * (live_rate() or EUR_TO_USD)
    return {
      limits = {
        {
          label = "API credits",
          detail = string.format("EUR %.2f (~USD %.2f) left", credits, approx),
        },
      },
    }
  end,
})
