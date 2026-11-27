-- Inference Cooperative (inference.coop), a member-governed gateway in
-- front of several providers. Model ids are `<provider>/<model>`, so a maki
-- spec reads `inference-coop/greenpt/glm-5.3`. The curated table describes
-- the models (tiers, windows, vision, thinking ladders); `list_models` reads
-- the live rates off the gateway's /model/info route and only lists an id the
-- table knows.
--
-- Model, context window, vision and rate data from the co-op's public docs:
-- https://git.inference.coop/co-op/docs/src/branch/main/guides/models.md (the
-- member-facing model list) and the LiteLLM config it names as the
-- authoritative pricing source,
-- https://git.inference.coop/code/litellm/src/branch/main/config.yaml.
-- Keep the table in sync with those when the co-op adds models or rates
-- change.

local parse = require("maki.provider_parse")

local API_KEY_ENV = "INFERENCE_COOP_API_KEY"

-- The gateway is a LiteLLM proxy, and its management and model-info routes
-- sit at the host root rather than under the /v1 chat origin, so the calls
-- below cannot be built by appending a path to base_url.
local MODEL_INFO_PATH = "/model/info"
local KEY_INFO_PATH = "/key/info"
local TEAM_INFO_PATH = "/team/info"

-- What the co-op calls a month: LiteLLM spells its allowance window this way.
local MONTHLY_DURATION = "30d"

-- Prices are per 1M tokens and are what the co-op pays the provider, not
-- what a member pays: members get a monthly allowance. Recorded anyway, so
-- maki's cost sums track co-op spend. The live figures come from the
-- gateway's /model/info: its model_info carries per-token dollar costs, the
-- exact ones the gateway meters each call at, EUR-quoted providers included
-- at the ECB daily rate. `list_models` restates them per 1M, and maki lets a
-- discovered price outrank a row's. The static pricing is the fallback for
-- when the route answers nothing (it is a LiteLLM admin route the co-op
-- leaves open to member keys, documented nowhere, and could be closed
-- without notice) or the gateway is unreachable.
-- A fallback is the figure the committed config states in model_info, in
-- dollars, changed in nothing else. That config's header says its
-- greenpt/* and regolo/* dollar fields are generated from the repo's
-- eur_prices.json at the ECB daily rate ("never paste EUR numerals into
-- model_info", since 2026-11-26), so a committed figure is the last pin
-- (FX 1.0975 = ECB 2026-11-26) and the gateway one rate ahead of it. Never
-- copy a provider's own EUR numerals (GreenPT's at
-- https://docs.greenpt.ai/model-cards, Regolo's embedded in
-- https://regolo.ai/models) into a row, and do not convert here: the rows
-- copy the config's numbers. Tinfoil quotes dollars, so its list matches the
-- config directly. No provider bills a cache write, so a fallback cache_write
-- is 0.0, and an unlisted cache read is 0.0 too. A sync re-reads the numbers
-- and the header's pin.
-- The gateway forwards to OpenAI-compatible endpoints that reason by
-- default, and no built-in effort dialect matches that shape (off must send
-- "none" while "standard" omits the field on off), so no dialect is declared
-- and each row spells its own ladder: a level the row names is sent as a
-- reasoning_effort of the same name, "off" sends "none", and a mode the row
-- leaves out sends no field at all, leaving the model's default in charge.
-- Models that reason whether asked or not declare requires_thinking, so off
-- clamps to the lowest rung of their ladder.
local function efforts(...)
  local fields = {}
  for _, name in ipairs({ ... }) do
    fields[name] = { reasoning_effort = name == "off" and "none" or name }
  end
  return fields
end

local MODELS = {
  {
    -- The co-op's default model. Serves the 1017 snapshot since 2026-11-16
    -- (GreenPT dropped the base release) under the same id, so only the rate
    -- moved: GreenPT's 1017 list of 0.36/1.45/0.04 EUR at the config's pin,
    -- FX 1.0975 (ECB 2026-11-26).
    prefixes = { "greenpt/deepseek-v4.1-flash" },
    tier = "medium",
    context_window = 1000000,
    supports_thinking = true,
    supports_vision = true,
    pricing = { input = 0.3951, output = 1.591375, cache_write = 0.0, cache_read = 0.0439 },
    thinking_fields = efforts("off", "minimal", "low", "medium", "high"),
  },
  {
    prefixes = { "tinfoil/deepseek-v4-1-flash" },
    tier = "medium",
    context_window = 1000000,
    supports_thinking = true,
    supports_vision = true,
    pricing = { input = 0.65, output = 1.45, cache_write = 0.0, cache_read = 0.13 },
    thinking_fields = efforts("off", "minimal", "low", "medium", "high"),
  },
  {
    prefixes = { "greenpt/glm-5.3" },
    tier = "strong",
    context_window = 1000000,
    supports_thinking = true,
    pricing = { input = 1.20725, output = 4.829, cache_write = 0.0, cache_read = 0.3018125 },
    thinking_fields = efforts("off", "minimal", "low", "medium", "high"),
  },
  {
    -- Text-only: models.md shows no vision and the LiteLLM config spells
    -- "Text-only (no vision)". Replaced tinfoil/glm-5-3-flash, which
    -- Tinfoil deprecated 2026-10-09.
    prefixes = { "tinfoil/glm-5.3" },
    tier = "strong",
    context_window = 1000000,
    supports_thinking = true,
    pricing = { input = 1.80, output = 5.75, cache_write = 0.0, cache_read = 0.45 },
    thinking_fields = efforts("off", "minimal", "low", "medium", "high"),
  },
  {
    prefixes = { "greenpt/glm-5.3-flash" },
    tier = "medium",
    context_window = 1000000,
    supports_thinking = true,
    pricing = { input = 0.120725, output = 0.4829, cache_write = 0.0, cache_read = 0.024145 },
    thinking_fields = efforts("off", "minimal", "low", "medium", "high"),
  },
  {
    -- Replaced PublicAI (removed 2026-10-16; billing never operational) as
    -- the co-op's Apertus provider: same open weights, EU ZDR + renewables.
    -- Context is the co-op's measured 262K; Regolo's catalogue advertises
    -- 30K input, which the gateway demonstrably exceeds. Prices are the
    -- co-op's dollar rates (Regolo's EUR list at the config's pin, 1.0975).
    prefixes = { "regolo/apertus-70b" },
    tier = "medium",
    context_window = 262144,
    supports_vision = true,
    pricing = { input = 1.0975, output = 3.7315, cache_write = 0.0, cache_read = 0.0 },
  },
  {
    -- The gateway forces chat_template_kwargs: {enable_thinking: false} for
    -- this id (LiteLLM config); without it the reasoning phase eats the
    -- whole token budget and the content comes back empty.
    prefixes = { "regolo/qwen3.5-122b" },
    tier = "medium",
    context_window = 262144,
    supports_vision = true,
    pricing = { input = 0.6585, output = 3.7315, cache_write = 0.0, cache_read = 0.0 },
  },
  {
    -- Added 2026-11-13. Hybrid instruct + reasoning Small 4 (119B) with
    -- vision and tool calling. Context is the co-op's measured 262K; the
    -- LiteLLM config still declares Regolo's catalogued 60K, which the
    -- gateway demonstrably exceeds (docs commit 808e5450, 2026-11-13).
    prefixes = { "regolo/mistral-small-4-119b" },
    tier = "medium",
    context_window = 262144,
    supports_vision = true,
    pricing = { input = 0.2195, output = 0.76825, cache_write = 0.0, cache_read = 0.0 },
  },
  {
    -- Added 2026-11-13. Dense multimodal Gemma 4 (31B) with native function
    -- calling. Context is the co-op's measured 262K, not the config's 100K.
    prefixes = { "regolo/gemma4-31b" },
    tier = "medium",
    context_window = 262144,
    supports_vision = true,
    pricing = { input = 0.439, output = 0.6585, cache_write = 0.0, cache_read = 0.0 },
  },
  {
    -- Reasons whether asked or not and accepts no "none", so off clamps to
    -- low, the lowest rung of its ladder.
    prefixes = { "tinfoil/gpt-oss-120b" },
    tier = "weak",
    context_window = 131072,
    requires_thinking = true,
    pricing = { input = 0.15, output = 0.60, cache_write = 0.0, cache_read = 0.0 },
    thinking_fields = efforts("low", "medium", "high"),
  },
}

local KNOWN = {}
for _, row in ipairs(MODELS) do
  KNOWN[row.prefixes[1]] = true
end

-- scheme://host[:port] of an origin, dropping whatever path it carries, so a
-- member who points the slug at a gateway under a path prefix keeps working.
local function origin(url)
  if type(url) ~= "string" then
    return nil
  end
  return url:match("^(%a[%a%d+.-]*://[^/?#]+)")
end

local function dollars(amount)
  return string.format("$%.2f", amount)
end
-- The window is named from what the gateway reports rather than assumed, since
-- the co-op pins each member's reset to their billing day and a guest account
-- has a cap that never resets at all.
local function window_label(duration)
  if duration == nil then
    return "Allowance"
  elseif duration == MONTHLY_DURATION then
    return "Monthly allowance"
  end
  return "Allowance (" .. tostring(duration) .. ")"
end

maki.provider.register({
  slug = "inference-coop",
  display_name = "Inference Cooperative",
  codec = "openai",
  base_url = "https://gateway.inference.coop/v1",
  api_key_env = API_KEY_ENV,
  -- No output cap is declared, so no max_tokens is sent: the gateway's
  -- upstreams enforce their own limits, and no row states one.
  max_output_tokens = false,
  models = MODELS,

  -- /model/info also lists the alias routes (deepseek-flash-green) and the
  -- audio, embedding and image models. Anything the table does not list is
  -- filtered out, as we can't know what a foreign id describes. A price read
  -- here outranks the row's fallback; a row the gateway prices only partly
  -- keeps its fallback rather than a half price, and a row without a
  -- rateable pair still lists with the fallback untouched.
  list_models = function(ctx)
    local root = origin(ctx.base_url)
    if not root then
      return nil, "cannot read the gateway origin from " .. tostring(ctx.base_url)
    end
    local body, err = ctx.get_json(root .. MODEL_INFO_PATH)
    if err then
      return nil, err
    end
    return parse.models(body, function(entry)
      if type(entry) ~= "table" or type(entry.model_name) ~= "string" or KNOWN[entry.model_name] == nil then
        return nil
      end
      local info = type(entry.model_info) == "table" and entry.model_info or {}
      if type(info.mode) == "string" and info.mode ~= "chat" then
        return nil
      end
      local pricing = parse.pricing(
        parse.as_f64(info.input_cost_per_token),
        parse.as_f64(info.output_cost_per_token),
        parse.as_f64(info.cache_creation_input_token_cost),
        parse.as_f64(info.cache_read_input_token_cost)
      )
      return { id = entry.model_name, pricing = pricing }
    end)
  end,

  -- The co-op meters usage in dollars against a LiteLLM team, one team per
  -- member, and that single cap covers the chat and every API key, so the
  -- team's spend is the number a member sees on the dashboard. A key's own
  -- spend is lifetime for that key and says nothing about the allowance, so
  -- /key/info is only good for finding out which team the key belongs to.
  --
  -- The cap arrives as one figure: the monthly allowance plus any credit pack
  -- bought. The co-op keeps its non-expiring credit balance in its own portal
  -- database and only pushes the sum here, so the split between allowance and
  -- credits cannot be read from the gateway, and neither can the per-day or
  -- per-model history the dashboard charts: those routes are master-key only.
  fetch_usage = function(ctx)
    local root = origin(ctx.base_url)
    if not root then
      return nil, "cannot read the gateway origin from " .. tostring(ctx.base_url)
    end

    local key_info, err = ctx.get_json(root .. KEY_INFO_PATH)
    if err then
      return nil, err
    end
    local team_id = type(key_info) == "table" and type(key_info.info) == "table"
      and key_info.info.team_id or nil
    if type(team_id) ~= "string" then
      return nil, "the gateway reported no budget team for this key"
    end

    local team, terr = ctx.get_json(root .. TEAM_INFO_PATH .. "?team_id=" .. team_id)
    if terr then
      return nil, terr
    end
    local info = type(team) == "table" and team.team_info or nil
    if type(info) ~= "table" then
      return nil, "the gateway reported no budget for this key's team"
    end

    local spent = parse.as_f64(info.spend)
    local cap = parse.as_f64(info.max_budget)
    if spent == nil or cap == nil then
      return nil, "the gateway reported neither spend nor budget for this key's team"
    end

    local detail = dollars(spent) .. " spent of " .. dollars(cap)
    local percentage
    if cap > 0 then
      detail = detail .. ", " .. dollars(math.max(cap - spent, 0)) .. " left"
      percentage = math.min(100, math.max(0, math.floor(spent / cap * 100 + 0.5)))
    end

    return {
      limits = {
        {
          label = window_label(info.budget_duration),
          percentage = percentage,
          reset_at = info.budget_reset_at,
          detail = detail,
        },
      },
    }
  end,
})
