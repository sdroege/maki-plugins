-- Inference Cooperative (inference.coop), a member-governed gateway in
-- front of several providers. Model ids are `<provider>/<model>`, so a maki
-- spec reads `inference-coop/greenpt/glm-5.3`. The gateway has no model
-- metadata API beyond the OpenAI /models list, so the curated table is the
-- catalogue and `list_models` only drops an id the gateway no longer lists.
--
-- Model, context window, vision and rate data from the co-op's public docs:
-- https://git.inference.coop/co-op/docs/src/branch/main/guides/models.md (the
-- member-facing model list) and the LiteLLM config it names as the
-- authoritative pricing source,
-- https://git.inference.coop/code/litellm/src/branch/main/config.yaml.
-- Keep the table in sync with those when the co-op adds models or rates
-- change.

local parse = require("maki.provider_parse")

local MODELS_PATH = "/models"
local API_KEY_ENV = "INFERENCE_COOP_API_KEY"

-- The gateway is a LiteLLM proxy, and its management routes sit at the host
-- root rather than under the /v1 chat origin, so the usage calls below cannot
-- be built by appending a path to base_url.
local KEY_INFO_PATH = "/key/info"
local TEAM_INFO_PATH = "/team/info"

-- What the co-op calls a month: LiteLLM spells its allowance window this way.
local MONTHLY_DURATION = "30d"

-- Prices are per 1M tokens and are what the co-op pays the provider, not
-- what a member pays: members get a monthly allowance. Recorded anyway, so
-- maki's cost sums track co-op spend. The rows carry the co-op's own dollar
-- rates, and where a provider's own price list (GreenPT's at
-- https://docs.greenpt.ai/model-cards, Regolo's embedded in
-- https://regolo.ai/models) disagrees, the co-op's sources win: the rows
-- record what the co-op actually pays and what its spend records show. No
-- provider bills a cache write, so cache_write is 0.0, and an unlisted cache
-- read is 0.0 too. The co-op arrives at its dollar rates differently per
-- provider: greenpt/* rows are GreenPT's EUR list stored unconverted in its
-- config's dollar fields, so those rows match GreenPT's list by
-- construction, while regolo/* rows are Regolo's EUR list converted at
-- 1.16, and the rows record those converted dollar figures.
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
    -- moved: GreenPT's 1017 list, 0.36/1.45/0.04.
    prefixes = { "greenpt/deepseek-v4.1-flash" },
    tier = "medium",
    context_window = 1000000,
    supports_thinking = true,
    supports_vision = true,
    pricing = { input = 0.36, output = 1.45, cache_write = 0.0, cache_read = 0.04 },
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
    pricing = { input = 1.10, output = 4.40, cache_write = 0.0, cache_read = 0.275 },
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
    pricing = { input = 0.11, output = 0.44, cache_write = 0.0, cache_read = 0.022 },
    thinking_fields = efforts("off", "minimal", "low", "medium", "high"),
  },
  {
    -- Replaced PublicAI (removed 2026-10-16; billing never operational) as
    -- the co-op's Apertus provider: same open weights, EU ZDR + renewables.
    -- Context is the co-op's measured 262K; Regolo's catalogue advertises
    -- 30K input, which the gateway demonstrably exceeds. Prices are the
    -- co-op's dollar rates (Regolo's EUR list at 1.16).
    prefixes = { "regolo/apertus-70b" },
    tier = "medium",
    context_window = 262144,
    supports_vision = true,
    pricing = { input = 1.16, output = 3.944, cache_write = 0.0, cache_read = 0.0 },
  },
  {
    -- The gateway forces chat_template_kwargs: {enable_thinking: false} for
    -- this id (LiteLLM config); without it the reasoning phase eats the
    -- whole token budget and the content comes back empty.
    prefixes = { "regolo/qwen3.5-122b" },
    tier = "medium",
    context_window = 262144,
    supports_vision = true,
    pricing = { input = 0.696, output = 3.944, cache_write = 0.0, cache_read = 0.0 },
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
    pricing = { input = 0.20, output = 0.70, cache_write = 0.0, cache_read = 0.0 },
  },
  {
    -- Added 2026-11-13. Dense multimodal Gemma 4 (31B) with native function
    -- calling. Context is the co-op's measured 262K, not the config's 100K.
    prefixes = { "regolo/gemma4-31b" },
    tier = "medium",
    context_window = 262144,
    supports_vision = true,
    pricing = { input = 0.40, output = 0.60, cache_write = 0.0, cache_read = 0.0 },
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

  -- /models also lists the speech models (whisper, voxtral-tts). Anything
  -- the table does not list is filtered out as we can't know from the
  -- models list what kind of model is behind the id.
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
